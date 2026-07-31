import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Everything Elephruit knows about one calendar event that the calendar itself does not.
///
/// A read-only projection, assembled from links that already exist. Nothing here is stored twice.
public struct EventAnnotation: Sendable, Hashable {
    public var identity: EventIdentity

    /// The meeting item that carries the links, when one has been created.
    ///
    /// `nil` for the overwhelming majority of events, which nobody has attached anything to. That is
    /// the point of creating it lazily: a year of calendar entries costs nothing until somebody
    /// writes something about one of them.
    public var meetingItemID: UUID?

    public var personIDs: [UUID]
    public var noteIDs: [UUID]
    public var projectIDs: [UUID]
    public var attachmentCount: Int

    /// What was written before the meeting.
    public var preparationNotes: String

    /// What was written after it.
    public var debriefNotes: String

    public var isEmpty: Bool {
        personIDs.isEmpty && noteIDs.isEmpty && projectIDs.isEmpty
            && attachmentCount == 0 && preparationNotes.isEmpty && debriefNotes.isEmpty
    }

    public init(
        identity: EventIdentity,
        meetingItemID: UUID? = nil,
        personIDs: [UUID] = [],
        noteIDs: [UUID] = [],
        projectIDs: [UUID] = [],
        attachmentCount: Int = 0,
        preparationNotes: String = "",
        debriefNotes: String = ""
    ) {
        self.identity = identity
        self.meetingItemID = meetingItemID
        self.personIDs = personIDs
        self.noteIDs = noteIDs
        self.projectIDs = projectIDs
        self.attachmentCount = attachmentCount
        self.preparationNotes = preparationNotes
        self.debriefNotes = debriefNotes
    }
}

/// Links between calendar events and the rest of the library.
///
/// ### Why an event's links are an `Item`, not a table of their own
/// A meeting somebody has attached people, notes, a project, and a file to is exactly what
/// ``ItemKind/meeting`` already describes, and the store has carried an ``EventReference`` on it
/// since milestone 1. Reusing that shape means linking a person is an ``ItemLink``, attaching a file
/// is an ``Attachment``, the debrief is the item's body, and every one of those is already indexed,
/// exported, trashed, restored, and reconciled when two people are merged.
///
/// A parallel table would have needed its own answer to all six of those, and standing rule R5 asks
/// for proof that the existing shape cannot do the job before a new one is added. There is none.
///
/// ### Created lazily, and that matters
/// The meeting item does not exist until somebody links something. A year of somebody's calendar is
/// several thousand events; writing a row for each one so that eleven of them can have notes would
/// make the store larger than the library it belongs to, and would fill search with meetings nobody
/// wrote anything about.
///
/// ### Nothing here reaches the calendar
/// Every value in this file lives in Elephruit's own store. There is no path from a linked person to
/// an `EventDraft`, which is what makes "private context stays local" structural — see
/// `CalendarWriteSafetyTests`.
@MainActor
public final class EventAnnotationService {
    private let context: ModelContext
    private let items: any ItemRepository
    private let dateProvider: any DateProvider

    /// Marks the paragraph of a meeting's body that holds what was written beforehand.
    ///
    /// A marker in the body rather than two columns, because a meeting's notes are one document a
    /// person reads top to bottom, and splitting them into "prep" and "debrief" fields would mean a
    /// sentence written at the wrong moment lands in the wrong box forever.
    static let preparationHeading = "## Before"
    static let debriefHeading = "## After"

    public init(context: ModelContext, items: any ItemRepository, dateProvider: any DateProvider) {
        self.context = context
        self.items = items
        self.dateProvider = dateProvider
    }

    // MARK: - Reading

    /// What is attached to an event, without creating anything.
    public func annotation(for identity: EventIdentity) throws(AppError) -> EventAnnotation {
        guard let meeting = try meetingItem(for: identity) else {
            return EventAnnotation(identity: identity)
        }
        return annotation(of: meeting, identity: identity)
    }

    /// Annotations for a whole window, in one pass.
    ///
    /// The list and grid views ask "does this event have anything attached" once per event, and doing
    /// that as one fetch each is how a month view becomes a thousand queries. One fetch of every
    /// meeting item, keyed by identity, is the same answer for the price of one.
    public func annotations(for identities: [EventIdentity]) throws(AppError) -> [String: EventAnnotation] {
        let wanted = Set(identities.map { $0.storageKey })
        guard !wanted.isEmpty else { return [:] }

        var result: [String: EventAnnotation] = [:]
        for meeting in try allMeetingItems() {
            guard let reference = meeting.eventReference else { continue }
            guard wanted.contains(reference.identityKey), let identity = reference.identity else { continue }
            result[reference.identityKey] = annotation(of: meeting, identity: identity)
        }
        return result
    }

