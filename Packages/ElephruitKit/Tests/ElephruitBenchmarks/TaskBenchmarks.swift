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
    private func makeLibrary() throws -> (StoreFixture, TaskViewService) {
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

    @Test("Today over a large library")
    func today() throws {
        let (_, views) = try makeLibrary()

        let measurement = Benchmark.measure("tasks.today", budget: .milliseconds(120)) {
            _ = try? views.today()
        }
        print(measurement.report)
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("Anytime over a large library")
    func anytime() throws {
        let (_, views) = try makeLibrary()

        // Anytime is the widest of them: it evaluates availability for every open task and then
        // groups by container, which is a second walk up the tree per row.
        let measurement = Benchmark.measure("tasks.anytime", budget: .milliseconds(200)) {
            _ = try? views.anytime()
        }
        print(measurement.report)
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("The upcoming agenda over a large library")
    func upcoming() throws {
        let (_, views) = try makeLibrary()

        let measurement = Benchmark.measure("tasks.upcoming", budget: .milliseconds(200)) {
            _ = try? views.upcoming()
        }
        print(measurement.report)
        #expect(measurement.passes, "\(measurement.report)")
    }

    @Test("A smart list over a large library")
    func smartList() throws {
        let (_, views) = try makeLibrary()
        let filter = TaskFilter(match: .all, rules: [.flagged(true), .hasDeadline(false)])

        let measurement = Benchmark.measure("tasks.smartList", budget: .milliseconds(150)) {
            _ = try? views.tasks(matching: filter)
        }
        print(measurement.report)
        #expect(measurement.passes, "\(measurement.report)")
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

        let measurement = Benchmark.measure("tasks.deepNesting", budget: .milliseconds(60)) {
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
