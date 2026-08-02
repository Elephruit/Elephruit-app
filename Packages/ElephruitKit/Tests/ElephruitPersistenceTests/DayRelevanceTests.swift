import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The day-relevance projection: the derived floor that lets Today fetch a window instead of the
/// whole open library.
///
/// The invariant every test here defends is directional: a wrong key may only ever *over-fetch*.
/// The rules still decide what a day shows; the key only decides what is brought into memory for
/// them to look at, so the one unforgivable failure is a row the fetch hides that a rule would
/// have accepted.
@MainActor
@Suite("Day relevance")
struct DayRelevanceTests {
    private static var clock: FixedDateProvider { .reference }

    // MARK: - The projection

    @Test("The key is the earliest date any route holds")
    func keyIsTheEarliestRoute() {
        let sooner = Self.clock.startOfDay(daysFromToday: 2)
        let later = Self.clock.startOfDay(daysFromToday: 9)

        let key = Item.projectedDayRelevance(
            dueAt: later,
            startAt: nil,
            deferUntil: nil,
            todayCommittedOn: nil,
            reminderAt: sooner,
            followUpAt: nil,
            isSomeday: false
        )
        #expect(key == sooner)
    }

    @Test("No route means no window ever matches")
    func undatedWorkNeverMatches() {
        let key = Item.projectedDayRelevance(
            dueAt: nil, startAt: nil, deferUntil: nil,
            todayCommittedOn: nil, reminderAt: nil, followUpAt: nil,
            isSomeday: false
        )
        #expect(key == .distantFuture)
    }

    @Test("Someday work is parked whatever dates it carries")
    func somedayIsParked() {
        let key = Item.projectedDayRelevance(
            dueAt: Self.clock.startOfToday, startAt: nil, deferUntil: nil,
            todayCommittedOn: nil, reminderAt: nil, followUpAt: nil,
            isSomeday: true
        )
        #expect(key == .distantFuture)
    }

    @Test("A legacy defer date still counts as a route")
    func legacyDeferDatesParticipate() {
        // `deferUntil` predates the scheduling model and nothing writes it any more, but a library
        // that has not run `TaskDateMigration` still reads availability through it — see
        // `Item.availableFrom`. Dropping it from the projection would hide exactly those rows.
        let deferred = Self.clock.startOfDay(daysFromToday: 3)
        let key = Item.projectedDayRelevance(
            dueAt: nil, startAt: nil, deferUntil: deferred,
            todayCommittedOn: nil, reminderAt: nil, followUpAt: nil,
            isSomeday: false
        )
        #expect(key == deferred)
    }

    // MARK: - Maintenance on the write paths

    @Test("Every write path keeps the key current")
    func writesRefreshTheKey() throws {
        let fixture = try StoreFixture()
        let due = Self.clock.startOfDay(daysFromToday: 5)

        let task = try fixture.makeTask(title: "Dated", dueAt: due)
        #expect(task.dayRelevanceKey == due)

        let sooner = Self.clock.startOfDay(daysFromToday: 1)
        try fixture.items.update(task) { $0.reminderAt = sooner }
        #expect(task.dayRelevanceKey == sooner)

        try fixture.items.update(task) {
            $0.reminderAt = nil
            $0.dueAt = nil
        }
        #expect(task.dayRelevanceKey == .distantFuture)
    }

    @Test("The windowed query keeps overdue work and drops far-future work")
    func windowedQueryIsASupersetOfTheWindow() throws {
        let fixture = try StoreFixture()

        let overdue = try fixture.makeTask(
            title: "Overdue", dueAt: Self.clock.startOfDay(daysFromToday: -30)
        )
        let inWindow = try fixture.makeTask(
            title: "This week", dueAt: Self.clock.startOfDay(daysFromToday: 3)
        )
        let farFuture = try fixture.makeTask(
            title: "Next quarter", dueAt: Self.clock.startOfDay(daysFromToday: 60)
        )
        let undated = try fixture.makeTask(title: "Undated")

        var query = ItemQuery()
        query.kinds = [.task]
        query.statuses = [.open]
        query.dayRelevantBefore = Self.clock.startOfDay(daysFromToday: 5)

        let fetched = Set(try fixture.items.items(matching: query).map(\.id))
        #expect(fetched.contains(overdue.id), "overdue collapses onto today, so today's window needs it")
        #expect(fetched.contains(inWindow.id))
        #expect(!fetched.contains(farFuture.id))
        #expect(!fetched.contains(undated.id))
    }

    // MARK: - Rows from before the column existed

    @Test("A stale key over-fetches rather than hiding work, and the backfill converges it")
    func sentinelRowsFailSafe() throws {
        let fixture = try StoreFixture()
        let due = Self.clock.startOfDay(daysFromToday: 40)

        let task = try fixture.makeTask(title: "Written by an older build", dueAt: due)
        let stamped = task.updatedAt

        // Reset the derived column the way a pre-column store arrives: sentinel everywhere.
        task.dayRelevanceKey = .distantPast
        try fixture.context.save()

        // The sentinel matches every window — over-fetched, never hidden.
        var narrow = ItemQuery()
        narrow.kinds = [.task]
        narrow.statuses = [.open]
        narrow.dayRelevantBefore = Self.clock.startOfDay(daysFromToday: 1)
        #expect(try fixture.items.items(matching: narrow).map(\.id) == [task.id])

        // One pass computes the real key without stamping `updatedAt` — this is a derived column
        // catching up, not an edit, and the reminder sync must not read it as one.
        #expect(try DayRelevanceBackfill.apply(in: fixture.context) == 1)
        #expect(task.dayRelevanceKey == due)
        #expect(task.updatedAt == stamped)
        #expect(try fixture.items.items(matching: narrow).isEmpty)

        // Converged means converged: the next pass finds nothing to do.
        #expect(try DayRelevanceBackfill.apply(in: fixture.context) == 0)
    }
}
