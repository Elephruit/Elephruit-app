import Foundation

/// What starts a rule.
public enum AutomationTrigger: Codable, Sendable, Hashable {
    case itemCreated
    case movedToStage(UUID)
    case movedToStageCategory(WorkflowStageCategory)
    case itemResolved
    case assigneeChanged
    case priorityChanged
    case deadlineApproaching(days: Int)
    case becameOverdue
    case commentAdded
    case recurrenceDue

    /// A trigger written by a newer build. Preserved so editing a rule here does not destroy it,
    /// and never fired — see ``AutomationDefinition/isRunnable``.
    case unrecognised(name: String)

    /// Whether this fires from a user action or has to be swept for on a schedule.
    ///
    /// Deadlines and recurrence have no event to hang off: nothing *happens* when a date passes,
    /// so somebody has to go looking. Keeping the distinction explicit stops a scheduled rule from
    /// being quietly wired to an event that will never arrive.
    public var isScheduled: Bool {
        switch self {
        case .deadlineApproaching, .becameOverdue, .recurrenceDue: true
        default: false
        }
    }

    public var summary: String {
        switch self {
        case .itemCreated: "When work is added"
        case .movedToStage: "When it moves to a particular stage"
        case .movedToStageCategory(let category): "When it moves to \(category.displayName)"
        case .itemResolved: "When it is finished"
        case .assigneeChanged: "When the assignee changes"
        case .priorityChanged: "When the priority changes"
        case .deadlineApproaching(let days):
            days == 1 ? "The day before it is due" : "\(days) days before it is due"
        case .becameOverdue: "When it goes past its deadline"
        case .commentAdded: "When somebody comments"
        case .recurrenceDue: "When a repeat comes round"
        case .unrecognised(let name): "An unknown trigger (\(name))"
        }
    }
}

/// What a rule does.
public enum AutomationAction: Codable, Sendable, Hashable {
    case assign(UUID)
    case unassign
    case setPriority(Priority)
    case setSeverity(BugSeverity)
    case moveToStage(UUID)
    case addTag(String)
    case removeTag(String)
    case setMilestone(UUID)
    case setRelease(UUID)

    /// Close every subtask beneath this item.
    case completeSubtasks

    /// Close the parent when this was the last open child.
    case completeParentWhenLastChild

    case setDeadline(daysFromNow: Int)
    case notify(NotificationKind)
    case comment(String)

    /// Hand off to something outside the app.
    ///
    /// Declared now and refused honestly at run time. The point is that wiring GitHub or Slack in
    /// later is an added conformance rather than a redesign of the rule format — and that a rule
    /// mentioning one today says "this needs an integration" instead of silently doing nothing.
    case external(IntegrationTarget, payload: String)

    case unrecognised(name: String)

    /// The outside system this action needs, if any.
    public var integrationTarget: IntegrationTarget? {
        if case .external(let target, _) = self { return target }
        return nil
    }

    public var summary: String {
        switch self {
        case .assign: "assign it"
        case .unassign: "clear the assignee"
        case .setPriority(let priority): "set priority to \(priority.displayName)"
        case .setSeverity(let severity): "set severity to \(severity.displayName)"
        case .moveToStage: "move it to a stage"
        case .addTag(let tag): "tag it #\(tag)"
        case .removeTag(let tag): "remove #\(tag)"
        case .setMilestone: "aim it at a milestone"
        case .setRelease: "put it in a release"
        case .completeSubtasks: "close its subtasks"
        case .completeParentWhenLastChild: "close the parent if this was the last one"
        case .setDeadline(let days): "set the deadline \(days) days out"
        case .notify(let kind): "notify — \(kind.displayName)"
        case .comment: "add a comment"
        case .external(let target, _): "tell \(target.displayName)"
        case .unrecognised(let name): "an unknown action (\(name))"
        }
    }
}

/// An outside system a rule can reach.
public enum IntegrationTarget: String, Codable, Sendable, Hashable, CaseIterable {
    case sourceControl
    case chat
    case email
    case calendar
    case documents
    case issueTracker

    public var displayName: String {
        switch self {
        case .sourceControl: "source control"
        case .chat: "chat"
        case .email: "email"
        case .calendar: "the calendar"
        case .documents: "documents"
        case .issueTracker: "an issue tracker"
        }
    }

    public var symbolName: String {
        switch self {
        case .sourceControl: "arrow.triangle.branch"
        case .chat: "bubble.left.and.bubble.right"
        case .email: "envelope"
        case .calendar: "calendar"
        case .documents: "doc.text"
        case .issueTracker: "ant"
        }
    }
}

/// A whole rule: when, whether, and what.
public struct AutomationDefinition: Codable, Sendable, Hashable {
    public var trigger: AutomationTrigger

    /// Which items the trigger applies to.
    ///
    /// **A rule with no conditions matches everything**, and `TaskFilter` with `includesResolved`
    /// means literally everything. That is correct behaviour and a sharp edge: a template rule
    /// shipped with empty conditions fires on every item the project will ever hold. Templates
    /// carry their conditions for exactly this reason.
    public var conditions: TaskFilter

    public var actions: [AutomationAction]

    public init(
        trigger: AutomationTrigger,
        conditions: TaskFilter = TaskFilter(includesResolved: true),
        actions: [AutomationAction] = []
    ) {
        self.trigger = trigger
        self.conditions = conditions
        self.actions = actions
    }

    /// Whether this build understands every part of it.
    ///
    /// All-or-nothing on purpose. Running the three actions a build recognises and skipping the
    /// fourth is not a smaller automation, it is a different one that nobody configured — and the
    /// person who configured it is on another machine, with no way to know.
    public var isRunnable: Bool {
        if case .unrecognised = trigger { return false }
        if actions.isEmpty { return false }
        return !actions.contains { if case .unrecognised = $0 { true } else { false } }
    }

    /// Whether it needs something not built yet.
    public var requiredIntegrations: [IntegrationTarget] {
        actions.compactMap(\.integrationTarget)
    }

    /// A sentence for the rules list.
    public var summary: String {
        let doing = actions.map(\.summary).formatted(.list(type: .and))
        let when = trigger.summary
        guard !conditions.rules.isEmpty else { return "\(when), \(doing)." }
        let ifs = conditions.rules.map(\.summary).formatted(
            .list(type: conditions.match == .all ? .and : .or)
        )
        return "\(when) and \(ifs), \(doing)."
    }
}

/// What happened when a rule was given its chance.
///
/// Every non-run has a distinct case rather than collapsing into "nothing happened", because the
/// question people ask is never "did it run" — it is "why didn't it".
public enum AutomationOutcome: Sendable, Hashable {
    /// It ran and something changed.
    case ran

    /// It ran and everything was already the way it asked for.
    case noChange

    /// The trigger matched but the conditions did not.
    case conditionsNotMet

    /// Switched off, or holding a trigger or action this build cannot read.
    case notRunnable

    /// It needs an integration that does not exist yet.
    case needsIntegration(IntegrationTarget)

    /// It was not offered the chance — a different trigger fired.
    case notTriggered

    public var didChangeAnything: Bool {
        self == .ran
    }

    public var explanation: String {
        switch self {
        case .ran: "Ran"
        case .noChange: "Nothing to change"
        case .conditionsNotMet: "Conditions did not match"
        case .notRunnable: "Switched off, or written by a newer version"
        case .needsIntegration(let target): "Needs \(target.displayName), which is not connected"
        case .notTriggered: "Not triggered"
        }
    }
}
