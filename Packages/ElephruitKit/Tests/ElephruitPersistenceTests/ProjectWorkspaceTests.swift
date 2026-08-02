import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
private struct WorkspaceFixture {
    let store: StoreFixture
    let workspace: ProjectWorkspaceService
    let workItems: WorkItemService
    let bugs: BugService
    let inbox: InboxService
    let templates: ProjectTemplateService
    let automations: AutomationEngine
    let reports: ProjectReportingService

    init() throws {
        store = try StoreFixture()
        workspace = ProjectWorkspaceService(
            items: store.items,
            context: store.context,
            dateProvider: store.dateProvider
        )
        workItems = WorkItemService(
            items: store.items,
            workspace: workspace,
            context: store.context,
            dateProvider: store.dateProvider
        )
        bugs = BugService(
            items: store.items,
            workItems: workItems,
            context: store.context,
            dateProvider: store.dateProvider
        )
        inbox = InboxService(context: store.context, dateProvider: store.dateProvider)
        templates = ProjectTemplateService(
            items: store.items,
            workspace: workspace,
            workItems: workItems,
            context: store.context
        )
        automations = AutomationEngine(
            items: store.items,
            workspace: workspace,
            workItems: workItems,
            bugs: bugs,
            inbox: inbox,
            context: store.context,
            dateProvider: store.dateProvider
        )
        reports = ProjectReportingService(
            workspace: workspace,
            bugs: bugs,
            dateProvider: store.dateProvider
        )
    }

    func makeProject(_ name: String = "Elephruit", template: ProjectTemplate = .blank) throws -> Item {
        try templates.createProject(named: name, from: template)
    }
}

// MARK: - The two axes

@Suite("Project board")
@MainActor
struct ProjectBoardTests {
    @Test("Setting a board item's due date makes it eligible for Today")
    func dueDateRefreshesTodayIndex() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let task = try fixture.workItems.createWorkItem(title: "Redesign tasks", in: project)
        let today = fixture.store.dateProvider.startOfToday

        #expect(task.dayRelevanceKey == .distantFuture)

        try fixture.workItems.setDueDate(today, on: task)

        #expect(task.dayRelevanceKey == today)

        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = [.open]
        query.dayRelevantBefore = fixture.store.dateProvider.startOfTomorrow

        #expect(try fixture.store.items.items(matching: query).map(\.id).contains(task.id))
    }

    @Test("Dropping into a terminal column resolves the work")
    func terminalColumnWritesStatus() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let stages = fixture.workspace.stages(in: project)
        let done = try #require(stages.first { $0.category == .done })

        let task = try fixture.workItems.createWorkItem(title: "Ship it", in: project)
        let move = try fixture.workspace.move(task, to: done)

        #expect(move.resolvedStatus == .completed)
        #expect(task.status == .completed)
        #expect(task.completedAt != nil)
    }

    @Test("Moving between two open columns writes nothing about the lifecycle")
    func openToOpenIsSilent() throws {
        // Backlog and active are the same answer to "is this outstanding", so treating the drag as a
        // lifecycle change would put a line in the history for a gesture that changed no facts.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let stages = fixture.workspace.stages(in: project)
        let todo = try #require(stages.first { $0.category == .backlog })
        let doing = try #require(stages.first { $0.category == .active })

        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project, stage: todo)
        let move = try fixture.workspace.move(task, to: doing)

        #expect(move.resolvedStatus == nil)
        #expect(!move.changedStatus)
        #expect(task.status == .open)
        #expect(task.workflowStageID == doing.id)
    }

    @Test("Dragging finished work back out reopens it")
    func leavingTerminalReopens() throws {
        // Or the board sits there disagreeing with itself: a card in "In progress" that the rest of
        // the app believes is done.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let stages = fixture.workspace.stages(in: project)
        let doing = try #require(stages.first { $0.category == .active })
        let done = try #require(stages.first { $0.category == .done })

        let task = try fixture.workItems.createWorkItem(title: "Ship it", in: project)
        try fixture.workspace.move(task, to: done)
        let move = try fixture.workspace.move(task, to: doing)

        #expect(move.didReopen)
        #expect(task.status == .open)
        #expect(task.completedAt == nil)
    }

    @Test("Removing a column unplaces its work rather than stranding it")
    func removingColumnUnplaces() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let doing = try #require(fixture.workspace.stages(in: project).first { $0.category == .active })

        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project, stage: doing)
        try fixture.workspace.removeStage(doing, movingItemsTo: nil)

        // Unplaced, not dangling. A leftover identifier makes the work invisible on the only view
        // claiming to show everything.
        #expect(task.workflowStageID == nil)
        #expect(task.deletedAt == nil)
    }

    @Test("A WIP limit is reported and never enforced")
    func wipLimitDoesNotRefuse() throws {
        // A board that refuses a drop does not reduce work in progress; it moves the work somewhere
        // the board cannot see.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject(template: .software)
        let inProgress = try #require(
            fixture.workspace.stages(in: project).first { $0.name == "In progress" }
        )
        #expect(inProgress.wipLimit == 3)

        for index in 1...5 {
            let task = try fixture.workItems.createWorkItem(title: "W\(index)", in: project)
            try fixture.workspace.move(task, to: inProgress)
        }

        let placed = project.descendantWork().filter { $0.workflowStageID == inProgress.id }
        #expect(placed.count == 5)
        #expect(inProgress.facts.isOverLimit(placed.count))
    }
}

