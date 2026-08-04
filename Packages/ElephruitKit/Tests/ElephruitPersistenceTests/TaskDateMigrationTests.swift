import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Fixtures written the way a library *before* the scheduling model looked: `dueAt` for anything
/// dated, `deferUntil` for anything held back, and no reminder field at all.
@MainActor
private struct LegacyLibrary {
    let fixture: StoreFixture
    var calendar: Calendar { fixture.dateProvider.calendar }

    init() throws {
        fixture = try StoreFixture()
    }

    func day(_ offset: Int) -> Date {
        fixture.dateProvider.startOfDay(daysFromToday: offset)
    }

    func instant(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset)) ?? day(offset)
    }

    /// Writes the columns directly, because that is what an old build left behind — going through
    /// `ItemDraft` would apply today's meaning to yesterday's data and prove nothing.
    @discardableResult
    func legacyTask(
        _ title: String,
        dueAt: Date? = nil,
        startAt: Date? = nil,
        deferUntil: Date? = nil,
        completed: Bool = false
    ) throws -> Item {
        let task = try fixture.items.create(ItemDraft(kind: .task, title: title))
        try fixture.items.update(task) { subject in
            subject.dueAt = dueAt
            subject.startAt = startAt
            subject.deferUntil = deferUntil
            if completed {
                subject.status = .completed
                subject.completedAt = day(-1)
            }
        }
        return task
    }
}

@Suite("Migrating a library written before start dates and deadlines were separate")
@MainActor
struct TaskDateMigrationTests {
    @Test("A hold-until date becomes a start date, because it already meant that")
    func deferBecomesStart() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask("Renew the lease", deferUntil: library.day(5))

