import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// A store plus a task service over it.
@MainActor
private struct WhenFixture {
    let store: StoreFixture
    let tasks: ReminderLifecycleService

    init() throws {
        store = try StoreFixture()
        tasks = ReminderLifecycleService(items: store.items, context: store.context, dateProvider: store.dateProvider)
    }

    var calendar: Calendar { store.dateProvider.calendar }
    var now: Date { store.dateProvider.now }

    func day(_ offset: Int) -> Date { store.dateProvider.startOfDay(daysFromToday: offset) }

    func task(_ title: String = "A task") throws -> Item {
        try store.items.create(ItemDraft(kind: .task, title: title))
    }
}

/// ### The property this suite exists for
/// The scheduling model rests on one distinction: a start date says *do not ask me until then* and
/// can never make a task late, while a deadline is an outside commitment and is the only date that
/// can. The *When* control offers five answers, all of them on the first side of that line. A control
/// that quietly crossed it would leave everything downstream — Today, Upcoming, the overdue count —
/// wrong while looking right, which is the kind of wrong nobody notices for a month.
@Suite("Every answer to “when” is a start, a commitment, or Someday — never a deadline")
@MainActor
struct TaskWhenChoiceTests {
    @Test("No choice writes a deadline, on a task that has none and on one that has")
    func nothingEverSetsADeadline() throws {
        let fixture = try WhenFixture()

        for choice in TaskWhenChoice.allChoices(startingOn: fixture.day(2)) {
            let fresh = try fixture.task()
            try fixture.tasks.apply(choice, to: fresh)
            #expect(fresh.dueAt == nil, "\(choice) invented a deadline")

            // And the other direction: a task that already has one keeps it. A When control that
            // cleared a deadline as a side effect would silently drop an outside commitment.
            let committed = try fixture.task("Send the contract")
            try fixture.tasks.setDeadline(fixture.day(4), on: committed)
            try fixture.tasks.apply(choice, to: committed)
            #expect(
                committed.dueAt.map { fixture.calendar.isDate($0, inSameDayAs: fixture.day(4)) } == true,
                "\(choice) disturbed an existing deadline"
            )
        }
    }

    @Test("Today puts it on today's plan and nowhere else")
    func todayCommits() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()

        try fixture.tasks.apply(.today, to: task)

        #expect(fixture.tasks.isCommittedToToday(task))
        #expect(!task.isLaterToday)
        #expect(task.availableFrom == nil)
    }

    @Test("This Evening is today, in the back half of it")
    func thisEveningIsStillToday() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()

        try fixture.tasks.apply(.thisEvening, to: task)

        #expect(fixture.tasks.isCommittedToToday(task))
        #expect(task.isLaterToday)
    }

    @Test("Someday parks it")
    func somedayParks() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()

        try fixture.tasks.apply(.someday, to: task)

        #expect(task.isSomeday)
        #expect(task.taskFacts().lifecycle == .someday)
    }

    @Test("A day from the grid is a start date, and un-parks a task that was Someday")
    func aChosenDayIsAStartDate() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()
        try fixture.tasks.apply(.someday, to: task)

        try fixture.tasks.apply(.startingOn(fixture.day(3)), to: task)

        #expect(task.availableFrom.map { fixture.calendar.isDate($0, inSameDayAs: fixture.day(3)) } == true)
        // Someday means "no date, deliberately". Both at once is a contradiction somebody would
        // otherwise have to resolve on the user's behalf, and choosing a day *is* the user resolving
        // it.
        #expect(!task.isSomeday)
    }

    @Test("A past start date still makes nothing overdue")
    func aStartDateIsNeverLate() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()

        try fixture.tasks.apply(.startingOn(fixture.day(-30)), to: task)

        #expect(
            task.taskFacts().deadlineUrgency(on: fixture.now, calendar: fixture.calendar) == .none
        )
    }

    @Test("Clear undoes all three ways of answering, together")
    func clearUndoesEverything() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()
        try fixture.tasks.apply(.today, to: task)
        try fixture.tasks.setStartDate(fixture.day(2), on: task)

        try fixture.tasks.apply(.clear, to: task)

        #expect(task.availableFrom == nil)
        #expect(!task.isSomeday)
        #expect(!fixture.tasks.isCommittedToToday(task))
    }

    @Test("A reminder is never created by choosing a day")
    func choosingADayNeverInterrupts() throws {
        let fixture = try WhenFixture()

        for choice in TaskWhenChoice.allChoices(startingOn: fixture.day(2)) {
            let task = try fixture.task()
            try fixture.tasks.apply(choice, to: task)
            // Visibility and interruption are different requests, and an app that turns the first
            // into the second is one people switch off.
            #expect(task.reminderAt == nil, "\(choice) created a reminder")
        }
    }
}

/// ### Why the conversion is asserted rather than eyeballed
/// The thing being kept is the task's *identity*: every link pointing at it, every mention in
/// somebody's body text, every search result somebody has open. The manual route — make a project,
/// drag the subtasks over, delete the task — breaks all of that silently, which is exactly why this
/// exists and exactly what a test has to prove it does not do.
@Suite("A task that turned out to be a project keeps everything pointing at it")
@MainActor
struct ConvertToProjectTests {
    @Test("The row survives, with its identity, its links and its subtasks")
    func identityAndChildrenSurvive() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task("Move house")
        let id = task.id
        let ana = try fixture.store.items.create(ItemDraft(kind: .person, title: "Ana"))
        try fixture.tasks.setRelatedPeople([ana], on: task)

