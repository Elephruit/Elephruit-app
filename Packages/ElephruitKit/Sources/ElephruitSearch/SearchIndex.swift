import ElephruitCore
import Foundation

/// An inverted index over item text.
///
/// An `actor`, so it can be built and queried off the main actor without blocking the
/// interface, and it holds only ``ItemSnapshot`` values — never `PersistentModel` objects.
/// That is the architecture's one hard concurrency rule, and this type is where it earns its
/// keep: indexing is exactly the sort of bulk work that would otherwise be tempted to pass a
/// model across an isolation boundary.
///
/// **This is a cache.** It may be discarded at any moment and rebuilt from the store with no
/// loss. See `docs/adr/0004-search-is-derived.md`, including the escalation path to SQLite
/// FTS5 if an in-memory index ever stops being enough.
public actor SearchIndex {
    /// term → item identifiers containing it.
    private var postings: [String: Set<UUID>] = [:]

    /// The snapshots themselves, so a result can be ranked and rendered without touching the
    /// store again.
    private var snapshots: [UUID: ItemSnapshot] = [:]

    /// Terms per item, so an update can remove an item's old postings precisely rather than
    /// scanning every term.
    private var termsByItem: [UUID: Set<String>] = [:]

    public private(set) var isWarm = false

    public init() {}

    // MARK: - Building

    /// Replaces the whole index.
    public func rebuild(from items: [ItemSnapshot]) {
        postings.removeAll(keepingCapacity: true)
        snapshots.removeAll(keepingCapacity: true)
        termsByItem.removeAll(keepingCapacity: true)

        for item in items {
            insert(item)
        }

        isWarm = true
        Diagnostics.search.info("Rebuilt index: \(items.count, privacy: .public) items, \(self.postings.count, privacy: .public) terms")
    }

    /// Adds or replaces one item.
    public func update(_ item: ItemSnapshot) {
        remove(id: item.id)
        insert(item)
    }

    /// Removes an item and every posting that mentioned it.
    public func remove(id: UUID) {
        guard let existingTerms = termsByItem.removeValue(forKey: id) else {
            snapshots.removeValue(forKey: id)
            return
        }

        for term in existingTerms {
            postings[term]?.remove(id)
            if postings[term]?.isEmpty == true {
                postings.removeValue(forKey: term)
            }
        }

        snapshots.removeValue(forKey: id)
    }

    private func insert(_ item: ItemSnapshot) {
        // Trashed items are indexed too: Trash is searchable, and excluding them here would
        // mean the index disagreed with the store about what exists.
        let text = [item.title, item.body, item.tagSlugs.joined(separator: " ")]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let terms = Set(TextNormalizer.searchTerms(in: text))

        for term in terms {
            postings[term, default: []].insert(item.id)

            // Prefix postings make "lau" find "launch" without scanning every term at query
            // time. Capped at eight characters: beyond that the exact-term posting already
            // narrows enough, and unbounded prefixes would multiply memory by average word
            // length for no benefit.
            if term.count > 2 {
                for length in 2..<min(term.count, 8) {
                    let prefix = String(term.prefix(length))
                    postings["\(prefix)*", default: []].insert(item.id)
                }
            }
        }

        termsByItem[item.id] = terms
        snapshots[item.id] = item
    }

    // MARK: - Querying

    /// Identifiers matching *every* term, or `nil` if the index is cold.
    ///
    /// `nil` rather than an empty set is the important distinction: an empty set means "nothing
    /// matches", while `nil` means "ask the store instead". Conflating them would show an empty
    /// search result during the first second after launch.
    public func candidates(matchingAll terms: [String]) -> Set<UUID>? {
        guard isWarm else { return nil }
        guard !terms.isEmpty else { return Set(snapshots.keys) }

        var result: Set<UUID>?

        // Rarest term first, so the intersection shrinks as fast as possible.
        let ordered = terms.sorted { lookup($0).count < lookup($1).count }

        for term in ordered {
            let matches = lookup(term)
            if matches.isEmpty { return [] }

            if var current = result {
                current.formIntersection(matches)
                if current.isEmpty { return [] }
                result = current
            } else {
                result = matches
            }
        }

        return result ?? []
    }

    /// Exact matches, falling back to prefix matches so search feels live as the user types.
    ///
    /// Folds the incoming term rather than trusting the caller to have done it. The parser does
    /// fold, but the index is also called directly — by link completion and by tests — and an
    /// index that silently misses `CAFE` because someone forgot to lowercase is a bug waiting
    /// for a call site.
    private func lookup(_ rawTerm: String) -> Set<UUID> {
        let term = TextNormalizer.foldedForMatching(rawTerm)
        guard !term.isEmpty else { return [] }

        if let exact = postings[term] { return exact }
        if term.count >= 2, let prefixed = postings["\(term)*"] { return prefixed }
        return []
    }

    public func snapshot(id: UUID) -> ItemSnapshot? {
        snapshots[id]
    }

    public func snapshots(ids: some Sequence<UUID>) -> [ItemSnapshot] {
        ids.compactMap { snapshots[$0] }
    }

    /// Item titles, for `[[` link completion and the command palette.
    public func titles(matching prefix: String, limit: Int = 12) -> [(id: UUID, title: String)] {
        let folded = TextNormalizer.foldedForMatching(prefix)

        var matches: [(id: UUID, title: String, rank: Int)] = []

        for snapshot in snapshots.values where snapshot.deletedAt == nil && !snapshot.title.isEmpty {
            let foldedTitle = TextNormalizer.foldedForMatching(snapshot.title)

            // Titles that *begin* with the query rank above titles that merely contain it,
            // because that is what the user is usually reaching for.
            if folded.isEmpty {
                matches.append((snapshot.id, snapshot.title, 2))
            } else if foldedTitle.hasPrefix(folded) {
                matches.append((snapshot.id, snapshot.title, 0))
            } else if foldedTitle.contains(folded) {
                matches.append((snapshot.id, snapshot.title, 1))
            }
        }

        return matches
            .sorted { left, right in
                left.rank == right.rank
                    ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                    : left.rank < right.rank
            }
            .prefix(limit)
            .map { (id: $0.id, title: $0.title) }
    }

    /// Statistics for the diagnostics pane in Settings.
    public func statistics() -> (items: Int, terms: Int, isWarm: Bool) {
        (snapshots.count, postings.count, isWarm)
    }

    /// Discards everything. The next query falls back to the store until a rebuild finishes.
    public func invalidate() {
        postings.removeAll()
        snapshots.removeAll()
        termsByItem.removeAll()
        isWarm = false
    }
}
