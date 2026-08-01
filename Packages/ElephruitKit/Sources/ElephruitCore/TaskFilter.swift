import Foundation

/// One condition a task either meets or does not.
///
/// ### Why an enum rather than a query string
/// Saved *searches* store the text the user typed, deliberately, so they survive a grammar change
/// and can be read and edited by hand. A smart list is a different thing: it is built by picking
/// from menus, it has to round-trip back into those menus for editing, and half its conditions —
/// "in this project", "waiting on this person" — refer to records by identity rather than by name.
/// A string cannot hold an identity that survives a rename, and re-parsing one to fill in a picker
/// means the picker and the text can disagree.
///
/// So this is `Codable` and stored as JSON. Unknown cases are the one real cost, and they are
/// handled: a rule written by a newer build decodes as ``TaskRule/unrecognised`` and the smart list
/// says so rather than silently matching everything.
public enum TaskRule: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    case lifecycle(Set<TaskLifecycle>)
    case flagged(Bool)
    case priority(Set<Priority>)
    case committedToToday
    case waiting

    // MARK: Dates

    /// Past its deadline as of the evaluation instant.
    case overdue

    /// Has a deadline within `days` days. `0` means today.
    case deadlineWithin(days: Int)

    case hasDeadline(Bool)
    case hasStartDate(Bool)

    /// Becomes available within `days` days.
    case startsWithin(days: Int)

    case hasReminder(Bool)

    /// No start date, no deadline, no reminder. The pile that needs a decision.
    case hasNoDate

    case completedWithin(days: Int)
    case createdWithin(days: Int)

    // MARK: Filing

    case area(UUID)
    case project(UUID)
    case list(UUID)
    case section(UUID)
    case tag(String)

    /// Filed nowhere at all.
    case unfiled

    // MARK: Relationships

    case relatedPerson(UUID)
    case waitingOnPerson(UUID)

    /// Linked to any person at all.
    case linkedToAnyPerson

    // MARK: Provenance and sync

    case source(SourceKind)
    case syncState(Set<TaskSyncState>)

    /// Any sync state the user has to do something about.
    case syncNeedsAttention

    // MARK: Content

    case hasAttachments(Bool)
    case repeating(Bool)
    case hasSubtasks(Bool)

    /// Matched against the folded title and notes.
    case text(String)

    // MARK: Project workspace
    //
    // These are rules, not a second filter engine, and that is the decision worth defending. A
    // board column, a table, a bug list and a saved smart list all ask the same question of the
    // same facts. Two engines would be two copies of every subtlety — and it means "every critical
    // bug across the whole library" is something the existing smart-list editor can already build.

    /// Which kinds of work — task, bug, feature.
    case kind(Set<ItemKind>)

    /// Sitting in one specific board column.
    case workflowStage(UUID)

    /// Sitting in any column of these categories. Survives a column being renamed or replaced,
    /// which `workflowStage` does not.
    case stageCategory(Set<WorkflowStageCategory>)

    case assignee(UUID)

    /// Nobody has taken it.
    case unassigned

    case blocked(Bool)

    case milestone(UUID)
    case release(UUID)

    /// **Never matches an item with no severity.** A rule asking for critical bugs that swept in
    /// every task in the project would be worse than useless: it would look like it worked.
    case severity(Set<BugSeverity>)

    case regression(Bool)

    case hasEstimate(Bool)

    /// Tracked time has passed the estimate.
    case overEstimate

    /// A custom field holds this value. Compared against ``MetadataValue/comparableString``, not the
    /// display string, so the match does not depend on the reader's locale.
    case customField(name: String, equals: String)

    /// A rule this build does not understand, preserved so editing a smart list written by a newer
    /// version does not destroy it.
    case unrecognised(name: String)

    /// A one-line description, for the rule editor and for explaining a list's contents.
    public var summary: String {
        switch self {
        case .lifecycle(let states):
            "Status is " + states.map(\.displayName).sorted().formatted(.list(type: .or))
        case .flagged(let value):
            value ? "Flagged" : "Not flagged"
        case .priority(let values):
            "Priority is " + values.map(\.displayName).sorted().formatted(.list(type: .or))
        case .committedToToday:
            "Chosen for today"
        case .waiting:
            "Waiting on somebody"
        case .overdue:
            "Past its deadline"
        case .deadlineWithin(let days):
            days == 0 ? "Deadline today" : "Deadline within \(days) days"
        case .hasDeadline(let value):
            value ? "Has a deadline" : "Has no deadline"
        case .hasStartDate(let value):
            value ? "Has a start date" : "Has no start date"
        case .startsWithin(let days):
            days == 0 ? "Starts today" : "Starts within \(days) days"
        case .hasReminder(let value):
            value ? "Has a reminder" : "Has no reminder"
        case .hasNoDate:
            "Has no dates at all"
        case .completedWithin(let days):
            "Finished in the last \(days) days"
        case .createdWithin(let days):
            "Added in the last \(days) days"
        case .area:
            "In a particular area"
        case .project:
            "In a particular project"
        case .list:
            "In a particular list"
        case .section:
            "In a particular section"
        case .tag(let slug):
            "Tagged #\(slug)"
        case .unfiled:
            "Filed nowhere"
        case .relatedPerson:
            "Linked to a particular person"
        case .waitingOnPerson:
            "Waiting on a particular person"
        case .linkedToAnyPerson:
            "Linked to somebody"
        case .source(let kind):
            "Came from \(kind.displayName)"
        case .syncState(let states):
            "Sync state is " + states.map(\.displayName).sorted().formatted(.list(type: .or))
        case .syncNeedsAttention:
            "Reminders sync needs review"
        case .hasAttachments(let value):
            value ? "Has attachments" : "Has no attachments"
        case .repeating(let value):
            value ? "Repeats" : "Does not repeat"
        case .hasSubtasks(let value):
            value ? "Has subtasks" : "Has no subtasks"
        case .text(let text):
            "Mentions “\(text)”"

        case .kind(let kinds):
            "Type is " + kinds.map(\.displayName).sorted().formatted(.list(type: .or))
        case .workflowStage:
            "In a particular stage"
        case .stageCategory(let categories):
            "Stage is " + categories.map(\.displayName).sorted().formatted(.list(type: .or))
        case .assignee:
            "Assigned to a particular person"
        case .unassigned:
            "Nobody assigned"
        case .blocked(let value):
            value ? "Blocked" : "Not blocked"
        case .milestone:
            "Aimed at a particular milestone"
        case .release:
            "Part of a particular release"
        case .severity(let severities):
            "Severity is " + severities.map(\.displayName).sorted().formatted(.list(type: .or))
        case .regression(let value):
            value ? "Is a regression" : "Is not a regression"
        case .hasEstimate(let value):
            value ? "Has an estimate" : "Has no estimate"
        case .overEstimate:
            "Over its estimate"
        case .customField(let name, let value):
            "\(name) is “\(value)”"

        case .unrecognised(let name):
            "Unknown condition (\(name))"
        }
    }

    /// Whether this rule can be evaluated at all by this build.
    public var isUnderstood: Bool {
        if case .unrecognised = self { return false }
        return true
    }
}

