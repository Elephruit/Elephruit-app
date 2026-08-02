import ElephruitCore
import Foundation
import SwiftData

// Everything a project workspace stores beyond `Item` itself.
//
// Eight satellites, all following the `PersonProfile` pattern: an optional to-one back to `Item`
// (or to the project) whose inverse is declared on `Item`, every attribute defaulted, and no unique constraints —
// the CloudKit rules from `docs/05-cloudkit-and-migrations.md`, which have held since v1 and are
// cheaper to keep than to retrofit.

// MARK: - Workflow stages

/// A board column.
///
/// The name is the user's and the category is the app's. See ``WorkflowStageCategory`` for why the
/// two are separate and why only the category ever leaves the board.
@Model
public final class WorkflowStage {
    public var id: UUID = UUID()
    public var name: String = ""

    /// Raw so a column written by a newer build with a category this one has never heard of can be
    /// read back without losing the column. Unknown values read as `.backlog`, which is the safe
    /// end: work shows up as outstanding rather than silently finished.
    public var categoryRaw: String = WorkflowStageCategory.backlog.rawValue

    public var colorName: String?
    public var sortOrder: Double = 0

    /// `0` means no limit. Not optional, because "no limit" and "a limit of zero" are the same
    /// intention and two spellings of it would be two code paths.
    public var wipLimit: Int = 0

    public var createdAt: Date = Date()

    public var project: Item?

    public init(
        id: UUID = UUID(),
        name: String = "",
        category: WorkflowStageCategory = .backlog,
        colorName: String? = nil,
        sortOrder: Double = 0,
        wipLimit: Int = 0
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.colorName = colorName
        self.sortOrder = sortOrder
        self.wipLimit = wipLimit
        self.createdAt = Date()
    }

    public var category: WorkflowStageCategory {
        get { WorkflowStageCategory(rawValue: categoryRaw) ?? .backlog }
        set { categoryRaw = newValue.rawValue }
    }

    public var facts: WorkflowStageFacts {
        WorkflowStageFacts(
            id: id,
            name: name,
            category: category,
            colorName: colorName,
            sortOrder: sortOrder,
            wipLimit: wipLimit
        )
    }
}

// MARK: - Views

/// One configured lens over a project's work.
@Model
public final class ProjectViewRecord {
    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: String = ProjectViewKind.list.rawValue

    /// The whole ``ProjectViewConfiguration`` as JSON. One column rather than fifteen, because
    /// these fields change together and adding a grouping option should be an enum case rather
    /// than a migration.
    public var configurationData: Data?

    public var sortOrder: Double = 0

    /// Overrides the kind's glyph when the user picks one.
    public var symbolName: String?

    public var createdAt: Date = Date()

    public var project: Item?

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: ProjectViewKind = .list,
        configuration: ProjectViewConfiguration? = nil,
        sortOrder: Double = 0,
        symbolName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.configurationData = (configuration ?? .default(for: kind)).encoded()
        self.sortOrder = sortOrder
        self.symbolName = symbolName
        self.createdAt = Date()
    }

    /// Unknown kinds read as `.list`, which can draw anything.
    public var kind: ProjectViewKind {
        get { ProjectViewKind(rawValue: kindRaw) ?? .list }
        set { kindRaw = newValue.rawValue }
    }

    public var configuration: ProjectViewConfiguration {
        get { ProjectViewConfiguration.decode(from: configurationData, kind: kind) }
        set { configurationData = newValue.encoded() }
    }

    public var displaySymbolName: String {
        symbolName ?? kind.symbolName
    }
}

// MARK: - Bugs

/// What makes a defect answerable. The satellite on a `.bug` item.
@Model
public final class BugRecord {
    public var id: UUID = UUID()
    public var severityRaw: String = BugSeverity.minor.rawValue
    public var stepsToReproduce: String?
    public var expectedBehavior: String?
    public var actualBehavior: String?
    public var environment: String?
    public var affectedVersion: String?
    public var fixVersion: String?
    public var isRegression: Bool = false