        let packing = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Pack the kitchen", parentID: task.id)
        )

        try fixture.tasks.convertToProject(task)

        #expect(task.kind == .project)
        #expect(task.id == id)
        #expect(task.linkedPeople(kinds: [.mentions]).map(\.id) == [ana.id])
        #expect(packing.parent?.id == id)
        #expect(task.children.contains { $0.id == packing.id })
    }

    @Test("Steps become tasks rather than being dropped on the floor")
    func stepsBecomeTasks() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task("Move house")
        try fixture.tasks.addChecklistItem("Book the van", to: task)
        try fixture.tasks.addChecklistItem("Change the address", to: task)

        try fixture.tasks.convertToProject(task)

        // A project has no checklist, so conforming to the kind would have thrown both away. A
        // conversion that silently discards two steps is not one anybody would have agreed to.
        #expect(task.checklist.isEmpty)
        let titles = task.children.map(\.title).sorted()
        #expect(titles == ["Book the van", "Change the address"])
        #expect(task.children.allSatisfy { $0.kind == .reminder })
    }

    @Test("A task inside a heading becomes a project somewhere a project may live")
    func rehomedOutOfAHeading() throws {
        let fixture = try WhenFixture()
        let area = try fixture.store.items.create(ItemDraft(kind: .area, title: "Home"))
        let project = try fixture.store.items.create(
            ItemDraft(kind: .project, title: "Renovation", parentID: area.id)
        )
        let heading = try fixture.store.items.create(
            ItemDraft(kind: .heading, title: "Kitchen", parentID: project.id)
        )
        let task = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Replace the worktop", parentID: heading.id)
        )

        try fixture.tasks.convertToProject(task)

        // Nothing in the containment rules permits a project inside a heading, so it rises to the
        // nearest ancestor that may hold one — here the area, since a project cannot hold a project.
        #expect(task.parent?.id == area.id)
        #expect(area.kind.canContain(.project))
    }

    @Test("A task with nowhere above it that can hold a project becomes an unfiled one")
    func topLevelIsAValidOutcome() throws {
        let fixture = try WhenFixture()
        let parent = try fixture.task("The bigger thing")
        let task = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Actually a project", parentID: parent.id)
        )

        try fixture.tasks.convertToProject(task)

        // An unfiled project is an ordinary thing, and a better outcome than refusing the conversion
        // because of where the task happened to sit.
        #expect(task.parent == nil)
        #expect(task.kind == .project)
    }

    @Test("Fields a project cannot hold are reported rather than silently dropped")
    func clearedFieldsAreNamed() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task("Move house")
        try fixture.tasks.setReminder(fixture.day(2), timed: true, on: task)

        let cleared = try fixture.tasks.convertToProject(task)

        #expect(task.reminderAt == nil)
        #expect(!cleared.isEmpty, "the reminder went without being named")
    }

    @Test("Converting something that is not a task does nothing at all")
    func onlyTasksConvert() throws {
        let fixture = try WhenFixture()
        let note = try fixture.store.items.create(ItemDraft(kind: .note, title: "A thought"))

        #expect(try fixture.tasks.convertToProject(note).isEmpty)
        #expect(note.kind == .note)
    }
}

/// ### Why people-on-a-task gets its own assertions
/// Because the obvious implementation — replace every person link — silently stops a task waiting on
/// Ana the moment somebody adds a second name to it. A control that quietly undoes a different
/// control is worse than one that does less.
@Suite("Attaching people to a task leaves the other person links alone")
@MainActor
struct TaskRelatedPeopleTests {
    @Test("Setting the set adds, removes, and is idempotent")
    func wholeSetSemantics() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()
        let ana = try fixture.store.items.create(ItemDraft(kind: .person, title: "Ana"))
        let bo = try fixture.store.items.create(ItemDraft(kind: .person, title: "Bo"))

        try fixture.tasks.setRelatedPeople([ana, bo], on: task)
        #expect(Set(task.linkedPeople(kinds: [.mentions]).map(\.id)) == [ana.id, bo.id])

        // Twice is the same as once: the caller's intent is "these are the people".
        try fixture.tasks.setRelatedPeople([ana, bo], on: task)
        #expect(task.linkedPeople(kinds: [.mentions]).count == 2)

        try fixture.tasks.setRelatedPeople([bo], on: task)
        #expect(task.linkedPeople(kinds: [.mentions]).map(\.id) == [bo.id])

        try fixture.tasks.setRelatedPeople([], on: task)
        #expect(task.linkedPeople(kinds: [.mentions]).isEmpty)
    }

    @Test("Clearing everybody does not stop the task waiting on somebody")
    func waitingSurvives() throws {
        let fixture = try WhenFixture()
        let task = try fixture.task()
        let ana = try fixture.store.items.create(ItemDraft(kind: .person, title: "Ana"))
        let bo = try fixture.store.items.create(ItemDraft(kind: .person, title: "Bo"))

        try fixture.tasks.markWaiting(task, on: ana)
        try fixture.tasks.setRelatedPeople([bo], on: task)
        try fixture.tasks.setRelatedPeople([], on: task)

        #expect(task.waitingOnPerson()?.id == ana.id)
        #expect(task.waitingSince != nil)
    }
}
