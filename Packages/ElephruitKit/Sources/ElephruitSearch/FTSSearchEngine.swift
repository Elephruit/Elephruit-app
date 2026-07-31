import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData

/// The search engine, backed by the FTS5 sidecar.
///
/// Replaces `DefaultSearchEngine` behind the same protocol, so not one view changed to adopt it.
///
/// ### What actually got faster, and why
/// The old engine kept an inverted index in memory, then resolved each candidate into a SwiftData
/// object and applied structural filters in Swift. Three costs followed from that: the index had to
/// be rebuilt in full at every launch, every result meant a store fetch, and a filter like
/// `is:open due:<7d` was applied *after* materialising everything the words matched.
///
/// Here the index is on disk and survives launch, filters are a `WHERE` clause, and a result row
/// carries everything it needs to draw itself — so painting a page of results touches the store
/// exactly zero times. `SearchZeroFetchTests` asserts that last claim rather than trusting it.
@MainActor
public final class FTSSearchEngine: SearchEngine {
    private let store: SearchIndexStore
    private let container: ModelContainer?
    private let dateProvider: any DateProvider

    /// The store fetch used only before the index has ever been built.
    private let items: any ItemRepository

    private var rebuildTask: Task<Void, Never>?

    /// Mirrors the actor's rebuild state so a view can read it synchronously while drawing.
    public private(set) var status: IndexStatus = .opening

    public init(
        items: any ItemRepository,
        indexURL: URL,
        dateProvider: any DateProvider,
        container: ModelContainer? = nil
    ) {
        self.items = items
        self.store = SearchIndexStore(url: indexURL)
        self.dateProvider = dateProvider
        self.container = container
    }

    // MARK: - Lifecycle

    /// Opens the index and waits until it is fully built.
    ///
    /// The waiting is for the caller's benefit, not the interface's: search is usable from the
    /// moment ``openIndex()`` returns, and the app calls this off the launch path.
    public func warmIndex() async {
        await openIndex()
        await waitForIndexing()
    }

    /// Opens the index, starting a rebuild in the background if one is needed.
    ///
    /// An index that already exists is used immediately — that is the whole reason it is on disk.
    /// Only a missing or incomplete one triggers a rebuild, and the search field stays usable
    /// throughout, answering from whatever has been indexed so far.
    public func openIndex() async {
        let signpost = Diagnostics.performance
        let state = signpost.beginInterval("openIndex")

        do {
            try await store.open()
            let isComplete = try await store.isComplete()
            let indexed = try await store.indexedCount()
            signpost.endInterval("openIndex", state)

            if isComplete {
                status = .ready(indexed: indexed)
                Diagnostics.search.info("Search index open with \(indexed, privacy: .public) entries")
            } else {
                // Either the first launch, or a rebuild that was interrupted. Whatever is already
                // in there stays queryable while the rest fills in.
                status = .building(progress: RebuildProgress(indexed: indexed, expected: 0, isRebuilding: true))
                rebuild()
            }
        } catch {
            signpost.endInterval("openIndex", state)
            status = .unavailable(reason: error.summary)
            Diagnostics.search.error("Search index unavailable: \(error.summary, privacy: .public)")
        }
    }

    /// Rebuilds the whole index from the store, in the background.
    public func rebuild() {
        guard let container else {
            Diagnostics.search.error("Rebuild skipped: no container available")
            return
        }
        guard rebuildTask == nil else { return }

        let store = self.store
        rebuildTask = Task { [weak self] in
            // Bound strongly for the duration: the rebuild has work to finish, and the batch
            // handler below is a `@Sendable` closure that cannot chain off a weak capture.
            guard let self else { return }

            let signpost = Diagnostics.performance
            let state = signpost.beginInterval("rebuildIndex")
            defer { signpost.endInterval("rebuildIndex", state) }

            let worker = IndexWorker(modelContainer: container)

            do {
                let total = try await worker.itemCount()
                try await store.beginRebuild(expecting: total)
                status = .building(progress: RebuildProgress(indexed: 0, expected: total, isRebuilding: true))

                try await worker.stream(batchSize: 2_000) { batch, processed, expected in
                    do {
                        try await store.upsert(batch)
                        await store.recordRebuildProgress(indexed: processed)
                        self.report(.building(progress: RebuildProgress(
                            indexed: processed, expected: expected, isRebuilding: true
                        )))
                    } catch {
                        // One bad batch is not a reason to abandon the rest of the library.
                        let reason = (error as? AppError)?.summary ?? error.localizedDescription
                        Diagnostics.search.error("Index batch failed: \(reason, privacy: .public)")
                    }
                }

                try await store.finishRebuild()

                let indexed = try await store.indexedCount()
                status = .ready(indexed: indexed)
                Diagnostics.search.info("Search index rebuilt: \(indexed, privacy: .public) entries")
            } catch is CancellationError {
                await store.abandonRebuild()
            } catch {
                // Whatever landed stays usable and the index stays marked incomplete, so the next
                // launch finishes the job. A partial index is worth more than none.
                await store.abandonRebuild()
                let reason = (error as? AppError)?.summary ?? error.localizedDescription
                status = .unavailable(reason: reason)
                Diagnostics.search.error("Index rebuild failed: \(reason, privacy: .public)")
            }

            rebuildTask = nil
        }
    }

    /// Awaits an in-flight rebuild.
    ///
    /// Nothing in the interface needs this — the whole design is that search works *during* a
    /// rebuild. It exists so a test can assert against a finished index instead of racing one, and
    /// so "Rebuild Search Index" in Settings can report when it is actually done.
    public func waitForIndexing() async {
        await rebuildTask?.value
    }