// MARK: - References

@Suite("Work item references")
@MainActor
struct WorkItemReferenceServiceTests {
    @Test("Reference numbers only ever go up, including across deletions")
    func referencesNeverReused() throws {
        // A gap is the record of something deleted. Reusing the number makes a handle written in a
        // March commit message start pointing at different work.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()

        let first = try fixture.workItems.createWorkItem(title: "One", in: project)
        let second = try fixture.workItems.createWorkItem(title: "Two", in: project)
        try fixture.store.items.deletePermanently(second)
        let third = try fixture.workItems.createWorkItem(title: "Three", in: project)

        let firstKey = try #require(first.referenceKey)
        let thirdKey = try #require(third.referenceKey)
        let firstNumber = try #require(WorkItemReference.parse(firstKey))
        let thirdNumber = try #require(WorkItemReference.parse(thirdKey))
        #expect(thirdNumber.number > firstNumber.number + 1)
    }

    @Test("Two projects never share a key")
    func keysAreUnique() throws {
        let fixture = try WorkspaceFixture()
        let first = try fixture.makeProject("Design System")
        let second = try fixture.makeProject("Design Sprint")
        #expect(first.projectKey != second.projectKey)
    }
}

// MARK: - Custom fields

@Suite("Custom fields")
@MainActor
struct CustomFieldTests {
    @Test("Renaming a field moves its values with it")
    func renameMovesValues() throws {
        // Fields cost no storage — the definition names a key, values live in userMetadata — so a
        // rename touching only the definition orphans every value under a name nothing looks for.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let field = try fixture.workspace.addCustomField(to: project, name: "Budget", type: .number)

        let task = try fixture.workItems.createWorkItem(title: "Book the venue", in: project)
        try fixture.workspace.setCustomFieldValue(.number(1000), named: "Budget", on: task)

        try fixture.workspace.renameCustomField(field, to: "Cost")

        #expect(task.userMetadata["Cost"] == .number(1000))
        #expect(task.userMetadata["Budget"] == nil)
    }

    @Test("Removing a field takes its values with it")
    func removeClearsValues() throws {
        // Otherwise re-adding a field of the same name silently resurrects old data.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let field = try fixture.workspace.addCustomField(to: project, name: "Budget", type: .number)
        let task = try fixture.workItems.createWorkItem(title: "Book the venue", in: project)
        try fixture.workspace.setCustomFieldValue(.number(1000), named: "Budget", on: task)

        try fixture.workspace.removeCustomField(field)
        #expect(task.userMetadata["Budget"] == nil)
    }
}

