import Foundation

// MARK: - Workflow stages

/// What a board column *means*, independent of what it is called.
///
/// This is the join between the app's two state axes, and the reason they can stay apart.
///
/// ``ItemStatus`` is the lifecycle. It is what Today reads, what counts count, what `taskProgress()`
/// divides by, and what the Logbook is made of. It has three values and it must keep having three
/// values, because every one of those readers would have to learn any new one.
///
/// A **workflow stage** is a second axis, owned by a single project and named by whoever set it up:
/// Triage, Ready, In progress, In review, Done. Boards need that freedom — a board whose columns
/// were the status could only ever have three of them — but a status derived from column *names*
/// would mean that adding a column called "Blocked" changed what "open" means everywhere in the app.
///
/// So a stage declares a category instead. The category is the only thing outside the board that
/// reads a stage, and it is what turns a drag into a status change: dropping work into a terminal
/// category resolves it, and dragging it back out reopens it. Moving between two *open* categories
/// writes nothing at all — both mean open, and stamping `updatedAt` on every drag would make the
/// board rewrite history for a gesture that changed no facts.
public enum WorkflowStageCategory: String, Codable, Sendable, Hashable, CaseIterable {
    /// Known about, not started, not committed to.
    case backlog

    /// Being worked on. Everything between picked-up and finished — in progress, in review, waiting
    /// on a build — because the distinctions there are exactly what column names are for.
    case active

    /// Finished successfully.
    case done

    /// Abandoned. Not a failure state: deciding not to do something is a legitimate ending, and a
    /// board with nowhere to put that decision gets a column called "Done" full of things nobody did.
    case cancelled

    /// The lifecycle status that landing in this category writes, or `nil` if it writes nothing.
    ///
    /// `nil` for both open categories, which is the whole point. Backlog and active are the same
    /// answer to "is this outstanding?", so moving between them is a board fact and not a lifecycle
    /// one.
    public var resolvedStatus: ItemStatus? {
        switch self {
        case .backlog, .active: nil
        case .done: .completed
        case .cancelled: .cancelled
        }
    }

    /// Whether work in this category has stopped moving.
    public var isTerminal: Bool {
        resolvedStatus != nil
    }

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .active: "Active"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    public var symbolName: String {
        switch self {
        case .backlog: "tray"
        case .active: "circle.dashed"
        case .done: "checkmark.circle.fill"
        case .cancelled: "slash.circle"
        }
    }
}

/// A board column, as a value.
public struct WorkflowStageFacts: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var category: WorkflowStageCategory
    public var colorName: String?
    public var sortOrder: Double
    /// The most items this column should hold, or `0` for no limit.
    public var wipLimit: Int

    public init(
        id: UUID,
        name: String,
        category: WorkflowStageCategory,
        colorName: String? = nil,
        sortOrder: Double = 0,
        wipLimit: Int = 0
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.colorName = colorName
        self.sortOrder = sortOrder
        self.wipLimit = wipLimit
    }

    public var hasLimit: Bool { wipLimit > 0 }

    /// Whether `count` items is over this column's limit.
    ///
    /// **Reported, never enforced.** A board that refuses a drop does not reduce work in progress;
    /// it moves the work somewhere the board cannot see it, and the limit then measures how well
    /// people are avoiding the board. Saying "this is over its limit" is the entire mechanism —
    /// it works because people are looking at it, and it stops working the moment it starts saying
    /// no.
    public func isOverLimit(_ count: Int) -> Bool {
        hasLimit && count > wipLimit
    }

    public func isAtLimit(_ count: Int) -> Bool {
        hasLimit && count == wipLimit
    }
}

// MARK: - Views

