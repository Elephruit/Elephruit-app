import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Runs a project's rules.
///
/// ### Why it cannot re-enter
///
/// "When it moves to Done, tag it verified" plus "when it is tagged verified, move it to Done" is a
/// loop somebody writes in thirty seconds without noticing, and there is no way to detect it from
/// the rules alone — each is perfectly sensible on its own. So a run is one pass: actions taken by a
/// rule do not trigger further rules. That makes some chains impossible, and the alternative is an
/// app that hangs on a configuration the user had every reason to expect would work.
@MainActor
public final class AutomationEngine {
    /// Something that happened, which rules may care about.
    public enum Event: Sendable {
        case itemCreated
        case movedToStage(UUID, category: WorkflowStageCategory)
        case itemResolved
        case assigneeChanged
        case priorityChanged
        case commentAdded
        case becameOverdue
        case deadlineApproaching(days: Int)
        case recurrenceDue
    }

    /// What one rule did.
    public struct RuleOutcome: Sendable, Hashable, Identifiable {
        public var ruleID: UUID
        public var ruleName: String
        public var outcome: AutomationOutcome
        public var id: UUID { ruleID }
    }

    private let items: any ItemRepository
    private let workspace: ProjectWorkspaceService
    private let workItems: WorkItemService
    private let bugs: BugService
    private let inbox: InboxService
    private let context: ModelContext
    private let dateProvider: any DateProvider

    /// The re-entrancy guard. See the type's own note.
    private var isRunning = false

    public init(
        items: any ItemRepository,
        workspace: ProjectWorkspaceService,
        workItems: WorkItemService,
        bugs: BugService,
        inbox: InboxService,
        context: ModelContext,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.workspace = workspace
        self.workItems = workItems
        self.bugs = bugs
        self.inbox = inbox
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Running

    /// Offers an event to every rule in the item's project.
    ///
    /// Returns an outcome per rule — including the ones that did nothing, and *why*. The question
    /// people ask about an automation is never "did it run", it is "why didn't it", and a method
    /// that returns only what happened cannot answer that.
    @discardableResult
    public func handle(_ event: Event, on item: Item) throws(AppError) -> [RuleOutcome] {
        guard !isRunning else { return [] }
        guard let project = owningProject(of: item) else { return [] }

        isRunning = true
        defer { isRunning = false }

        let facts = item.taskFacts()
        let now = dateProvider.now
        var outcomes: [RuleOutcome] = []

        for rule in project.automationRules.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let definition = rule.definition else {
                outcomes.append(RuleOutcome(ruleID: rule.id, ruleName: rule.name, outcome: .notRunnable))
                continue
            }
            guard matches(definition.trigger, event) else {
                outcomes.append(RuleOutcome(ruleID: rule.id, ruleName: rule.name, outcome: .notTriggered))
                continue
            }
            guard rule.isRunnable else {
                outcomes.append(RuleOutcome(ruleID: rule.id, ruleName: rule.name, outcome: .notRunnable))
                continue
            }
            if let target = definition.requiredIntegrations.first {
                rule.lastFailureReason = "Needs \(target.displayName)"
                outcomes.append(
                    RuleOutcome(ruleID: rule.id, ruleName: rule.name, outcome: .needsIntegration(target))
                )
                continue
            }
            guard definition.conditions.matches(facts, now: now, calendar: .current) else {
                outcomes.append(
                    RuleOutcome(ruleID: rule.id, ruleName: rule.name, outcome: .conditionsNotMet)
                )
                continue
            }

            var changedAnything = false
            for action in definition.actions {
                changedAnything = try perform(action, on: item, in: project, rule: rule) || changedAnything
            }

            rule.lastFiredAt = now
            rule.fireCount += 1
            rule.lastFailureReason = nil
            outcomes.append(
                RuleOutcome(
                    ruleID: rule.id,
                    ruleName: rule.name,
                    outcome: changedAnything ? .ran : .noChange
                )
            )
        }

        try save()
        return outcomes
    }

    /// Runs the rules that have no event to hang off — deadlines and recurrence.
    ///
    /// Nothing *happens* when a date passes, so somebody has to go looking. Called on launch and on
    /// a day boundary rather than continuously.
    @discardableResult
    public func runScheduledRules(in project: Item, calendar: Calendar = .current) throws(AppError) -> [RuleOutcome] {
        let now = dateProvider.now
        let today = calendar.startOfDay(for: now)
        var outcomes: [RuleOutcome] = []

        for item in project.descendantWork() {
            guard let due = item.dueAt else { continue }
            let day = calendar.startOfDay(for: due)
            guard let delta = calendar.dateComponents([.day], from: today, to: day).day else { continue }

            if delta < 0, item.status == .open {
                outcomes += try handle(.becameOverdue, on: item)
            } else if delta >= 0 {
                outcomes += try handle(.deadlineApproaching(days: delta), on: item)
            }
        }
        return outcomes
    }

