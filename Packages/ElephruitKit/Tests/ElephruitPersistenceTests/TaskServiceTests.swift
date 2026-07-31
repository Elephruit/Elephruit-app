import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// A store plus the two task services over it.
@MainActor
private struct TaskFixture {
    let store: StoreFixture
    let tasks: TaskService
    let views: TaskViewService

    init() throws {
        store = try StoreFixture()
        tasks = TaskService(
            items: store.items,
            context: store.context,
            dateProvider: store.dateProvider
        )
        views = TaskViewService(
            items: store.items,
            context: store.context,
            dateProvider: store.dateProvider
        )
    }

    var calendar: Calendar { store.dateProvider.calendar }
    var now: Date { store.dateProvider.now }

    func day(_ offset: Int) -> Date { store.dateProvider.startOfDay(daysFromToday: offset) }

    func instant(_ offset: Int, hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day(offset)) ?? day(offset)
    }

    @discardableResult
    func task(_ title: String, in parent: Item? = nil) throws -> Item {
        try store.items.create(ItemDraft(kind: .task, title: title, parentID: parent?.id))
    }

    func person(_ name: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .person, title: name))
    }

    func titles(_ groups: [TaskSectionGroup], section: TodaySection) throws -> [String] {
        guard let group = groups.first(where: { $0.heading == .today(section) }) else { return [] }
        return try group.taskIDs.map { try store.sameContextItem(id: $0).title }
    }
}

@Suite("Choosing what to do today")
@MainActor
struct TodayPlanningTests {
    @Test("Committing a task puts it in Today; nothing else arrives on its own")
    func commitment() throws {
        let fixture = try TaskFixture()
        let chosen = try fixture.task("Draft the brief")
        try fixture.task("Something else entirely")

        try fixture.tasks.commitToToday(chosen)

        #expect(try fixture.titles(fixture.views.today(), section: .today) == ["Draft the brief"])
    }

    @Test("Later Today is its own section")
    func laterToday() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Call the bank")

        try fixture.tasks.moveToLaterToday(task)
        let groups = try fixture.views.today()

        #expect(try fixture.titles(groups, section: .laterToday) == ["Call the bank"])
        #expect(try fixture.titles(groups, section: .today).isEmpty)
    }

    @Test("Overdue work sits above the plan, ordered by how long it has been waiting")
    func overdueOrdering() throws {
        let fixture = try TaskFixture()
        let recent = try fixture.task("Two days late")
        let ancient = try fixture.task("Two weeks late")
        try fixture.tasks.setDeadline(fixture.day(-2), on: recent)
        try fixture.tasks.setDeadline(fixture.day(-14), on: ancient)

        let groups = try fixture.views.today()

        #expect(groups.first?.heading == .today(.overdue))
        #expect(try fixture.titles(groups, section: .overdue) == ["Two weeks late", "Two days late"])
    }

    @Test("Today's order is independent of the project's order")
    func todayOrderIsSeparate() throws {
        let fixture = try TaskFixture()
        let project = try fixture.store.makeProject(title: "Launch")
        let first = try fixture.task("Step one", in: project)
        let second = try fixture.task("Step two", in: project)
        let third = try fixture.task("Step three", in: project)

        for task in [first, second, third] { try fixture.tasks.commitToToday(task) }

        // Today is reordered back to front.
        try fixture.tasks.reorderToday([third, first, second])

        #expect(
            try fixture.titles(fixture.views.today(), section: .today)
                == ["Step three", "Step one", "Step two"]
        )

        // The project's own order is untouched — which is the whole point of the second column.
        let contents = try fixture.store.sameContextItem(id: project.id)
            .ungroupedTasks()
            .map(\.title)
        #expect(contents == ["Step one", "Step two", "Step three"])
    }

    @Test("Committing something already committed does not restart its clock")
    func commitmentIsIdempotent() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Carried over")
        try fixture.store.items.update(task) { $0.todayCommittedOn = fixture.day(-3) }

        try fixture.tasks.commitToToday(task)

        // Still reads as carried forward rather than freshly planned.
        #expect(try fixture.store.requireItem(id: task.id).todayCommittedOn == fixture.day(-3))
    }

    @Test("Suggestions offer available work that is not already on the plan")
    func suggestions() throws {
        let fixture = try TaskFixture()
        let due = try fixture.task("Due in three days")
        try fixture.tasks.setDeadline(fixture.day(3), on: due)
        let flagged = try fixture.task("Flagged")
        try fixture.tasks.setFlagged(true, on: flagged)
        let parked = try fixture.task("Parked")
        try fixture.tasks.setSomeday(true, on: parked)
        let later = try fixture.task("Not yet")
        try fixture.tasks.setStartDate(fixture.day(9), on: later)
        let planned = try fixture.task("Already chosen")
        try fixture.tasks.commitToToday(planned)

        let offered = try fixture.views.todaySuggestions().map(\.title)

        #expect(offered.prefix(2) == ["Due in three days", "Flagged"])
        #expect(!offered.contains("Parked"))
        #expect(!offered.contains("Not yet"))
        #expect(!offered.contains("Already chosen"))
    }

    @Test("Parking a task takes it off the plan and out of Anytime")
    func somedayRemovesFromEverything() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Learn piano")
        try fixture.tasks.commitToToday(task)

        try fixture.tasks.setSomeday(true, on: task)

        #expect(try fixture.views.today().isEmpty)
        #expect(try fixture.views.tasks(in: .anytime).isEmpty)
        #expect(try fixture.views.tasks(in: .someday).map(\.title) == ["Learn piano"])
        #expect(try fixture.store.requireItem(id: task.id).todayCommittedOn == nil)
    }
}

