import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What moving a card across a board actually did.
///
/// Returned rather than inferred, for the reason ``WorkItemCompletionOutcome`` is: a drag can change the
/// column, the lifecycle status, both, or — most often — only the column. A caller that re-reads the
/// store to work out which will announce "marked complete" for a drag between two open columns.
public struct BoardMove: Sendable, Hashable {
    public var itemID: UUID
    public var fromStageID: UUID?
    public var toStageID: UUID?

    /// The status this drag wrote, if it wrote one at all.
    public var resolvedStatus: ItemStatus?

    /// Whether finished work was dragged back out of a terminal column.
    public var didReopen: Bool

    public var changedStatus: Bool { resolvedStatus != nil || didReopen }
}

/// Everything a project's furniture is made of: its columns, its views, and its custom fields.
///
/// `@MainActor` for the reason every other service here is — it hands back model objects, which
/// belong to the context that owns them.
@MainActor
public final class ProjectWorkspaceService {
    /// The gap left between adjacent sort orders, so a hundred drops happen before anything needs
    /// renumbering.
    static let orderGap: Double = 1024

    private let items: any ItemRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, context: ModelContext, dateProvider: any DateProvider) {
        self.items = items
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Stages

    public func stages(in project: Item) -> [WorkflowStage] {
        project.workflowStages.sorted { $0.sortOrder < $1.sortOrder }
    }

    @discardableResult
    public func addStage(
        to project: Item,
        name: String,
        category: WorkflowStageCategory = .backlog,
        colorName: String? = nil,
        wipLimit: Int = 0
    ) throws(AppError) -> WorkflowStage {
        let stage = WorkflowStage(
            name: name,
            category: category,
            colorName: colorName,
            sortOrder: (stages(in: project).last?.sortOrder ?? 0) + Self.orderGap,
            wipLimit: wipLimit
        )
        stage.project = project
        context.insert(stage)
        try save()
        return stage
    }

    public func renameStage(_ stage: WorkflowStage, to name: String) throws(AppError) {
        stage.name = name
        try save()
    }

    public func setCategory(_ category: WorkflowStageCategory, on stage: WorkflowStage) throws(AppError) {
        stage.category = category
        try save()
    }

    public func setWipLimit(_ limit: Int, on stage: WorkflowStage) throws(AppError) {
        stage.wipLimit = max(0, limit)
        try save()
    }

    public func reorderStages(_ ordered: [WorkflowStage]) throws(AppError) {
        for (index, stage) in ordered.enumerated() {
            stage.sortOrder = Double(index) * Self.orderGap
        }
        try save()
    }

    /// Removes a column, moving its work somewhere explicit.
    ///
    /// `destination: nil` **unplaces** the work rather than stranding it — it keeps its project and
    /// shows up in the board's "Unplaced" column. Leaving a dangling `workflowStageID` would make
    /// the work invisible on the only view that claims to show everything, which is the failure
    /// mode worth spending a parameter to avoid.
    public func removeStage(
        _ stage: WorkflowStage,
        movingItemsTo destination: WorkflowStage?
    ) throws(AppError) {
        guard let project = stage.project else {
            context.delete(stage)
            try save()
            return
        }

        let stranded = project.descendantWork().filter { $0.workflowStageID == stage.id }
        for item in stranded {
            item.workflowStageID = destination?.id
            item.updatedAt = dateProvider.now
        }
        context.delete(stage)
        try save()
    }

    // MARK: - Moving work across the board

    /// Moves work into a column, writing the lifecycle status only when the column's category says
    /// something about it.
    ///
    /// **This is the join between the app's two state axes**, and the three rules are the whole
    /// reason they can stay apart:
    ///
    /// - Landing in a **terminal** category (done, cancelled) writes the status.
    /// - Landing in an **open** category from another open one writes *nothing at all*. Backlog and
    ///   active are the same answer to "is this outstanding?", so treating that as a lifecycle
    ///   change would stamp `updatedAt` on every drag and put a line in the history for a gesture
    ///   that changed no facts.
    /// - Dragging **finished work back out** of a terminal column reopens it, or the board would
    ///   sit there disagreeing with itself.
    @discardableResult
    public func move(
        _ item: Item,
        to stage: WorkflowStage?,
        after predecessor: Item? = nil,
        before successor: Item? = nil
    ) throws(AppError) -> BoardMove {
        let fromStageID = item.workflowStageID
        let wasTerminal = item.status == .completed || item.status == .cancelled

        item.workflowStageID = stage?.id
        item.boardOrder = Self.order(after: predecessor?.boardOrder, before: successor?.boardOrder)

        var resolved: ItemStatus?
        var reopened = false

        if let category = stage?.category, let status = category.resolvedStatus {
            if item.status != status {
                item.status = status
                switch status {
                case .completed:
                    item.completedAt = dateProvider.now
                    item.cancelledAt = nil
                case .cancelled:
                    item.cancelledAt = dateProvider.now
                    item.completedAt = nil
                case .none, .open:
                    break
                }
                resolved = status
            }
        } else if wasTerminal {
            // Out of a terminal column and into an open one.
            item.status = .open
            item.completedAt = nil
            item.cancelledAt = nil
            reopened = true
        }

        item.updatedAt = dateProvider.now
        try save()

        return BoardMove(
            itemID: item.id,
            fromStageID: fromStageID,
            toStageID: stage?.id,
            resolvedStatus: resolved,
            didReopen: reopened
        )
    }

    /// A sort order that lands between two neighbours.
    static func order(after predecessor: Double?, before successor: Double?) -> Double {
        switch (predecessor, successor) {
        case let (before?, after?): (before + after) / 2
        case let (before?, nil): before + orderGap
        case let (nil, after?): after - orderGap
        case (nil, nil): 0
        }
    }

    // MARK: - Views

    public func views(in project: Item) -> [ProjectViewRecord] {
        project.projectViews.sorted { $0.sortOrder < $1.sortOrder }
    }

    @discardableResult
    public func addView(
        to project: Item,
        kind: ProjectViewKind,
        name: String? = nil,
        configuration: ProjectViewConfiguration? = nil
    ) throws(AppError) -> ProjectViewRecord {
        let record = ProjectViewRecord(
            name: name ?? kind.displayName,
            kind: kind,
            configuration: configuration,
            sortOrder: (views(in: project).last?.sortOrder ?? 0) + Self.orderGap
        )
        record.project = project
        context.insert(record)
        try save()
        return record
    }

    public func renameView(_ view: ProjectViewRecord, to name: String) throws(AppError) {
        view.name = name
        try save()
    }

    public func updateConfiguration(
        _ view: ProjectViewRecord,
        _ mutate: (inout ProjectViewConfiguration) -> Void
    ) throws(AppError) {
        var configuration = view.configuration
        mutate(&configuration)
        view.configuration = configuration
        try save()
    }

    @discardableResult
    public func duplicateView(_ view: ProjectViewRecord) throws(AppError) -> ProjectViewRecord? {
        guard let project = view.project else { return nil }
        return try addView(
            to: project,
            kind: view.kind,
            name: view.name + " copy",
            configuration: view.configuration
        )
    }

    public func reorderViews(_ ordered: [ProjectViewRecord]) throws(AppError) {
        for (index, view) in ordered.enumerated() {
            view.sortOrder = Double(index) * Self.orderGap
        }
        try save()
    }

    /// Removes a view, **refusing the last one**.
    ///
    /// A project with no views is a project you cannot open. Returning `false` rather than throwing
    /// because this is not an error the user made — it is a menu item that should have been
    /// disabled, and the caller disables it with the same question.
    @discardableResult
    public func removeView(_ view: ProjectViewRecord) throws(AppError) -> Bool {
        guard let project = view.project, project.projectViews.count > 1 else { return false }
        context.delete(view)
        try save()
        return true
    }

    // MARK: - Custom fields

    public func customFields(in project: Item) -> [CustomFieldDefinition] {
        project.customFieldDefinitions.sorted { $0.sortOrder < $1.sortOrder }
    }

    @discardableResult
    public func addCustomField(
        to project: Item,
        name: String,
        type: CustomFieldType,
        options: [String] = []
    ) throws(AppError) -> CustomFieldDefinition {
        let field = CustomFieldDefinition(
            name: name,
            type: type,
            options: options,
            sortOrder: (customFields(in: project).last?.sortOrder ?? 0) + Self.orderGap
        )
        field.project = project
        context.insert(field)
        try save()
        return field
    }

    /// Renames a field **and moves every value with it**.
    ///
    /// Custom fields cost no storage of their own — the definition names a key and the values live
    /// in `Item.userMetadata`. So a rename that touched only the definition would leave every value
    /// filed under a name nothing looks for: the data still there, invisible, forever, and the
    /// field looking empty for reasons nobody could reconstruct.
    public func renameCustomField(_ field: CustomFieldDefinition, to name: String) throws(AppError) {
        let oldName = field.name
        guard oldName != name else { return }

        if let project = field.project {
            for item in project.descendantWork() {
                guard let value = item.userMetadata[oldName] else { continue }
                var metadata = item.userMetadata
                metadata[name] = value
                metadata.removeValue(forKey: oldName)
                item.userMetadata = metadata
                item.updatedAt = dateProvider.now
            }
        }

        field.name = name
        try save()
    }

    /// Removes a definition **and the values under it**.
    ///
    /// Unlike a rename, this is a deletion the user asked for, and leaving orphaned values behind
    /// would mean re-adding a field of the same name silently resurrected old data.
    public func removeCustomField(_ field: CustomFieldDefinition) throws(AppError) {
        let name = field.name
        if let project = field.project {
            for item in project.descendantWork() where item.userMetadata[name] != nil {
                var metadata = item.userMetadata
                metadata.removeValue(forKey: name)
                item.userMetadata = metadata
                item.updatedAt = dateProvider.now
            }
        }
        context.delete(field)
        try save()
    }

    public func setCustomFieldValue(
        _ value: MetadataValue?,
        named name: String,
        on item: Item
    ) throws(AppError) {
        var metadata = item.userMetadata
        if let value {
            metadata[name] = value
        } else {
            metadata.removeValue(forKey: name)
        }
        item.userMetadata = metadata
        item.updatedAt = dateProvider.now
        try save()
    }

    // MARK: - Reference keys

    public func setProjectKey(_ key: String, on project: Item) throws(AppError) {
        guard project.kind == .project else { return }
        let taken = Set(try allProjectKeys().filter { $0 != project.projectKey })
        project.projectKey = WorkItemReference.uniqueKey(from: key, taken: taken)
        try save()
    }

    /// Hands out the next reference for a project.
    ///
    /// **The number only ever goes up**, including across deletions. A gap in the sequence is the
    /// record of something deleted; reusing the number would make a reference written in a March
    /// commit message start pointing at different work, silently, in a place nobody would think to
    /// look for the cause.
    public func allocateReferenceKey(in project: Item) throws(AppError) -> String? {
        let key = takeReferenceKey(in: project)
        try save()
        return key
    }

    /// The same, without saving.
    ///
    /// For callers already inside a larger act that will save once at the end. Saving here as well
    /// meant three write transactions to create one work item, which is what made populating a
    /// project feel like the app had stopped.
    public func takeReferenceKey(in project: Item) -> String? {
        guard let key = project.projectKey else { return nil }
        let number = project.nextReferenceNumber
        project.nextReferenceNumber = number + 1
        return WorkItemReference.format(key: key, number: number)
    }

    private func allProjectKeys() throws(AppError) -> [String] {
        var query = ItemQuery()
        query.kinds = [.project]
        // Everything, including trashed. An archived project's references are still written down in
        // commit messages, and a trashed one can be restored — reissuing either key would make two
        // projects answer to the same handle.
        query.scope = .all
        return try items.items(matching: query).compactMap(\.projectKey)
    }

    // MARK: - Making a project into a workspace

    /// Gives a project the furniture it needs, without disturbing what it already has.
    ///
    /// Idempotent and additive: a project that already has columns keeps them, one that has a key
    /// keeps it. Called when a project is first opened, so that projects made before any of this
    /// existed become workspaces by being looked at rather than by a migration.
    @discardableResult
    public func ensureWorkspace(
        for project: Item,
        using template: ProjectTemplate = .blank
    ) throws(AppError) -> Bool {
        guard project.kind == .project || project.kind == .list else { return false }
        var changed = false

        if project.projectKey == nil, project.kind == .project {
            let suggestion = WorkItemReference.suggestedKey(forProjectNamed: project.title) ?? "PRJ"
            let taken = Set(try allProjectKeys())
            project.projectKey = WorkItemReference.uniqueKey(from: suggestion, taken: taken)
            changed = true
        }

        if project.workflowStages.isEmpty {
            for (index, specification) in template.stages.enumerated() {
                let stage = WorkflowStage(
                    name: specification.name,
                    category: specification.category,
                    colorName: specification.colorName,
                    sortOrder: Double(index) * Self.orderGap,
                    wipLimit: specification.wipLimit
                )
                stage.project = project
                context.insert(stage)
            }
            changed = true
        }

        if project.projectViews.isEmpty {
            for (index, specification) in template.views.enumerated() {
                let record = ProjectViewRecord(
                    name: specification.name ?? specification.kind.displayName,
                    kind: specification.kind,
                    configuration: specification.configuration,
                    sortOrder: Double(index) * Self.orderGap
                )
                record.project = project
                context.insert(record)
            }
            changed = true
        }

        if changed { try save() }
        return changed
    }

    // MARK: - Saving

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "projectWorkspace", reason: error.localizedDescription)
        }
    }
}