/// A way of looking at the same work.
///
/// Every project ships all of these, which is deliberate. A view holds no work — it is a lens, and
/// the work exists whether or not anything is pointed at it — so an unused tab costs a word of width
/// and a missing one costs finding the add-view menu and knowing what to ask for. Templates decide
/// the *order* they appear in, not which of them exist.
public enum ProjectViewKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Health, goals, recent activity, what needs attention.
    case overview
    /// Columns and cards.
    case board
    /// Rows, grouped and sorted.
    case list
    /// A spreadsheet with configurable columns and editable cells.
    case table
    /// The list, with the bug fields promoted and severity leading.
    case bugs
    /// Work with dates, on a month or week.
    case calendar
    /// Milestones, releases, and what is aimed at them.
    case timeline

    public var displayName: String {
        switch self {
        case .overview: "Overview"
        case .board: "Board"
        case .list: "List"
        case .table: "Table"
        case .bugs: "Bugs"
        case .calendar: "Calendar"
        case .timeline: "Timeline"
        }
    }

    public var symbolName: String {
        switch self {
        case .overview: "chart.pie"
        case .board: "rectangle.split.3x1"
        case .list: "list.bullet"
        case .table: "tablecells"
        case .bugs: "ant"
        case .calendar: "calendar"
        case .timeline: "chart.bar.xaxis"
        }
    }

    /// The design-system colour name for this view's glyph.
    ///
    /// Coloured for the same reason People colours a phone number apart from an email: a tab bar of
    /// seven identical grey glyphs is read by its labels alone, which means it is read slowly every
    /// time. A hue per lens makes the one you want findable before the word is.
    public var colorName: String {
        switch self {
        case .overview: "purple"
        case .board: "blue"
        case .list: "teal"
        case .table: "indigo"
        case .bugs: "red"
        case .calendar: "orange"
        case .timeline: "green"
        }
    }

    /// One line for the add-view menu.
    public var hint: String {
        switch self {
        case .overview: "Health, goals, and what needs attention"
        case .board: "Columns you drag work between"
        case .list: "Rows, grouped and sorted"
        case .table: "A spreadsheet you can edit in place"
        case .bugs: "Defects by severity, with reproduction detail"
        case .calendar: "Work with dates, on a month"
        case .timeline: "Milestones, releases, and what is aimed at them"
        }
    }

    /// Whether this view is laid out by workflow stage rather than by a chosen grouping.
    public var usesWorkflowStages: Bool {
        self == .board
    }

    /// Whether the user may choose what this view groups by.
    public var supportsGrouping: Bool {
        switch self {
        case .list, .table, .bugs: true
        // A board groups by stage by definition; the overview, calendar and timeline are laid out
        // by their own axis, and offering a grouping control that does nothing is worse than not
        // offering one.
        case .overview, .board, .calendar, .timeline: false
        }
    }
}

/// What a view divides work into.
public enum WorkItemGrouping: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case stage
    case status
    case assignee
    case priority
    case severity
    case kind
    case milestone
    case release
    case dueDate
    case tag
    case heading

    public var displayName: String {
        switch self {
        case .none: "No grouping"
        case .stage: "Stage"
        case .status: "Status"
        case .assignee: "Assignee"
        case .priority: "Priority"
        case .severity: "Severity"
        case .kind: "Type"
        case .milestone: "Milestone"
        case .release: "Release"
        case .dueDate: "Due date"
        case .tag: "Tag"
        case .heading: "Section"
        }
    }
}

/// What a view sorts by within each group.
public enum WorkItemSortField: String, Codable, Sendable, Hashable, CaseIterable {
    /// The order the user dragged them into.
    case manual
    case title
    case reference
    case priority
    case severity
    case dueDate
    case startDate
    case createdAt
    case updatedAt
    case estimate

    public var displayName: String {
        switch self {
        case .manual: "Manual"
        case .title: "Title"
        case .reference: "ID"
        case .priority: "Priority"
        case .severity: "Severity"
        case .dueDate: "Due date"
        case .startDate: "Start date"
        case .createdAt: "Created"
        case .updatedAt: "Updated"
        case .estimate: "Estimate"
        }
    }
}

/// A column in the table, or a field on a card.
public enum WorkItemField: String, Codable, Sendable, Hashable, CaseIterable {
    case reference
    case title
    case kind
    case status
    case stage
    case priority
    case severity
    case assignee
    case dueDate
    case startDate
    case estimate
    case tracked
    case milestone
    case release
    case tags
    case comments
    case blocked
    case regression
    case affectedVersion
    case fixVersion
    case updatedAt

    public var displayName: String {
        switch self {
        case .reference: "ID"
        case .title: "Title"
        case .kind: "Type"
        case .status: "Status"
        case .stage: "Stage"
        case .priority: "Priority"
        case .severity: "Severity"
        case .assignee: "Assignee"
        case .dueDate: "Due"
        case .startDate: "Start"
        case .estimate: "Estimate"
        case .tracked: "Tracked"
        case .milestone: "Milestone"
        case .release: "Release"
        case .tags: "Tags"
        case .comments: "Comments"
        case .blocked: "Blocked"
        case .regression: "Regression"
        case .affectedVersion: "Affected"
        case .fixVersion: "Fixed in"
        case .updatedAt: "Updated"
        }
    }

    /// Whether a table cell for this field can be edited where it sits.
    ///
    /// `false` for the derived ones. Tracked time is the sum of time entries, blocked is the
    /// existence of an unresolved dependency, and updated is a consequence of editing something
    /// else — offering a cursor in any of them promises an edit that cannot be honoured.
    public var isInlineEditable: Bool {
        switch self {
        case .tracked, .blocked, .updatedAt, .reference: false
        default: true
        }
    }

    /// The columns a new table view starts with.
    public static let defaultTableColumns: [WorkItemField] = [
        .reference, .title, .kind, .status, .assignee, .priority, .dueDate, .estimate,
    ]

    /// The columns a new bug view starts with — severity leads, because it is what a bug list is
    /// scanned by.
    public static let defaultBugColumns: [WorkItemField] = [
        .reference, .title, .severity, .status, .assignee, .regression, .affectedVersion, .fixVersion,
    ]
}