    /// Which identities in a window have anything attached at all.
    public func annotatedKeys(among identities: [EventIdentity]) throws(AppError) -> Set<String> {
        Set(try annotations(for: identities).filter { !$0.value.isEmpty }.keys)
    }

    private func annotation(of meeting: Item, identity: EventIdentity) -> EventAnnotation {
        var personIDs: [UUID] = []
        var noteIDs: [UUID] = []
        var projectIDs: [UUID] = []

        for link in meeting.outgoingLinks {
            guard let target = link.target, target.deletedAt == nil else { continue }
            switch target.kind {
            case .person where link.kind == .participant: personIDs.append(target.id)
            case .project, .area: projectIDs.append(target.id)
            default: noteIDs.append(target.id)
            }
        }

        // Notes written *about* the meeting point at it rather than the other way round, which is
        // the direction a wiki link naturally runs.
        for link in meeting.incomingLinks {
            guard let source = link.source, source.deletedAt == nil else { continue }
            guard source.kind != .person, !noteIDs.contains(source.id) else { continue }
            noteIDs.append(source.id)
        }

        let sections = Self.split(body: meeting.body)

        return EventAnnotation(
            identity: identity,
            meetingItemID: meeting.id,
            personIDs: personIDs,
            noteIDs: noteIDs,
            projectIDs: projectIDs,
            attachmentCount: meeting.attachments.count,
            preparationNotes: sections.preparation,
            debriefNotes: sections.debrief
        )
    }

    // MARK: - The meeting item

    /// The meeting item for an event, if one exists.
    public func meetingItem(for identity: EventIdentity) throws(AppError) -> Item? {
        let key = identity.storageKey
        return try allMeetingItems().first { $0.eventReference?.identityKey == key }
    }

    /// The meeting item for an event, creating it if this is the first thing attached.
    ///
    /// The cached title and times are refreshed on every call, so the item stays readable when the
    /// calendar is switched off or permission is revoked.
    @discardableResult
    public func meetingItem(
        for event: CalendarEventSummary,
        creatingIfNeeded: Bool = true
    ) throws(AppError) -> Item? {
        if let existing = try meetingItem(for: event.identity) {
            try items.update(existing) { item in
                item.eventReference?.absorb(event, at: dateProvider.now)
            }
            return existing
        }

        guard creatingIfNeeded else { return nil }

        let created = try items.create(ItemDraft(kind: .meeting, title: event.displayTitle))
        try items.update(created) { item in
            let reference = EventReference(
                identityKey: event.identity.storageKey,
                cachedTitle: event.title,
                startAt: event.startAt,
                endAt: event.endAt
            )
            reference.absorb(event, at: dateProvider.now)
            reference.item = item
            item.eventReference = reference

            // `startAt` and nothing else. A meeting's supported fields deliberately exclude a due
            // date — an event has an end, not a deadline — and `ItemValidator` refuses one, which is
            // how this was caught rather than shipped as a field nobody could see and nothing read.
            // The end lives on the reference, where the calendar's own answer belongs.
            item.startAt = event.startAt
        }
        return created
    }

    private func allMeetingItems() throws(AppError) -> [Item] {
        // Fetched by kind through the repository rather than by a predicate on `eventReference`,
        // because SwiftData cannot translate a comparison across a to-one relationship into SQL and
        // the fallback is a scan of the whole table either way.
        var query = ItemQuery()
        query.scope = .active
        query.kinds = [.meeting]
        query.includesNonContentKinds = true
        return try items.items(matching: query)
    }

    // MARK: - Linking

    /// Links a person to an event, creating the meeting item if this is the first link.
    @discardableResult
    public func link(person: Item, to event: CalendarEventSummary) throws(AppError) -> Item? {
        guard let meeting = try meetingItem(for: event) else { return nil }
        try items.link(meeting, to: person, kind: .participant)
        return meeting
    }

    public func unlink(person: Item, from identity: EventIdentity) throws(AppError) {
        guard let meeting = try meetingItem(for: identity) else { return }

        for link in meeting.outgoingLinks
        where link.kind == .participant && link.target?.id == person.id {
            context.delete(link)
        }
        try save()
    }

    /// Files an event under a project or area.
    @discardableResult
    public func file(_ event: CalendarEventSummary, under container: Item?) throws(AppError) -> Item? {
        guard let meeting = try meetingItem(for: event) else { return nil }
        try items.fileItem(meeting, under: container)
        return meeting
    }

