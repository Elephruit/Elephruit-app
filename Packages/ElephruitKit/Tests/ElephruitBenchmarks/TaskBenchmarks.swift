import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The Tasks module's timing target: assembling a system view over a large library.
///
/// ### The design decision this exists to check
/// `TaskViewService` does **one fetch and then Swift**. None of the scheduling rules translate to
/// SQL — they compare against today in the user's calendar, read a commitment made on an earlier day,
/// and consult a lifecycle derived from four columns and a traversal — so the predicate carries kind
/// and status and the rules run over what comes back.
///
/// The cost of that is real and is exactly what this measures: Today evaluates every open task. If
/// the linear pass is the wrong shape, this is where it shows, and the escalation path is the derived
/// index in ADR 0004 rather than a bigger predicate.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`.
@MainActor
@Suite("Tasks benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct TaskBenchmarks {
    private static var scale: String {
        ProcessInfo.processInfo.environment["ELEPHRUIT_BENCHMARK_SCALE"] ?? "reduced"
    }

    /// How many tasks to build.
    ///
    /// **5,000 is the default.** A person with five thousand open tasks has a problem this app cannot
    /// solve, so it is already past any realistic library and comfortably into the region where a
    /// linear pass would show. `full` doubles it for when a number is wanted rather than a pass or
    /// fail; nothing above that is offered, because a tier nobody waits for is a tier nobody runs.
    private static var taskCount: Int {
        switch scale {
        case "full": 10_000
        default: 5_000
        }
    }

    /// A library with the shape a real one has: mostly undated, some scheduled, some overdue, a
    /// tenth parked, a twentieth waiting.
    ///
    /// The mix matters. A corpus of five thousand identical tasks would measure the fetch and nothing
    /// else; the branches in `todaySection` only run when the states that reach them exist.
    private func makeLibrary() throws -> (fixture: StoreFixture, views: TaskViewService) {
        let fixture = try StoreFixture()
        let tasks = TaskService(
            items: fixture.items,
            context: fixture.context,
            dateProvider: fixture.dateProvider
        )
        let views = TaskViewService(
            items: fixture.items,
            context: fixture.context,
            dateProvider: fixture.dateProvider
        )

        let projects = try (0..<40).map { index in
            try fixture.items.create(ItemDraft(kind: .project, title: "Project \(index)"))
        }

        for index in 0..<Self.taskCount {
            let task = try fixture.items.create(
                ItemDraft(
                    kind: .task,
                    title: "Task \(index)",
                    parentID: projects[index % projects.count].id
                )
            )

            switch index % 20 {
            case 0: try tasks.setDeadline(fixture.dateProvider.startOfDay(daysFromToday: -3), on: task)
            case 1: try tasks.commitToToday(task)
            case 2: try tasks.setStartDate(fixture.dateProvider.startOfDay(daysFromToday: 30), on: task)
            case 3: try tasks.setDeadline(fixture.dateProvider.startOfDay(daysFromToday: 5), on: task)
            case 4: try tasks.setSomeday(true, on: task)
            case 5: try tasks.markWaiting(task, on: nil)
            case 6: try tasks.setFlagged(true, on: task)
            default: break
            }
        }

        return (fixture, views)
    }

    /// The four system views, measured against **one** library.
    ///
    /// ### Why they share a test rather than having one each
    /// Building the fixture costs far more than measuring it: `ItemRepository.create` validates,
    /// refreshes the derived columns, and saves on every row, so five thousand tasks is five thousand
    /// store commits. Four tests meant four builds, and the suite stopped being something anybody
    /// would wait for — which is the same objection `PhaseCBenchmarks` records against its own
    /// 200,000 tier, and the reason that tier was removed rather than demoted.
    ///
    /// One library, four measurements, each reported and asserted separately. Nothing is lost: the
    /// views do not mutate, so measuring them in sequence measures the same thing four times as
    /// measuring them apart would.
    ///
    /// ### What running this actually found, and what the budgets therefore mean
    /// At 5,000 open tasks: the bare fetch is **222 ms**, and all four views land between **320 and
    /// 337 ms** — within 5% of each other despite doing very different amounts of work afterwards.
    /// Today evaluates a scheduling rule per row; the smart list here evaluates two trivial
    /// predicates; Anytime additionally walks up the tree per row to find its container. If the
    /// rules dominated, those three would differ by a lot. They do not.
    ///
    /// So the shape is: **roughly two-thirds materialising rows, one-third rules** — about 20 µs a
    /// task for everything the scheduling model does, including the traversals `taskFacts()` makes.
    /// That is the price of the one-fetch-then-Swift design, stated rather than assumed.
    ///
    /// The budgets are set from that measurement with headroom. The first version of this file
    /// carried 120 ms, invented before anything had been run, and it was wrong by a factor of three
    /// — a budget nobody has measured against is a number, not a target.
    ///
    /// **This is not a realistic library.** Five thousand *open* tasks is a situation no task manager
    /// fixes. At a few hundred — which is a heavy real user — the same path is tens of milliseconds.
    /// The escalation path if that ever stops being true is the derived index in ADR 0004, not a
    /// bigger predicate: none of these rules translates to SQL.
    @Test("The system views over a large library")
    func systemViews() throws {
        let (fixture, views) = try makeLibrary()

        // The floor: what it costs to bring the rows into memory, before any rule runs.
        var query = ItemQuery()
        query.kinds = [.task]
        query.statuses = [.open]
        let fetch = Benchmark.measure("tasks.fetch", budget: .milliseconds(450)) {
            _ = try? fixture.items.items(matching: query)
        }

        let today = Benchmark.measure("tasks.today", budget: .milliseconds(450)) {
            _ = try? views.today()
        }

        // Anytime is the widest: it evaluates availability for every open task and then groups by
        // container, which is a second walk up the tree per row.
        let anytime = Benchmark.measure("tasks.anytime", budget: .milliseconds(500)) {
            _ = try? views.anytime()
        }

        let upcoming = Benchmark.measure("tasks.upcoming", budget: .milliseconds(500)) {
            _ = try? views.upcoming()
        }

        let filter = TaskFilter(match: .all, rules: [.flagged(true), .hasDeadline(false)])
        let smartList = Benchmark.measure("tasks.smartList", budget: .milliseconds(450)) {
            _ = try? views.tasks(matching: filter)
        }

        // What the workspace actually asks for on arrival: the grouping and the flat list together.
        // It used to ask for them separately, which fetched every open task twice and ran the rules
        // over all of it twice — so this must stay close to `tasks.today`, not to twice it.
        let contents = Benchmark.measure("tasks.contents.today", budget: .milliseconds(500)) {
            _ = try? views.contents(of: .today)
        }

        for measurement in [fetch, today, anytime, upcoming, smartList, contents] {
            print(measurement.report)
            #expect(measurement.passes, "\(measurement.report)")
        }

        // The whole point of `contents(of:)`. Two calls would be two fetches and two rule passes;
        // one call is one of each plus a dictionary. Anything approaching `today + fetch` means the
        // second traversal has crept back in.
        #expect(
            contents.rawSeconds < today.rawSeconds + fetch.rawSeconds,
            "Arriving in Tasks is traversing the library twice again — \(contents.report)"
        )

        // The shape above, asserted rather than left in a comment. Today currently costs about 1.5×
        // its own fetch; 2× is the line at which the rules would have started to dominate, and
        // crossing it is the signal that something has become quadratic or has started faulting in a
        // relationship per row.
        #expect(
            today.rawSeconds < fetch.rawSeconds * 2,
            "The rules should stay small beside the fetch — \(today.report) vs \(fetch.report)"
        )
    }

    @Test("Deeply nested subtasks do not make the container walk quadratic")
    func deepNesting() throws {
        let fixture = try StoreFixture()
        let views = TaskViewService(
            items: fixture.items,
            context: fixture.context,
            dateProvider: fixture.dateProvider
        )

        // `enclosingContainers` and `ancestors` are both bounded at 32 and 64 respectively, so a
        // pathological chain cannot hang the interface. This checks that the bound is doing its job
        // rather than merely existing.
        var parent = try fixture.items.create(ItemDraft(kind: .project, title: "Deep"))
        for index in 0..<200 {
            parent = try fixture.items.create(
                ItemDraft(kind: .task, title: "Level \(index)", parentID: parent.id)
            )
        }

        let measurement = Benchmark.measure("tasks.deepNesting", budget: .milliseconds(80)) {
            _ = try? views.anytime()
        }
        print(measurement.report)
        #expect(measurement.passes, "\(measurement.report)")
    }
}

/// A store fixture, duplicated here because the benchmark target cannot import the persistence test
/// target. Small enough that sharing it would mean a fourth target to hold one struct.
@MainActor
private struct StoreFixture {
    let stack: PersistenceStack
    let context: ModelContext
    let items: SwiftDataItemRepository
    let tags: SwiftDataTagRepository
    let dateProvider: FixedDateProvider

    init() throws {
        stack = try PersistenceStack.inMemory()
        context = ModelContext(stack.container)
        dateProvider = .reference
        tags = SwiftDataTagRepository(context: context, dateProvider: dateProvider)
        items = SwiftDataItemRepository(context: context, dateProvider: dateProvider, tags: tags)
    }
}
