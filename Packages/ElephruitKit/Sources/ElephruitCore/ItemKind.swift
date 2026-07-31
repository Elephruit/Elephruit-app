/// What a piece of content *is*.
///
/// Everything the user can link, tag, search, favourite, archive, or trash is a
/// single `Item` entity discriminated by this kind. See
/// `docs/adr/0002-single-item-entity.md` for why one entity beats fourteen.
///
/// Stored as a raw `String` on the persisted row rather than as an enum column, so a
/// store written by a newer version — which may contain kinds this build has never
/// heard of — can be read without data loss. Unknown raw values surface as
/// ``ItemKind/reference`` for *display only* and are never written back, leaving the
/// original value intact on disk.
public enum ItemKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Free-form written content. The default kind.
    case note

    /// Something to be done. Carries status, dates, priority, and recurrence.
    case task

    /// A finite effort with an outcome. Contains tasks and notes.
    case project

    /// An ongoing responsibility with no completion date. Contains projects.
    case area

    /// A human being. Detail lives in a `PersonProfile` satellite.
    case person

    /// A company, team, or institution.
    case organization

    /// A recorded exchange with one or more people — a call, an email, a chat.
    case interaction

    /// A scheduled gathering. May carry an `EventReference` to a calendar event.
    case meeting

    /// A saved link with its own notes.
    case bookmark

    /// One day's log. Keyed by `dayKey` (`yyyy-MM-dd`).
    case dailyEntry

    /// A thought that is not yet a project or a task.
    case idea

    /// A desired outcome, usually spanning projects.
    case goal

    /// A choice made, with its reasoning, so it can be revisited.
    case decision

    /// Material kept because it may be needed, not because it is being worked on.
    case reference

    /// A named section inside a project — "Planning", "Items to buy".
    ///
    /// Project *organisation*, not content. A heading has a title, an order, and tasks beneath it,
    /// and nothing else: no body, no dates, no status, no tags. It never appears in search, the
    /// Inbox, or any content list, and it never counts as work.
    ///
    /// Modelled as a kind rather than as a string field on each task so that drag-to-reorder,
    /// archive, trash, and restore all work on a heading and its tasks with no new machinery.
    /// Adding a kind costs nothing at the storage layer — `kindRaw` is already a `String`, so this
    /// is not a schema change at all.
    case heading
}

// MARK: - Fields

/// Which of ``Item``'s fields a given ``ItemKind`` actually uses.
///
/// `Item` is a single wide row, so a note technically *has* a `dueAt` column. This
/// type is the one place that says which kinds legitimately use which fields;
/// `ItemValidator` enforces it on every save path. Adding a field to `Item` without
/// declaring its owning kinds here fails a test.
public struct ItemFields: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Long-form Markdown text.
    public static let body = ItemFields(rawValue: 1 << 0)
    /// Open / completed / cancelled lifecycle.
    public static let status = ItemFields(rawValue: 1 << 1)
    /// `dueAt`.
    public static let dueDate = ItemFields(rawValue: 1 << 2)
    /// `startAt`.
    public static let startDate = ItemFields(rawValue: 1 << 3)
    /// `deferUntil` — hidden from Today until this date.
    public static let deferDate = ItemFields(rawValue: 1 << 4)
    /// `recurrenceData`.
    public static let recurrence = ItemFields(rawValue: 1 << 5)
    /// `priority`.
    public static let priority = ItemFields(rawValue: 1 << 6)
    /// May contain other items via `children`.
    public static let children = ItemFields(rawValue: 1 << 7)
    /// `symbolName` and `colorName` are meaningful and user-editable.
    public static let appearance = ItemFields(rawValue: 1 << 8)
    /// `dayKey`.
    public static let dayKey = ItemFields(rawValue: 1 << 9)
    /// `sourceURLString` is the point of the item, not incidental provenance.
    public static let url = ItemFields(rawValue: 1 << 10)
    /// Has a `PersonProfile` satellite.
    public static let personProfile = ItemFields(rawValue: 1 << 11)
    /// Has an `EventReference` satellite.
    public static let eventReference = ItemFields(rawValue: 1 << 12)
    /// May carry tags. Everything except a heading, which is structure rather than content.
    public static let tags = ItemFields(rawValue: 1 << 13)

    /// Fields every kind supports, and which therefore need no declaration:
    /// title, timestamps, tags, links, attachments, flags, sort order, metadata.
    public static let none: ItemFields = []
}

extension ItemKind {
    /// The fields this kind uses. Anything not listed here must be `nil`/default on
    /// a saved item of this kind.
    public var supportedFields: ItemFields {
        switch self {
        case .note, .idea, .reference:
            [.body, .tags]

        case .task:
            [.body, .tags, .status, .dueDate, .startDate, .deferDate, .recurrence, .priority, .children]

        case .project:
            [.body, .tags, .status, .dueDate, .startDate, .deferDate, .priority, .children, .appearance]

        case .area:
            [.body, .tags, .children, .appearance]

        case .person:
            [.body, .tags, .appearance, .personProfile]

        case .organization:
            [.body, .tags, .appearance, .url]

        case .interaction:
            [.body, .tags, .startDate]

        case .meeting:
            [.body, .tags, .startDate, .children, .eventReference]

        case .bookmark:
            [.body, .tags, .url]

        case .dailyEntry:
            [.body, .tags, .dayKey, .children]

        case .goal:
            [.body, .tags, .status, .dueDate, .startDate, .children, .appearance]

        case .decision:
            [.body, .tags, .startDate]

        case .heading:
            // A title, an order, and tasks. Nothing else — deliberately.
            [.children]
        }
    }