@Suite("Rescheduling never changes a date the user did not point at")
@MainActor
struct RescheduleTests {
    @Test("Dragging a start date moves the start date and leaves the deadline alone")
    func draggingStartLeavesDeadline() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Plan the trip")
        try fixture.tasks.setStartDate(fixture.day(2), on: task)
        try fixture.tasks.setDeadline(fixture.day(20), on: task)

        try fixture.tasks.reschedule(task, reason: .becomesAvailable, to: fixture.day(5))
        let moved = try fixture.store.requireItem(id: task.id)

        #expect(moved.startAt == fixture.day(5))
        // The acceptance criterion: dragging must never silently turn a deadline into a start date,
        // or move one when the other was dragged.
        #expect(moved.dueAt == fixture.day(20))
        #expect(moved.reminderAt == nil)
    }

    @Test("Dragging a deadline moves the deadline and leaves the start date alone")
    func draggingDeadlineLeavesStart() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("File the accounts")
        try fixture.tasks.setStartDate(fixture.day(2), on: task)
        try fixture.tasks.setDeadline(fixture.day(20), on: task)

        try fixture.tasks.reschedule(task, reason: .deadline, to: fixture.day(25))
        let moved = try fixture.store.requireItem(id: task.id)

        #expect(moved.dueAt == fixture.day(25))
        #expect(moved.startAt == fixture.day(2))
    }

    @Test("Dragging a reminder keeps its time of day")
    func reminderKeepsItsTime() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Standup")
        let nine = fixture.instant(1, hour: 9)
        try fixture.tasks.setReminder(nine, timed: true, on: task)

        try fixture.tasks.reschedule(task, reason: .reminder(nine), to: fixture.day(4))
        let moved = try fixture.store.requireItem(id: task.id)

        #expect(moved.reminderAt == fixture.instant(4, hour: 9))
        #expect(moved.reminderIsTimed)
    }

    @Test("Setting a deadline never creates a reminder")
    func deadlineDoesNotImplyAReminder() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Renew the passport")

        try fixture.tasks.setDeadline(fixture.day(30), on: task)

        let stored = try fixture.store.requireItem(id: task.id)
        #expect(stored.reminderAt == nil)
        #expect(stored.reminderOwner == .none)
    }

    @Test("A reminder can be added without touching the deadline")
    func reminderIsIndependent() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Renew the passport")
        try fixture.tasks.setDeadline(fixture.day(30), on: task)

        try fixture.tasks.setReminder(fixture.instant(28, hour: 10), timed: true, on: task)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.dueAt == fixture.day(30))
        #expect(stored.reminderAt == fixture.instant(28, hour: 10))
        #expect(stored.reminderOwner == .app)
    }

    @Test("Start dates and deadlines are stored as days, not as the moment they were dragged")
    func datesAreNormalisedToTheDay() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Something")

        try fixture.tasks.setStartDate(fixture.instant(3, hour: 14), on: task)
        try fixture.tasks.setDeadline(fixture.instant(9, hour: 17), on: task)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.startAt == fixture.day(3))
        #expect(stored.dueAt == fixture.day(9))
    }
}

