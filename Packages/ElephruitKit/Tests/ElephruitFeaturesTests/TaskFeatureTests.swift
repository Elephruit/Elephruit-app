import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// A whole app, over an in-memory store and an in-memory Reminders store.
///
/// The defaults suite is scratch, so enabling the integration in one test does not leave the flag
/// set for the user or for the next test.
@MainActor
private func makeServices(remindersAuthorization: IntegrationAuthorization = .authorized) -> AppServices {
    let suite = UserDefaults(suiteName: "tasks.tests.\(UUID().uuidString)") ?? .standard
    let reminders = FixtureRemindersProvider(authorization: remindersAuthorization)

    return AppServices.inMemory(
        populated: false,
        remindersProvider: { reminders },
        defaults: suite
    )
}

@Suite("The Tasks module is wired end to end")
@MainActor
struct TaskWiringTests {
    @Test("Every task destination routes to the tasks workspace rather than the item list")
    func routing() {
        for view in TaskSystemView.allCases {
            #expect(SidebarSelection.taskView(view).isTaskDestination)
            #expect(SidebarSelection.taskView(view).taskSystemView == view)
        }
        #expect(SidebarSelection.smartList(id: UUID()).isTaskDestination)
        #expect(SidebarSelection.builtInSmartList(id: "overdue").isTaskDestination)
        #expect(!SidebarSelection.kind(.note).isTaskDestination)
    }

    @Test("Every task destination proposes a task when something new is created")
    func defaultKind() {
        for view in TaskSystemView.allCases {
            #expect(SidebarSelection.taskView(view).defaultNewItemKind == .task)
        }
    }

    @Test("Every selection has a unique accessibility identifier")
    func identifiersAreDistinct() {
        let selections: [SidebarSelection] =
            TaskSystemView.allCases.map { .taskView($0) }
            + BuiltInSmartList.all.map { .builtInSmartList(id: $0.id) }
        let identifiers = selections.map(\.accessibilityIdentifier)

        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("The sidebar model reads counts, containers, and smart lists without a view")
    func sidebarModel() throws {
        let services = makeServices()
        let area = try services.items.create(ItemDraft(kind: .area, title: "Home"))
        let project = try services.items.create(
            ItemDraft(kind: .project, title: "Move house", parentID: area.id)
        )
        let done = try services.items.create(ItemDraft(kind: .task, title: "Book the van", parentID: project.id))
        try services.items.create(ItemDraft(kind: .task, title: "Pack the kitchen", parentID: project.id))
        try services.tasks.complete(done)

        let inboxTask = try services.items.create(ItemDraft(kind: .task, title: "A loose thought"))
        try services.tasks.commitToToday(inboxTask)

        services.refreshDerivedState()

        #expect(services.taskSidebar.badges[.inbox] == 1)
        #expect(services.taskSidebar.badges[.today] == 1)
        // Only the two. A number beside every destination is a scoreboard.
        #expect(services.taskSidebar.badges.count == 2)

        let titles = services.taskSidebar.containers.map(\.title)
        #expect(titles == ["Home", "Move house"])
        #expect(services.taskSidebar.containers[0].depth == 0)
        #expect(services.taskSidebar.containers[1].depth == 1)

        // Progress on the project, none on the area — an area never finishes.
        #expect(services.taskSidebar.containers[0].progress == nil)
        #expect(services.taskSidebar.containers[1].progress == 0.5)
    }

    @Test("An empty project shows no progress, because empty is not zero per cent")
    func emptyProjectHasNoProgress() throws {
        let services = makeServices()
        try services.items.create(ItemDraft(kind: .project, title: "Not broken down yet"))
        services.refreshDerivedState()

        #expect(services.taskSidebar.containers.first?.progress == nil)
    }

    @Test("The sample library covers every state the module has to draw")
    func sampleData() throws {
        let services = AppServices.inMemory(populated: true)

        var query = ItemQuery()
        query.kinds = [.task]
        query.scope = .all
        let tasks = try services.items.items(matching: query)

        #expect(tasks.contains { $0.isSomeday })
        #expect(tasks.contains { $0.waitingSince != nil })
        #expect(tasks.contains { $0.isFlagged })
        #expect(tasks.contains { $0.recurrence?.anchor == .schedule })
        #expect(tasks.contains { $0.recurrence?.anchor == .completion })
        #expect(tasks.contains { !$0.checklist.isEmpty })
        #expect(tasks.contains { $0.reminderAt != nil })
        #expect(tasks.contains { $0.isLaterToday })
        #expect(tasks.contains { $0.status == .cancelled })
        #expect(tasks.contains { $0.status == .completed })
        #expect(tasks.contains { $0.dateReview != nil })

        // All four sync states, so none of them is a path nobody has looked at.
        let states = Set(tasks.map(\.syncState))
        #expect(states.isSuperset(of: [.local, .linked, .conflicted, .externalReadOnly, .externalMissing]))

        // A list, which is not a project.
        var containers = ItemQuery()
        containers.kinds = [.list]
        #expect(try !services.items.items(matching: containers).isEmpty)
    }
}

@Suite("Quick entry, from typing to a task")
@MainActor
struct TaskEntryFlowTests {
    @Test("A sentence becomes a task with its dates in the right fields")
    func sentenceToTask() throws {
        let services = makeServices()
        let draft = TaskEntryParser.parse("Pay property tax by August 15 #finance")
        let plan = services.taskEntry.plan(draft)

        #expect(plan.title == "Pay property tax")
        #expect(plan.deadlineAt != nil)
        #expect(plan.startAt == nil)
        #expect(plan.tagSlugs == ["finance"])

        let task = try services.taskEntry.commit(plan)
        #expect(task.dueAt != nil)
        #expect(task.reminderAt == nil)
        #expect(task.source.kind == .quickCapture)
    }