    /// When somebody confirmed the fix actually works.
    ///
    /// **Separate from the item's status, and deliberately not part of ``BugFacts``.** Fixed is a
    /// claim by whoever wrote the fix; verified is a claim by whoever checked it. Collapsing them
    /// loses the only state anybody testing a release actually needs to see — the fixes nobody has
    /// looked at yet.
    public var verifiedAt: Date?

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var item: Item?

    public init(id: UUID = UUID(), facts: BugFacts = BugFacts()) {
        self.id = id
        self.createdAt = Date()
        self.updatedAt = Date()
        apply(facts)
    }

    public var severity: BugSeverity {
        get { BugSeverity(rawValue: severityRaw) ?? .minor }
        set { severityRaw = newValue.rawValue }
    }

    public var facts: BugFacts {
        get {
            BugFacts(
                severity: severity,
                stepsToReproduce: stepsToReproduce,
                expectedBehavior: expectedBehavior,
                actualBehavior: actualBehavior,
                environment: environment,
                affectedVersion: affectedVersion,
                fixVersion: fixVersion,
                isRegression: isRegression
            )
        }
        set { apply(newValue) }
    }

    private func apply(_ facts: BugFacts) {
        severityRaw = facts.severity.rawValue
        stepsToReproduce = facts.stepsToReproduce
        expectedBehavior = facts.expectedBehavior
        actualBehavior = facts.actualBehavior
        environment = facts.environment
        affectedVersion = facts.affectedVersion
        fixVersion = facts.fixVersion
        isRegression = facts.isRegression
    }

    /// The parts worth folding into the owning item's search text.
    ///
    /// Reproduction steps above all: "the crash when the list is empty" is written in the steps,
    /// not in the title, and it is what somebody types when they are looking for it again.
    public var searchableText: String {
        [stepsToReproduce, expectedBehavior, actualBehavior, environment, affectedVersion, fixVersion]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Comments

/// One remark on a work item.
@Model
public final class ItemComment {
    public var id: UUID = UUID()
    public var body: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// The person who wrote it, when it was not the user.
    public var authorID: UUID?

    /// People named in it, as JSON. A stored array rather than links because a mention is part of
    /// the text — editing the comment rewrites it — and links are for associations that outlive
    /// their sentence.
    public var mentionedPersonIDsData: Data?

    public var item: Item?

    public init(id: UUID = UUID(), body: String = "", authorID: UUID? = nil) {
        self.id = id
        self.body = body
        self.authorID = authorID
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var mentionedPersonIDs: [UUID] {
        get {
            guard let mentionedPersonIDsData else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: mentionedPersonIDsData)) ?? []
        }
        set { mentionedPersonIDsData = try? JSONEncoder().encode(newValue) }
    }
}

// MARK: - Activity

/// One thing that happened to a work item.
///
/// ### Why this stores words and not identifiers
///
/// `oldValue` and `newValue` are **display strings**. That makes history unqueryable, which is the
/// price, and it makes history *permanent*, which is the point: "moved from In review to Done"
/// still reads correctly after the stage has been renamed, and after it has been deleted — which is
/// exactly the moment somebody goes looking. An identifier-based history renders as "moved from
/// (unknown) to (unknown)" precisely when it is needed.
@Model
public final class ItemActivity {
    public var id: UUID = UUID()
    public var at: Date = Date()
    public var kindRaw: String = ""

    /// Which field changed, in words — "Priority", "Severity".
    public var field: String?
    public var oldValue: String?
    public var newValue: String?

    /// Who did it, when it was not the user.
    public var actorID: UUID?

    /// Which rule did it, when it was not a person at all. An automation's changes have to be
    /// attributable, or the first surprising one costs an afternoon.
    public var automationRuleID: UUID?

    public var item: Item?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        kind: ActivityKind = .created,
        field: String? = nil,
        oldValue: String? = nil,
        newValue: String? = nil,
        actorID: UUID? = nil,
        automationRuleID: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.kindRaw = kind.rawValue
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.actorID = actorID
        self.automationRuleID = automationRuleID
    }

    public var kind: ActivityKind {
        get { ActivityKind(rawValue: kindRaw) ?? .edited }
        set { kindRaw = newValue.rawValue }
    }

