import Foundation

/// A project's starting furniture: its columns, its views, its fields, and optionally some work.
///
/// A template decides what a project *starts* as, never what it is allowed to become. Nothing here
/// is enforced afterwards — every column can be renamed, every view removed, every field deleted —
/// because a template that constrains is a template people avoid choosing.
public struct ProjectTemplate: Sendable, Hashable, Identifiable {
    public struct StageSpec: Sendable, Hashable {
        public var name: String
        public var category: WorkflowStageCategory
        public var colorName: String?
        public var wipLimit: Int

        public init(
            _ name: String,
            _ category: WorkflowStageCategory,
            colorName: String? = nil,
            wipLimit: Int = 0
        ) {
            self.name = name
            self.category = category
            self.colorName = colorName
            self.wipLimit = wipLimit
        }
    }

    public struct ViewSpec: Sendable, Hashable {
        public var kind: ProjectViewKind
        public var name: String?
        public var configuration: ProjectViewConfiguration?

        public init(
            _ kind: ProjectViewKind,
            name: String? = nil,
            configuration: ProjectViewConfiguration? = nil
        ) {
            self.kind = kind
            self.name = name
            self.configuration = configuration
        }
    }

    public struct FieldSpec: Sendable, Hashable {
        public var name: String
        public var type: CustomFieldType
        public var options: [String]

        public init(_ name: String, _ type: CustomFieldType, options: [String] = []) {
            self.name = name
            self.type = type
            self.options = options
        }
    }

    public struct ItemSpec: Sendable, Hashable {
        public var title: String
        public var kind: ItemKind
        /// Index into ``ProjectTemplate/stages``, resolved to a real identifier on install.
        public var stageIndex: Int?
        public var severity: BugSeverity?
        public var body: String?

        public init(
            _ title: String,
            kind: ItemKind = .reminder,
            stageIndex: Int? = nil,
            severity: BugSeverity? = nil,
            body: String? = nil
        ) {
            self.title = title
            self.kind = kind
            self.stageIndex = stageIndex
            self.severity = severity
            self.body = body
        }
    }

    public struct AutomationSpec: Sendable, Hashable {
        public var name: String
        public var trigger: AutomationTrigger

        /// **Required, and the reason this type exists rather than an `AutomationDefinition`.**
        ///
        /// An `AutomationDefinition` defaults its conditions to an empty `TaskFilter`, and an empty
        /// filter with `includesResolved` matches literally everything. A template rule shipped that
        /// way fires on every item the project will ever hold — which is how "flag work that arrives
        /// critical" ended up flagging a shopping list. Making it a required parameter here means
        /// the omission cannot happen silently.
        public var conditions: TaskFilter
        public var actions: [AutomationAction]

        public init(
            _ name: String,
            trigger: AutomationTrigger,
            conditions: TaskFilter,
            actions: [AutomationAction]
        ) {
            self.name = name
            self.trigger = trigger
            self.conditions = conditions
            self.actions = actions
        }

        public var definition: AutomationDefinition {
            AutomationDefinition(trigger: trigger, conditions: conditions, actions: actions)
        }
    }

    public var id: String
    public var name: String
    public var summary: String
    public var symbolName: String
    public var suggestedKey: String?
    public var stages: [StageSpec]

    /// The views this template puts **first**. Not the views it allows — see ``views``.
    public var featuredViews: [ViewSpec]

    public var fields: [FieldSpec]
    public var items: [ItemSpec]
    public var automations: [AutomationSpec]

    /// Every view, with the template's choices leading and the rest appended.
    ///
    /// **A template orders views; it does not choose them.** A view holds no work — it is a lens,
    /// and the work exists whether or not anything is pointed at it — so an unused tab costs a word
    /// of width while a missing one costs finding the add menu and knowing what to ask for. A
    /// software project leads with its board and a marketing campaign with its calendar, and both
    /// still have all seven.
    public var views: [ViewSpec] {
        let featured = featuredViews
        let claimed = Set(featured.map(\.kind))
        return featured + ProjectViewKind.allCases
            .filter { !claimed.contains($0) }
            .map { ViewSpec($0) }
    }

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        suggestedKey: String? = nil,
        stages: [StageSpec] = [],
        featuredViews: [ViewSpec] = [],
        fields: [FieldSpec] = [],
        items: [ItemSpec] = [],
        automations: [AutomationSpec] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.suggestedKey = suggestedKey
        self.stages = stages
        self.featuredViews = featuredViews
        self.fields = fields
        self.items = items
        self.automations = automations
    }
}

// MARK: - The templates

extension ProjectTemplate {
    public static let all: [ProjectTemplate] = [
        .blank, .software, .productLaunch, .marketingCampaign, .personalPlanning, .generalTasks,
    ]