@Suite("Waiting on somebody")
@MainActor
struct WaitingTests {
    @Test("A waiting task leaves Anytime and joins Waiting")
    func waitingLeavesAnytime() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let task = try fixture.task("Budget approval")

        try fixture.tasks.markWaiting(task, on: maya)

        #expect(try fixture.views.tasks(in: .waiting).map(\.title) == ["Budget approval"])
        #expect(try fixture.views.tasks(in: .anytime).isEmpty)
        #expect(try fixture.views.today().isEmpty)
    }

    @Test("The person is a link, so the task turns up on their page")
    func personIsALink() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let task = try fixture.task("Budget approval")

        try fixture.tasks.markWaiting(task, on: maya)

        let stored = try fixture.store.sameContextItem(id: task.id)
        #expect(stored.waitingOnPerson()?.id == maya.id)

        // And from the other side, which is what the person's workspace reads.
        let backlinks = try fixture.store.sameContextItem(id: maya.id).visibleBacklinks()
        #expect(backlinks.contains { $0.kind == .waitingOn && $0.source?.id == task.id })
    }

    @Test("A follow-up date brings it back on that day and not before")
    func followUpSurfacesOnItsDay() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let task = try fixture.task("Budget approval")

        try fixture.tasks.markWaiting(task, on: maya, followUp: fixture.day(3))
        #expect(try fixture.views.today().isEmpty)

        try fixture.tasks.markWaiting(task, on: maya, followUp: fixture.day(0))
        #expect(try fixture.titles(fixture.views.today(), section: .today) == ["Budget approval"])
    }

    @Test("Changing who you are waiting on replaces the link rather than adding a second")
    func waitingLinkIsReplaced() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let jordan = try fixture.person("Jordan")
        let task = try fixture.task("Budget approval")

        try fixture.tasks.markWaiting(task, on: maya)
        try fixture.tasks.markWaiting(task, on: jordan)

        let stored = try fixture.store.sameContextItem(id: task.id)
        #expect(stored.outgoingLinks.count { $0.kind == .waitingOn } == 1)
        #expect(stored.waitingOnPerson()?.id == jordan.id)
    }

    @Test("Completing a waiting task stops it waiting, and says so")
    func completionClearsWaiting() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let task = try fixture.task("Budget approval")
        try fixture.tasks.markWaiting(task, on: maya, followUp: fixture.day(4))

        try fixture.tasks.complete(task)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.waitingSince == nil)
        #expect(stored.followUpAt == nil)
        #expect(stored.status == .completed)
    }
}

@Suite("Completing, repeating, and keeping the history")
@MainActor
struct TaskCompletionTests {
    @Test("A plain task just finishes")
    func plainCompletion() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Buy milk")

        let outcome = try fixture.tasks.complete(task)

