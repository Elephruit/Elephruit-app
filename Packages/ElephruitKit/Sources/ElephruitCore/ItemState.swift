import Foundation

/// Where an item sits in the open/completed lifecycle.
///
/// Kinds that do not support status (a note, a bookmark) are always ``none``. The
/// invariant `status == .completed ⇔ completedAt != nil` is enforced on every save
/// path and covered by a test.
public enum ItemStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not applicable to this kind, or not yet started tracking.
    case none

    /// Actionable and incomplete.
    case open

    /// Done.
    case completed

    /// Deliberately abandoned. Distinct from deleted: the record of *not* doing it is
    /// worth keeping.
    case cancelled

    /// Whether the item still asks something of the user.
    public var isActionable: Bool { self == .open }

    /// Whether the item has reached a terminal state, either way.
    public var isResolved: Bool { self == .completed || self == .cancelled }

    public var displayName: String {
        switch self {
        case .none: "No Status"
        case .open: "Open"
        case .completed: "Completed"
        case .cancelled: "Canceled"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: "circle.dotted"
        case .open: "circle"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

/// How much a task matters, relative to its peers.
///
/// Four levels deliberately: enough to sort by, few enough that the user does not
/// spend time on the choice. ``normal`` is the default and is rendered without
/// decoration, so priority is only ever visible when it is meaningful.
public enum Priority: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case low
    case normal
    case high

    /// Sort weight. Higher sorts first.
    public var weight: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.weight < rhs.weight
    }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    /// `nil` for ``normal`` — the default carries no visual weight.
    public var symbolName: String? {
        switch self {
        case .low: "arrow.down"
        case .normal: nil
        case .high: "exclamationmark"
        }
    }
}

/// The nature of a link between two items.
///
/// Links are an explicit entity rather than a bare relationship because they carry
/// their own meaning and metadata. See `docs/04-domain-model.md`.
public enum LinkKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Written by the user as `[[Title]]` inside a body. Owned by the text: if the
    /// text changes, the link changes.
    case wiki

    /// An explicit association made through the inspector. Owned by the user.
    case related

    /// This item mentions that person or organisation.
    case mentions

    /// That person took part in this interaction or meeting.
    case participant

    /// This item cannot proceed until that one is resolved.
    case blockedBy

    /// This task is waiting on that person.
    ///
    /// Its own kind rather than a column on the task, so the person's page, their timeline, and
    /// their meeting brief all find it by the traversal they already do. A stored `waitingForPersonID`
    /// would be a second place the same fact lived, and the first thing to go stale when somebody is
    /// merged into a duplicate.
    case waitingOn

    /// This task is something the user owes that person.
    ///
    /// The mirror of ``waitingOn``: one is a promise made, the other a promise waited on, and a
    /// relationship needs both halves to be worth anything.
    case promisedTo

    /// Deliberately filed with a project or area.
    ///
    /// Distinct from ``LinkKind/wiki`` and ``LinkKind/related`` because the project workspace shows
    /// them separately: *Project notes* are what you filed here, *Related notes* merely mention it.
    /// The user never sees either phrase as a link type — only as those two headings.
    case filedUnder

    /// This item is the next occurrence of that recurring series.
    case recurrenceSeries

    /// This item is a conflicted copy preserved from a sync merge.
    case conflictCopy

    /// That person is the one doing this work.
    ///
    /// A link rather than an `assigneeID` column for the same reason ``waitingOn`` is: the person's
    /// page, their workload, and their meeting brief all find it by the traversal they already do,
    /// and a stored identifier would be a second place the same fact lived — the first thing to go
    /// stale when somebody is merged into a duplicate.
    ///
    /// **At most one may exist per item**, and that is enforced in `WorkItemService.assign` rather
    /// than in the schema, because the schema cannot express it and a store that has somehow
    /// acquired two must still open.
    case assignee

    /// This item reports the same defect as that one.
    ///
    /// The only one of the four that appears in backlinks, because it is the only one where the
    /// *other* item's page genuinely wants to say "two people reported this".
    case duplicateOf

    /// This work is aimed at that milestone.
    case targetsMilestone

    /// This work is part of that release — the version it lands in, or for a bug, the version it
    /// was found in.
    case relatesToRelease

    /// Whether the link's existence is derived from body text and therefore
    /// regenerated on every save, rather than edited directly by the user.
    public var isDerivedFromText: Bool { self == .wiki }

    /// Whether a link of this kind should appear in the Backlinks section.
    public var appearsInBacklinks: Bool {
        switch self {
        case .wiki, .related, .mentions, .participant, .blockedBy, .filedUnder, .waitingOn, .promisedTo: true
        case .duplicateOf: true
        case .recurrenceSeries, .conflictCopy: false
        // Drawn where they mean something — on the card, in the workload lane, on the roadmap — and
        // listing them again under Backlinks would say "this bug is assigned to Sam" in the section
        // meant for things that refer to it.
        case .assignee, .targetsMilestone, .relatesToRelease: false
        }
    }

    public var displayName: String {
        switch self {
        case .wiki: "Link"
        case .filedUnder: "Filed under"
        case .related: "Related"
        case .mentions: "Mentions"
        case .participant: "Participant"
        case .blockedBy: "Blocked By"
        case .waitingOn: "Waiting on"
        case .promisedTo: "Reminder for"
        case .recurrenceSeries: "Recurrence"
        case .conflictCopy: "Conflicted Copy"
        case .assignee: "Assigned to"
        case .duplicateOf: "Duplicate of"
        case .targetsMilestone: "Milestone"
        case .relatesToRelease: "Release"
        }
    }
}

