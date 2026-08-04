import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData

/// One search result.
public struct SearchResult: Sendable, Hashable, Identifiable {
    public var item: ItemSnapshot
    public var score: Double

    /// Ranges within the title that matched, for highlighting. Character offsets rather than
    /// `String.Index`, so the value can cross an isolation boundary.
    public var titleMatchRanges: [Range<Int>]

    /// A body excerpt centred on the first match, so the result shows *why* it matched.
    public var bodyExcerpt: String?

    public var id: UUID { item.id }

    public init(item: ItemSnapshot, score: Double, titleMatchRanges: [Range<Int>] = [], bodyExcerpt: String? = nil) {
        self.item = item
        self.score = score
        self.titleMatchRanges = titleMatchRanges
        self.bodyExcerpt = bodyExcerpt
    }
}

/// Running searches.
///
/// A protocol so features can be tested against a double and so the engine can be replaced —
/// with an FTS5-backed one, for instance — without touching a single view.
@MainActor
public protocol SearchEngine: AnyObject {
    /// Runs a query. Ordered by relevance, then by recency.
    func search(_ query: SearchQuery, limit: Int) async throws(AppError) -> [SearchResult]

    /// Item titles for `[[` completion and the palette.
    func titleSuggestions(prefix: String, limit: Int) async -> [(id: UUID, title: String)]

    /// Builds the index from the store. Safe to call repeatedly.
    func warmIndex() async

    /// Reflects a saved item in the index.
    func indexDidChange(for item: Item) async

    /// Removes an item from the index.
    func removeFromIndex(id: UUID) async

    /// Discards the index. The next search falls back to the store.
    func invalidateIndex() async

    /// How much is indexed, and whether the index is built yet.
    ///
    /// On the protocol rather than on the engines, which both had it already. Settings ▸ Advanced
    /// reached it by casting `search` to `DefaultSearchEngine`; the engine in the app is an
    /// `FTSSearchEngine`, so the cast failed, and the three rows that report the index were never
    /// drawn. Nothing raised — a failed `as?` is a `nil` and the view simply had nothing to show, so
    /// the screen looked like a screen with no statistics on it rather than like a bug.
    ///
    /// The general shape of that mistake is a view asking "which engine am I talking to"; the fix is
    /// for it never to need to know.
    func indexStatistics() async -> (items: Int, terms: Int, isWarm: Bool)
}

/// The v1 engine.
///
/// Combines two paths, as `docs/adr/0004-search-is-derived.md` describes:
///
/// 1. **Free text** goes to the in-memory ``SearchIndex``, which is fast and supports prefix
///    matching and ranking.
/// 2. **Structural filters** — kind, tag, state, dates — are applied to the resulting items.
///
/// If the index is cold, the whole query falls back to a store fetch with `searchText`
/// matching. Slower, but correct, so the first search after launch returns the right answer
/// rather than an empty list.
@MainActor
public final class DefaultSearchEngine: SearchEngine {
    private let items: any ItemRepository
    private let index: SearchIndex
    private let dateProvider: any DateProvider

    /// Used to spin up a `@ModelActor` for off-main-actor reads. Optional so a test can inject a
    /// repository double without a real container.
    private let container: ModelContainer?

    public init(
        items: any ItemRepository,
        index: SearchIndex = SearchIndex(),
        dateProvider: any DateProvider,
        container: ModelContainer? = nil
    ) {
        self.items = items
        self.index = index
        self.dateProvider = dateProvider
        self.container = container
    }

    // MARK: - Index lifecycle

    /// Builds the index by streaming the store in batches, off the main actor.
    ///
    /// This used to materialise every row on the main actor at launch — a multi-second hang on a
    /// mature library, at precisely the moment the app should feel fastest. Now a `@ModelActor`
    /// reads batches on its own context and hands back plain `Sendable` structs, and the index stays
    /// queryable throughout, so a search run mid-warm returns partial results rather than a false
    /// empty state.
    public func warmIndex() async {
        guard let container else {
            Diagnostics.search.error("Index warm skipped: no container available")
            return
        }

        let signpost = Diagnostics.performance
        let state = signpost.beginInterval("warmIndex")
        defer { signpost.endInterval("warmIndex", state) }

        let worker = SnapshotWorker(modelContainer: container)
        let index = self.index

        do {
            let total = try await worker.itemCount()
            await index.beginRebuild(expecting: total)

            try await worker.streamSnapshots(batchSize: 500) { batch, _, _ in
                await index.absorb(batch)
            }

            await index.finishRebuild()
        } catch {
            Diagnostics.search.error("Index warm failed: \(String(describing: error), privacy: .public)")
            // Whatever landed stays usable; the index simply reports itself as still building.
            await index.finishRebuild()
        }
    }

