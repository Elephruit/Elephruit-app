import Foundation

/// One thing that happened, on somebody's page.
///
/// ### Why the timeline is a projection and not a table
/// Nothing here is stored. A person's history *is* the notes, meetings, tasks, interactions, files,
/// and time entries that already point at them — so the timeline is a merge over links that exist,
/// and writing a row for every event would create a second copy that goes wrong the first time a
/// note is edited. This is the same argument `PeopleService` makes for `PersonContext`, applied to
/// the whole history rather than to its most recent line.
public struct PersonTimelineEntry: Sendable, Hashable, Identifiable {
    public var id: UUID

    /// What the underlying item is.
    public var kind: ItemKind

    public var title: String

    /// A short piece of the body, for a row that has room for one.
    public var excerpt: String?

    /// When it happened — a meeting's scheduled time, everything else's creation date.
    public var date: Date

    /// Where it came from: typed here, captured, imported, mirrored from a system store.
    public var source: SourceKind

    /// For an interaction, how the app came to know about it.
    public var provenance: InteractionProvenance?

    /// Which channel it happened through, when that is known.
    public var channel: ContactChannel?

    public var tagSlugs: [String]

    /// Everybody else involved.
    public var otherPeople: [PersonReference]

    /// Facts recorded from this entry, already confirmed.
    public var confirmedFactCount: Int

    /// Facts this entry suggests, still awaiting confirmation.
    public var suggestedFactCount: Int

    /// Whether the item is still open — a task, a promise.
    public var isOpen: Bool

    /// Whether the entry is a promise the user made.
    public var isPromise: Bool

    public var attachmentCount: Int

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        excerpt: String? = nil,
        date: Date,
        source: SourceKind = .manual,
        provenance: InteractionProvenance? = nil,
        channel: ContactChannel? = nil,
        tagSlugs: [String] = [],
        otherPeople: [PersonReference] = [],
        confirmedFactCount: Int = 0,
        suggestedFactCount: Int = 0,
        isOpen: Bool = false,
        isPromise: Bool = false,
        attachmentCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.excerpt = excerpt
        self.date = date
        self.source = source
        self.provenance = provenance
        self.channel = channel
        self.tagSlugs = tagSlugs
        self.otherPeople = otherPeople
        self.confirmedFactCount = confirmedFactCount
        self.suggestedFactCount = suggestedFactCount
        self.isOpen = isOpen
        self.isPromise = isPromise
        self.attachmentCount = attachmentCount
    }

    /// The line beneath the title: what kind of thing this is, where it came from, and who else.
    public var provenanceLine: String {
        var parts: [String] = []

        if let provenance {
            parts.append(provenance.phrase(channel: channel))
        } else {
            parts.append(kind.displayName.lowercased())
        }

        if source != .manual { parts.append(source.displayName.lowercased()) }
        if !otherPeople.isEmpty {
            parts.append("with " + otherPeople.map(\.name).joined(separator: ", "))
        }
        if attachmentCount > 0 {
            parts.append("\(attachmentCount) file\(attachmentCount == 1 ? "" : "s")")
        }

        return parts.joined(separator: " · ")
    }

    /// Whether this counts as having actually been in touch.
    ///
    /// The same rule as ``ContactMoment/isContact``, plus the provenance test that says a call the
    /// user *started* is not a call they had. Both rules live in one expression so a timeline row
    /// and a last-contact line cannot disagree.
    public var isContact: Bool {
        guard kind == .meeting || kind == .interaction else { return false }
        guard let provenance else { return true }
        return provenance.countsAsContact
    }
}

/// Somebody named on a timeline entry, thin enough to carry around.
public struct PersonReference: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Timeline entries grouped the way a person reads them.
public enum TimelineGrouping {
    /// Groups into months, newest first, with entries newest first inside each.
    public static func byMonth(
        _ entries: [PersonTimelineEntry],
        calendar: Calendar
    ) -> [(month: Date, entries: [PersonTimelineEntry])] {
        Dictionary(grouping: entries) { entry in
            calendar.date(from: calendar.dateComponents([.year, .month], from: entry.date)) ?? entry.date
        }
        .sorted { $0.key > $1.key }
        .map { (month: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
    }

    /// The filters a timeline offers, each naming the kinds it keeps.
    public enum Filter: String, Sendable, Hashable, CaseIterable, Identifiable {
        case everything
        case conversations
        case notes
        case commitments
        case files

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .everything: "Everything"
            case .conversations: "Conversations"
            case .notes: "Notes"
            case .commitments: "Tasks & promises"
            case .files: "Files"
            }
        }

        public func matches(_ entry: PersonTimelineEntry) -> Bool {
            switch self {
            case .everything: true
            case .conversations: entry.kind == .interaction || entry.kind == .meeting
            case .notes: entry.kind == .note || entry.kind == .dailyEntry || entry.kind == .decision
            case .commitments: entry.kind == .task || entry.isPromise
            case .files: entry.attachmentCount > 0
            }
        }
    }
}