        #expect(outcome.nextOccurrenceID == nil)
        #expect(!outcome.seriesEnded)
        #expect(try fixture.store.requireItem(id: task.id).completedAt != nil)
    }

    @Test("Completing an occurrence leaves it as history and creates the next one")
    func recurrenceRollsForward() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Submit timesheet")
        try fixture.store.items.update(task) { subject in
            subject.recurrence = RecurrenceRule(frequency: .weekly, weekdays: [6])
            subject.dueAt = fixture.day(0)
        }

        let outcome = try fixture.tasks.complete(task)
        let nextID = try #require(outcome.nextOccurrenceID)
        let next = try fixture.store.requireItem(id: nextID)
        let completed = try fixture.store.requireItem(id: task.id)

        // The completed occurrence survives, unchanged apart from being done.
        #expect(completed.status == .completed)
        #expect(completed.dueAt == fixture.day(0))
        // And the series carries on.
        #expect(next.status == .open)
        #expect(next.title == "Submit timesheet")
        #expect(next.recurrence?.frequency == .weekly)
        #expect(next.seriesID == completed.seriesID)
        #expect(next.seriesID != nil)
        #expect(next.source.kind == .generated)
    }

    @Test("The next occurrence gets the steps back, unticked")
    func checklistIsCarriedForwardEmpty() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Weekly review")
        try fixture.tasks.setChecklist(TaskChecklist.parse("- inbox\n- calendar"), on: task)
        try fixture.store.items.update(task) { subject in
            subject.recurrence = RecurrenceRule(frequency: .weekly)
            subject.dueAt = fixture.day(0)
        }
        guard let firstStep = task.checklist.items.first else { return }
        try fixture.tasks.setChecklistItem(firstStep.id, completed: true, on: task)

        let outcome = try fixture.tasks.complete(task)
        let nextID = try #require(outcome.nextOccurrenceID)
        let next = try fixture.store.requireItem(id: nextID)

        #expect(next.checklist.items.map(\.title) == ["inbox", "calendar"])
        #expect(next.checklist.completed == 0)
        // The history keeps its ticks.
        #expect(try fixture.store.requireItem(id: task.id).checklist.completed == 1)
    }

    @Test("The next occurrence is not linked to the reminder the last one was")
    func linkIsNotInherited() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Water the plants")
        try fixture.store.items.update(task) { subject in
            subject.recurrence = RecurrenceRule(frequency: .daily, interval: 3)
            subject.dueAt = fixture.day(0)
            subject.setReminderLink(
                ReminderLinkState(
                    externalID: "rem-1",
                    listID: "list-1",
                    lastSyncedFingerprint: "abc",
                    lastSyncedAt: fixture.now,
                    lastSyncedLocalStamp: fixture.now
                )
            )
            subject.syncState = .linked
        }

        let outcome = try fixture.tasks.complete(task)
        let nextID = try #require(outcome.nextOccurrenceID)
        let next = try fixture.store.requireItem(id: nextID)

        // Two tasks claiming one reminder is how a sync pass starts deleting things.
        #expect(next.reminderLink == nil)
        #expect(next.syncState == .local)
        #expect(outcome.needsReminderPush)
    }

    @Test("The last occurrence of a finite series ends it rather than looping")
    func seriesEnds() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Three sessions")
        try fixture.store.items.update(task) { subject in
            subject.recurrence = RecurrenceRule(frequency: .weekly, end: .afterOccurrences(2))
            subject.dueAt = fixture.day(0)
            subject.occurrenceCount = 2
        }

        let outcome = try fixture.tasks.complete(task)

        #expect(outcome.nextOccurrenceID == nil)
        #expect(outcome.seriesEnded)
    }

    @Test("Cancelling a repeating task does not generate the next one")
    func cancellationDoesNotRepeat() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("A habit being dropped")
        try fixture.store.items.update(task) { subject in
            subject.recurrence = RecurrenceRule(frequency: .daily)
            subject.dueAt = fixture.day(0)
        }

        try fixture.tasks.cancel(task)

        // Skipping one Friday is not doing it, and a series somebody is trying to stop must be
        // stoppable.
        #expect(try fixture.views.tasks(in: .all).count == 1)
        #expect(try fixture.store.requireItem(id: task.id).cancelledAt != nil)
    }

    @Test("A cancelled task keeps no reminder")
    func cancellationClearsTheAlarm() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Abandoned")
        try fixture.tasks.setReminder(fixture.instant(2, hour: 9), timed: true, on: task)

        try fixture.tasks.cancel(task)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.reminderAt == nil)
        #expect(stored.reminderOwner == .none)
    }

    @Test("The log groups by the day work was resolved, and keeps abandoned work")
    func logbook() throws {
        let fixture = try TaskFixture()
        let done = try fixture.task("Finished")
        let dropped = try fixture.task("Abandoned")

        try fixture.tasks.complete(done)
        try fixture.tasks.cancel(dropped)

        let log = try fixture.views.logbook()
        #expect(log.count == 1)
        #expect(log.first?.taskIDs.count == 2)
        #expect(try fixture.views.tasks(in: .completed).count == 2)
    }

    @Test("Reopening a task brings it back without its completion date")
    func reopening() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Not so fast")
        try fixture.tasks.complete(task)

        try fixture.tasks.reopen(task)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.status == .open)
        #expect(stored.completedAt == nil)
        #expect(try fixture.views.tasks(in: .anytime).count == 1)
    }
}