    /// Progress of an in-flight rebuild, for the search header.
    public func indexProgress() async -> (indexed: Int, expected: Int, isRebuilding: Bool) {
        await (index.indexedCount, index.expectedCount, index.isRebuilding)
    }

    public func indexDidChange(for item: Item) async {
        let snapshot = item.snapshot()
        await index.update(snapshot)
    }

    public func removeFromIndex(id: UUID) async {
        await index.remove(id: id)
    }

    public func invalidateIndex() async {
        await index.invalidate()
    }

    public func indexStatistics() async -> (items: Int, terms: Int, isWarm: Bool) {
        await index.statistics()
    }

    // MARK: - Searching

    public func search(_ query: SearchQuery, limit: Int = 200) async throws(AppError) -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        let candidateIDs = await index.candidates(matchingAll: query.terms)
        let matches = try resolveCandidates(candidateIDs, query: query)

        let filtered = matches.filter { matchesStructuralFilters($0, query: query) }

        return filtered
            .map { makeResult(for: $0, query: query) }
            .sorted(by: Self.rank)
            .prefix(limit)
            .map { $0 }
    }

    /// Resolves the index's answer into items, or falls back to the store when it has none.
    private func resolveCandidates(_ candidateIDs: Set<UUID>?, query: SearchQuery) throws(AppError) -> [Item] {
        guard let candidateIDs else {
            // Cold index. Ask the store, using its own `searchText` column.
            var fallback = ItemQuery()
            fallback.scope = query.states.contains(.trashed) ? .trashed : .active
            if !query.terms.isEmpty {
                fallback.text = query.terms.joined(separator: " ")
            }
            Diagnostics.search.debug("Index cold — using store fallback")
            return try items.items(matching: fallback)
        }

        guard !candidateIDs.isEmpty else { return [] }

        // Fetching each by identifier keeps this correct without a large `IN` predicate, which
        // would run into the same translation ceiling documented in `ItemPredicateBuilder`.
        var resolved: [Item] = []
        resolved.reserveCapacity(candidateIDs.count)
        for id in candidateIDs {
            if let item = try items.item(id: id) {
                resolved.append(item)
            }
        }
        return resolved
    }

    public func titleSuggestions(prefix: String, limit: Int = 12) async -> [(id: UUID, title: String)] {
        await index.titles(matching: prefix, limit: limit)
    }

    // MARK: - Filtering

    /// Applies every non-text clause. Plain Swift, so each rule is directly testable.
    private func matchesStructuralFilters(_ item: Item, query: SearchQuery) -> Bool {
        // Trash is only searched when explicitly asked for.
        let wantsTrash = query.states.contains(.trashed)
        if wantsTrash != (item.deletedAt != nil) { return false }

        // Archived items are likewise excluded unless asked for.
        if !query.states.contains(.archived), item.archivedAt != nil { return false }

        if !query.kinds.isEmpty, !query.kinds.contains(item.kind) { return false }

        // Structural kinds stay out of global results unless the query names them — `type:heading`.
        // Searching *within* an open project is a different surface and does match them.
        if !item.kind.participatesInContentViews, !query.kinds.contains(item.kind) { return false }

        if !query.tagSlugs.isEmpty {
            let slugs = Set((item.tags ?? []).map(\.slug))
            // A parent tag matches its descendants: `tag:work` finds `work/clients` too, which
            // is the whole reason hierarchical tags are worth having.
            let satisfied = query.tagSlugs.allSatisfy { required in
                slugs.contains(required) || slugs.contains { $0.hasPrefix(required + "/") }
            }
            if !satisfied { return false }
        }

        if !query.containerTitles.isEmpty {
            let ancestorTitles = Set(item.ancestors().map { TextNormalizer.foldedForMatching($0.title) })
            let satisfied = query.containerTitles.contains { required in
                ancestorTitles.contains { $0.contains(required) }
            }
            if !satisfied { return false }
        }

        for state in query.states where !matches(state: state, item: item) {
            return false
        }

        if let due = query.due, !due.matches(item.dueAt, using: dateProvider) { return false }
        if let created = query.created, !created.matches(item.createdAt, using: dateProvider) { return false }
        if let updated = query.updated, !updated.matches(item.updatedAt, using: dateProvider) { return false }

        return true
    }

    private func matches(state: StateFilter, item: Item) -> Bool {
        switch state {
        case .open: item.status == .open
        case .completed: item.status == .completed
        case .cancelled: item.status == .cancelled
        case .favorite: item.isFavorite
        case .pinned: item.isPinned
        // Handled above as scope, so they never exclude here.
        case .archived, .trashed: true
        case .overdue: item.isOverdue(using: dateProvider)
        case .untagged: (item.tags ?? []).isEmpty
        case .unfiled: item.parent == nil
        case .linked: !(item.outgoingLinks ?? []).isEmpty || !(item.incomingLinks ?? []).isEmpty
        case .unlinked: (item.outgoingLinks ?? []).isEmpty && (item.incomingLinks ?? []).isEmpty
        }
    }

    // MARK: - Ranking

    /// Scores a match and finds its highlight ranges.
    ///
    /// The weighting is deliberately simple and explainable — a title hit beats a body hit, a
    /// whole-word hit beats a prefix hit, and recency breaks ties. A user should be able to
    /// guess why a result is where it is.
    private func makeResult(for item: Item, query: SearchQuery) -> SearchResult {
        let foldedTitle = TextNormalizer.foldedForMatching(item.title)
        let foldedBody = TextNormalizer.foldedForMatching(item.body)

        var score = 0.0
        var titleRanges: [Range<Int>] = []

        for term in query.terms {
            if let range = foldedTitle.range(of: term) {
                let start = foldedTitle.distance(from: foldedTitle.startIndex, to: range.lowerBound)
                titleRanges.append(start..<(start + term.count))

                // Exact whole-title match, then title prefix, then anywhere in the title.
                if foldedTitle == term {
                    score += 100
                } else if range.lowerBound == foldedTitle.startIndex {
                    score += 40
                } else {
                    score += 20
                }
            } else if foldedBody.contains(term) {
                score += 5
            }
        }

        // Structural filters contribute nothing to the score — they are gates, not preferences.
        // These, on the other hand, are things the user has said matter.
        if item.isPinned { score += 8 }
        if item.isFavorite { score += 4 }
        if item.status == .completed { score -= 6 }

        return SearchResult(
            item: item.snapshot(),
            score: score,
            titleMatchRanges: titleRanges.sorted { $0.lowerBound < $1.lowerBound },
            bodyExcerpt: bodyExcerpt(from: item.body, folded: foldedBody, terms: query.terms)
        )
    }

    /// A window of body text around the first matching term.
    private func bodyExcerpt(from body: String, folded: String, terms: [String]) -> String? {
        guard !body.isEmpty else { return nil }

        for term in terms {
            guard let range = folded.range(of: term) else { continue }

            let matchOffset = folded.distance(from: folded.startIndex, to: range.lowerBound)
            let windowStart = max(0, matchOffset - 40)

            // Offsets are computed in the folded string; folding preserves character count for
            // the transformations used here, so they map onto the original.
            guard windowStart < body.count else { break }
            let start = body.index(body.startIndex, offsetBy: windowStart, limitedBy: body.endIndex) ?? body.startIndex
            let end = body.index(start, offsetBy: 160, limitedBy: body.endIndex) ?? body.endIndex

            var excerpt = String(body[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if windowStart > 0 { excerpt = "…" + excerpt }
            if end < body.endIndex { excerpt += "…" }
            return excerpt.replacingOccurrences(of: "\n", with: " ")
        }

        return TextNormalizer.excerpt(from: body)
    }

    private static func rank(_ left: SearchResult, _ right: SearchResult) -> Bool {
        if left.score != right.score { return left.score > right.score }
        return left.item.updatedAt > right.item.updatedAt
    }
}