    /// Three columns and nothing else. The default, and deliberately unopinionated: a project whose
    /// shape is not yet known should not arrive pre-committed to somebody else's process.
    public static let blank = ProjectTemplate(
        id: "blank",
        name: "Blank",
        summary: "Three columns and nothing else",
        symbolName: "square.dashed",
        stages: [
            StageSpec("To do", .backlog),
            StageSpec("Doing", .active),
            StageSpec("Done", .done, colorName: "green"),
        ],
        featuredViews: [ViewSpec(.board), ViewSpec(.list)]
    )

    public static let software = ProjectTemplate(
        id: "software",
        name: "Software project",
        summary: "Triage to shipped, with bugs tracked apart from features",
        symbolName: "chevron.left.forwardslash.chevron.right",
        suggestedKey: "DEV",
        stages: [
            StageSpec("Triage", .backlog),
            StageSpec("Ready", .backlog, colorName: "blue"),
            // Limits on the two stages where work actually piles up. Reported, never enforced.
            StageSpec("In progress", .active, colorName: "orange", wipLimit: 3),
            StageSpec("In review", .active, colorName: "purple", wipLimit: 4),
            StageSpec("Done", .done, colorName: "green"),
            StageSpec("Won't do", .cancelled),
        ],
        featuredViews: [ViewSpec(.board), ViewSpec(.bugs), ViewSpec(.list), ViewSpec(.timeline)],
        fields: [
            FieldSpec("Component", .choice, options: ["App", "Sync", "Search", "Design system"]),
        ],
        automations: [
            AutomationSpec(
                "Flag work that arrives critical",
                trigger: .itemCreated,
                // The conditions that were missing the first time. Without them this fires on every
                // item the project will ever hold.
                conditions: TaskFilter(rules: [.severity([.critical])], includesResolved: true),
                actions: [.setPriority(.high), .notify(.assigned)]
            ),
            AutomationSpec(
                "Close the subtasks when the parent is done",
                trigger: .itemResolved,
                conditions: TaskFilter(rules: [.hasSubtasks(true)], includesResolved: true),
                actions: [.completeSubtasks]
            ),
        ]
    )

    public static let productLaunch = ProjectTemplate(
        id: "productLaunch",
        name: "Product launch",
        summary: "Milestones, a date everything points at, and who owns what",
        symbolName: "shippingbox",
        stages: [
            StageSpec("Planned", .backlog),
            StageSpec("In progress", .active, colorName: "orange"),
            StageSpec("Blocked", .active, colorName: "red"),
            StageSpec("Ready", .active, colorName: "blue"),
            StageSpec("Launched", .done, colorName: "green"),
        ],
        featuredViews: [ViewSpec(.timeline), ViewSpec(.board), ViewSpec(.overview)],
        fields: [FieldSpec("Owner team", .text)],
        automations: [
            AutomationSpec(
                "Warn a week before anything is due",
                trigger: .deadlineApproaching(days: 7),
                conditions: TaskFilter(rules: [.hasDeadline(true)]),
                actions: [.notify(.dueSoon)]
            ),
        ]
    )

    public static let marketingCampaign = ProjectTemplate(
        id: "marketing",
        name: "Marketing campaign",
        summary: "A calendar first, because a campaign is mostly dates",
        symbolName: "megaphone",
        stages: [
            StageSpec("Ideas", .backlog),
            StageSpec("Drafting", .active, colorName: "orange"),
            StageSpec("In review", .active, colorName: "purple"),
            StageSpec("Scheduled", .active, colorName: "blue"),
            StageSpec("Published", .done, colorName: "green"),
        ],
        featuredViews: [ViewSpec(.calendar), ViewSpec(.board), ViewSpec(.table)],
        fields: [
            FieldSpec("Channel", .choice, options: ["Email", "Social", "Blog", "Paid", "Event"]),
        ]
    )

    public static let personalPlanning = ProjectTemplate(
        id: "personal",
        name: "Personal planning",
        summary: "A list and a calendar, with nothing to administer",
        symbolName: "person.crop.circle",
        stages: [
            StageSpec("Someday", .backlog),
            StageSpec("This week", .active, colorName: "blue"),
            StageSpec("Done", .done, colorName: "green"),
        ],
        featuredViews: [ViewSpec(.list), ViewSpec(.calendar), ViewSpec(.board)]
    )

    public static let generalTasks = ProjectTemplate(
        id: "general",
        name: "General tasks",
        summary: "A plain list of work, grouped into sections",
        symbolName: "checklist",
        stages: [
            StageSpec("To do", .backlog),
            StageSpec("Doing", .active, colorName: "orange"),
            StageSpec("Done", .done, colorName: "green"),
        ],
        featuredViews: [ViewSpec(.list), ViewSpec(.board), ViewSpec(.table)]
    )
}
