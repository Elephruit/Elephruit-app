import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
private struct TimeFixture {
    let store: StoreFixture
    let time: SwiftDataTimeEntryRepository
    var clock: any DateProvider { store.dateProvider }

    init() throws {
        store = try StoreFixture()
        time = SwiftDataTimeEntryRepository(
            context: store.context,
            dateProvider: store.dateProvider,
            tags: store.tags
        )
    }

    var now: Date { clock.now }

    func makeTask(_ title: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .task, title: title))
    }
}

@Suite("Time tracking invariant")
@MainActor
struct TimeEntryInvariantTests {
    @Test("Nothing is running to begin with")
    func nothingRunsInitially() throws {
        let fixture = try TimeFixture()
        #expect(try fixture.time.runningEntry() == nil)
    }

    @Test("A second timer cannot start while one runs")
    func secondTimerRefused() throws {
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Draft the brief")

        _ = try fixture.time.start(item: task, description: "", tagSlugs: [])

        #expect(throws: AppError.self) {
            try fixture.time.start(item: nil, description: "Something else", tagSlugs: [])
        }

        // And the refusal left the first one alone, which is the point of refusing.
        let running = try #require(try fixture.time.runningEntry())
        #expect(running.item?.id == task.id)
    }

    @Test("The error says what is already being timed")
    func refusalNamesTheRunningTimer() throws {
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Draft the brief")
        _ = try fixture.time.start(item: task, description: "", tagSlugs: [])

        do {
            _ = try fixture.time.start(item: nil, description: "Other", tagSlugs: [])
            Issue.record("Expected the start to be refused")
        } catch {
            #expect(error.failureReason?.contains("Draft the brief") == true,
                    "An error that does not say what is running is not actionable")
        }
    }

    @Test("Switching stops the first and starts the second")
    func switchingIsOneAction() throws {
        let fixture = try TimeFixture()
        let first = try fixture.makeTask("First")
        let second = try fixture.makeTask("Second")

        let firstEntry = try fixture.time.start(item: first, description: "", tagSlugs: [])
        let secondEntry = try fixture.time.switchTo(item: second, description: "", tagSlugs: [])

        #expect(firstEntry.endedAt != nil, "Switching has to close what it switched away from")
        #expect(secondEntry.isRunning)

        let running = try #require(try fixture.time.runningEntry())
        #expect(running.id == secondEntry.id)
    }

    @Test("Stopping when nothing runs is not an error")
    func stoppingNothingIsFine() throws {
        let fixture = try TimeFixture()
        #expect(try fixture.time.stopRunning(at: nil) == nil)
    }

    @Test("An entry can never end before it starts")
    func durationCannotGoNegative() throws {
        let fixture = try TimeFixture()
        let entry = try fixture.time.start(item: nil, description: "Work", tagSlugs: [])

        // A clock that jumped backwards — a time-zone change, an NTP correction, a user edit.
        _ = try fixture.time.stopRunning(at: entry.startedAt.addingTimeInterval(-3_600))

        #expect(entry.duration() >= 0)
        #expect(entry.endedAt == entry.startedAt)
    }

    @Test("Editing cannot invert an entry either")
    func editingCannotInvert() throws {
        let fixture = try TimeFixture()
        let entry = try fixture.time.addManual(
            item: nil,
            description: "Work",
            startedAt: fixture.now.addingTimeInterval(-3_600),
            endedAt: fixture.now,
            tagSlugs: []
        )

        try fixture.time.update(entry) { $0.endedAt = $0.startedAt.addingTimeInterval(-60) }
        #expect(entry.duration() >= 0)
    }

    @Test("Manual entries have to have positive length")
    func manualEntryNeedsDuration() throws {
        let fixture = try TimeFixture()
        #expect(throws: AppError.self) {
            try fixture.time.addManual(
                item: nil,
                description: "Nothing at all",
                startedAt: fixture.now,
                endedAt: fixture.now,
                tagSlugs: []
            )
        }
    }

    @Test("Restoring a discarded running entry does not resurrect a second timer")
    func restoringDoesNotBreakTheInvariant() throws {
        let fixture = try TimeFixture()
        let first = try fixture.time.start(item: nil, description: "First", tagSlugs: [])
        try fixture.time.delete(first)

        // Something else is running by the time the user changes their mind.
        _ = try fixture.time.start(item: nil, description: "Second", tagSlugs: [])
        try fixture.time.restore(first)

        #expect(first.endedAt != nil, "A restored entry is closed at the moment it was discarded")

        let running = try #require(try fixture.time.runningEntry())
        #expect(running.entryDescription == "Second")
    }
}