/// A set of conditions and how to combine them.
public struct TaskFilter: Sendable, Hashable, Codable {
    public enum Match: String, Sendable, Hashable, Codable, CaseIterable {
        /// Every rule must hold.
        case all
        /// Any one rule is enough.
        case any

        public var displayName: String {
            switch self {
            case .all: "all of"
            case .any: "any of"
            }
        }
    }

    public var match: Match
    public var rules: [TaskRule]

    /// Whether completed and cancelled work may appear.
    ///
    /// Separate from the rules because it is a *scope*, not a condition: almost every smart list
    /// wants open work, and making each one carry an explicit "status is not completed" rule would
    /// be a line of noise on every list plus a trap for the one that forgot it.
    public var includesResolved: Bool

    public init(match: Match = .all, rules: [TaskRule] = [], includesResolved: Bool = false) {
        self.match = match
        self.rules = rules
        self.includesResolved = includesResolved
    }

    /// Whether the filter would match everything.
    ///
    /// A smart list with no rules is almost always a half-finished one, and showing the entire
    /// library under a name like "Client work" is worse than showing nothing.
    public var isUnconstrained: Bool {
        rules.isEmpty
    }

    /// Rules this build cannot evaluate.
    public var unrecognisedRules: [TaskRule] {
        rules.filter { !$0.isUnderstood }
    }

    // MARK: - Evaluation