    /// Publishes a status change from off the main actor.
    ///
    /// The batch handler runs wherever the worker's stream happens to be; this is the one hop back.
    private nonisolated func report(_ status: IndexStatus) {
        Task { @MainActor in self.status = status }
    }

    public func indexProgress() async -> (indexed: Int, expected: Int, isRebuilding: Bool) {
        let progress = await store.rebuildProgress
        return (progress.indexed, progress.expected, progress.isRebuilding)
    }

    /// Whether the index considers itself fully built.
    public func isComplete() async throws(AppError) -> Bool {
        try await store.isComplete()
    }

    public func indexStatistics() async -> (items: Int, terms: Int, isWarm: Bool) {
        let indexed = (try? await store.indexedCount()) ?? 0
        let complete = (try? await store.isComplete()) ?? false
        // Term count is not something FTS5 exposes cheaply, and nothing depends on it. Reporting a
        // number here would mean inventing one.
        return (indexed, 0, complete)
    }

    // MARK: - Incremental maintenance

    public func indexDidChange(for item: Item) async {
        let document = IndexDocumentBuilder.make(item)
        do {
            try await store.upsert(document)
        } catch {
            Diagnostics.search.error("Index update failed: \(error.summary, privacy: .public)")
        }
    }

    public func removeFromIndex(id: UUID) async {
        do {
            try await store.remove(id: id)
        } catch {
            Diagnostics.search.error("Index removal failed: \(error.summary, privacy: .public)")
        }
    }

    /// Discards the index entirely and rebuilds it.
    ///
    /// The recovery path for "search is showing me something wrong". Costs a rebuild and nothing
    /// else, because there is nothing here that the store does not already hold.
    public func invalidateIndex() async {
        rebuildTask?.cancel()
        rebuildTask = nil

        do {
            try await store.destroy()
            try await store.open()
            status = .building(progress: RebuildProgress(indexed: 0, expected: 0, isRebuilding: true))
            rebuild()
        } catch {
            status = .unavailable(reason: error.summary)
            Diagnostics.search.error("Index reset failed: \(error.summary, privacy: .public)")
        }
    }

    // MARK: - Searching

    public func search(_ query: SearchQuery, limit: Int = 200) async throws(AppError) -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        let signpost = Diagnostics.performance
        let state = signpost.beginInterval("search")
        defer { signpost.endInterval("search", state) }

        // No index to ask — not yet opened, or opening failed. Answer from the store instead.
        // Slower, but a slow right answer beats a fast empty one, and correctness must never
        // depend on a cache being warm.
        switch status {
        case .opening, .unavailable:
            return try storeFallback(query, limit: limit)
        case .building, .ready:
            return try await runIndexedSearch(query, limit: limit)
        }
    }

    private func runIndexedSearch(_ query: SearchQuery, limit: Int) async throws(AppError) -> [SearchResult] {
        let compiled = SearchCompiler.compile(query, limit: limit, dateProvider: dateProvider)

        let primary: [SearchResult]
        do {
            primary = try await store.query(compiled)
        } catch {
            // A broken index must not become a broken search.
            Diagnostics.search.error("Indexed search failed: \(error.summary, privacy: .public)")
            return try storeFallback(query, limit: limit)
        }

        // Tokenised search cannot match a fragment inside a word — "aunch" is not a prefix of any
        // token in "Launch". When the word index found little, ask the trigram index too, and append
        // rather than merge, so a substring hit never displaces a real word match.
        guard primary.count < substringThreshold,
              let trigram = SearchCompiler.compileTrigram(query, limit: limit, dateProvider: dateProvider)
        else {
            return primary
        }

        let extra: [SearchResult]
        do {
            extra = try await store.query(trigram)
        } catch {
            return primary
        }

        var seen = Set(primary.map(\.id))
        var combined = primary
        for result in extra where seen.insert(result.id).inserted {
            combined.append(result)
        }
        return Array(combined.prefix(limit))
    }

    /// Below this many word matches, it is worth also trying substrings.
    ///
    /// Not zero: someone who typed a real word and got four good answers does not want them diluted
    /// by everything that happens to contain those letters.
    private let substringThreshold = 5

    /// The path used only when there is no usable index.
    private func storeFallback(_ query: SearchQuery, limit: Int) throws(AppError) -> [SearchResult] {
        Diagnostics.search.debug("Index unavailable — using store fallback")

        var fallback = ItemQuery()
        fallback.scope = query.states.contains(.trashed) ? .trashed : .active
        if !query.terms.isEmpty {
            fallback.text = query.terms.joined(separator: " ")
        }
        fallback.limit = limit

        return try items.items(matching: fallback).map { item in
            SearchResult(
                item: item.snapshot(),
                score: 0,
                titleMatchRanges: [],
                bodyExcerpt: TextNormalizer.excerpt(from: item.body)
            )
        }
    }

    public func titleSuggestions(prefix: String, limit: Int = 12) async -> [(id: UUID, title: String)] {
        do {
            return try await store.titles(prefix: prefix, limit: limit)
        } catch {
            return []
        }
    }
}

/// What the index can currently answer.
///
/// Distinguished so the search field can say which of these it is. "No results" and "not finished
/// indexing" look identical on screen and mean opposite things, and conflating them is how a user
/// concludes their note is gone.
public enum IndexStatus: Sendable, Hashable {
    case opening
    case building(progress: RebuildProgress)
    case ready(indexed: Int)
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// A phrase for the results header, or `nil` when there is nothing worth saying.
    public var explanation: String? {
        switch self {
        case .opening:
            "Opening the index…"
        case .building(let progress) where progress.expected > 0:
            "Still indexing — \(progress.indexed) of \(progress.expected) so far."
        case .building:
            "Still indexing…"
        case .ready:
            nil
        case .unavailable:
            "Searching without the index. Results may be slower and less complete."
        }
    }
}