@Suite("Concurrent timer reconciliation")
@MainActor
struct ConcurrentTimerTests {
    /// Two devices, two timers. Writing them directly, because the repository will not create this
    /// state — which is exactly why a repair for it has to be tested from the outside.
    private func makeTwoRunning(_ fixture: StoreFixture, apart seconds: TimeInterval) throws
        -> (earlier: TimeEntry, later: TimeEntry) {
        let start = fixture.dateProvider.now.addingTimeInterval(-seconds * 2)

        let earlier = TimeEntry(startedAt: start, entryDescription: "On the laptop")
        let later = TimeEntry(startedAt: start.addingTimeInterval(seconds), entryDescription: "On the desktop")

        fixture.context.insert(earlier)
        fixture.context.insert(later)
        try fixture.context.save()
        return (earlier, later)
    }

    @Test("The earlier timer is closed where the later one began, and nothing is deleted")
    func reconcileClosesRatherThanDeletes() throws {
        let store = try StoreFixture()
        let time = SwiftDataTimeEntryRepository(
            context: store.context, dateProvider: store.dateProvider, tags: store.tags
        )
        let (earlier, later) = try makeTwoRunning(store, apart: 1_800)

        let closed = try time.reconcileConcurrentTimers()
        #expect(closed == 1)

        #expect(earlier.endedAt == later.startedAt, "The gap belongs to whichever timer came next")
        #expect(later.isRunning, "The most recent timer is the one that survives running")
        #expect(earlier.deletedAt == nil, "A merge never deletes a record of work")
        #expect(earlier.duration() == 1_800)
    }

    @Test("Reconciling when only one runs changes nothing")
    func reconcileIsANoOpWhenHealthy() throws {
        let store = try StoreFixture()
        let time = SwiftDataTimeEntryRepository(
            context: store.context, dateProvider: store.dateProvider, tags: store.tags
        )
        _ = try time.start(item: nil, description: "Only one", tagSlugs: [])

        #expect(try time.reconcileConcurrentTimers() == 0)
        #expect(try time.runningEntry() != nil)
    }

    @Test("Three concurrent timers collapse into a chain")
    func reconcileHandlesMoreThanTwo() throws {
        let store = try StoreFixture()
        let time = SwiftDataTimeEntryRepository(
            context: store.context, dateProvider: store.dateProvider, tags: store.tags
        )
        let base = store.dateProvider.now.addingTimeInterval(-10_800)

        for offset in 0..<3 {
            let entry = TimeEntry(
                startedAt: base.addingTimeInterval(Double(offset) * 3_600),
                entryDescription: "Device \(offset)"
            )
            store.context.insert(entry)
        }
        try store.context.save()

        #expect(try time.reconcileConcurrentTimers() == 2)

        let descriptor = FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\TimeEntry.startedAt)])
        let all = try store.context.fetch(descriptor)
        #expect(all.count == 3, "Nothing was deleted")
        #expect(all.filter(\.isRunning).count == 1, "Exactly one survives running")
        #expect(all[0].endedAt == all[1].startedAt)
        #expect(all[1].endedAt == all[2].startedAt)
    }
}