@Suite("Steps, subtasks, and the door between them")
@MainActor
struct ChecklistAndSubtaskTests {
    @Test("A checklist step is not a task and does not appear in any list")
    func stepsAreNotTasks() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Post the parcel")
        try fixture.tasks.addChecklistItem("buy stamps", to: task)

        #expect(try fixture.store.requireItem(id: task.id).checklist.total == 1)
        #expect(try fixture.views.tasks(in: .anytime).count == 1)
    }

    @Test("A subtask is a task, with its own row everywhere")
    func subtasksAreTasks() throws {
        let fixture = try TaskFixture()
        let parent = try fixture.task("Post the parcel")
        try fixture.task("Buy stamps", in: parent)

        #expect(try fixture.views.tasks(in: .anytime).count == 2)
    }

    @Test("Promoting a step turns it into a subtask and removes the step")
    func promotion() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Post the parcel")
        try fixture.tasks.addChecklistItem("buy stamps", to: task)
        let step = try #require(try fixture.store.sameContextItem(id: task.id).checklist.items.first)

        let subtask = try #require(try fixture.tasks.promoteChecklistItem(step.id, of: task))

        // Nothing is duplicated: the step goes, the task arrives.
        #expect(try fixture.store.requireItem(id: task.id).checklist.isEmpty)
        #expect(subtask.title == "buy stamps")
        #expect(subtask.parent?.id == task.id)
    }

    @Test("Demoting a subtask puts it back as a step")
    func demotion() throws {
        let fixture = try TaskFixture()
        let parent = try fixture.task("Post the parcel")
        let subtask = try fixture.task("Buy stamps", in: parent)

        try fixture.tasks.demoteToChecklistItem(subtask)

        #expect(try fixture.store.requireItem(id: parent.id).checklist.items.map(\.title) == ["Buy stamps"])
        #expect(try fixture.store.requireItem(id: subtask.id).deletedAt != nil)
    }

    @Test("Indenting makes a task a subtask of the one above")
    func indenting() throws {
        let fixture = try TaskFixture()
        let first = try fixture.task("Post the parcel")
        let second = try fixture.task("Buy stamps")

        #expect(try fixture.tasks.indent(second, under: first))
        #expect(try fixture.store.requireItem(id: second.id).parent?.id == first.id)
    }

    @Test("Indenting under a descendant is declined rather than failing")
    func indentingRefusesACycle() throws {
        let fixture = try TaskFixture()
        let parent = try fixture.task("Post the parcel")
        let child = try fixture.task("Buy stamps", in: parent)

        // A keyboard handler needs to know nothing happened so it can decline the Tab.
        #expect(try !fixture.tasks.indent(parent, under: child))
        #expect(try fixture.store.requireItem(id: parent.id).parent == nil)
    }

    @Test("Outdenting lifts a subtask one level")
    func outdenting() throws {
        let fixture = try TaskFixture()
        let project = try fixture.store.makeProject(title: "Errands")
        let parent = try fixture.task("Post the parcel", in: project)
        let child = try fixture.task("Buy stamps", in: parent)

        #expect(try fixture.tasks.outdent(child))
        #expect(try fixture.store.requireItem(id: child.id).parent?.id == project.id)
    }
}

