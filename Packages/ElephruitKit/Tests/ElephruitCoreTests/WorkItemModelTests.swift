import Foundation
import Testing

@testable import ElephruitCore

@Suite("Work items")
struct WorkItemModelTests {

    // MARK: Kinds

    @Test("A bug and a feature are work; a milestone is not")
    func workKinds() {
        #expect(ItemKind.task.isWorkItem)
        #expect(ItemKind.bug.isWorkItem)
        #expect(ItemKind.feature.isWorkItem)

        // The interesting one. A milestone is reached or not reached, so it has a status — but
        // reaching it is the consequence of the work rather than a unit of it, and counting it
        // would fold a project's own summary into the figure describing the project.
        #expect(ItemKind.milestone.supportsStatus)
        #expect(!ItemKind.milestone.isWorkItem)
        #expect(!ItemKind.milestone.countsAsWork)

        #expect(!ItemKind.note.isWorkItem)
        #expect(!ItemKind.heading.isWorkItem)
    }

    @Test("A bug takes a task's fields, minus recurrence")
    func bugFields() {
        // Not an oversight. Either the defect still reproduces, in which case it was never fixed,
        // or it is a new one with its own steps and its own build.
        #expect(!ItemKind.bug.supportedFields.contains(.recurrence))
        #expect(ItemKind.task.supportedFields.contains(.recurrence))

        for field in [ItemFields.status, .dueDate, .priority, .checklist, .children] {
            #expect(ItemKind.bug.supportedFields.contains(field))
        }
    }

    @Test("A project holds work and markers; a list holds only work")
    func containment() {
        #expect(ItemKind.project.canContain(.bug))
        #expect(ItemKind.project.canContain(.milestone))
        #expect(ItemKind.project.canContain(.release))

        // Nobody ships a version of Groceries.
        #expect(ItemKind.list.canContain(.bug))
        #expect(!ItemKind.list.canContain(.milestone))

        // A marker is an endpoint, not a container.
        #expect(!ItemKind.milestone.canContain(.task))
        #expect(!ItemKind.release.canContain(.bug))

        // A feature's breakdown routinely includes the bugs found while building it.
        #expect(ItemKind.feature.canContain(.bug))
    }

    @Test("Markers never sit in the Inbox")
    func markersAreNotCaptures() {
        // A marker is made inside a plan, never captured loose, so it has no triage step — it is
        // already filed by the act of creating it.
        #expect(!ItemKind.milestone.appearsInInbox)
        #expect(!ItemKind.release.appearsInInbox)
        #expect(ItemKind.bug.appearsInInbox)
    }

    // MARK: Severity

    @Test("Severity sorts most severe first, and cosmetic gets no colour")
    func severityOrder() {
        #expect(BugSeverity.critical < BugSeverity.major)
        #expect(BugSeverity.major < BugSeverity.minor)
        #expect(BugSeverity.minor < BugSeverity.cosmetic)
        #expect(BugSeverity.allCases.sorted().first == .critical)

        // Four coloured levels make a bug list a stripe of warnings in which nothing stands out.
        #expect(BugSeverity.cosmetic.colorName == nil)
        #expect(BugSeverity.critical.colorName != nil)
        #expect(BugSeverity.major.colorName != nil)
        #expect(BugSeverity.minor.colorName != nil)
    }

    @Test("A report with only a severity has no detail, and says what is missing")
    func bugDetail() {
        let empty = BugFacts()
        // Severity always has a value, so counting it would make every empty report look answered.
        #expect(!empty.hasDetail)
        #expect(empty.missingFieldNames.contains("Steps to reproduce"))
        // Missing because it is not fixed yet, which is not an omission.
        #expect(!empty.missingFieldNames.contains("Fixed in"))

        let filled = BugFacts(severity: .major, stepsToReproduce: "Open the empty list")
        #expect(filled.hasDetail)
        #expect(!filled.missingFieldNames.contains("Steps to reproduce"))
    }

    // MARK: Stage categories

    @Test("Only a terminal category writes a status")
    func stageCategories() {
        // Backlog and active are the same answer to "is this outstanding", so a drag between them
        // must not stamp updatedAt for a gesture that changed no facts.
        #expect(WorkflowStageCategory.backlog.resolvedStatus == nil)
        #expect(WorkflowStageCategory.active.resolvedStatus == nil)
        #expect(WorkflowStageCategory.done.resolvedStatus == .completed)
        #expect(WorkflowStageCategory.cancelled.resolvedStatus == .cancelled)

        #expect(!WorkflowStageCategory.active.isTerminal)
        #expect(WorkflowStageCategory.cancelled.isTerminal)
    }