@Suite("Time entries and items")
@MainActor
struct TimeEntryItemTests {
    @Test("Deleting an item keeps the hours worked on it")
    func deletingAnItemDoesNotDestroyTime() throws {
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Draft the brief")

        let entry = try fixture.time.addManual(
            item: task,
            description: "",
            startedAt: fixture.now.addingTimeInterval(-7_200),
            endedAt: fixture.now,
            tagSlugs: []
        )
        let entryID = entry.id

        try fixture.store.items.deletePermanently(task)

        let survivor = try #require(try fixture.time.entry(id: entryID))
        #expect(survivor.item == nil, "The link goes")
        #expect(survivor.duration() == 7_200, "The time does not")
    }

    @Test("Time against a task reports under that task's project")
    func timeRollsUpToTheProject() throws {
        let fixture = try TimeFixture()
        let project = try fixture.store.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        let task = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Book the venue", parentID: project.id)
        )

        let entry = try fixture.time.addManual(
            item: task,
            description: "",
            startedAt: fixture.now.addingTimeInterval(-3_600),
            endedAt: fixture.now,
            tagSlugs: []
        )

        #expect(entry.reportingProject()?.id == project.id,
                "Time by project is unanswerable if a task's time does not roll up to it")
    }

    /// The optimisation this guards.
    ///
    /// Resolving each entry's project one at a time made a year of history take 1.9 seconds over a
    /// 200,000-entry store, because tens of thousands of entries walked their parent chains to reach
    /// a few hundred distinct answers. `snapshots(in:)` memoises by item — and a cache that returns
    /// something different from what it replaced is worse than the cost it saved, so this asserts
    /// they agree, including for the cases most likely to break a memo.
    @Test("Memoised snapshots agree with resolving each entry on its own")
    func snapshotsMatchIndividualResolution() throws {
        let fixture = try TimeFixture()

        let projectA = try fixture.store.items.create(ItemDraft(kind: .project, title: "Alpha"))
        let projectB = try fixture.store.items.create(ItemDraft(kind: .project, title: "Beta"))
        let taskA = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Task A", parentID: projectA.id)
        )
        let taskB = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Task B", parentID: projectB.id)
        )
        let orphan = try fixture.makeTask("No project")

        // Several entries per item, two items sharing nothing, one item with no project at all, and
        // entries with no item — the four shapes a per-item memo has to keep straight.
        for (index, subject) in [taskA, taskB, taskA, orphan, taskB].enumerated() {
            _ = try fixture.time.addManual(
                item: subject,
                description: "Session \(index)",
                startedAt: fixture.now.addingTimeInterval(Double(-3_600 * (index + 2))),
                endedAt: fixture.now.addingTimeInterval(Double(-3_600 * (index + 1))),
                tagSlugs: []
            )
        }
        _ = try fixture.time.addManual(
            item: nil,
            description: "Unassigned",
            startedAt: fixture.now.addingTimeInterval(-600),
            endedAt: fixture.now,
            tagSlugs: []
        )

        let window = fixture.now.addingTimeInterval(-86_400)..<fixture.now.addingTimeInterval(86_400)

        let memoised = try fixture.time.snapshots(in: window, limit: nil)
        let individually = try fixture.time.entries(in: window, limit: nil)
            .map { $0.snapshot(at: fixture.now) }

        #expect(memoised.count == individually.count)
        #expect(memoised.map(\.id) == individually.map(\.id), "…and in the same order")

        for (fast, slow) in zip(memoised, individually) {
            #expect(fast.projectID == slow.projectID, "Project resolution must not depend on the path")
            #expect(fast.projectTitle == slow.projectTitle)
            #expect(fast.itemID == slow.itemID)
            #expect(fast.duration(at: fixture.now) == slow.duration(at: fixture.now))
        }

        // And the memo genuinely distinguished the two projects rather than collapsing them.
        #expect(Set(memoised.compactMap(\.projectTitle)) == ["Alpha", "Beta"])
    }

    @Test("Continuing a previous entry keeps its subject and starts fresh")
    func resumeCarriesTheSubject() throws {
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Draft the brief")

        let original = try fixture.time.addManual(
            item: task,
            description: "second pass",
            startedAt: fixture.now.addingTimeInterval(-3_600),
            endedAt: fixture.now.addingTimeInterval(-1_800),
            tagSlugs: ["writing"]
        )

        let resumed = try fixture.time.resume(original)

        #expect(resumed.id != original.id, "Continuing makes a new entry, it does not reopen an old one")
        #expect(resumed.item?.id == task.id)
        #expect(resumed.entryDescription == "second pass")
        #expect(resumed.tagSlugs == ["writing"])
        #expect(resumed.isRunning)
        #expect(original.endedAt != nil, "The original is untouched and still closed")
    }

    @Test("An entry spanning midnight belongs to both days")
    func overlapRatherThanContainment() throws {
        let fixture = try TimeFixture()
        let midnight = fixture.clock.startOfToday

        _ = try fixture.time.addManual(
            item: nil,
            description: "Late session",
            startedAt: midnight.addingTimeInterval(-3_600),
            endedAt: midnight.addingTimeInterval(3_600),
            tagSlugs: []
        )

        let today = try fixture.time.entries(in: midnight..<midnight.addingTimeInterval(86_400), limit: nil)
        #expect(today.count == 1, "A report that drops the overnight entry simply loses the hours")

        let yesterday = try fixture.time.entries(in: midnight.addingTimeInterval(-86_400)..<midnight, limit: nil)
        #expect(yesterday.count == 1)
    }

    @Test("Discarded entries stay out of every reading")
    func deletedEntriesAreExcluded() throws {
        let fixture = try TimeFixture()
        let entry = try fixture.time.addManual(
            item: nil,
            description: "Mistake",
            startedAt: fixture.now.addingTimeInterval(-600),
            endedAt: fixture.now,
            tagSlugs: []
        )
        try fixture.time.delete(entry)

        let window = fixture.now.addingTimeInterval(-86_400)..<fixture.now.addingTimeInterval(86_400)
        #expect(try fixture.time.entries(in: window, limit: nil).isEmpty)
        #expect(try fixture.time.recentEntries(limit: 10).isEmpty)
        #expect(try fixture.time.runningEntry() == nil)
    }
}