// MARK: - Views

@Suite("Project views")
@MainActor
struct ProjectViewTests {
    @Test("Every project ships all seven views")
    func allViewsExist() throws {
        // A view holds no work, so an unused tab costs a word of width and a missing one costs
        // finding the add menu. Templates order them; they do not choose them.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject(template: .software)
        let kinds = Set(fixture.workspace.views(in: project).map(\.kind))
        #expect(kinds == Set(ProjectViewKind.allCases))
    }

    @Test("A template leads with its own views")
    func templateOrdersViews() throws {
        let fixture = try WorkspaceFixture()
        let marketing = try fixture.makeProject("Spring", template: .marketingCampaign)
        #expect(fixture.workspace.views(in: marketing).first?.kind == .calendar)

        let software = try fixture.makeProject("App", template: .software)
        #expect(fixture.workspace.views(in: software).first?.kind == .board)
    }

    @Test("The last view cannot be removed")
    func lastViewRefuses() throws {
        // A project with no views is a project you cannot open.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        var views = fixture.workspace.views(in: project)
        while views.count > 1 {
            _ = try fixture.workspace.removeView(views.removeLast())
        }
        let refused = try fixture.workspace.removeView(try #require(views.first))
        #expect(!refused)
    }
}

// MARK: - Bugs

@Suite("Bug tracking")
@MainActor
struct BugTrackingTests {
    @Test("A freshly filed bug reports a severity rather than nothing")
    func lazyRecordStillHasSeverity() throws {
        // The record is created lazily so a bug can be filed in eight seconds. In the gap, severity
        // has to read as minor rather than nil, or the bug falls out of every band into "Not a bug".
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let bug = try fixture.workItems.createWorkItem(title: "Crashes on launch", kind: .bug, in: project)
        #expect(bug.taskFacts().severity != nil)
    }

    @Test("Fixed and verified are separate facts, and verification persists")
    func verificationPersists() throws {
        // Two claims by two different people. The gap between them is the only list anybody
        // preparing a release wants.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let bug = try fixture.bugs.fileBug(title: "Wrong padding", in: project, severity: .minor)

        try fixture.store.items.toggleCompletion(bug)
        #expect(fixture.bugs.awaitingVerification(in: project).count == 1)

        try fixture.bugs.markVerified(bug)
        #expect(fixture.bugs.isVerified(bug))
        #expect(fixture.bugs.awaitingVerification(in: project).isEmpty)

        // Read back through a fresh fetch rather than the object we still hold, which is the part
        // that would catch verification not actually reaching the store.
        let fetched = try fixture.store.items.item(id: bug.id)
        let refetched = try #require(fetched)
        #expect(refetched.bugRecord?.verifiedAt != nil)
    }

    @Test("Verifying a bug that never had a record still sticks")
    func verifyingWithoutARecord() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        // Created straight through the repository, the way an import or a capture that predates
        // bug tracking would arrive: a .bug item with no record at all.
        let bug = try fixture.store.items.create(
            ItemDraft(kind: .bug, title: "No record yet", parentID: project.id)
        )
        #expect(bug.bugRecord == nil)

        try fixture.bugs.markVerified(bug)
        let fetched = try fixture.store.items.item(id: bug.id)
        let refetched = try #require(fetched)
        #expect(refetched.bugRecord?.verifiedAt != nil)
    }

