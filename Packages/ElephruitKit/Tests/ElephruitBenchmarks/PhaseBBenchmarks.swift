import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import Foundation
import SwiftData
import Testing

/// Phase B's timing targets.
///
/// ### What these do and do not measure
/// Every figure here is **keystroke to results returned**, not keystroke to results *painted*. The
/// painting cannot be timed without a window, so it is covered a different way: the behavioural
/// criterion in `SearchCostTests` proves a result list is built without touching SwiftData at all,
/// which is what bounds the render. Timing what can be timed and asserting the rest behaviourally is
/// more honest than a number that quietly excludes half of what it claims to cover.
///
/// Budgets are stated at p95, because a median says nothing about whether typing feels smooth.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`.
@MainActor
@Suite("Phase B benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct PhaseBBenchmarks {
    private static var scale: String {
        ProcessInfo.processInfo.environment["ELEPHRUIT_BENCHMARK_SCALE"] ?? "reduced"
    }

    /// Three sizes. `reduced` keeps an ordinary run short; `full` is the 50k the budgets are written
    /// against; `huge` is the 200k figure, which takes minutes to build and is opted into by name.
    private static var corpusSize: (notes: Int, tasks: Int, projects: Int, people: Int) {
        switch scale {
        // Exactly the sizes the published criteria name — 50,000 and 200,000 — so a result can be
        // read against the budget directly rather than extrapolated in a report.
        case "huge": (130_000, 60_000, 4_000, 6_000)
        case "full": (26_000, 18_000, 2_000, 4_000)
        default: (3_000, 2_000, 200, 500)
        }
    }

    /// Budgets scale with the corpus, so the reduced run still means something.
    ///
    /// The published figures are 40 ms at 50k and 80 ms at 200k. The reduced corpus is roughly a
    /// tenth of the first, and search cost grows with the *matched set* rather than the library, so
    /// the budget is tightened rather than left slack — a reduced run that passes a 50k budget would
    /// prove nothing.
    private static var keystrokeBudget: Duration {
        switch scale {
        case "huge": .milliseconds(80)
        case "full": .milliseconds(40)
        default: .milliseconds(20)
        }
    }

    private static var rebuildBudget: Duration {
        switch scale {
        case "huge": .seconds(24)
        case "full": .seconds(6)
        default: .milliseconds(1_200)
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let stack: PersistenceStack
        let context: ModelContext
        let items: SwiftDataItemRepository
        let indexURL: URL
        let engine: FTSSearchEngine
        let itemCount: Int
    }

    private func makeFixture() throws -> Fixture {
        let stack = try PersistenceStack.inMemory()
        let context = ModelContext(stack.container)
        let clock = SystemDateProvider()
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let size = Self.corpusSize
        let count = try CorpusGenerator().populate(
            context: context, notes: size.notes, tasks: size.tasks,
            projects: size.projects, people: size.people
        )

        // Inside the workspace, which is wiped once per process. These files run to hundreds of
        // megabytes at the full corpus, and there used to be one per fixture with nothing deleting
        // any of them.
        let indexURL = BenchmarkWorkspace.indexURL(named: "search-\(UUID().uuidString)")

        return Fixture(
            stack: stack,
            context: context,
            items: items,
            indexURL: indexURL,
            engine: FTSSearchEngine(
                items: items,
                indexURL: indexURL,
                dateProvider: clock,
                container: stack.container
            ),
            itemCount: count
        )
    }

    /// Prefixes of real words from the corpus vocabulary, in the order someone would type them.
    ///
    /// Typing a word one letter at a time is the actual workload: the expensive query is not the
    /// finished word but the two- and three-letter prefixes on the way to it, which match a large
    /// slice of the library.
    private static func keystrokeSequences() -> [String] {
        let words = [
            "launch", "migration", "pricing", "quarter", "invoice", "reporting",
            "positioning", "customer", "rollback", "catering", "announcement", "instance",
        ]
        return words.flatMap { word -> [String] in
            (2...word.count).map { String(word.prefix($0)) }
        }
    }

    // MARK: - Interactive latency

    @Test("Keystroke to results")
    func keystrokeLatency() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        let measurement = await Benchmark.measurePercentile(
            "search.keystroke",
            budget: Self.keystrokeBudget,
            inputs: Self.keystrokeSequences()
        ) { text in
            _ = try? await fixture.engine.search(SearchQueryParser.parse(text), limit: 200)
        }

        print("  └ corpus \(fixture.itemCount) items · scale \(Self.scale)")
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Keystroke to results with structural filters")
    func filteredKeystrokeLatency() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        // The shape that used to be worst: words *and* filters. In the old engine the filters ran
        // after every match had been materialised, so this was the slowest thing search could do.
        let inputs = Self.keystrokeSequences().map { "\($0) type:task is:open" }

        let measurement = await Benchmark.measurePercentile(
            "search.keystroke.filtered",
            budget: Self.keystrokeBudget,
            inputs: inputs
        ) { text in
            _ = try? await fixture.engine.search(SearchQueryParser.parse(text), limit: 200)
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("A structural query with no words at all")
    func structuralOnlyLatency() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        let inputs = [
            "is:open type:task", "is:overdue", "type:note is:untagged",
            "due:<7d", "is:favorite", "type:project is:open",
        ]

        let measurement = await Benchmark.measurePercentile(
            "search.structural",
            budget: Self.keystrokeBudget,
            inputs: inputs
        ) { text in
            _ = try? await fixture.engine.search(SearchQueryParser.parse(text), limit: 200)
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    // MARK: - Index lifecycle

    @Test("Cold open of an index that already exists")
    func coldOpen() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        // A second engine over the same file, as the next launch does. The point of the index being
        // on disk is that this costs nothing like a rebuild.
        let measurement = await Benchmark.measure("search.coldOpen", budget: .milliseconds(150), iterations: 5) {
            let relaunched = FTSSearchEngine(
                items: fixture.items,
                indexURL: fixture.indexURL,
                dateProvider: SystemDateProvider(),
                container: fixture.stack.container
            )
            await relaunched.openIndex()
        }

        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Full rebuild")
    func fullRebuild() async throws {
        let fixture = try makeFixture()

        // Three, not one. A rebuild is slow enough that a single sample is tempting, but the figure
        // lands close enough to its budget that run-to-run variance decides the result — which makes
        // the test a coin toss rather than a measurement. The median of three is worth the extra
        // half-minute on a benchmark nobody runs by accident.
        let measurement = await Benchmark.measure(
            "search.rebuild",
            budget: Self.rebuildBudget,
            iterations: 3
        ) {
            await fixture.engine.invalidateIndex()
            await fixture.engine.waitForIndexing()
        }

        let indexed = await fixture.engine.indexStatistics().items
        print("  └ indexed \(indexed) of \(fixture.itemCount) items")
        #expect(indexed == fixture.itemCount, "A rebuild must index everything, not most of it")
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Search stays responsive while the index rebuilds")
    func searchDuringRebuild() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        // Start a rebuild and keep typing through it. The budget is deliberately the same: a
        // background rebuild that makes the search field stutter has failed at its one job.
        await fixture.engine.invalidateIndex()

        let measurement = await Benchmark.measurePercentile(
            "search.duringRebuild",
            budget: Self.keystrokeBudget,
            inputs: Self.keystrokeSequences()
        ) { text in
            _ = try? await fixture.engine.search(SearchQueryParser.parse(text), limit: 200)
        }

        await fixture.engine.waitForIndexing()
        #expect(measurement.passes, "\(measurement.report)")
    }

    // MARK: - Incremental cost

    @Test("Saving an item costs one small write, not a rebuild")
    func incrementalUpdateCost() async throws {
        let fixture = try makeFixture()
        await fixture.engine.warmIndex()

        let subject = try #require(try fixture.items.items(matching: .kind(.note)).first)

        let measurement = await Benchmark.measure(
            "search.incrementalUpdate",
            budget: .milliseconds(10),
            iterations: 20
        ) {
            await fixture.engine.indexDidChange(for: subject)
        }

        #expect(measurement.passes, "\(measurement.report)")
    }
}