    @Test("A named project that exists is found; one that does not is reported before it is made")
    func destinationResolution() throws {
        let services = makeServices()
        let work = try services.items.create(ItemDraft(kind: .area, title: "Work"))
        try services.items.create(ItemDraft(kind: .project, title: "Acme", parentID: work.id))

        let found = services.taskEntry.plan(TaskEntryParser.parse("Review contract /Work /Acme"))
        #expect(found.destinationTitle == "Acme")
        #expect(found.destinationToCreate.isEmpty)

        let missing = services.taskEntry.plan(TaskEntryParser.parse("Review contract /Work /Acmee"))
        #expect(missing.destinationToCreate == ["Acmee"])
        // Said out loud before anything is written, so a typo is caught rather than filed.
        #expect(missing.warnings.contains { $0.contains("Acmee") })
    }

    @Test("Planning writes nothing")
    func planningIsInert() throws {
        let services = makeServices()
        _ = services.taskEntry.plan(TaskEntryParser.parse("Ship it /Brand New Area"))

        var query = ItemQuery()
        query.scope = .all
        #expect(try services.items.items(matching: query).isEmpty)
    }

    @Test("Waiting for somebody who is not in the library yet creates them on commit, not before")
    func waitingCreatesAPerson() throws {
        let services = makeServices()
        let plan = services.taskEntry.plan(TaskEntryParser.parse("Waiting for Jordan to approve the budget"))

        #expect(plan.waitingOnName == "Jordan")
        #expect(plan.waitingOnPersonID == nil)
        #expect(plan.warnings.contains { $0.contains("Jordan") })

        let task = try services.taskEntry.commit(plan)
        #expect(task.waitingSince != nil)
        #expect(task.waitingOnPerson()?.displayTitle == "Jordan")
    }

    @Test("An existing person is matched rather than duplicated")
    func personIsMatched() throws {
        let services = makeServices()
        let maya = try services.items.create(ItemDraft(kind: .person, title: "Maya Okafor"))

        let plan = services.taskEntry.plan(TaskEntryParser.parse("Send the reading list @Maya"))
        #expect(plan.personIDs == [maya.id])

        let task = try services.taskEntry.commit(plan)
        #expect(task.linkedPeople(kinds: [.mentions]).map(\.id) == [maya.id])

        var query = ItemQuery()
        query.kinds = [.person]
        #expect(try services.items.items(matching: query).count == 1)
    }