    /// Whether this kind participates in the open/completed lifecycle.
    public var supportsStatus: Bool {
        supportedFields.contains(.status)
    }

    /// Whether an item of `childKind` may sit beneath an item of this kind.
    ///
    /// Containment is **the work-breakdown structure, and nothing else**:
    ///
    /// ```
    /// Area ▸ Project, Goal        Project ▸ Heading, Task
    /// Goal ▸ Project              Heading ▸ Task            Task ▸ Task
    /// ```
    ///
    /// Everything else — notes, bookmarks, meetings, interactions, daily entries — contains nothing
    /// and is contained by nothing. It associates by *link* instead.
    ///
    /// The reason is ownership. Containment implies exactly one owner and cascades on archive and
    /// trash. That is right for a task inside a project and wrong for a note: a note can relate to
    /// three projects at once, and archiving one of them should not sweep the note away with it.
    /// Making that a link rather than a parent gives every kind exactly one answer to "where does
    /// this live?", and it merges cleanly under future sync where a single `parent` would not.
    public func canContain(_ childKind: ItemKind) -> Bool {
        guard supportedFields.contains(.children) else { return false }

        switch self {
        case .area:
            return childKind == .project || childKind == .goal
        case .goal:
            return childKind == .project
        case .project:
            return childKind == .heading || childKind == .task
        case .heading:
            return childKind == .task
        case .task:
            return childKind == .task
        default:
            return false
        }
    }

    /// Whether this kind is a container in the work-breakdown structure.
    ///
    /// Used by the migration to tell "was contained, should now be linked" from "was never
    /// contained".
    public var isWorkBreakdownContainer: Bool {
        switch self {
        case .area, .goal, .project, .heading, .task: true
        default: false
        }
    }

    /// The kinds milestone 1 ships dedicated UI for. The rest exist in the schema so
    /// that later phases add views rather than migrations.
    public static let shippingInMilestoneOne: [ItemKind] = [
        .note, .task, .project, .area, .bookmark, .dailyEntry,
    ]

    /// Whether an unfiled item of this kind belongs in the Inbox.
    ///
    /// Inbox means *unprocessed*, not *unparented*. A project with no area above it is not an
    /// unprocessed capture — it is a container that happens to sit at the top level, and listing it
    /// beside a half-formed thought is what made the Inbox useless. Containers organise; they are
    /// never themselves the thing awaiting triage.
    public var appearsInInbox: Bool {
        switch self {
        case .project, .area, .goal:
            // Containers.
            false
        case .person, .organization:
            // These accumulate over time and are never "processed", so they would fill the Inbox
            // permanently and never leave it.
            false
        case .dailyEntry:
            // Created by the calendar, not captured by the user.
            false
        case .heading:
            // Structure, not content.
            false
        default:
            true
        }
    }

    /// Whether items of this kind belong in ordinary content views — search results, the Inbox, the
    /// Notes and Tasks lists, tag views.
    ///
    /// `false` only for ``ItemKind/heading``. A heading is scaffolding for a project; surfacing it
    /// beside notes and tasks would be like listing a folder among its own files. Views that
    /// legitimately need it — a project's own contents, Archive, Trash, export — opt in explicitly
    /// via `ItemQuery.includesNonContentKinds`, and search matches it when `type:heading` names it.
    public var participatesInContentViews: Bool {
        self != .heading
    }

    /// Whether completing items of this kind constitutes progress.
    ///
    /// A heading is never work, so a project whose only remaining children are empty headings is
    /// finished.
    public var countsAsWork: Bool {
        supportsStatus
    }
}

// MARK: - Presentation

extension ItemKind {
    /// SF Symbol representing this kind. Chosen for legibility at 13pt in a list row.
    public var symbolName: String {
        switch self {
        case .note: "note.text"
        case .task: "checkmark.circle"
        case .project: "square.stack.3d.up"
        case .area: "square.grid.2x2"
        case .person: "person"
        case .organization: "building.2"
        case .interaction: "bubble.left.and.bubble.right"
        case .meeting: "calendar"
        case .bookmark: "bookmark"
        case .dailyEntry: "sun.horizon"
        case .idea: "lightbulb"
        case .goal: "target"
        case .decision: "arrow.triangle.branch"
        case .reference: "books.vertical"
        case .heading: "text.append"
        }
    }

    /// Singular display name. Not localised in v1; routed through one accessor so
    /// localisation is a single change.
    public var displayName: String {
        switch self {
        case .note: "Note"
        case .task: "Task"
        case .project: "Project"
        case .area: "Area"
        case .person: "Person"
        case .organization: "Organisation"
        case .interaction: "Interaction"
        case .meeting: "Meeting"
        case .bookmark: "Bookmark"
        case .dailyEntry: "Daily Entry"
        case .idea: "Idea"
        case .goal: "Goal"
        case .decision: "Decision"
        case .reference: "Reference"
        case .heading: "Heading"
        }
    }

    /// Plural display name, for section headers and counts.
    public var pluralDisplayName: String {
        switch self {
        case .person: "People"
        case .dailyEntry: "Daily Entries"
        default: displayName + "s"
        }
    }

    /// The token users type in search to filter by this kind — `type:task`.
    public var searchToken: String { rawValue }
}