// MARK: - View configuration

/// Everything a single view remembers.
///
/// Persisted as JSON in one `Data` column rather than as fifteen columns on `ProjectViewRecord`,
/// because these fields change together and only ever as a set. Adding a grouping option should be
/// an enum case, not a migration.
public struct ProjectViewConfiguration: Sendable, Hashable, Codable {
    public var grouping: WorkItemGrouping
    /// A second axis for a board — rows crossing the columns.
    public var swimlane: WorkItemGrouping
    public var sortField: WorkItemSortField
    public var sortAscending: Bool
    /// The view's own filter. Saved with the view, unlike a search, which is transient.
    public var filter: TaskFilter
    /// Which work kinds this view shows at all.
    public var kinds: Set<ItemKind>
    /// Table columns, in order.
    public var columns: [WorkItemField]
    /// The fields a board card shows beneath its title.
    public var cardFields: [WorkItemField]
    /// Whether a subtask gets a row of its own when its parent is already shown.
    public var showsSubtasks: Bool
    /// Whether completed and cancelled work appears.
    public var showsResolved: Bool
    /// Groups the user has collapsed, by the stable key `WorkItemArrangement` assigns.
    public var collapsedGroupKeys: Set<String>

    public init(
        grouping: WorkItemGrouping = .none,
        swimlane: WorkItemGrouping = .none,
        sortField: WorkItemSortField = .manual,
        sortAscending: Bool = true,
        filter: TaskFilter = TaskFilter(includesResolved: true),
        kinds: Set<ItemKind> = ItemKind.workItemKindSet,
        columns: [WorkItemField] = WorkItemField.defaultTableColumns,
        cardFields: [WorkItemField] = [.assignee, .dueDate, .tags],
        showsSubtasks: Bool = false,
        showsResolved: Bool = false,
        collapsedGroupKeys: Set<String> = []
    ) {
        self.grouping = grouping
        self.swimlane = swimlane
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.filter = filter
        self.kinds = kinds
        self.columns = columns
        self.cardFields = cardFields
        self.showsSubtasks = showsSubtasks
        self.showsResolved = showsResolved
        self.collapsedGroupKeys = collapsedGroupKeys
    }

    /// What a freshly added view of each kind starts as.
    ///
    /// The defaults differ because the lenses differ. A board shows resolved work — the Done column
    /// is most of the point — while a list does not, because a list of everything ever finished is
    /// not a working list. A bug view starts sorted by severity and shows only bugs.
    public static func `default`(for kind: ProjectViewKind) -> ProjectViewConfiguration {
        switch kind {
        case .overview:
            ProjectViewConfiguration(showsResolved: true)

        case .board:
            ProjectViewConfiguration(
                grouping: .stage,
                sortField: .manual,
                showsResolved: true
            )

        case .list:
            ProjectViewConfiguration(
                grouping: .heading,
                sortField: .manual
            )

        case .table:
            ProjectViewConfiguration(
                grouping: .none,
                sortField: .reference,
                columns: WorkItemField.defaultTableColumns,
                showsSubtasks: true
            )

        case .bugs:
            ProjectViewConfiguration(
                grouping: .severity,
                sortField: .severity,
                kinds: [.bug],
                columns: WorkItemField.defaultBugColumns
            )

        case .calendar:
            ProjectViewConfiguration(sortField: .dueDate)

        case .timeline:
            ProjectViewConfiguration(
                grouping: .milestone,
                sortField: .dueDate,
                showsResolved: true
            )
        }
    }

    /// Whether the user has narrowed this view beyond its kind's default scope.
    ///
    /// Asks the rules and the kind set, not `showsResolved` — hiding finished work is the normal
    /// state of a working list, and badging it as "filtered" would badge almost every view.
    public var isFiltered: Bool {
        !filter.rules.isEmpty || kinds != ItemKind.workItemKindSet
    }

    /// How many narrowings are in force, for the filter bar's badge.
    public var activeFilterCount: Int {
        filter.rules.count + (kinds == ItemKind.workItemKindSet ? 0 : 1)
    }

    // MARK: Storage

    /// JSON for the `configurationData` column.
    ///
    /// Returns `nil` rather than throwing: a view whose configuration will not encode should still
    /// be saveable, falling back to its kind's default, because losing a sort order is a smaller
    /// harm than refusing to save the project.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Reads a stored configuration, falling back to the kind's default.
    ///
    /// The fallback is the point. A configuration written by a newer build may hold a grouping this
    /// one has never heard of, and a view that will not draw is worse than one that draws with the
    /// default arrangement — especially since the stored bytes are left alone, so the newer build
    /// still finds its own setting intact.
    public static func decode(from data: Data?, kind: ProjectViewKind) -> ProjectViewConfiguration {
        guard let data,
              let decoded = try? JSONDecoder().decode(ProjectViewConfiguration.self, from: data)
        else {
            return .default(for: kind)
        }
        return decoded
    }
}