    /// Applies a rule to work that already exists.
    ///
    /// **A named, separate action**, never something that happens when a rule is saved. A rule
    /// created today describes what should happen from now on; silently rewriting two hundred
    /// existing items is a different and much larger thing to ask for, and it should be asked for.
    @discardableResult
    public func runNowOnEverything(_ rule: AutomationRule) throws(AppError) -> Int {
        guard let project = rule.project, let definition = rule.definition, rule.isRunnable else {
            return 0
        }
        guard definition.requiredIntegrations.isEmpty else { return 0 }

        let now = dateProvider.now
        var changed = 0

        isRunning = true
        defer { isRunning = false }

        for item in project.descendantWork() {
            guard definition.conditions.matches(item.taskFacts(), now: now, calendar: .current) else {
                continue
            }
            var didChange = false
            for action in definition.actions {
                didChange = try perform(action, on: item, in: project, rule: rule) || didChange
            }
            if didChange { changed += 1 }
        }

        rule.lastFiredAt = now
        rule.fireCount += 1
        try save()
        return changed
    }

    // MARK: - Matching

    private func matches(_ trigger: AutomationTrigger, _ event: Event) -> Bool {
        switch (trigger, event) {
        case (.itemCreated, .itemCreated),
             (.itemResolved, .itemResolved),
             (.assigneeChanged, .assigneeChanged),
             (.priorityChanged, .priorityChanged),
             (.commentAdded, .commentAdded),
             (.becameOverdue, .becameOverdue),
             (.recurrenceDue, .recurrenceDue):
            return true
        case let (.movedToStage(wanted), .movedToStage(actual, _)):
            return wanted == actual
        case let (.movedToStageCategory(wanted), .movedToStage(_, category)):
            return wanted == category
        case let (.deadlineApproaching(wanted), .deadlineApproaching(actual)):
            // Fires on the day and every day after it, so a rule set for seven days out still says
            // something on day three when nobody acted on day seven.
            return actual <= wanted
        default:
            return false
        }
    }

    // MARK: - Acting

    /// Returns whether anything actually changed.
    private func perform(
        _ action: AutomationAction,
        on item: Item,
        in project: Item,
        rule: AutomationRule
    ) throws(AppError) -> Bool {
        switch action {
        case .assign(let personID):
            guard let person = try items.item(id: personID), item.assignee()?.id != personID else {
                return false
            }
            try workItems.assign(item, to: person)
            return true

        case .unassign:
            guard item.assignee() != nil else { return false }
            try workItems.assign(item, to: nil)
            return true

        case .setPriority(let priority):
            guard item.priority != priority else { return false }
            try workItems.setPriority(priority, on: item)
            return true

        case .setSeverity(let severity):
            guard item.kind == .bug, item.bugRecord?.severity != severity else { return false }
            try bugs.setSeverity(severity, on: item)
            return true

        case .moveToStage(let stageID):
            guard let stage = workspace.stages(in: project).first(where: { $0.id == stageID }),
                  item.workflowStageID != stageID
            else { return false }
            try workspace.move(item, to: stage)
            return true

        case .addTag(let slug):
            guard !item.tagSlugs.contains(slug) else { return false }
            try items.setTags(item, slugs: item.tagSlugs + [slug])
            return true

        case .removeTag(let slug):
            guard item.tagSlugs.contains(slug) else { return false }
            try items.setTags(item, slugs: item.tagSlugs.filter { $0 != slug })
            return true

        case .setMilestone(let milestoneID):
            guard let milestone = try items.item(id: milestoneID) else { return false }
            try workItems.setMilestone(milestone, on: item)
            return true

        case .setRelease(let releaseID):
            guard let release = try items.item(id: releaseID) else { return false }
            try workItems.setRelease(release, on: item)
            return true

        case .completeSubtasks:
            let open = item.children.filter { $0.kind.isWorkItem && $0.status == .open }
            guard !open.isEmpty else { return false }
            for child in open { try items.toggleCompletion(child) }
            return true

        case .completeParentWhenLastChild:
            guard let parent = item.parent, parent.kind.isWorkItem, parent.status == .open else {
                return false
            }
            let stillOpen = parent.children.filter { $0.kind.isWorkItem && $0.status == .open }
            guard stillOpen.isEmpty else { return false }
            try items.toggleCompletion(parent)
            return true

        case .setDeadline(let days):
            guard let date = Calendar.current.date(byAdding: .day, value: days, to: dateProvider.now)
            else { return false }
            try workItems.setDueDate(date, on: item)
            return true

        case .notify(let kind):
            try inbox.post(
                kind,
                about: item,
                summary: "\(rule.name) — \(item.title)",
                automationRuleID: rule.id
            )
            return true

        case .comment(let body):
            try workItems.addComment(body, to: item)
            return true

        case .external, .unrecognised:
            // Refused honestly rather than silently skipped. Reaching here means `isRunnable` or the
            // integration check let something through, which is a bug worth the failure reason.
            rule.lastFailureReason = "This build cannot run \(action.summary)"
            return false
        }
    }

    private func owningProject(of item: Item) -> Item? {
        var container: Item? = item
        while let next = container {
            if next.kind == .project || next.kind == .list { return next }
            container = next.parent
        }
        return nil
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "automation", reason: error.localizedDescription)
        }
    }
}