@Suite("Smart lists over the store")
@MainActor
struct SmartListStoreTests {
    @Test("Membership is computed and ownership is untouched")
    func membershipDoesNotMove() throws {
        let fixture = try TaskFixture()
        let project = try fixture.store.makeProject(title: "Launch")
        let task = try fixture.task("Write the copy", in: project)
        try fixture.tasks.setFlagged(true, on: task)

        let matches = try fixture.views.tasks(matching: TaskFilter(rules: [.flagged(true)]))

        #expect(matches.map(\.title) == ["Write the copy"])
        #expect(try fixture.store.requireItem(id: task.id).parent?.id == project.id)
    }

    @Test("A filter that includes finished work reaches into the log")
    func resolvedScope() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Finished thing")
        try fixture.tasks.complete(task)

        let openOnly = try fixture.views.tasks(matching: TaskFilter(rules: [.hasNoDate]))
        let withLog = try fixture.views.tasks(
            matching: TaskFilter(rules: [.completedWithin(days: 1)], includesResolved: true)
        )

        #expect(openOnly.isEmpty)
        #expect(withLog.map(\.title) == ["Finished thing"])
    }

    @Test("Every built-in list runs against a real store without throwing")
    func builtInsRun() throws {
        let fixture = try TaskFixture()
        let maya = try fixture.person("Maya")
        let overdue = try fixture.task("Late")
        try fixture.tasks.setDeadline(fixture.day(-1), on: overdue)
        let waiting = try fixture.task("Blocked")
        try fixture.tasks.markWaiting(waiting, on: maya)
        let repeating = try fixture.task("Weekly")
        try fixture.store.items.update(repeating) { $0.recurrence = RecurrenceRule(frequency: .weekly) }

        for list in BuiltInSmartList.all {
            _ = try fixture.views.tasks(matching: list.filter)
        }

        #expect(try fixture.views.tasks(matching: BuiltInSmartList.list(id: "overdue")?.filter ?? TaskFilter()).count == 1)
        #expect(try fixture.views.tasks(matching: BuiltInSmartList.list(id: "waiting")?.filter ?? TaskFilter()).count == 1)
        #expect(try fixture.views.tasks(matching: BuiltInSmartList.list(id: "repeating")?.filter ?? TaskFilter()).count == 1)
    }
}

@Suite("The system views agree with each other")
@MainActor
struct SystemViewTests {
    @Test("An unfiled capture is in the Inbox and leaves when it is given a home")
    func inboxMembership() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("A thought")

        #expect(try fixture.views.tasks(in: .inbox).map(\.title) == ["A thought"])

        try fixture.store.items.setTags(task, slugs: ["home"])
        #expect(try fixture.views.tasks(in: .inbox).isEmpty)
    }

    @Test("A future start date keeps work out of Anytime and puts it in Upcoming")
    func futureWorkIsNotAvailable() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Start the tax return")
        try fixture.tasks.setStartDate(fixture.day(30), on: task)

        #expect(try fixture.views.tasks(in: .anytime).isEmpty)
        #expect(try fixture.views.tasks(in: .upcoming).map(\.title) == ["Start the tax return"])

        let agenda = try fixture.views.upcoming()
        let entries = agenda.flatMap(\.entries)
        #expect(entries.contains { $0.reason == .becomesAvailable })
        #expect(!entries.contains { $0.reason == .deadline })
    }

    @Test("Someday work is in no count and no agenda")
    func somedayIsQuiet() throws {
        let fixture = try TaskFixture()
        let task = try fixture.task("Learn piano")
        try fixture.tasks.setDeadline(fixture.day(5), on: task)
        try fixture.tasks.setSomeday(true, on: task)

        #expect(try fixture.views.upcoming().allSatisfy(\.entries.isEmpty))
        #expect(try fixture.views.badgeCount(for: .today) == 0)
    }

    @Test("Only Inbox and Today carry a badge")
    func badgesAreRestrained() throws {
        let fixture = try TaskFixture()
        for view in TaskSystemView.allCases {
            let count = try fixture.views.badgeCount(for: view)
            #expect((count != nil) == view.showsCount, "\(view.title) badge")
        }
    }

    @Test("Anytime groups by container, with unfiled work last")
    func anytimeGrouping() throws {
        let fixture = try TaskFixture()
        let project = try fixture.store.makeProject(title: "Launch")
        try fixture.task("Loose end")
        try fixture.task("Write the copy", in: project)

        let groups = try fixture.views.anytime()

        #expect(groups.count == 2)
        #expect(groups.first?.heading.title == "Launch")
        #expect(groups.last?.heading == .unfiled)
    }
}