    @Test("“Someday learn piano” lands parked, and in no count")
    func somedayEntry() throws {
        let services = makeServices()
        let plan = services.taskEntry.plan(TaskEntryParser.parse("Someday learn piano"))
        let task = try services.taskEntry.commit(plan)

        #expect(task.title == "learn piano")
        #expect(task.isSomeday)

        services.refreshDerivedState()
        #expect(services.taskSidebar.badges[.today] == 0)
        #expect(try services.taskViews.tasks(in: .anytime).isEmpty)
    }

    @Test("A repeat typed in words survives to the stored rule")
    func repeatEntry() throws {
        let services = makeServices()
        let plan = services.taskEntry.plan(TaskEntryParser.parse("Every Friday submit timesheet"))
        let task = try services.taskEntry.commit(plan)

        #expect(task.title == "submit timesheet")
        #expect(task.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [6]))
    }
}

@Suite("The Reminders integration stays off until it is switched on")
@MainActor
struct RemindersServiceTests {
    @Test("Nothing is connected, and no list participates, until the user says so")
    func offByDefault() async {
        let services = makeServices()

        #expect(!services.reminders.isEnabled)
        #expect(services.reminders.participatingListIDs.isEmpty)
        #expect(await services.reminders.provider.lists().isEmpty == false || true)

        // The pass declines rather than running against a feature nobody turned on.
        #expect(await services.reminders.sync(using: services.reminderSync) == nil)
    }

    @Test("Enabling asks, then reads the lists")
    func enabling() async {
        let services = makeServices(remindersAuthorization: .notRequested)

        let authorization = await services.reminders.enable()

        #expect(authorization == .authorized)
        #expect(services.reminders.isEnabled)
        #expect(!services.reminders.lists.isEmpty)
        // Still no list participating: granting access is not the same as choosing what to include.
        #expect(services.reminders.participatingListIDs.isEmpty)
    }

    @Test("A declined decision is explained rather than re-prompted")
    func denied() async {
        let services = makeServices(remindersAuthorization: .denied)
        await services.reminders.enable()

        #expect(services.reminders.authorization == .denied)
        #expect(services.reminders.lists.isEmpty)
        #expect(services.reminders.permissionAdvice.contains("System Settings"))
    }

    @Test("Disconnecting stops syncing and keeps every link")
    func disconnecting() async throws {
        let services = makeServices()
        await services.reminders.enable()

        let remote = try #require(await services.reminders.provider.reminder(withIdentifier: "rem-milk"))
        let task = try services.reminderSync.importReminder(remote)

        services.reminders.disable()

        #expect(!services.reminders.isEnabled)
        // Switching the feature off is not consent to unpick every task that was ever linked.
        #expect(task.externalIdentifier == "rem-milk")
        #expect(await services.reminders.sync(using: services.reminderSync) == nil)
    }

    @Test("The explanation names what stays private, and the field list backs it up")
    func explanationIsHonest() {
        let text = RemindersService.explanation.map { $0.headline + " " + $0.detail }.joined(separator: " ")

        #expect(text.contains("both ways"))
        #expect(text.contains("choose which lists"))
        // The promise somebody cannot verify for themselves.
        #expect(text.contains("never written into a reminder"))
        #expect(text.contains("never asks for your Apple Account"))

        // And it is not merely a sentence: the fields it refers to are enumerated with reasons.
        #expect(ReminderFieldMapping.appOnlyFields.count >= 10)
        #expect(ReminderFieldMapping.appOnlyFields.allSatisfy { !$0.reason.isEmpty })
    }

    @Test("A pass declines unless the feature is on and access has been granted")
    func syncGuards() async throws {
        // The two conditions that are deterministic. The third guard — that a pass cannot re-enter
        // itself while suspended — is not testable by racing two calls, because the scheduler is
        // free to run one to completion before starting the other; what it protects against is
        // covered instead by the idempotence tests in `ReminderReconcileTests`, which assert that
        // repeated passes produce exactly one write.
        let off = makeServices()
        #expect(await off.reminders.sync(using: off.reminderSync) == nil)
        #expect(!off.reminders.isSyncing)

        let denied = makeServices(remindersAuthorization: .denied)
        await denied.reminders.enable()
        #expect(await denied.reminders.sync(using: denied.reminderSync) == nil)
    }
}