    @Test("A duplicate is cancelled, not completed")
    func duplicatesAreCancelled() throws {
        // Nobody did the work; somebody noticed it was already written down. Counting it as
        // completed inflates every velocity figure with reports rather than repairs.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let original = try fixture.bugs.fileBug(title: "Crash", in: project)
        let copy = try fixture.bugs.fileBug(title: "It crashes", in: project)

        try fixture.workItems.markDuplicate(copy, of: original)

        #expect(copy.status == .cancelled)
        #expect(copy.completedAt == nil)
        #expect(fixture.bugs.duplicates(of: original).map(\.id) == [copy.id])
    }

    @Test("Editing a report reindexes the item so the steps are findable")
    func editingTouchesSearchText() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let bug = try fixture.bugs.fileBug(title: "Crash", in: project)

        try fixture.bugs.update(bug) { $0.stepsToReproduce = "Open an empty list" }
        #expect(bug.searchText.contains("empty list"))
    }
}

// MARK: - Dependencies

@Suite("Dependencies")
@MainActor
struct DependencyTests {
    @Test("A dependency that would close a loop is refused")
    func cyclesRefused() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let first = try fixture.workItems.createWorkItem(title: "A", in: project)
        let second = try fixture.workItems.createWorkItem(title: "B", in: project)

        #expect(try fixture.workItems.addDependency(second, blockedBy: first))
        // Now first would wait on second, which waits on first. Neither could ever start.
        #expect(try !fixture.workItems.addDependency(first, blockedBy: second))
    }

    @Test("Blocked means something unresolved is in the way")
    func blockedIsDerived() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let blocker = try fixture.workItems.createWorkItem(title: "First", in: project)
        let blocked = try fixture.workItems.createWorkItem(title: "Second", in: project)

        _ = try fixture.workItems.addDependency(blocked, blockedBy: blocker)
        #expect(blocked.taskFacts().isBlocked)

        try fixture.store.items.toggleCompletion(blocker)
        #expect(!blocked.taskFacts().isBlocked)
    }

    @Test("At most one assignee, whatever order they are set in")
    func singleAssignee() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project)
        let sam = try fixture.store.items.create(ItemDraft(kind: .person, title: "Sam"))
        let rowan = try fixture.store.items.create(ItemDraft(kind: .person, title: "Rowan"))

        try fixture.workItems.assign(task, to: sam)
        try fixture.workItems.assign(task, to: rowan)

        #expect(task.outgoingLinks.filter { $0.kind == .assignee }.count == 1)
        #expect(task.assignee()?.id == rowan.id)
    }
}

// MARK: - History

@Suite("Work item history")
@MainActor
struct WorkItemHistoryTests {
    @Test("Setting a field to what it already was writes no history")
    func noHistoryForNonEvents() throws {
        // A history full of non-events is a history nobody reads.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project)

        try fixture.workItems.setPriority(.high, on: task)
        let after = fixture.workItems.history(of: task).count
        try fixture.workItems.setPriority(.high, on: task)

        #expect(fixture.workItems.history(of: task).count == after)
    }

    @Test("History survives the stage it describes being renamed")
    func historyKeepsItsWords() throws {
        // The reason activity stores display strings rather than identifiers: an identifier-based
        // history reads "moved from (unknown) to (unknown)" precisely when somebody needs it.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let doing = try #require(fixture.workspace.stages(in: project).first { $0.category == .active })
        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project)

        // Written the way the service writes it: the stage's *name*, not its identifier.
        let activity = ItemActivity(
            kind: .stageChanged,
            oldValue: "To do",
            newValue: doing.name
        )
        activity.item = task
        fixture.store.context.insert(activity)

        let nameAtTheTime = doing.name
        try fixture.workspace.renameStage(doing, to: "Something else entirely")
        try fixture.workspace.removeStage(doing, movingItemsTo: nil)

        // Renamed and then deleted, and the sentence still says what happened — which is exactly
        // the moment somebody goes looking at history.
        let sentence = try #require(fixture.workItems.history(of: task).first?.sentence)
        #expect(sentence.contains(nameAtTheTime))
        #expect(sentence.contains("To do"))
    }
}

