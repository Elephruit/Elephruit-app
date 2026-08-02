import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Asking for one container's children must not cost the whole library.
///
/// `ItemQuery.children(of:)` is what a project's contents, a heading's tasks, and every
/// expansion in a tree ask. `parentID` and `hasNoParent` were post-filters, so each of those
/// questions fetched and materialised every active item in the store and then kept the dozen
/// that mattered — the same shape `nextSortOrder` had before 1d6b54b, measured at ~77 µs per
/// materialised row.
///
/// The budget is set at several times the store-side figure, so an honest regression — the
/// parent clause falling back to Swift — overshoots by orders of magnitude while machine noise
/// never fails at all.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`, like every benchmark.
@MainActor
@Suite("Children-query benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct ChildrenQueryBenchmarks {
    private static let storeSizes = [100, 1_000, 5_000, 10_000]
    private static let childCount = 20

    /// A store of `count` top-level notes plus one project holding ``childCount`` tasks.
    private func makeStore(named name: String, count: Int) throws -> (PersistenceStack, SwiftDataItemRepository, UUID) {
        let stack = try PersistenceStack.open(mode: .onDisk(BenchmarkWorkspace.storeLocation(named: name)))
        let context = ModelContext(stack.container)
        let clock = SystemDateProvider()
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let now = Date()
        for index in 0..<count {
            let note = Item(
                kind: .note,
                title: "Seed note \(index)",
                body: "Body text for seed note number \(index).",
                createdAt: now.addingTimeInterval(-Double(index)),
                sortOrder: Double(index) * 1_024
            )
            note.refreshSearchText()
            context.insert(note)
            if index % 1_000 == 999 { try context.save() }
        }

        let project = Item(kind: .project, title: "The project", createdAt: now, status: .open)
        project.refreshSearchText()
        context.insert(project)

        for index in 0..<Self.childCount {
            let task = Item(
                kind: .task,
                title: "Child \(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                status: .open,
                sortOrder: Double(index) * 1_024
            )
            task.parent = project
            task.refreshSearchText()
            context.insert(task)
        }
        try context.save()

        return (stack, items, project.id)
    }

    @Test("A container's children cost the children, not the library")
    func childrenScaling() throws {
        for size in Self.storeSizes {
            let (_, items, projectID) = try makeStore(named: "children-\(size)", count: size)

            let measurement = try Benchmark.measure(
                "children@\(size)", budget: .milliseconds(10), iterations: 10
            ) {
                let rows = try items.items(matching: .children(of: projectID))
                precondition(rows.count == Self.childCount)
            }

            #expect(measurement.passes, "children at store size \(size): \(measurement.report)")
        }
    }

    @Test("A tag page and the Inbox cost their rows, not the library")
    func taggedAndInboxScaling() throws {
        // 5,000 filed-away notes (tagged, so out of the Inbox), 20 notes on the tag being asked
        // about, 20 loose captures. Both questions used to fetch all 5,040 rows.
        let stack = try PersistenceStack.open(mode: .onDisk(BenchmarkWorkspace.storeLocation(named: "tag-inbox")))
        let context = ModelContext(stack.container)
        let clock = SystemDateProvider()
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let seedTag = ElephruitModel.Tag(name: "seed")
        let specialTag = ElephruitModel.Tag(name: "special")
        context.insert(seedTag)
        context.insert(specialTag)

        let now = Date()
        for index in 0..<5_000 {
            let note = Item(kind: .note, title: "Filed note \(index)", createdAt: now.addingTimeInterval(-Double(index)))
            note.tags = [seedTag]
            note.refreshSearchText()
            context.insert(note)
            if index % 1_000 == 999 { try context.save() }
        }
        for index in 0..<20 {
            let special = Item(kind: .note, title: "Special \(index)", createdAt: now)
            special.tags = [specialTag]
            special.refreshSearchText()
            context.insert(special)

            let capture = Item(kind: .note, title: "Capture \(index)", createdAt: now)
            capture.refreshSearchText()
            context.insert(capture)
        }
        try context.save()

        let tagged = try Benchmark.measure("tagPage@5000", budget: .milliseconds(10), iterations: 10) {
            let rows = try items.items(matching: .tag(slug: "special"))
            precondition(rows.count == 20)
        }
        #expect(tagged.passes, "\(tagged.report)")

        let inbox = try Benchmark.measure("inbox@5000", budget: .milliseconds(10), iterations: 10) {
            let rows = try items.items(matching: .inbox())
            precondition(rows.count == 20)
        }
        #expect(inbox.passes, "\(inbox.report)")
    }

    @Test("Top-level rows cost the top level, not the trash and the archive")
    func topLevelScaling() throws {
        // `hasNoParent` matches almost everything in this store, so the point here is not row
        // count but shape: the store must do the filtering, and the budget reflects one fetch of
        // the matching rows rather than fetch-everything-then-discard.
        let (_, items, _) = try makeStore(named: "children-toplevel", count: 1_000)

        var query = ItemQuery()
        query.hasNoParent = true
        query.kinds = [.project]

        let measurement = try Benchmark.measure(
            "topLevelProjects@1000", budget: .milliseconds(10), iterations: 10
        ) {
            let rows = try items.items(matching: query)
            precondition(rows.count == 1)
        }

        #expect(measurement.passes, "\(measurement.report)")
    }
}
