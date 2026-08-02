import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Creating an item must not get slower as the library grows.
///
/// ### What this guards
/// `create(_:)` once cost ~0.1 ms per *existing* item, because `nextSortOrder(parentID:)` went
/// through `ItemQuery` with `hasNoParent`/`parentID` — both post-filters — so every create fetched
/// and materialised the whole store to learn one number. Measured on this harness before the fix:
/// 12 ms at 100 items, 106 ms at 1,000, 531 ms at 5,000, 1,051 ms at 10,000. After: ~1–3 ms flat.
///
/// The budgets below are set at several times the post-fix figures, so an honest regression —
/// anything that reintroduces a per-sibling or per-item scan — fails by orders of magnitude while
/// machine noise does not fail at all. The companion *behavioural* guard is
/// `CreateOrderingTests.createFetchCountIsFixed`, which pins the number of fetches a create may
/// perform and runs in the ordinary suite on every build.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`, like every benchmark.
@MainActor
@Suite("Create-path benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct CreateItemBenchmarks {
    private static let storeSizes = [0, 100, 1_000, 5_000, 10_000]

    /// A store holding `count` top-level notes with varied titles, saved in batches.
    ///
    /// Raw inserts rather than `create(_:)`, because populating through the code under test would
    /// make setup itself quadratic — and would bake the very scan being guarded against into the
    /// fixture's runtime.
    private func makeStore(named name: String, count: Int) throws -> (PersistenceStack, ModelContext, SwiftDataItemRepository) {
        let stack = try PersistenceStack.open(mode: .onDisk(BenchmarkWorkspace.storeLocation(named: name)))
        let context = ModelContext(stack.container)
        let clock = SystemDateProvider()
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let now = Date()
        for index in 0..<count {
            let note = Item(
                kind: .note,
                title: "Seed note \(index) \(index % 97)",
                body: "Body text for seed note number \(index), holding a sentence of ordinary prose.",
                createdAt: now.addingTimeInterval(-Double(index)),
                sortOrder: Double(index) * 1_024
            )
            note.refreshSearchText()
            context.insert(note)
            if index % 1_000 == 999 { try context.save() }
        }
        try context.save()

        return (stack, context, items)
    }

    @Test("Single-item create stays flat as the store grows")
    func createScaling() throws {
        var steadyBySize: [Int: Benchmark.Measurement] = [:]

        for size in Self.storeSizes {
            let (_, _, items) = try makeStore(named: "create-scaling-\(size)", count: size)

            var draftIndex = 0
            let steady = try Benchmark.measure(
                "create.steady@\(size)", budget: .milliseconds(10), iterations: 15
            ) {
                draftIndex += 1
                try items.create(
                    ItemDraft(kind: .note, title: "Created \(size)-\(draftIndex)", body: "A created note body.")
                )
            }
            steadyBySize[size] = steady
        }

        for (size, measurement) in steadyBySize.sorted(by: { $0.key < $1.key }) {
            #expect(measurement.passes, "create at store size \(size): \(measurement.report)")
        }
    }

    @Test("Importer-style sequential creates hold their per-item cost at full size")
    func bulkSequentialCreates() throws {
        let (_, _, items) = try makeStore(named: "create-bulk", count: 10_000)

        var index = 0
        // Per-item budget over a sustained run, the shape `importMarkdownFiles` produces: one
        // repository create per document, each with its own save.
        let measurement = try Benchmark.measure(
            "create.sequential@10k", budget: .milliseconds(10), iterations: 300
        ) {
            index += 1
            try items.create(
                ItemDraft(
                    kind: .note,
                    title: "Imported note \(index)",
                    body: "Imported body \(index) with a sentence of ordinary prose."
                )
            )
        }

        #expect(measurement.passes, "\(measurement.report)")
    }
}