    /// Whether one task belongs in this list.
    ///
    /// Pure, and taking its clock as an argument, so every date-relative rule is testable across a
    /// daylight-saving boundary without touching the machine's settings.
    ///
    /// An unrecognised rule **fails** under `.all` and is **skipped** under `.any`. Both readings
    /// are the conservative one: a list whose author asked for four conditions and got three should
    /// show less than intended, never more.
    public func matches(_ facts: TaskFacts, now: Date, calendar: Calendar) -> Bool {
        if !includesResolved, !facts.lifecycle.isOpen { return false }
        if rules.isEmpty { return includesResolved || facts.lifecycle.isOpen }

        switch match {
        case .all:
            return rules.allSatisfy { evaluate($0, facts, now, calendar) }
        case .any:
            return rules.contains { $0.isUnderstood && evaluate($0, facts, now, calendar) }
        }
    }

    private func evaluate(_ rule: TaskRule, _ facts: TaskFacts, _ now: Date, _ calendar: Calendar) -> Bool {
        func whollyWithin(_ date: Date?, days: Int) -> Bool {
            guard let date else { return false }
            let today = calendar.startOfDay(for: now)
            let target = calendar.startOfDay(for: date)
            guard let delta = calendar.dateComponents([.day], from: today, to: target).day else { return false }
            return delta >= 0 && delta <= days
        }

        func withinPast(_ date: Date?, days: Int) -> Bool {
            guard let date else { return false }
            let today = calendar.startOfDay(for: now)
            let target = calendar.startOfDay(for: date)
            guard let delta = calendar.dateComponents([.day], from: target, to: today).day else { return false }
            return delta >= 0 && delta <= days
        }

        switch rule {
        case .lifecycle(let states):
            return states.contains(facts.lifecycle)
        case .flagged(let value):
            return facts.isFlagged == value
        case .priority(let values):
            return values.contains(facts.priority)
        case .committedToToday:
            return facts.isCommittedToToday(on: now, calendar: calendar)
        case .waiting:
            return facts.lifecycle == .waiting

        case .overdue:
            return facts.deadlineUrgency(on: now, calendar: calendar).isOverdue
        case .deadlineWithin(let days):
            return whollyWithin(facts.deadlineAt, days: days)
        case .hasDeadline(let value):
            return (facts.deadlineAt != nil) == value
        case .hasStartDate(let value):
            return (facts.startAt != nil) == value
        case .startsWithin(let days):
            return whollyWithin(facts.startAt, days: days)
        case .hasReminder(let value):
            return (facts.reminderAt != nil) == value
        case .hasNoDate:
            return facts.startAt == nil && facts.deadlineAt == nil && facts.reminderAt == nil
        case .completedWithin(let days):
            return withinPast(facts.completedAt ?? facts.cancelledAt, days: days)
        case .createdWithin(let days):
            return withinPast(facts.createdAt, days: days)

        case .area(let id):
            return facts.areaID == id
        case .project(let id):
            return facts.projectID == id
        case .list(let id):
            return facts.listID == id
        case .section(let id):
            return facts.sectionID == id
        case .tag(let slug):
            return facts.tagSlugs.contains(slug)
        case .unfiled:
            return !facts.hasHome

        case .relatedPerson(let id):
            return facts.relatedPersonIDs.contains(id) || facts.waitingOnPersonID == id
        case .waitingOnPerson(let id):
            return facts.waitingOnPersonID == id
        case .linkedToAnyPerson:
            return !facts.relatedPersonIDs.isEmpty || facts.waitingOnPersonID != nil

        case .source(let kind):
            return facts.source == kind
        case .syncState(let states):
            return states.contains(facts.syncState)
        case .syncNeedsAttention:
            return facts.syncState.needsAttention

        case .hasAttachments(let value):
            return facts.hasAttachments == value
        case .repeating(let value):
            return facts.isRepeating == value
        case .hasSubtasks(let value):
            return facts.hasSubtasks == value
        case .text(let text):
            let folded = TextNormalizer.foldedForMatching(text)
            return folded.isEmpty || facts.searchText.contains(folded)

        case .kind(let kinds):
            return kinds.contains(facts.kind)
        case .workflowStage(let id):
            return facts.workflowStageID == id
        case .stageCategory(let categories):
            guard let category = facts.stageCategory else { return false }
            return categories.contains(category)
        case .assignee(let id):
            return facts.assigneeID == id
        case .unassigned:
            return facts.assigneeID == nil
        case .blocked(let value):
            return facts.isBlocked == value
        case .milestone(let id):
            return facts.milestoneID == id
        case .release(let id):
            return facts.releaseID == id
        case .severity(let severities):
            // No severity is not a match, ever. See the case's own note: a rule asking for critical
            // bugs must not quietly return every task in the project.
            guard let severity = facts.severity else { return false }
            return severities.contains(severity)
        case .regression(let value):
            return facts.isRegression == value
        case .hasEstimate(let value):
            return (facts.estimateMinutes != nil) == value
        case .overEstimate:
            guard let estimate = facts.estimateMinutes, estimate > 0 else { return false }
            return facts.trackedMinutes > estimate
        case .customField(let name, let value):
            return facts.customFields[name]?.comparableString == value

        case .unrecognised:
            return false
        }
    }
}