/// Where an item came from.
///
/// Provenance is kept because "did I write this or did it arrive from somewhere?" is
/// a question the user will ask, and because import needs to be reversible.
public enum SourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Created in the app in the normal way.
    case manual

    /// Created through Quick Capture.
    case quickCapture

    /// Captured from a web page by the Safari extension.
    case webClip

    /// Created by importing a Markdown file.
    case markdownImport

    /// Created by importing a versioned JSON archive.
    case archiveImport

    /// Created by importing some other format; the importer names itself in
    /// ``ItemSource/identifier``.
    case otherImport

    /// Mirrored from a system store (Contacts, Calendar) that remains authoritative.
    case systemStore

    /// Generated by the app — a recurring task's next occurrence, a conflicted copy.
    case generated

    public var displayName: String {
        switch self {
        case .manual: "Created here"
        case .quickCapture: "Quick Capture"
        case .webClip: "Web clip"
        case .markdownImport: "Markdown import"
        case .archiveImport: "Archive import"
        case .otherImport: "Import"
        case .systemStore: "System"
        case .generated: "Generated"
        }
    }
}

/// Full provenance for an item: what made it, and what it was called there.
public struct ItemSource: Sendable, Hashable, Codable {
    public var kind: SourceKind

    /// The originating URL, for bookmarks and web-derived content.
    public var url: URL?

    /// An identifier meaningful to whatever created this — an importer name, a source
    /// file path, an external record ID.
    public var identifier: String?

    public init(kind: SourceKind, url: URL? = nil, identifier: String? = nil) {
        self.kind = kind
        self.url = url
        self.identifier = identifier
    }

    public static let manual = ItemSource(kind: .manual)
    public static let quickCapture = ItemSource(kind: .quickCapture)
}

/// A user-defined field value.
///
/// The escape hatch for metadata the app does not model. Deliberately a closed set of
/// primitives — no nesting, no arrays — because anything richer belongs in the schema
/// rather than in an untyped bag. App logic never reads these.
public enum MetadataValue: Sendable, Hashable, Codable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case date(Date)

    /// A display string, for the inspector's generic field renderer.
    public func displayString(formatting formatter: (Date) -> String) -> String {
        switch self {
        case .text(let value): value
        case .number(let value): value.formatted(.number)
        case .flag(let value): value ? "Yes" : "No"
        case .date(let value): formatter(value)
        }
    }

    /// A stable string for *comparison* — filter rules, grouping keys, saved views.
    ///
    /// Deliberately not ``displayString(formatting:)``. That one is localised and grouped, so a
    /// custom field holding `1000` renders as `"1,000"`, and a saved filter looking for `1000` stops
    /// matching it — in a different locale, it stops matching something else. A rule that silently
    /// finds nothing is worse than one that refuses, because nobody goes looking for the reason.
    ///
    /// Dates use ISO-8601 for the same reason: it sorts as text, which is what grouping needs.
    public var comparableString: String {
        switch self {
        case .text(let value): value
        case .number(let value): String(value)
        case .flag(let value): value ? "true" : "false"
        case .date(let value): ISO8601DateFormatter().string(from: value)
        }
    }
}