/// ``TaskViewService/contents(of:)`` exists to stop the workspace traversing the library twice for
/// one destination, and the only way that is worth having is if it gives the same answer as the two
/// calls it replaced. This is that check, over a library with a task in each of the states the views
/// distinguish — because an agreement that only holds for an empty store is not an agreement.
@Suite("One pass says what two passes said")
@MainActor
struct TaskViewContentsTests {
    /// A library with something in every view.
    private func populated() throws -> TaskFixture {
        let fixture = try TaskFixture()
        let project = try fixture.store.makeProject(title: "Launch")

        try fixture.task("Loose end")
        let overdue = try fixture.task("Overdue thing", in: project)
        try fixture.tasks.setDeadline(fixture.day(-3), on: overdue)

        let committed = try fixture.task("Chosen for today", in: project)
        try fixture.tasks.commitToToday(committed)

        let later = try fixture.task("Starts next month")
        try fixture.tasks.setStartDate(fixture.day(30), on: later)

        let due = try fixture.task("Due Friday", in: project)
        try fixture.tasks.setDeadline(fixture.day(5), on: due)

        let parked = try fixture.task("Learn piano")
        try fixture.tasks.setSomeday(true, on: parked)

        let flagged = try fixture.task("Flagged one")
        try fixture.tasks.setFlagged(true, on: flagged)

        let waiting = try fixture.task("Waiting on Sam")
        try fixture.tasks.markWaiting(waiting, on: nil)

        let done = try fixture.task("Finished")
        try fixture.store.items.toggleCompletion(done)

        return fixture
    }

    /// Guards the two tests below, which would pass on an empty store and prove nothing.
    @Test("The library used here reaches every view", arguments: TaskSystemView.allCases)
    func fixtureIsNotVacuous(view: TaskSystemView) throws {
        let fixture = try populated()
        #expect(try !fixture.views.contents(of: view).tasks.isEmpty, "\(view.title) is empty")
    }

    @Test("Every view's tasks are the ones the pair of calls returned", arguments: TaskSystemView.allCases)
    func tasksAgree(view: TaskSystemView) throws {
        let fixture = try populated()

        let contents = try fixture.views.contents(of: view)
        let separately = try fixture.views.tasks(in: view)

        #expect(
            Set(contents.tasks.map(\.id)) == Set(separately.map(\.id)),
            "\(view.title) names a different set of tasks in one pass than in two"
        )
    }

    @Test("Every view's grouping is the one the section call returned")
    func sectionsAgree() throws {
        let fixture = try populated()

        #expect(try ids(fixture.views.contents(of: .today).sections) == ids(fixture.views.today()))
        #expect(try ids(fixture.views.contents(of: .anytime).sections) == ids(fixture.views.anytime()))
        #expect(try ids(fixture.views.contents(of: .someday).sections) == ids(fixture.views.someday()))
        #expect(try ids(fixture.views.contents(of: .completed).sections) == ids(fixture.views.logbook()))

        let agenda = try fixture.views.contents(of: .upcoming).agenda
        let separately = try fixture.views.upcoming()
        #expect(agenda.map(\.id) == separately.map(\.id))
    }

    /// The flat list has to hold every task the sections name, or a row would draw as a gap and a
    /// selection would act on nothing.
    @Test("Nothing a section names is missing from the flat list")
    func sectionsAreCovered() throws {
        let fixture = try populated()

        for view in TaskSystemView.allCases {
            let contents = try fixture.views.contents(of: view)
            let named = Set(contents.sections.flatMap(\.taskIDs))
            #expect(
                named.isSubset(of: Set(contents.tasks.map(\.id))),
                "\(view.title) draws a section naming a task it did not load"
            )
        }
    }

    private func ids(_ groups: [TaskSectionGroup]) -> [String] {
        groups.map { "\($0.id):\($0.taskIDs.map(\.uuidString).joined(separator: ","))" }
    }
}
