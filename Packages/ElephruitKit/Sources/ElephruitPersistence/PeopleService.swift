import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Everything about people, computed from the links that already exist.
///
/// No new entity and no new stored state: a relationship's history *is* the notes, meetings and
/// tasks that mention someone. Recording "last contacted" separately would be a second source of
/// truth that goes stale the first time a note is edited.
@MainActor
public final class PeopleService {
    private let items: any ItemRepository
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, dateProvider: any DateProvider) {
        self.items = items
        self.dateProvider = dateProvider
    }

    /// What is true about one person right now.
    public func context(for person: Item) -> PersonContext {
        var moments: [ContactMoment] = []
        var openItemIDs: [UUID] = []
        var seen = Set<UUID>()

        for link in person.incomingLinks {
            guard let source = link.source, source.deletedAt == nil, seen.insert(source.id).inserted else {
                continue
            }

            if source.kind == .task, source.status == .open {
                openItemIDs.append(source.id)
            }

            moments.append(ContactMoment(
                id: source.id,
                kind: source.kind,
                title: source.displayTitle,
                date: Self.contactDate(of: source)
            ))
        }

        // Outgoing too: a meeting links *to* its attendees, so a person's meetings arrive this way.
        for link in person.outgoingLinks {
            guard let target = link.target, target.deletedAt == nil, seen.insert(target.id).inserted else {
                continue
            }
            moments.append(ContactMoment(
                id: target.id,
                kind: target.kind,
                title: target.displayTitle,
                date: Self.contactDate(of: target)
            ))
        }

        let now = dateProvider.now
        let past = moments.filter { $0.date <= now }.sorted { $0.date > $1.date }
        let future = moments.filter { $0.date > now }.sorted { $0.date < $1.date }

        return PersonContext(
            personID: person.id,
            displayName: person.displayTitle,
            // Only meetings and recorded conversations count as contact. See `ContactMoment.isContact`.
            lastContact: past.first(where: \.isContact),
            lastMention: past.first,
            nextContact: future.first(where: \.isContact),
            openItemIDs: openItemIDs,
            mentionCount: moments.count
        )
    }

    /// When a piece of content counts as contact.
    ///
    /// A meeting's *scheduled* time, because that is when it happened or will; anything else uses
    /// when it was written. Using `updatedAt` throughout would make re-reading an old note look like
    /// having spoken to someone.
    static func contactDate(of item: Item) -> Date {
        if item.kind == .meeting || item.kind == .interaction {
            return item.startAt ?? item.dueAt ?? item.createdAt
        }
        return item.createdAt
    }

    /// Every person, with their context.
    public func allContexts() throws(AppError) -> [PersonContext] {
        var query = ItemQuery()
        query.kinds = [.person, .organization]
        query.scope = .active

        return try items.items(matching: query).map(context(for:))
    }

    /// People worth getting back to, most overdue first.
    ///
    /// Returns nothing unless asked — the caller decides whether the feature is on.
    public func followUpSuggestions(thresholdDays: Int) throws(AppError) -> [FollowUpSuggestion] {
        FollowUpPolicy.suggestions(
            from: try allContexts(),
            thresholdDays: thresholdDays,
            using: dateProvider
        )
    }

    // MARK: - Interactions

    /// Records that a conversation happened.
    ///
    /// An `interaction` is its own kind rather than a note with a tag, because it answers a different
    /// question — *when did we last speak* — and that answer has to be findable without reading
    /// anything.
    @discardableResult
    public func recordInteraction(
        with person: Item,
        summary: String,
        at date: Date? = nil,
        notes: String = ""
    ) throws(AppError) -> Item {
        var draft = ItemDraft(kind: .interaction, title: summary)
        draft.body = notes
        draft.startAt = date ?? dateProvider.now

        let interaction = try items.create(draft)
        try items.link(interaction, to: person, kind: .mentions)
        return interaction
    }

    // MARK: - Daily entries

    /// The daily entry for a date, created only if asked for.
    ///
    /// Keyed on ``DayKey`` rather than on a date range, so "today's entry" is an equality test and
    /// two entries for one day cannot quietly coexist.
    public func dailyEntry(for date: Date, creatingIfNeeded: Bool) throws(AppError) -> Item? {
        let key = dateProvider.dayKey(for: date)

        var query = ItemQuery()
        query.kinds = [.dailyEntry]
        query.dayKey = key
        query.scope = .active

        if let existing = try items.items(matching: query).first(where: { $0.dayKey == key }) {
            return existing
        }

        guard creatingIfNeeded else { return nil }

        var draft = ItemDraft(kind: .dailyEntry, title: Self.dailyTitle(for: date, using: dateProvider))
        draft.dayKey = key
        return try items.create(draft)
    }

    static func dailyTitle(for date: Date, using dateProvider: any DateProvider) -> String {
        date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year()
                .locale(dateProvider.calendar.locale ?? .current)
        )
    }
}
