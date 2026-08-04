import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Reads the store and produces ``IndexDocument`` values for the sidecar.
///
/// A `@ModelActor`, so a full rebuild genuinely runs off the main actor with its own `ModelContext`,
/// and only `Sendable` structs cross back. No `Item` ever leaves the context that fetched it — the
/// one concurrency rule this codebase does not bend.
@ModelActor
actor IndexWorker {
    func itemCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Item>())
    }

    /// Every item's identifier, for the sweep that ends a rebuild.
    ///
    /// Identifiers only — the whole point is to know what still exists without materialising it.
    func liveIdentifiers() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Item>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    /// One page of documents, starting from a cursor rather than an offset.
    ///
    /// ### Why not `fetchOffset`
    /// `OFFSET n` makes the database walk and discard *n* rows on every page, so paging a whole
    /// library costs the square of its size. Measured on fifty-seven thousand items: the first page
    /// took 41 ms and the last took 426 ms, and the reads were 92% of a forty-second rebuild.
    ///
    /// A cursor turns each page into a seek plus a scan of the page itself, so every page costs the
    /// same as the first.
    ///
    /// The bound is `>=` rather than `>` because timestamps are not unique — a bulk import gives
    /// hundreds of items the same `createdAt`. The caller drops the overlap it has already seen,
    /// which is cheaper and safer than pretending the key is unique when it is not.
    func documents(from cursor: Date?, limit: Int) throws -> [IndexDocument] {
        var descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        if let cursor {
            descriptor.predicate = #Predicate<Item> { $0.createdAt >= cursor }
        }
        descriptor.fetchLimit = limit
        descriptor.relationshipKeyPathsForPrefetching = [
            \.tags, \.parent, \.outgoingLinks, \.incomingLinks,
        ]

        return try modelContext.fetch(descriptor).map(IndexDocumentBuilder.make)
    }

    /// Streams the whole store, handing each batch to `handler` as it is read.
    ///
    /// The index therefore fills progressively, and a search run while it is filling returns what
    /// has been indexed so far rather than an empty list.
    func stream(
        batchSize: Int = 400,
        handler: @Sendable ([IndexDocument], _ processed: Int, _ total: Int) async -> Void
    ) async throws {
        let total = try itemCount()

        var cursor: Date?
        var processed = 0
        var limit = batchSize

        /// Identifiers already handed over that share the cursor's timestamp.
        ///
        /// Only that timestamp's worth, so this stays small however large the library is.
        var emittedAtCursor: Set<UUID> = []

        while processed < total {
            try Task.checkCancellation()

            let page = try documents(from: cursor, limit: limit)
            guard !page.isEmpty else { break }

            let fresh = page.filter { !emittedAtCursor.contains($0.snapshot.id) }

            guard !fresh.isEmpty else {
                // Every row in the page was already handed over, which can only mean more items
                // share this timestamp than fit in a page. Widen until they do; without this the
                // loop would spin forever on a bulk import.
                guard page.count == limit else { break }
                limit *= 2
                continue
            }

            limit = batchSize
            processed += fresh.count

            guard let last = fresh.last else { break }
            cursor = last.snapshot.createdAt
            emittedAtCursor = Set(
                fresh.filter { $0.snapshot.createdAt == last.snapshot.createdAt }.map(\.snapshot.id)
            )

            await handler(fresh, processed, total)

            // The rebuild is background work behind a foreground app. Yielding between batches
            // keeps it from monopolising the cooperative pool while someone is typing.
            await Task.yield()
        }
    }
}

/// Projects an `Item` into the flat, `Sendable` shape the index stores.
///
/// Shared by the background rebuild and the incremental update on save, so a row written by one is
/// byte-for-byte what the other would have written. Two code paths producing subtly different
/// documents is how an index starts disagreeing with itself.
enum IndexDocumentBuilder {
    static func make(_ item: Item) -> IndexDocument {
        IndexDocument(
            snapshot: item.snapshot(),
            body: item.body,
            excerpt: TextNormalizer.excerpt(from: item.body),
            tagText: tagText(for: item),
            containerText: containerText(for: item),
            peopleText: peopleText(for: item),
            isFiled: item.parent != nil || !item.filedUnderContainers().isEmpty,
            hasLinks: !(item.outgoingLinks ?? []).isEmpty || !(item.incomingLinks ?? []).isEmpty
        )
    }

    /// Tag slugs, plus each path component as its own word.
    ///
    /// `work/clients/acme` becomes "work/clients/acme work clients acme", so searching "acme" finds
    /// it. Without the split, a hierarchical tag would be one long unsearchable token.
    private static func tagText(for item: Item) -> String {
        var words: [String] = []
        for slug in item.tagSlugs {
            words.append(slug)
            words.append(contentsOf: slug.split(separator: "/").map(String.init))
        }
        return words.joined(separator: " ")
    }

    /// Titles of everything this item sits inside or is filed under.
    ///
    /// Both, because since Phase A2 those are different relationships: a task is *inside* its
    /// project, a note is *filed under* one. `in:"Q3 Launch"` should find either.
    private static func containerText(for item: Item) -> String {
        var titles = item.ancestors().map(\.title)
        titles.append(contentsOf: item.filedUnderContainers().map(\.title))
        return titles.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Names of people and organisations this item links to, in either direction.
    ///
    /// A meeting links to its attendees; a person's page is linked *from* the notes about them.
    /// `person:ana` should find both, so both directions are indexed.
    private static func peopleText(for item: Item) -> String {
        var names: [String] = []
        var seen = Set<UUID>()

        for link in (item.outgoingLinks ?? []) {
            guard let target = link.target,
                  target.kind == .person || target.kind == .organization,
                  target.deletedAt == nil,
                  seen.insert(target.id).inserted
            else { continue }
            names.append(target.title)
        }

        for link in (item.incomingLinks ?? []) {
            guard let source = link.source,
                  source.kind == .person || source.kind == .organization,
                  source.deletedAt == nil,
                  seen.insert(source.id).inserted
            else { continue }
            names.append(source.title)
        }

        // A person's own page answers `person:their-name` too, which is what someone typing it
        // almost always wants first.
        if item.kind == .person || item.kind == .organization {
            names.append(item.title)
        }

        return names.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