// MARK: - Automations

@Suite("Automations")
@MainActor
struct AutomationTests {
    @Test("A rule cannot set off another rule")
    func noReEntry() throws {
        // "When it moves to Done, tag it verified" plus "when tagged verified, move it to Done" is a
        // loop somebody writes in thirty seconds, and neither rule is wrong on its own.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()

        let first = AutomationRule(
            name: "Tag on resolve",
            definition: AutomationDefinition(
                trigger: .itemResolved,
                conditions: TaskFilter(includesResolved: true),
                actions: [.addTag("verified")]
            )
        )
        first.project = project
        fixture.store.context.insert(first)

        let task = try fixture.workItems.createWorkItem(title: "Ship", in: project)
        let outcomes = try fixture.automations.handle(.itemResolved, on: task)

        #expect(outcomes.contains { $0.outcome == .ran })
        #expect(task.tagSlugs.contains("verified"))
    }

    @Test("A rule with no conditions matches everything, which is why templates carry them")
    func emptyConditionsMatchEverything() throws {
        // This is correct behaviour and a sharp edge — it is exactly how "flag work that arrives
        // critical" ended up flagging everything. The template's own rule is checked below.
        let empty = TaskFilter(includesResolved: true)
        #expect(empty.matches(TaskFacts(title: "anything"), now: .now, calendar: .current))
    }

    @Test("The software template's critical rule only fires on critical bugs")
    func templateRuleIsScoped() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject(template: .software)

        let ordinary = try fixture.workItems.createWorkItem(title: "Write the copy", in: project)
        let outcomes = try fixture.automations.handle(.itemCreated, on: ordinary)

        let critical = outcomes.first { $0.ruleName.contains("critical") }
        #expect(critical?.outcome == .conditionsNotMet)
        #expect(ordinary.priority == .normal)
    }

    @Test("A rule needing an integration refuses, and says which one")
    func integrationsRefuseHonestly() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()

        let rule = AutomationRule(
            name: "Tell chat",
            definition: AutomationDefinition(
                trigger: .itemCreated,
                conditions: TaskFilter(includesResolved: true),
                actions: [.external(.chat, payload: "#general")]
            )
        )
        rule.project = project
        fixture.store.context.insert(rule)

        let task = try fixture.workItems.createWorkItem(title: "Draft", in: project)
        let outcomes = try fixture.automations.handle(.itemCreated, on: task)

        #expect(outcomes.contains { $0.outcome == .needsIntegration(.chat) })
    }

    @Test("A rule written by a newer build is disabled whole, not run partially")
    func unknownActionsDisableTheWholeRule() throws {
        // Half an automation is not a smaller automation; it is a different one nobody configured.
        let definition = AutomationDefinition(
            trigger: .itemCreated,
            conditions: TaskFilter(includesResolved: true),
            actions: [.addTag("ok"), .unrecognised(name: "somethingNew")]
        )
        #expect(!definition.isRunnable)
    }
}

// MARK: - Reporting

@Suite("Project reporting")
@MainActor
struct ProjectReportingTests {
    @Test("An empty project has no completion figure at all")
    func emptyProjectHasNoPercentage() throws {
        // Not 0%. There is nothing to be finished, and a bar pinned to the left is a statement about
        // a project that has not made one.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        #expect(fixture.reports.health(of: project).completionFraction == nil)
    }

    @Test("Cycle time declines to answer from too small a sample")
    func cycleTimeReportsItsSampleSize() {
        let thin = CycleTimeSummary.from(durationsInDays: [1, 2, 3])
        #expect(thin?.isMeaningful == false)

        let enough = CycleTimeSummary.from(durationsInDays: [1, 2, 3, 4, 5, 6])
        #expect(enough?.isMeaningful == true)
        #expect(CycleTimeSummary.from(durationsInDays: []) == nil)
    }