        let report = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        #expect(migrated.startAt == library.day(5))
        #expect(migrated.deferUntil == nil)
        #expect(report.folds.count == 1)
        // Lossless, so nothing is flagged.
        #expect(report.flags.isEmpty)
        #expect(migrated.dateReview == nil)
    }

    @Test("A deadline is left alone, because it already meant a deadline")
    func deadlineIsUntouched() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask("File the accounts", dueAt: library.day(9))

        try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        #expect(migrated.dueAt == library.day(9))
        #expect(migrated.startAt == nil)
        #expect(migrated.reminderAt == nil)
        #expect(migrated.dateReview == nil)
    }

    @Test("A deadline carrying a time is flagged and **not** converted")
    func ambiguousDeadlineIsFlaggedOnly() throws {
        let library = try LegacyLibrary()
        let atFive = library.instant(3, hour: 17)
        let task = try library.legacyTask("Send the draft", dueAt: atFive)

        let report = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        // The whole point: the value does not move. "Finish by 5pm" and "tell me at 5pm" are
        // different requests, and the data cannot tell them apart.
        #expect(migrated.dueAt == atFive)
        #expect(migrated.reminderAt == nil)
        #expect(migrated.dateReview == .deadlineMayHaveBeenAReminder)
        #expect(report.flags.map(\.reason) == [.deadlineMayHaveBeenAReminder])
    }

    @Test("A task that already has a reminder is not second-guessed")
    func existingReminderMeansNoAmbiguity() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask("Standup", dueAt: library.instant(1, hour: 9))
        try library.fixture.items.update(task) { $0.reminderAt = library.instant(1, hour: 8) }

        try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        #expect(try library.fixture.requireItem(id: task.id).dateReview == nil)
    }

    @Test("Two disagreeing start dates keep the earlier one and say so")
    func disagreeingStartDates() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask(
            "Book the venue",
            startAt: library.day(8),
            deferUntil: library.day(3)
        )

        let report = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        // Earlier, so the task becomes visible sooner rather than vanishing for five days.
        #expect(migrated.startAt == library.day(3))
        #expect(migrated.deferUntil == nil)
        #expect(migrated.dateReview == .startAndDeferDisagreed)
        #expect(report.flags.map(\.reason) == [.startAndDeferDisagreed])
    }

    @Test("Two agreeing start dates just drop the legacy column, with nothing to decide")
    func agreeingStartDates() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask(
            "Order the cake",
            startAt: library.day(4),
            deferUntil: library.day(4)
        )

        let report = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        #expect(migrated.startAt == library.day(4))
        #expect(migrated.deferUntil == nil)
        #expect(report.flags.isEmpty)
    }

    @Test("Completed history is migrated too, so restoring a task does not bring back the old meaning")
    func historyIsMigrated() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask("Old errand", deferUntil: library.day(-40), completed: true)

        try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        #expect(migrated.startAt == library.day(-40))
        #expect(migrated.status == .completed)
        #expect(migrated.completedAt != nil)
    }

    @Test("Nothing else is touched: titles, tags, links, notes, and provenance all survive")
    func nothingElseChanges() throws {
        let library = try LegacyLibrary()
        let project = try library.fixture.makeProject(title: "Move house")
        let task = try library.fixture.items.create(
            ItemDraft(
                kind: .task,
                title: "Book the van",
                body: "Ask about insurance",
                tagSlugs: ["home"],
                parentID: project.id,
                priority: .high,
                source: ItemSource(kind: .quickCapture)
            )
        )
        try library.fixture.items.update(task) { $0.deferUntil = library.day(2) }

        try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let migrated = try library.fixture.requireItem(id: task.id)

        #expect(migrated.title == "Book the van")
        #expect(migrated.body == "Ask about insurance")
        #expect((migrated.tags ?? []).map(\.slug) == ["home"])
        #expect(migrated.parent?.id == project.id)
        #expect(migrated.priority == .high)
        #expect(migrated.source.kind == .quickCapture)
        #expect(migrated.createdAt == task.createdAt)
    }

    @Test("The dry run writes nothing and reports the same work")
    func dryRunIsInert() throws {
        let library = try LegacyLibrary()
        let task = try library.legacyTask("Renew the lease", deferUntil: library.day(5))

        let planned = try TaskDateMigration.plan(in: library.fixture.context, calendar: library.calendar)
        #expect(planned.isDryRun)
        #expect(planned.folds.count == 1)
        #expect(try library.fixture.requireItem(id: task.id).deferUntil == library.day(5))

        let applied = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        #expect(!applied.isDryRun)
        #expect(applied.folds.map(\.itemID) == planned.folds.map(\.itemID))
    }

    @Test("Running it twice is the same as running it once")
    func idempotent() throws {
        let library = try LegacyLibrary()
        try library.legacyTask("A", deferUntil: library.day(1))
        try library.legacyTask("B", dueAt: library.instant(2, hour: 14))

        let first = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)
        let second = try TaskDateMigration.apply(in: library.fixture.context, calendar: library.calendar)

        #expect(first.hasWork)
        #expect(second.folds.isEmpty)
        // The already-flagged task is not re-flagged into a second decision.
        #expect(second.flags.count == first.flags.count)
    }

    @Test("A library that never used the legacy column has no work to do")
    func modernLibraryIsUntouched() throws {
        let library = try LegacyLibrary()
        try library.legacyTask("Clean", dueAt: library.day(3), startAt: library.day(1))

        let report = try TaskDateMigration.plan(in: library.fixture.context, calendar: library.calendar)
        #expect(!report.hasWork)
        #expect(report.tasksExamined == 1)
    }

    @Test("Notes and bookmarks are never examined, because they cannot hold these dates")
    func onlyDateBearingKindsAreConsidered() throws {
        let library = try LegacyLibrary()
        try library.fixture.makeNote(title: "A thought")
        try library.legacyTask("A task")

        #expect(try TaskDateMigration.plan(in: library.fixture.context, calendar: library.calendar).tasksExamined == 1)
    }

    @Test("Midnight is a day, and any other time is a time")
    func timeOfDayDetection() {
        let calendar = FixedDateProvider.reference.calendar
        let midnight = FixedDateProvider.reference.startOfToday

        #expect(!TaskDateMigration.carriesTimeOfDay(midnight, calendar: calendar))
        #expect(
            TaskDateMigration.carriesTimeOfDay(
                calendar.date(byAdding: .minute, value: 1, to: midnight) ?? midnight,
                calendar: calendar
            )
        )
    }
}

@Suite("The new task columns behave in the store")
@MainActor
struct TaskColumnTests {
    @Test("A checklist survives a round trip through the store")
    func checklistRoundTrip() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Post the parcel")

        try fixture.items.update(task) {
            $0.checklist = TaskChecklist.parse("- buy stamps\n- address it")
        }