/// The corrections a log has to support to be worth keeping.
@Suite("Correcting tracked time")
@MainActor
struct TimeEntryCorrectionTests {
    @Test("A typed duration moves the end of a finished entry")
    func durationMovesTheEnd() throws {
        // The work began when it began; the guess about when it stopped is the part being fixed.
        let fixture = try TimeFixture()
        let started = fixture.now.addingTimeInterval(-3_600)
        let entry = try fixture.time.addManual(
            item: nil,
            description: "Drafting",
            startedAt: started,
            endedAt: fixture.now,
            tagSlugs: []
        )

        try fixture.time.setDuration(5_400, for: entry)

        #expect(entry.startedAt == started)
        #expect(entry.endedAt == started.addingTimeInterval(5_400))
        #expect(entry.duration() == 5_400)
    }

    @Test("A typed duration back-dates a running timer instead")
    func durationBackDatesARunningTimer() throws {
        // There is no end to move on something still running: its end is the present moment and
        // will still be the present moment a second later.
        let fixture = try TimeFixture()
        let entry = try fixture.time.start(item: nil, description: "Drafting", tagSlugs: [])

        try fixture.time.setDuration(5_400, for: entry)

        #expect(entry.endedAt == nil)
        #expect(entry.startedAt == fixture.now.addingTimeInterval(-5_400))
        #expect(entry.duration(at: fixture.now) == 5_400)
    }