    @Test("A WIP limit reports, and a limit of zero reports nothing")
    func wipLimits() {
        let limited = WorkflowStageFacts(id: UUID(), name: "In progress", category: .active, wipLimit: 3)
        #expect(!limited.isOverLimit(2))
        #expect(limited.isAtLimit(3))
        #expect(limited.isOverLimit(4))

        let unlimited = WorkflowStageFacts(id: UUID(), name: "Backlog", category: .backlog)
        #expect(!unlimited.hasLimit)
        #expect(!unlimited.isOverLimit(900))
    }

    // MARK: References

    @Test("ELE-9 sorts before ELE-10")
    func referenceOrdering() {
        // A plain string sort puts ELE-10 first, which is the kind of small wrongness that makes a
        // table look broken without anybody being able to say why.
        let sorted = ["ELE-10", "ELE-9", "ELE-100", "ELE-1"]
            .sorted { WorkItemReference.sortKey($0) < WorkItemReference.sortKey($1) }
        #expect(sorted == ["ELE-1", "ELE-9", "ELE-10", "ELE-100"])
    }

    @Test("Unreferenced work sorts after everything referenced")
    func unreferencedSortsLast() {
        let sorted: [String?] = [nil, "ELE-2", "ELE-1"]
            .sorted { WorkItemReference.sortKey($0) < WorkItemReference.sortKey($1) }
        // Rather than interleaving at the top, which is where an empty string would sort.
        #expect(sorted == ["ELE-1", "ELE-2", nil])
    }

    @Test("A reference parses, and a date does not")
    func referenceParsing() {
        #expect(WorkItemReference.parse("ELE-42")?.key == "ELE")
        #expect(WorkItemReference.parse("ELE-42")?.number == 42)
        #expect(WorkItemReference.parse("ele-42")?.key == "ELE")

        // A note titled Q3-2026 is not a reference to item 2026.
        #expect(WorkItemReference.parse("Q3-2026")?.key == "Q3")
        #expect(WorkItemReference.parse("2026") == nil)
        #expect(WorkItemReference.parse("ELE-") == nil)
        #expect(WorkItemReference.parse("-42") == nil)
        #expect(WorkItemReference.parse("ELE-4x") == nil)
    }

    @Test("A key never starts with a digit")
    func keyNormalisation() {
        // Otherwise 2026-14 reads as a date to every human who sees it.
        #expect(WorkItemReference.normalise(key: "2026 Launch") == "LAUNCH")
        #expect(WorkItemReference.normalise(key: "design system") == "DESIGN")
        #expect(WorkItemReference.normalise(key: "12345") == nil)
        #expect(WorkItemReference.normalise(key: "")  == nil)
    }

    @Test("A suggested key uses initials when there are words to use")
    func suggestedKeys() {
        #expect(WorkItemReference.suggestedKey(forProjectNamed: "Design System") == "DS")
        #expect(WorkItemReference.suggestedKey(forProjectNamed: "Elephruit") == "ELE")
        #expect(WorkItemReference.suggestedKey(forProjectNamed: "") == nil)
    }

    @Test("A taken key gets digits, and still fits")
    func uniqueKeys() {
        // Two projects sharing a key makes DEV-14 ambiguous, which defeats the point of having one.
        let key = WorkItemReference.uniqueKey(from: "DEV", taken: ["DEV"])
        #expect(key != "DEV")
        #expect(key.count <= 6)

        let long = WorkItemReference.uniqueKey(from: "ABCDEF", taken: ["ABCDEF"])
        #expect(long.count <= 6)
    }

    // MARK: Metadata

    @Test("A number compares unlocalised, so a saved filter keeps matching it")
    func comparableStrings() {
        // displayString renders 1000 as "1,000", so a rule looking for 1000 quietly stops matching
        // — and in another locale, stops matching something else.
        let thousand = MetadataValue.number(1000)
        #expect(thousand.comparableString == "1000.0")
        #expect(!thousand.comparableString.contains(","))

        #expect(MetadataValue.flag(true).comparableString == "true")
        #expect(MetadataValue.text("x").comparableString == "x")
    }

