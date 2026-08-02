import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Turning a template into a real project.
@MainActor
public final class ProjectTemplateService {
    private let items: any ItemRepository
    private let workspace: ProjectWorkspaceService
    private let workItems: WorkItemService
    private let context: ModelContext

    public init(
        items: any ItemRepository,
        workspace: ProjectWorkspaceService,
        workItems: WorkItemService,
        context: ModelContext
    ) {
        self.items = items
        self.workspace = workspace
        self.workItems = workItems
        self.context = context
    }

    /// Creates a project from a template.
    ///
    /// The key comes from the **project's own name** first and the template's suggestion second. A
    /// template called "Software project" suggests `DEV`, which is right for the first one and wrong
    /// for the fourth — by then the user has four projects and their references are `DEV-1`,
    /// `DEV2-1`, `DEV3-1`, none of which say which project they belong to.
    @discardableResult
    public func createProject(
        named name: String,
        from template: ProjectTemplate,
        in area: Item? = nil,
        key: String? = nil
    ) throws(AppError) -> Item {
        var draft = ItemDraft(kind: .project, title: name)
        if let area, area.kind.canContain(.project) { draft.parentID = area.id }

        let project = try items.create(draft)
        if project.parent == nil, let area, area.kind.canContain(.project) {
            project.parent = area
        }

        let preferred = key
            ?? WorkItemReference.suggestedKey(forProjectNamed: name)
            ?? template.suggestedKey
            ?? "PRJ"
        try workspace.setProjectKey(preferred, on: project)

        try install(template, into: project)
        return project
    }

    /// Adds a template's furniture to a project that already exists.
    ///
    /// **Additive, never replacing.** Applying a second template to a project keeps the columns and
    /// views it already had — somebody reaching for this wants more structure, not to lose the
    /// structure they built.
    public func apply(_ template: ProjectTemplate, to project: Item) throws(AppError) {
        try install(template, into: project, seedingItems: false)
    }

    private func install(
        _ template: ProjectTemplate,
        into project: Item,
        seedingItems: Bool = true
    ) throws(AppError) {
        var createdStages: [WorkflowStage] = []
        for specification in template.stages {
            let stage = try workspace.addStage(
                to: project,
                name: specification.name,
                category: specification.category,
                colorName: specification.colorName,
                wipLimit: specification.wipLimit
            )
            createdStages.append(stage)
        }

        for specification in template.views {
            try workspace.addView(
                to: project,
                kind: specification.kind,
                name: specification.name,
                configuration: specification.configuration
            )
        }

        for specification in template.fields {
            try workspace.addCustomField(
                to: project,
                name: specification.name,
                type: specification.type,
                options: specification.options
            )
        }

        for (index, specification) in template.automations.enumerated() {
            let rule = AutomationRule(
                name: specification.name,
                // The conditions travel with the rule. A template rule shipped without them fires on
                // every item the project will ever hold.
                definition: specification.definition,
                sortOrder: Double(index) * ProjectWorkspaceService.orderGap
            )
            rule.project = project
            context.insert(rule)
        }

        if seedingItems {
            for specification in template.items {
                let stage = specification.stageIndex.flatMap { index in
                    createdStages.indices.contains(index) ? createdStages[index] : nil
                }
                let item = try workItems.createWorkItem(
                    title: specification.title,
                    kind: specification.kind,
                    in: project,
                    stage: stage,
                    severity: specification.severity
                )
                if let body = specification.body { item.body = body }
            }
        }

        try save()
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "projectTemplate", reason: error.localizedDescription)
        }
    }
}