    @Test("A long tail is reported, so the median is shown instead of the mean")
    func longTailDetected() {
        let skewed = CycleTimeSummary.from(durationsInDays: [1, 1, 1, 1, 1, 100])
        #expect(skewed?.hasLongTail == true)
    }

    @Test("Workload always includes the unassigned lane")
    func workloadIncludesUnassigned() throws {
        // A chart of only the named people implies the work is all accounted for.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        _ = try fixture.workItems.createWorkItem(title: "Nobody's", in: project)

        let lanes = fixture.reports.workload(of: project)
        #expect(lanes.contains { $0.isUnassigned })
    }

    @Test("Health says what is wrong in sentences, and stays quiet when nothing is")
    func concernsAreEarned() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        #expect(fixture.reports.health(of: project).concerns.isEmpty)

        _ = try fixture.bugs.fileBug(title: "Crash", in: project, severity: .critical)
        let concerns = fixture.reports.health(of: project).concerns
        #expect(concerns.contains { $0.id == "critical" })
    }

    @Test("Velocity includes the periods where nothing happened")
    func velocityKeepsEmptyPeriods() throws {
        // A chart that hides the weeks with no velocity lies in exactly the direction people want.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        #expect(fixture.reports.velocity(of: project, periods: 6).count == 6)
    }
}

// MARK: - Inbox

@Suite("Project inbox")
@MainActor
struct ProjectInboxTests {
    @Test("Repeated unread notices of the same kind collapse into one")
    func unreadNoticesDedupe() throws {
        // Four comments on one bug is one thing to look at. Posting it four times teaches people
        // that the count is noise.
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let bug = try fixture.bugs.fileBug(title: "Crash", in: project)

        for index in 1...4 {
            try fixture.inbox.post(.commented, about: bug, summary: "Comment \(index)")
        }

        #expect(fixture.inbox.badgeCount(for: project) == 1)
        #expect(fixture.inbox.unread(in: project).first?.summary == "Comment 4")
    }

    @Test("A read notice does not suppress the next one")
    func readNoticesDoNotDedupe() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let bug = try fixture.bugs.fileBug(title: "Crash", in: project)

        let first = try fixture.inbox.post(.commented, about: bug, summary: "One")
        try fixture.inbox.markRead(first)
        try fixture.inbox.post(.commented, about: bug, summary: "Two")

        #expect(fixture.inbox.badgeCount(for: project) == 1)
    }

    @Test("The badge counts work nested under headings, not only direct children")
    func badgeReachesNestedWork() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.makeProject()
        let heading = try fixture.store.items.create(
            ItemDraft(kind: .heading, title: "Planning", parentID: project.id)
        )
        let task = try fixture.workItems.createWorkItem(title: "Nested", in: project, parent: heading)

        try fixture.inbox.post(.assigned, about: task, summary: "Assigned to you")
        #expect(fixture.inbox.badgeCount(for: project) == 1)
    }
}

// MARK: - Cost

@Suite("Project workspace cost")
@MainActor
struct ProjectWorkspaceCostTests {
    /// Enough to expose an O(items) walk, and no more.
    ///
    /// Creating items is itself expensive — see the note in the reconstruction doc — so a fixture
    /// large enough to be a "realistic library" costs minutes of suite time to build. Three hundred
    /// items is ample: a walk over them is three orders of magnitude above the budgets below, so the
    /// guards trip immediately if one comes back.
    private static let projectCount = 5
    private static let itemsPerProject = 60

    private static func populated() throws -> (WorkspaceFixture, [Item]) {
        let fixture = try WorkspaceFixture()
        let area = try fixture.store.items.create(ItemDraft(kind: .area, title: "Area"))
        var projects: [Item] = []
        for index in 0..<projectCount {
            let project = try fixture.templates.createProject(
                named: "Project \(index)",
                from: .blank,
                in: area
            )
            for itemIndex in 0..<itemsPerProject {
                _ = try fixture.workItems.createWorkItem(
                    title: "Work \(itemIndex)",
                    kind: itemIndex.isMultiple(of: 5) ? .bug : .task,
                    in: project
                )
            }
            projects.append(project)
        }
        return (fixture, projects)
    }