        let stored = try fixture.requireItem(id: task.id)
        #expect(stored.checklist.items.map(\.title) == ["buy stamps", "address it"])
        #expect(stored.checklist.total == 2)
    }

    @Test("A note cannot acquire a task's marks")
    func planningMarksAreRefusedOnANote() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "A thought")

        #expect(throws: AppError.self) {
            try fixture.items.update(note) { $0.isFlagged = true }
        }
        #expect(throws: AppError.self) {
            try fixture.items.update(note) { $0.reminderAt = fixture.dateProvider.now }
        }
    }

    @Test("A project may be parked and flagged, and may not be reminded about")
    func projectPlanningWithoutReminders() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Move house")

        try fixture.items.update(project) {
            $0.isSomeday = true
            $0.isFlagged = true
        }
        #expect(try fixture.requireItem(id: project.id).isSomeday)

        #expect(throws: AppError.self) {
            try fixture.items.update(project) { $0.reminderAt = fixture.dateProvider.now }
        }
    }

    @Test("Turning a task into a note clears its marks and drops the Reminders link, not the reminder")
    func conversionClearsTaskOnlyFields() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Call the bank")

        try fixture.items.update(task) { subject in
            subject.isFlagged = true
            subject.isSomeday = true
            subject.reminderAt = fixture.dateProvider.now
            subject.checklist = TaskChecklist.parse("- find the number")
            subject.setReminderLink(
                ReminderLinkState(
                    externalID: "rem-1",
                    listID: "list-1",
                    lastSyncedFingerprint: "abc",
                    lastSyncedAt: fixture.dateProvider.now,
                    lastSyncedLocalStamp: fixture.dateProvider.now
                )
            )
        }

        let cleared = try fixture.items.setKind(task, to: .note)
        let converted = try fixture.requireItem(id: task.id)

        #expect(!converted.isFlagged)
        #expect(!converted.isSomeday)
        #expect(converted.reminderAt == nil)
        #expect(converted.checklistData == nil)
        #expect(converted.externalIdentifier == nil)
        #expect(converted.syncState == .local)
        // The user is told rather than left to notice.
        #expect(cleared.contains("reminder"))
        #expect(cleared.contains("Reminders link"))
    }

    @Test("A half-written external link is not a link")
    func partialLinkIsIgnored() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Buy milk")

        try fixture.items.update(task) { $0.externalIdentifier = "rem-1" }
        #expect(try fixture.requireItem(id: task.id).reminderLink == nil)
    }

    @Test("A cancelled task needs a cancellation date, and a live one must not haveated")
    func cancellationStampIsEnforced() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Abandoned idea")

        #expect(throws: AppError.self) {
            try fixture.items.update(task) { $0.status = .cancelled }
        }

        try fixture.items.update(task) { subject in
            subject.status = .cancelled
            subject.cancelledAt = fixture.dateProvider.now
        }
        #expect(try fixture.requireItem(id: task.id).status == .cancelled)
    }

    @Test("A list holds tasks and headings, and sits inside an area")
    func listContainment() throws {
        let fixture = try StoreFixture()
        let area = try fixture.makeArea(title: "Home")
        let list = try fixture.items.create(ItemDraft(kind: .list, title: "Groceries", parentID: area.id))
        let task = try fixture.makeTask(title: "Milk", parentID: list.id)

        #expect(try fixture.requireItem(id: list.id).parent?.id == area.id)
        #expect(try fixture.requireItem(id: task.id).parent?.id == list.id)

        // A list is not a project and does not hold one.
        #expect(!ItemKind.list.canContain(.project))
        #expect(!ItemKind.list.supportsStatus)
    }

    @Test("A task in a section of a project in an area finds all four in one walk")
    func containerWalk() throws {
        let fixture = try StoreFixture()
        let area = try fixture.makeArea(title: "Work")
        let project = try fixture.makeProject(title: "Launch", parentID: area.id)
        let heading = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Before the trip", parentID: project.id)
        )
        let task = try fixture.makeTask(title: "Book flights", parentID: heading.id)

        let containers = try fixture.sameContextItem(id: task.id).enclosingContainers()
        #expect(containers.area?.id == area.id)
        #expect(containers.project?.id == project.id)
        #expect(containers.section?.id == heading.id)
        #expect(containers.list == nil)
    }

    @Test("A smart list's rules live beside a saved search's text, and never both at once")
    func smartListStorage() throws {
        let fixture = try StoreFixture()
        let saved = SavedSearch(name: "Client work", queryString: "type:task tag:clients")
        fixture.context.insert(saved)

        #expect(!saved.isTaskSmartList)

        saved.taskFilter = TaskFilter(rules: [.flagged(true)])
        try fixture.context.save()

        #expect(saved.isTaskSmartList)
        #expect(saved.queryString.isEmpty)
        #expect(saved.taskFilter?.rules == [.flagged(true)])
    }
}