    /// Links an existing note to an event.
    @discardableResult
    public func link(note: Item, to event: CalendarEventSummary) throws(AppError) -> Item? {
        guard let meeting = try meetingItem(for: event) else { return nil }
        try items.link(meeting, to: note, kind: .related)
        return meeting
    }

    // MARK: - Notes

    /// Replaces what was written before the meeting.
    public func setPreparationNotes(_ text: String, for event: CalendarEventSummary) throws(AppError) {
        try setSection(preparation: text, debrief: nil, for: event)
    }

    /// Replaces what was written after it.
    public func setDebriefNotes(_ text: String, for event: CalendarEventSummary) throws(AppError) {
        try setSection(preparation: nil, debrief: text, for: event)
    }

    private func setSection(
        preparation: String?,
        debrief: String?,
        for event: CalendarEventSummary
    ) throws(AppError) {
        guard let meeting = try meetingItem(for: event) else { return }

        let existing = Self.split(body: meeting.body)
        let combined = Self.compose(
            preamble: existing.preamble,
            preparation: preparation ?? existing.preparation,
            debrief: debrief ?? existing.debrief
        )

        try items.update(meeting) { item in
            item.body = combined
        }
        try items.reconcileWikiLinks(for: meeting)
    }

    /// Splits a meeting's body into the part before the headings and the two sections.
    ///
    /// Text written before either heading is kept as a preamble rather than being swallowed: a body
    /// that predates this feature, or one somebody typed into freehand, must not lose its first
    /// paragraph the moment a prep note is added.
    public static func split(body: String) -> (preamble: String, preparation: String, debrief: String) {
        var preamble: [String] = []
        var preparation: [String] = []
        var debrief: [String] = []
        var section = 0

        for line in body.components(separatedBy: .newlines) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case preparationHeading:
                section = 1
            case debriefHeading:
                section = 2
            default:
                switch section {
                case 1: preparation.append(line)
                case 2: debrief.append(line)
                default: preamble.append(line)
                }
            }
        }

        return (
            preamble: preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            preparation: preparation.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            debrief: debrief.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func compose(preamble: String, preparation: String, debrief: String) -> String {
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(preamble) }
        if !preparation.isEmpty { parts.append("\(preparationHeading)\n\(preparation)") }
        if !debrief.isEmpty { parts.append("\(debriefHeading)\n\(debrief)") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Follow-ups

    /// Creates a task in the Tasks module about this meeting.
    ///
    /// **The task never appears in a calendar view.** It is an ordinary task in the ordinary place,
    /// linked to the meeting so that opening either shows the other. A calendar that lists its own
    /// follow-ups turns into a to-do list with dates, which is a different and worse product.
    @discardableResult
    public func createFollowUp(
        title: String,
        dueAt: Date?,
        for event: CalendarEventSummary,
        aboutPeople people: [Item] = []
    ) throws(AppError) -> Item {
        let task = try items.create(ItemDraft(kind: .task, title: title))

        try items.update(task) { item in
            item.dueAt = dueAt
            item.status = .open
        }

        if let meeting = try meetingItem(for: event) {
            try items.link(task, to: meeting, kind: .related)
        }
        for person in people {
            try items.link(task, to: person, kind: .mentions)
        }

        return task
    }

    // MARK: - History

    /// Past meetings with the same people, most recent first.
    ///
    /// The question somebody actually has walking into a room: *when did I last see these people, and
    /// what happened*. Answered by traversing links already in memory rather than by a query, because
    /// the people are already loaded and their meetings are a link away.
    public func priorMeetings(
        withPeople personIDs: [UUID],
        before instant: Date,
        limit: Int = 8
    ) throws(AppError) -> [Item] {
        guard !personIDs.isEmpty else { return [] }
        let wanted = Set(personIDs)

        let meetings = try allMeetingItems().filter { meeting in
            guard let start = meeting.eventReference?.startAt, start < instant else { return false }
            let participants = meeting.outgoingLinks
                .filter { $0.kind == .participant }
                .compactMap { $0.target?.id }
            return !wanted.isDisjoint(with: participants)
        }

        return meetings
            .sorted { ($0.eventReference?.startAt ?? .distantPast) > ($1.eventReference?.startAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Meeting items whose event no longer resolves, so the interface can say so rather than showing
    /// a row that goes nowhere.
    public func lostMeetings() throws(AppError) -> [Item] {
        try allMeetingItems().filter { $0.eventReference?.isLost == true }
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "event links", reason: error.localizedDescription)
        }
    }
}