    @Test("Counting badges does not touch every item in the library")
    func badgesAreFetchedNotWalked() throws {
        // This ran on every mutation anywhere in the app, and it worked by faulting the
        // `notifications` relationship of every item in the store to count a handful of rows —
        // 144ms across ten projects of two hundred items. The budget is a hundredfold the measured
        // cost, so it only fails if somebody reintroduces a walk.
        let (fixture, projects) = try Self.populated()
        _ = try fixture.inbox.post(.assigned, about: projects[0], summary: "yours")

        let elapsed = ContinuousClock().measure {
            for _ in 0..<5 { _ = fixture.inbox.unreadCountsByContainer() }
        }
        #expect(elapsed < .milliseconds(50), "badge counting is walking the library again")
    }

    @Test("An area's badge counts the work inside its projects")
    func badgesRollUpToAreas() throws {
        // The roll-up is what the ancestor walk buys. An area that read as quiet while a project
        // inside it had unread work would be worse than no badge at all.
        let fixture = try WorkspaceFixture()
        let area = try fixture.store.items.create(ItemDraft(kind: .area, title: "Area"))
        let project = try fixture.templates.createProject(named: "Inside", from: .blank, in: area)
        let task = try fixture.workItems.createWorkItem(title: "Work", in: project)

        _ = try fixture.inbox.post(.assigned, about: task, summary: "yours")

        let counts = fixture.inbox.unreadCountsByContainer()
        #expect(counts[project.id] == 1)
        #expect(counts[area.id] == 1)
    }

    @Test("A read notification stops counting")
    func readNotificationsLeaveTheCount() throws {
        let fixture = try WorkspaceFixture()
        let project = try fixture.templates.createProject(named: "P", from: .blank)
        let notification = try fixture.inbox.post(.assigned, about: project, summary: "yours")

        #expect(fixture.inbox.unreadCountsByContainer()[project.id] == 1)
        try fixture.inbox.markRead(notification)
        #expect(fixture.inbox.unreadCountsByContainer()[project.id] == nil)
    }

    @Test("Health computed from facts already in hand costs almost nothing")
    func healthReusesTheArrangementsPass() throws {
        // Health used to walk the project itself, compute every fact a second time, and then walk it
        // again for the verification count — three passes for numbers the workspace had already
        // computed to draw the board. 25ms per project, on every mutation.
        let (fixture, projects) = try Self.populated()
        let facts = projects[0].descendantWork().map { $0.taskFacts() }

        let elapsed = ContinuousClock().measure {
            for _ in 0..<5 { _ = fixture.reports.health(of: projects[0], facts: facts) }
        }
        #expect(elapsed < .milliseconds(50), "health is recomputing facts it was handed")
    }

    @Test("Health from precomputed facts agrees with health that walks")
    func precomputedHealthAgrees() throws {
        // The optimisation is only worth having if it is the same answer.
        let fixture = try WorkspaceFixture()
        let project = try fixture.templates.createProject(named: "P", from: .software)
        let bug = try fixture.bugs.fileBug(title: "Crash", in: project, severity: .critical)
        _ = try fixture.workItems.createWorkItem(title: "Task", in: project)
        let fixed = try fixture.bugs.fileBug(title: "Fixed", in: project)
        try fixture.store.items.toggleCompletion(fixed)

        let walked = fixture.reports.health(of: project)
        let handed = fixture.reports.health(
            of: project,
            facts: project.descendantWork().map { $0.taskFacts() }
        )

        #expect(walked == handed)
        #expect(handed.criticalBugs == 1)
        #expect(handed.bugsAwaitingVerification == 1)
        _ = bug
    }
}