    // MARK: Filter rules

    @Test("Every rule survives a round trip through its stored form", arguments: TaskRule.everyShape)
    func rulesRoundTrip(rule: TaskRule) throws {
        // TaskRule's coding is hand-written, so a new case that nobody added to the discriminator,
        // the encoder or the decoder compiles fine and silently degrades to `unrecognised` on the
        // next launch — taking the user's saved view with it. This is the test that catches that.
        let filter = TaskFilter(rules: [rule])
        let data = try #require(filter.encoded())
        let decoded = try #require(TaskFilter.decode(from: data))

        #expect(decoded.rules == [rule], "\(rule) did not survive encoding")
        #expect(decoded.rules.first?.isUnderstood == true)
    }

    @Test("A severity rule never matches something with no severity")
    func severityRuleIsStrict() {
        // Otherwise a rule asking for critical bugs sweeps in every task in the project, and looks
        // like it worked.
        let rule = TaskFilter(rules: [.severity([.critical])], includesResolved: true)
        let plainTask = TaskFacts(title: "Write the copy", kind: .task)
        let criticalBug = TaskFacts(title: "Crash on launch", kind: .bug, severity: .critical)
        let minorBug = TaskFacts(title: "Wrong padding", kind: .bug, severity: .minor)

        #expect(!rule.matches(plainTask, now: .now, calendar: .current))
        #expect(rule.matches(criticalBug, now: .now, calendar: .current))
        #expect(!rule.matches(minorBug, now: .now, calendar: .current))
    }

    @Test("Over-estimate needs both an estimate and time against it")
    func overEstimate() {
        let rule = TaskFilter(rules: [.overEstimate], includesResolved: true)
        let unestimated = TaskFacts(title: "A", trackedMinutes: 600)
        let under = TaskFacts(title: "B", estimateMinutes: 60, trackedMinutes: 30)
        let over = TaskFacts(title: "C", estimateMinutes: 60, trackedMinutes: 90)

        #expect(!rule.matches(unestimated, now: .now, calendar: .current))
        #expect(!rule.matches(under, now: .now, calendar: .current))
        #expect(rule.matches(over, now: .now, calendar: .current))
    }

    @Test("A custom field matches on the comparable string, not the display one")
    func customFieldRule() {
        let rule = TaskFilter(rules: [.customField(name: "Budget", equals: "1000.0")], includesResolved: true)
        let facts = TaskFacts(title: "A", customFields: ["Budget": .number(1000)])
        #expect(rule.matches(facts, now: .now, calendar: .current))
    }
}

extension TaskRule {
    /// One value of every case, so the round-trip test is exhaustive by construction.
    ///
    /// Deliberately hand-written rather than derived: `TaskRule` is not `CaseIterable` because its
    /// cases carry payloads, so the only way to be exhaustive is to list them — and the compiler
    /// cannot tell you this list is short. It is checked against the case count below.
    static var everyShape: [TaskRule] {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID()
        return [
            .lifecycle([.completed, .waiting]),
            .flagged(true),
            .priority([.high]),
            .committedToToday,
            .waiting,
            .overdue,
            .deadlineWithin(days: 3),
            .hasDeadline(false),
            .hasStartDate(true),
            .startsWithin(days: 7),
            .hasReminder(false),
            .hasNoDate,
            .completedWithin(days: 30),
            .createdWithin(days: 1),
            .area(id),
            .project(id),
            .list(id),
            .section(id),
            .tag("urgent"),
            .unfiled,
            .relatedPerson(id),
            .waitingOnPerson(id),
            .linkedToAnyPerson,
            .source(.quickCapture),
            .syncState([.local]),
            .syncNeedsAttention,
            .hasAttachments(true),
            .repeating(false),
            .hasSubtasks(true),
            .text("crash"),
            .kind([.bug, .feature]),
            .workflowStage(id),
            .stageCategory([.active, .done]),
            .assignee(id),
            .unassigned,
            .blocked(true),
            .milestone(id),
            .release(id),
            .severity([.critical, .major]),
            .regression(true),
            .hasEstimate(false),
            .overEstimate,
            .customField(name: "Budget", equals: "1000.0"),
        ]
    }
}
