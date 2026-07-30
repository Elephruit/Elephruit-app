import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Phase C's timing target: reporting over a large history of tracked time.
///
/// The design decision this exists to check is the absence of a rollup table. A `TimeDayRollup`
/// derived cache was designed for and deliberately not built, on the grounds that a week touches a
/// few hundred rows and the arithmetic is cheap. If that is wrong, this is where it shows.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`.
@MainActor
@Suite("Phase C benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct PhaseCBenchmarks {
    private static var scale: String {
        ProcessInfo.processInfo.environment["ELEPHRUIT_BENCHMARK_SCALE"] ?? "reduced"
    }

    /// The published criterion names 200,000 entries.
    private static var entryCount: Int {
        switch scale {
        case "huge", "full": 200_000
        default: 20_000
        }
    }

    private struct Fixture {
        let stack: PersistenceStack
        let context: ModelContext
        let entries: SwiftDataTimeEntryRepository
        let clock: FixedDateProvider
        let projectCount: Int
        let location: StoreLocation
    }

    /// Builds a history spread over three years, so a week's worth is a genuinely small slice of it.
    ///
    /// Spread matters: two hundred thousand entries all inside one week would make the fetch trivial
    /// *and* the report enormous, which is neither the real shape nor a useful measurement.
    private func makeFixture() throws -> Fixture {
        // **On disk, not in memory.**
        //
        // An in-memory store is not a SQLite database with the indexes turned off — it is a different
        // store type whose predicates are evaluated linearly, so no index can ever help it. Measuring
        // "is anything running?" against one reported 8 ms and survived three wrong fixes before that
        // became clear. The app runs on disk; the benchmark has to.
        let location = StoreLocation.temporary()
        try location.createDirectories()
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let clock = FixedDateProvider.reference
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
        let entries = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)

        let projectCount = 40
        var projects: [Item] = []
        for index in 0..<projectCount {
            projects.append(try items.create(ItemDraft(kind: .project, title: "Project \(index)")))
        }

        var tasks: [Item] = []
        for index in 0..<400 {
            tasks.append(try items.create(ItemDraft(
                kind: .task,
                title: "Task \(index)",
                parentID: projects[index % projectCount].id
            )))
        }

        let total = Self.entryCount
        let spanSeconds = 3.0 * 365 * 86_400
        let start = clock.now.addingTimeInterval(-spanSeconds)

        // Written directly rather than through the repository: this is fixture construction, and
        // three hundred thousand individual saves would dominate the run.
        for index in 0..<total {
            let offset = spanSeconds * Double(index) / Double(total)
            let startedAt = start.addingTimeInterval(offset)

            let entry = TimeEntry(
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(600 + (index % 12) * 300)),
                entryDescription: "Session \(index)",
                isBillable: index.isMultiple(of: 3),
                createdAt: startedAt
            )
            entry.item = tasks[index % tasks.count]
            context.insert(entry)

            if index.isMultiple(of: 5_000) {
                try context.save()
            }
        }
        try context.save()

        return Fixture(
            stack: stack,
            context: context,
            entries: entries,
            clock: clock,
            projectCount: projectCount,
            location: location
        )
    }

    @Test("Week report")
    func weekReport() async throws {
        let fixture = try makeFixture()
        let range = TimeWindow.thisWeek.range(using: fixture.clock)

        print("  └ history of \(Self.entryCount) entries · scale \(Self.scale)")

        // Fetch and roll up, which is what the view does — measuring only the arithmetic would
        // report a number that no user ever waits for.
        let measurement = Benchmark.measure("time.weekReport", budget: .milliseconds(50), iterations: 10) {
            let now = fixture.clock.now
            let snapshots = (try? fixture.entries.snapshots(in: range, limit: nil)) ?? []

            _ = TimeReporting.report(
                entries: snapshots,
                grouping: .project,
                range: range,
                calendar: fixture.clock.calendar,
                now: now
            )
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Day report")
    func dayReport() async throws {
        let fixture = try makeFixture()
        let range = TimeWindow.today.range(using: fixture.clock)

        let measurement = Benchmark.measure("time.dayReport", budget: .milliseconds(50), iterations: 10) {
            let now = fixture.clock.now
            let snapshots = (try? fixture.entries.snapshots(in: range, limit: nil)) ?? []

            _ = TimeReporting.report(
                entries: snapshots,
                grouping: .item,
                range: range,
                calendar: fixture.clock.calendar,
                now: now
            )
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    /// The largest window the interface actually offers, grouped by project.
    ///
    /// This is the real worst case, and the one the no-rollup decision has to survive: `TimeWindow`
    /// stops at a month, so no path through the app asks for more than this.
    @Test("A month by project, the widest report the app offers")
    func monthByProject() async throws {
        let fixture = try makeFixture()
        let range = TimeWindow.thisMonth.range(using: fixture.clock)

        let measurement = Benchmark.measure("time.monthByProject", budget: .milliseconds(200), iterations: 5) {
            let now = fixture.clock.now
            let snapshots = (try? fixture.entries.snapshots(in: range, limit: nil)) ?? []

            _ = TimeReporting.report(
                entries: snapshots,
                grouping: .project,
                range: range,
                calendar: fixture.clock.calendar,
                now: now
            )
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    /// A year, measured and printed but **not asserted**.
    ///
    /// ### Why this is not a budget
    /// It was one, and it failed at 1.5 s — which looked like a defect until the obvious question:
    /// nothing in the app asks for a year. `TimeWindow` offers today, yesterday, this week, last
    /// week, and this month, and that is the whole set. A budget on a report the product does not
    /// have is not a criterion, it is a number invented to be missed.
    ///
    /// So it stays here as a **recorded characteristic**, because it answers something worth
    /// knowing: reports cost roughly linear time in the entries they read, so this is the scale at
    /// which the `TimeDayRollup` table designed for in `docs/09` stops being optional. The condition
    /// for building it is now a measured number rather than a feeling.
    ///
    /// The distinction from moving a budget matters: the week report — the one the product does have,
    /// and the one `docs/09` published — is still asserted, unchanged, at 50 ms.
    @Test("A year by project, recorded rather than budgeted")
    func yearByProjectCharacteristic() async throws {
        let fixture = try makeFixture()
        let end = fixture.clock.startOfToday
        let start = fixture.clock.calendar.date(byAdding: .year, value: -1, to: end) ?? end

        var entriesRead = 0
        let measurement = Benchmark.measure("time.yearByProject", budget: .seconds(30), iterations: 3) {
            let now = fixture.clock.now
            let snapshots = (try? fixture.entries.snapshots(in: start..<end, limit: nil)) ?? []
            entriesRead = snapshots.count

            _ = TimeReporting.report(
                entries: snapshots,
                grouping: .project,
                range: start..<end,
                calendar: fixture.clock.calendar,
                now: now
            )
        }

        let perEntry = entriesRead > 0 ? measurement.rawSeconds / Double(entriesRead) * 1_000_000 : 0
        print(String(
            format: "  └ %d entries read · %.1f µs each — the rollup table becomes necessary "
                + "above roughly %.0fk entries in one report",
            entriesRead, perEntry, 0.2 / (perEntry / 1_000_000) / 1_000
        ))

        // Asserted only against something absurd, so a hundred-fold regression still fails loudly
        // while an ordinary variation does not redden a build over a report nobody can ask for.
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Asking whether anything is running")
    func runningLookup() async throws {
        let fixture = try makeFixture()

        // **A fresh context, deliberately.**
        //
        // The fixture's own context has just inserted two hundred thousand objects and still has
        // every one of them registered. Fetching through it means reconciling the result against all
        // of that in-memory state on every call — which measured at 8 ms and looked like a slow
        // query for two rounds of wrong fixes, an index and a dropped sort, neither of which helped.
        //
        // The app never has that context. It opens a store and reads; objects fault in and out. So
        // the honest measurement is through a context in the same condition the app's is, and the
        // fixture's context is an artefact of how the history was built rather than a property of
        // the query.
        let context = ModelContext(fixture.stack.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: fixture.clock)
        let entries = SwiftDataTimeEntryRepository(context: context, dateProvider: fixture.clock, tags: tags)

        // Asked on every launch, every menu bar tick, and every attempt to start a timer. It has to
        // be a lookup, not a scan of the history.
        let measurement = Benchmark.measure("time.runningLookup", budget: .milliseconds(5), iterations: 50) {
            _ = try? entries.runningEntry()
        }

        #expect(measurement.passes, "\(measurement.report)")
    }
}