// MARK: - Built-in lists

/// A smart list the app ships with.
///
/// Built-ins are declared as filters rather than as bespoke query code so they are the *same*
/// mechanism the user's own lists use. A built-in that took a shortcut the user's lists cannot take
/// is a built-in whose behaviour cannot be reproduced, and the first question anybody asks of a
/// smart list is "how do I make one like that?".
public struct BuiltInSmartList: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var symbolName: String
    public var hint: String
    public var filter: TaskFilter

    public init(id: String, title: String, symbolName: String, hint: String, filter: TaskFilter) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.hint = hint
        self.filter = filter
    }

    public static let all: [BuiltInSmartList] = [
        BuiltInSmartList(
            id: "overdue",
            title: "Overdue",
            symbolName: "clock.badge.exclamationmark",
            hint: "Past a deadline you set. Nothing here is a start date.",
            filter: TaskFilter(rules: [.overdue])
        ),
        BuiltInSmartList(
            id: "due-soon",
            title: "Due Soon",
            symbolName: "calendar.badge.clock",
            hint: "A deadline inside the next week.",
            filter: TaskFilter(rules: [.deadlineWithin(days: 7)])
        ),
        BuiltInSmartList(
            id: "no-date",
            title: "No Date",
            symbolName: "calendar.badge.minus",
            hint: "Nothing scheduled, due, or set to remind. Work waiting on a decision.",
            filter: TaskFilter(rules: [.hasNoDate])
        ),
        BuiltInSmartList(
            id: "waiting",
            title: "Waiting",
            symbolName: "hourglass",
            hint: "Somebody else has the next move.",
            filter: TaskFilter(rules: [.waiting])
        ),
        BuiltInSmartList(
            id: "today-plan",
            title: "Assigned to Today",
            symbolName: "hand.point.right",
            hint: "What you deliberately picked, as opposed to what the calendar picked for you.",
            filter: TaskFilter(rules: [.committedToToday])
        ),
        BuiltInSmartList(
            id: "recently-added",
            title: "Recently Added",
            symbolName: "sparkles",
            hint: "Captured in the last three days.",
            filter: TaskFilter(rules: [.createdWithin(days: 3)])
        ),
        BuiltInSmartList(
            id: "recently-completed",
            title: "Recently Completed",
            symbolName: "checkmark.circle",
            hint: "Finished or abandoned in the last week.",
            filter: TaskFilter(
                rules: [.completedWithin(days: 7)],
                includesResolved: true
            )
        ),
        BuiltInSmartList(
            id: "linked-to-people",
            title: "Linked to People",
            symbolName: "person.2",
            hint: "Work that involves somebody, however it is filed.",
            filter: TaskFilter(rules: [.linkedToAnyPerson])
        ),
        BuiltInSmartList(
            id: "open-promises",
            title: "Open Tasks with People",
            symbolName: "hand.raised",
            hint: "Something you owe somebody, or somebody owes you.",
            filter: TaskFilter(
                match: .any,
                rules: [.waiting, .linkedToAnyPerson]
            )
        ),
        BuiltInSmartList(
            id: "has-attachments",
            title: "Has Attachments",
            symbolName: "paperclip",
            hint: "Tasks carrying a file.",
            filter: TaskFilter(rules: [.hasAttachments(true)])
        ),
        BuiltInSmartList(
            id: "repeating",
            title: "Repeating",
            symbolName: "repeat",
            hint: "Everything on a cycle, so the cycle itself can be reviewed.",
            filter: TaskFilter(rules: [.repeating(true)])
        ),
        // ### Why this list exists
        // Because imported reminders stopped appearing in the Inbox, and a thing that is nowhere is
        // worse than a thing in the wrong place. Their home is the list they came from, in another
        // application — true, and not somewhere this app can show you. This is where they are
        // reachable *here*: everything brought in from Reminders, in one place, whether or not it
        // has been filed since. See ``ElephruitModel/Item/hasHome``.
        BuiltInSmartList(
            id: "from-reminders",
            title: "From Reminders",
            symbolName: "app.badge.checkmark",
            hint: "Brought in from your Reminders lists, and kept in step with them.",
            filter: TaskFilter(rules: [.source(.systemStore)])
        ),
        BuiltInSmartList(
            id: "sync-issues",
            title: "Reminders Sync Issues",
            symbolName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
            hint: "Linked reminders that disagree, went missing, or cannot be written to.",
            filter: TaskFilter(rules: [.syncNeedsAttention], includesResolved: true)
        ),
    ]

    public static func list(id: String) -> BuiltInSmartList? {
        all.first { $0.id == id }
    }
}

