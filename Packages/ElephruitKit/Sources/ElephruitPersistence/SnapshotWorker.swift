import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Reads the store in batches, off the main actor.
///
/// ### The defect this replaces
/// Warming the search index used to run `items(matching: .everything()).map(\.snapshot())` on the
/// main actor — materialising every row in the library, at launch, on the thread that draws. On a
/// mature library that is a multi-second hang, and it happens exactly when the app should feel
/// fastest.
///
/// A `@ModelActor` owns its own `ModelContext`, so the work genuinely leaves the main actor, and it
/// returns ``ItemSnapshot`` values — plain structs — so no `PersistentModel` crosses an isolation
/// boundary. Batching bounds peak memory as well: the whole library is never resident at once.
@ModelActor
public actor SnapshotWorker {
    /// How many items there are, so a caller can show honest progress.
    public func itemCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Item>())
    }

    /// One batch of snapshots, ordered stably so paging cannot skip or repeat a row.
    ///
    /// Ordered by `createdAt` rather than by nothing: an unordered paged fetch is free to return the
    /// same row twice and miss another, which would leave the index quietly wrong.
    public func snapshots(offset: Int, limit: Int) throws -> [ItemSnapshot] {
        var descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor).map { $0.snapshot() }
    }

    /// Streams the whole store, one batch at a time.
    ///
    /// `handler` receives each batch as it arrives, so the index fills progressively and a search run
    /// mid-warm returns partial results rather than a false empty state.
    public func streamSnapshots(
        batchSize: Int = 500,
        handler: @Sendable ([ItemSnapshot], _ processed: Int, _ total: Int) async -> Void
    ) async throws {
        let total = try itemCount()
        var offset = 0

        while offset < total {
            try Task.checkCancellation()

            let batch = try snapshots(offset: offset, limit: batchSize)
            guard !batch.isEmpty else { break }

            offset += batch.count
            await handler(batch, offset, total)
        }
    }
}
