import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Phase A1's timing targets, measured against a realistic corpus.
///
/// The *primary* acceptance criterion for the sidebar is behavioural — zero item fetches during a
/// render, asserted by `FetchAudit` in the ordinary test suite, which passes or fails identically on
/// any machine. These are the secondary check: they catch a change that is correct but slow.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`, so an ordinary build never runs them.
@MainActor
@Suite("Phase A1 benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct PhaseA1Benchmarks {
    /// Smaller than the 50k target so a run stays under a minute; the budgets below are scaled to it.
    /// `ELEPHRUIT_BENCHMARK_SCALE=full` uses the full corpus.
    private static var isFullScale: Bool {
        ProcessInfo.processInfo.environment["ELEPHRUIT_BENCHMARK_SCALE"] == "full"
    }

    private static var corpusSize: (notes: Int, tasks: Int, projects: Int, people: Int) {
        isFullScale ? (30_000, 20_000, 2_000, 5_000) : (3_000, 2_000, 200, 500)
    }

    private func makeStore() throws -> (PersistenceStack, ModelContext, SwiftDataItemRepository) {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        let clock = SystemDateProvider()
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
        return (stack, context, items)
    }

    @Test("Sidebar counts")
    func sidebarCounts() async throws {
        let (stack, context, _) = try makeStore()
        let size = Self.corpusSize
        try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        let counts = CountsService(container: stack.container, dateProvider: SystemDateProvider())
        await counts.refreshAndWait()

        // What a sidebar body evaluation actually does: read two integers.
        let measurement = Benchmark.measure("sidebar.render", budget: .milliseconds(5), iterations: 20) {
            _ = (counts.counts.today, counts.counts.inbox)
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Counts computation")
    func countsComputation() async throws {
        let (stack, context, _) = try makeStore()
        let size = Self.corpusSize
        try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        let counts = CountsService(container: stack.container, dateProvider: SystemDateProvider())

        // Off the main actor, so this is about throughput rather than responsiveness — but a count
        // pass that takes seconds would still make the badge visibly stale.
        let measurement = await Benchmark.measure("counts.compute", budget: .milliseconds(400), iterations: 3) {
            await counts.refreshAndWait()
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Today view load")
    func todayLoad() async throws {
        let (_, context, items) = try makeStore()
        let size = Self.corpusSize
        try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        let clock = SystemDateProvider()
        let measurement = Benchmark.measure("today.load", budget: .milliseconds(30), iterations: 5) {
            _ = try? items.items(matching: .today(using: clock))
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Wiki link resolution stays flat as the library grows")
    func linkResolution() async throws {
        let (_, context, items) = try makeStore()
        let size = Self.corpusSize
        try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        let target = Item(kind: .note, title: "A Uniquely Named Target")
        target.refreshSearchText()
        context.insert(target)

        let source = Item(kind: .note, title: "Source")
        source.refreshSearchText()
        context.insert(source)
        try context.save()

        var counter = 0
        let measurement = Benchmark.measure("link.resolve", budget: .milliseconds(20), iterations: 5) {
            counter += 1
            _ = try? items.update(source) {
                $0.body = "Reference \(counter) to [[A Uniquely Named Target]]."
            }
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Index warm streams without blocking")
    func indexWarm() async throws {
        let (stack, context, _) = try makeStore()
        let size = Self.corpusSize
        try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        let worker = SnapshotWorker(modelContainer: stack.container)
        let budget: Duration = Self.isFullScale ? .seconds(6) : .milliseconds(1_500)

        let measurement = await Benchmark.measure("index.warm", budget: budget, iterations: 1) {
            try? await worker.streamSnapshots(batchSize: 500) { _, _, _ in }
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Report the machine these figures came from")
    func reportEnvironment() {
        let current = ReferenceMachine.current(calibrationSeconds: Benchmark.hostCalibrationSeconds)

        print("""

        ── benchmark environment ──────────────────────────────────
        model        \(current.modelIdentifier)
        cores        \(current.coreCount)
        os           \(current.operatingSystem)
        calibration  \(String(format: "%.4f", current.calibrationSeconds))s
        hostFactor   \(String(format: "%.2f", Benchmark.hostFactor))
        corpus       \(Self.isFullScale ? "full" : "reduced")
        ───────────────────────────────────────────────────────────

        """)

        #expect(current.coreCount > 0)
    }
}