// MARK: - Codable

/// Hand-written coding, because `TaskRule` carries payloads of several shapes and the synthesised
/// form would make the stored JSON a compiler implementation detail — unreadable by a person and
/// liable to change under us. A named discriminator plus named values survives adding a case, and
/// an unknown discriminator decodes to ``TaskRule/unrecognised(name:)`` rather than throwing away
/// the whole smart list.
extension TaskRule {
    private enum CodingKeys: String, CodingKey {
        case name, states, value, days, id, slug, text, priorities, source, syncStates
        case kinds, categories, severities, field
    }

    private var discriminator: String {
        switch self {
        case .lifecycle: "lifecycle"
        case .flagged: "flagged"
        case .priority: "priority"
        case .committedToToday: "committedToToday"
        case .waiting: "waiting"
        case .overdue: "overdue"
        case .deadlineWithin: "deadlineWithin"
        case .hasDeadline: "hasDeadline"
        case .hasStartDate: "hasStartDate"
        case .startsWithin: "startsWithin"
        case .hasReminder: "hasReminder"
        case .hasNoDate: "hasNoDate"
        case .completedWithin: "completedWithin"
        case .createdWithin: "createdWithin"
        case .area: "area"
        case .project: "project"
        case .list: "list"
        case .section: "section"
        case .tag: "tag"
        case .unfiled: "unfiled"
        case .relatedPerson: "relatedPerson"
        case .waitingOnPerson: "waitingOnPerson"
        case .linkedToAnyPerson: "linkedToAnyPerson"
        case .source: "source"
        case .syncState: "syncState"
        case .syncNeedsAttention: "syncNeedsAttention"
        case .hasAttachments: "hasAttachments"
        case .repeating: "repeating"
        case .hasSubtasks: "hasSubtasks"
        case .text: "text"
        case .kind: "kind"
        case .workflowStage: "workflowStage"
        case .stageCategory: "stageCategory"
        case .assignee: "assignee"
        case .unassigned: "unassigned"
        case .blocked: "blocked"
        case .milestone: "milestone"
        case .release: "release"
        case .severity: "severity"
        case .regression: "regression"
        case .hasEstimate: "hasEstimate"
        case .overEstimate: "overEstimate"
        case .customField: "customField"
        case .unrecognised(let name): name
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(discriminator, forKey: .name)

        switch self {
        case .lifecycle(let states):
            try container.encode(states.map(\.rawValue).sorted(), forKey: .states)
        case .priority(let values):
            try container.encode(values.map(\.rawValue).sorted(), forKey: .priorities)
        case .syncState(let states):
            try container.encode(states.map(\.rawValue).sorted(), forKey: .syncStates)
        case .kind(let kinds):
            try container.encode(kinds.map(\.rawValue).sorted(), forKey: .kinds)
        case .stageCategory(let categories):
            try container.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        case .severity(let severities):
            try container.encode(severities.map(\.rawValue).sorted(), forKey: .severities)
        case .customField(let name, let value):
            try container.encode(name, forKey: .field)
            try container.encode(value, forKey: .value)
        case .flagged(let value), .hasDeadline(let value), .hasStartDate(let value),
             .hasReminder(let value), .hasAttachments(let value), .repeating(let value),
             .hasSubtasks(let value), .blocked(let value), .regression(let value),
             .hasEstimate(let value):
            try container.encode(value, forKey: .value)
        case .deadlineWithin(let days), .startsWithin(let days),
             .completedWithin(let days), .createdWithin(let days):
            try container.encode(days, forKey: .days)
        case .area(let id), .project(let id), .list(let id), .section(let id),
             .relatedPerson(let id), .waitingOnPerson(let id), .workflowStage(let id),
             .assignee(let id), .milestone(let id), .release(let id):
            try container.encode(id, forKey: .id)
        case .tag(let slug):
            try container.encode(slug, forKey: .slug)
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .source(let kind):
            try container.encode(kind.rawValue, forKey: .source)
        case .committedToToday, .waiting, .overdue, .hasNoDate, .unfiled,
             .linkedToAnyPerson, .syncNeedsAttention, .unassigned, .overEstimate, .unrecognised:
            break
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)

        func bool() throws -> Bool { try container.decodeIfPresent(Bool.self, forKey: .value) ?? true }
        func days() throws -> Int { try container.decodeIfPresent(Int.self, forKey: .days) ?? 0 }
        func identifier() throws -> UUID? { try container.decodeIfPresent(UUID.self, forKey: .id) }

        switch name {
        case "lifecycle":
            let raws = try container.decodeIfPresent([String].self, forKey: .states) ?? []
            self = .lifecycle(Set(raws.compactMap(TaskLifecycle.init(rawValue:))))
        case "priority":
            let raws = try container.decodeIfPresent([String].self, forKey: .priorities) ?? []
            self = .priority(Set(raws.compactMap(Priority.init(rawValue:))))
        case "syncState":
            let raws = try container.decodeIfPresent([String].self, forKey: .syncStates) ?? []
            self = .syncState(Set(raws.compactMap(TaskSyncState.init(rawValue:))))
        case "flagged": self = .flagged(try bool())
        case "hasDeadline": self = .hasDeadline(try bool())
        case "hasStartDate": self = .hasStartDate(try bool())
        case "hasReminder": self = .hasReminder(try bool())
        case "hasAttachments": self = .hasAttachments(try bool())
        case "repeating": self = .repeating(try bool())
        case "hasSubtasks": self = .hasSubtasks(try bool())
        case "blocked": self = .blocked(try bool())
        case "regression": self = .regression(try bool())
        case "hasEstimate": self = .hasEstimate(try bool())
        case "unassigned": self = .unassigned
        case "overEstimate": self = .overEstimate
        case "kind":
            let raws = try container.decodeIfPresent([String].self, forKey: .kinds) ?? []
            self = .kind(Set(raws.compactMap(ItemKind.init(rawValue:))))
        case "stageCategory":
            let raws = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
            self = .stageCategory(Set(raws.compactMap(WorkflowStageCategory.init(rawValue:))))
        case "severity":
            let raws = try container.decodeIfPresent([String].self, forKey: .severities) ?? []
            self = .severity(Set(raws.compactMap(BugSeverity.init(rawValue:))))
        case "customField":
            guard let field = try container.decodeIfPresent(String.self, forKey: .field) else {
                self = .unrecognised(name: name)
                return
            }
            let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
            self = .customField(name: field, equals: value)
        case "deadlineWithin": self = .deadlineWithin(days: try days())
        case "startsWithin": self = .startsWithin(days: try days())
        case "completedWithin": self = .completedWithin(days: try days())
        case "createdWithin": self = .createdWithin(days: try days())
        case "committedToToday": self = .committedToToday
        case "waiting": self = .waiting
        case "overdue": self = .overdue
        case "hasNoDate": self = .hasNoDate
        case "unfiled": self = .unfiled
        case "linkedToAnyPerson": self = .linkedToAnyPerson
        case "syncNeedsAttention": self = .syncNeedsAttention
        case "tag":
            self = .tag(try container.decodeIfPresent(String.self, forKey: .slug) ?? "")
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "source":
            let raw = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
            self = SourceKind(rawValue: raw).map { TaskRule.source($0) } ?? .unrecognised(name: name)
        case "area", "project", "list", "section", "relatedPerson", "waitingOnPerson",
             "workflowStage", "assignee", "milestone", "release":
            guard let id = try identifier() else { self = .unrecognised(name: name); return }
            self = switch name {
            case "area": .area(id)
            case "project": .project(id)
            case "list": .list(id)
            case "section": .section(id)
            case "relatedPerson": .relatedPerson(id)
            case "workflowStage": .workflowStage(id)
            case "assignee": .assignee(id)
            case "milestone": .milestone(id)
            case "release": .release(id)
            default: .waitingOnPerson(id)
            }
        default:
            self = .unrecognised(name: name)
        }
    }
}

extension TaskFilter {
    /// Decodes a filter from its stored form.
    ///
    /// `nil` for absent or unreadable data, on the same terms as ``RecurrenceRule/decode(from:)`` —
    /// a smart list whose rules cannot be read is better shown as a list with no rules, which the
    /// interface can explain, than as a crash.
    public static func decode(from data: Data?) -> TaskFilter? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(TaskFilter.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