    @Test("A negative length is refused rather than quietly corrected")
    func negativeDurationRefused() throws {
        let fixture = try TimeFixture()
        let entry = try fixture.time.start(item: nil, description: "", tagSlugs: [])

        #expect(throws: AppError.self) {
            try fixture.time.setDuration(-60, for: entry)
        }
    }

    @Test("Tags can be replaced after the fact")
    func tagsAreEditable() throws {
        // One of the two fields most often wrong, because it is one of the two you skip when
        // starting a timer in a hurry.
        let fixture = try TimeFixture()
        let entry = try fixture.time.start(item: nil, description: "", tagSlugs: ["draft"])

        try fixture.time.setTags(["deep", "writing"], on: entry)

        #expect(entry.tagSlugs == ["deep", "writing"])
    }

    @Test("Duplicating copies an entry over the same stretch of clock")
    func duplicateLandsWhereTheOriginalDid() throws {
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Standup")
        let original = try fixture.time.addManual(
            item: task,
            description: "the second one",
            startedAt: fixture.now.addingTimeInterval(-1_800),
            endedAt: fixture.now,
            tagSlugs: ["meeting"],
            isBillable: true
        )

        let copy = try fixture.time.duplicate(original)

        #expect(copy.id != original.id)
        #expect(copy.startedAt == original.startedAt)
        #expect(copy.endedAt == original.endedAt)
        #expect(copy.item?.id == task.id)
        #expect(copy.entryDescription == "the second one")
        #expect(copy.tagSlugs == ["meeting"])
        #expect(copy.isBillable)

        // Typed into existence, so nothing can ever offer it for crash recovery.
        #expect(copy.source == .manual)
    }

    @Test("A running timer cannot be duplicated")
    func duplicateRefusesARunningTimer() throws {
        // Copying something with no end would produce a second running timer, which is the one
        // thing the whole repository exists to prevent.
        let fixture = try TimeFixture()
        let entry = try fixture.time.start(item: nil, description: "", tagSlugs: [])

        #expect(throws: AppError.self) {
            try fixture.time.duplicate(entry)
        }
        #expect(try fixture.time.runningEntry()?.id == entry.id)
    }

    @Test("Continuing an entry carries its billability")
    func resumeCarriesBillable() throws {
        // Whether work is billable is a fact about the work, not about the stretch of clock, so
        // losing it on continue is a silent revenue leak nobody notices until the invoice.
        let fixture = try TimeFixture()
        let task = try fixture.makeTask("Client work")
        let original = try fixture.time.addManual(
            item: task,
            description: "review",
            startedAt: fixture.now.addingTimeInterval(-3_600),
            endedAt: fixture.now,
            tagSlugs: ["client"],
            isBillable: true
        )

        let resumed = try fixture.time.resume(original)

        #expect(resumed.isBillable)
        #expect(resumed.item?.id == task.id)
        #expect(resumed.tagSlugs == ["client"])
    }

    @Test("Discarding a running timer keeps no time and leaves nothing running")
    func discardRunningKeepsNothing() throws {
        let fixture = try TimeFixture()
        _ = try fixture.time.start(item: nil, description: "Started by mistake", tagSlugs: [])

        let discarded = try #require(try fixture.time.discardRunning())

        #expect(try fixture.time.runningEntry() == nil)
        #expect(discarded.isDeleted)

        let window = fixture.now.addingTimeInterval(-86_400)..<fixture.now.addingTimeInterval(86_400)
        #expect(try fixture.time.entries(in: window, limit: nil).isEmpty)
    }

    @Test("A discarded timer restored from the trash does not come back running")
    func restoringADiscardedTimerIsSafe() throws {
        // A soft-deleted entry with no end is still `endedAt == nil`, so restoring it would
        // resurrect a second running timer. Discarding closes it as well as deleting it.
        let fixture = try TimeFixture()
        _ = try fixture.time.start(item: nil, description: "Started by mistake", tagSlugs: [])
        let discarded = try #require(try fixture.time.discardRunning())

        _ = try fixture.time.start(item: nil, description: "The real work", tagSlugs: [])
        try fixture.time.restore(discarded)

        #expect(try fixture.time.reconcileConcurrentTimers() == 0)
        #expect(try fixture.time.runningEntry()?.entryDescription == "The real work")
    }

    @Test("Discarding with nothing running is harmless")
    func discardWithNothingRunning() throws {
        let fixture = try TimeFixture()
        #expect(try fixture.time.discardRunning() == nil)
    }
}