    /// The sentence shown in the history list.
    public var sentence: String {
        kind.sentence(from: oldValue, to: newValue, field: field)
    }
}

// MARK: - Automation

/// One trigger-condition-action rule belonging to a project.
@Model
public final class AutomationRule {
    public var id: UUID = UUID()
    public var name: String = ""
    public var isEnabled: Bool = true

    /// The whole ``AutomationDefinition`` as JSON.
    public var definitionData: Data?

    public var sortOrder: Double = 0
    public var createdAt: Date = Date()

    public var lastFiredAt: Date?
    public var fireCount: Int = 0

    /// Why the last run did nothing, when it failed rather than simply not matching.
    ///
    /// Stored because a rule that silently stops working is the worst failure an automation can
    /// have: everything looks configured and nothing happens.
    public var lastFailureReason: String?

    public var project: Item?

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        definition: AutomationDefinition? = nil,
        sortOrder: Double = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.definitionData = definition.flatMap { try? JSONEncoder().encode($0) }
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    public var definition: AutomationDefinition? {
        get {
            guard let definitionData else { return nil }
            return try? JSONDecoder().decode(AutomationDefinition.self, from: definitionData)
        }
        set { definitionData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Whether this build can actually run it.
    ///
    /// A rule holding a trigger or action written by a newer version is disabled *whole* rather
    /// than run partially — half of an automation is not a smaller automation, it is a different
    /// one nobody asked for.
    public var isRunnable: Bool {
        isEnabled && definition?.isRunnable == true
    }
}

// MARK: - Custom fields

/// A field the user added to a project.
///
/// **This costs no storage of its own.** The definition names and types a key; the values live in
/// `Item.userMetadata`, which has been in the schema since v1. That is why renaming a field has to
/// move the values with it — a rename touching only the definition orphans every value under a name
/// nothing looks for, and the data is still there, invisibly, forever.
@Model
public final class CustomFieldDefinition {
    public var id: UUID = UUID()
    public var name: String = ""
    public var typeRaw: String = CustomFieldType.text.rawValue

    /// Choices, as JSON, for a `.choice` field.
    public var optionsData: Data?

    public var sortOrder: Double = 0

    /// Whether it shows on the card and in the header rather than behind a disclosure.
    public var isProminent: Bool = false

    public var createdAt: Date = Date()

    public var project: Item?

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: CustomFieldType = .text,
        options: [String] = [],
        sortOrder: Double = 0,
        isProminent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.optionsData = options.isEmpty ? nil : try? JSONEncoder().encode(options)
        self.sortOrder = sortOrder
        self.isProminent = isProminent
        self.createdAt = Date()
    }

    public var type: CustomFieldType {
        get { CustomFieldType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    public var options: [String] {
        get {
            guard let optionsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: optionsData)) ?? []
        }
        set { optionsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}

// MARK: - Inbox

/// One thing worth telling the user about.
@Model
public final class InboxNotification {
    public var id: UUID = UUID()
    public var at: Date = Date()
    public var kindRaw: String = ""
    public var isRead: Bool = false

    /// The whole sentence, already written.
    ///
    /// Stored for the same reason ``ItemActivity`` stores words: a notification about a stage that
    /// has since been renamed must still say what happened.
    public var summary: String = ""

    public var actorID: UUID?
    public var automationRuleID: UUID?

    public var item: Item?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        kind: NotificationKind = .mentioned,
        summary: String = "",
        actorID: UUID? = nil,
        automationRuleID: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.kindRaw = kind.rawValue
        self.summary = summary
        self.actorID = actorID
        self.automationRuleID = automationRuleID
    }

    public var kind: NotificationKind {
        get { NotificationKind(rawValue: kindRaw) ?? .mentioned }
        set { kindRaw = newValue.rawValue }
    }

    /// Whether this should push the sidebar's unread count up.
    ///
    /// Read notifications never count, and neither does anything the user did themselves — a badge
    /// that goes up because you assigned something to yourself teaches people to ignore the badge.
    public var countsTowardBadge: Bool {
        !isRead
    }
}
