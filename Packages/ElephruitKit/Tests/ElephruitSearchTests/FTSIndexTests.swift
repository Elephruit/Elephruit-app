import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import Foundation
import SwiftData
import Testing

/// A file-backed fixture, because half of what makes the sidecar worth having is that it survives
/// a launch — and an in-memory index would prove none of it.
@MainActor
struct IndexFixture {
    let stack: PersistenceStack
    let context: ModelContext
    let items: SwiftDataItemRepository
    let tags: SwiftDataTagRepository
    let audit = FetchAudit()
    let clock = FixedDateProvider.reference
    let indexURL: URL

    private(set) var engine: FTSSearchEngine

    init() throws {
        stack = try PersistenceStack.inMemory()
        context = ModelContext(stack.container)
        tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags, audit: audit)
        indexURL = URL.temporaryDirectory
            .appending(path: "ElephruitFTSTests", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).sqlite", directoryHint: .notDirectory)
        engine = FTSSearchEngine(
            items: items,
            indexURL: indexURL,
            dateProvider: clock,
            container: stack.container
        )
    }

    /// A second engine over the same file, as a relaunch would produce.
    func reopened() -> FTSSearchEngine {
        FTSSearchEngine(items: items, indexURL: indexURL, dateProvider: clock, container: stack.container)
    }

    func removeIndexFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(filePath: indexURL.path(percentEncoded: false) + suffix)
            guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try FileManager.default.removeItem(at: target)
        }
    }

    func indexFileExists() -> Bool {
        FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false))
    }

    @discardableResult
    func search(_ text: String, limit: Int = 50) async throws -> [SearchResult] {
        try await engine.search(SearchQueryParser.parse(text), limit: limit)
    }
}

@Suite("Search index durability")
@MainActor
struct SearchIndexDurabilityTests {
    @Test("The index survives a relaunch, so search works before anything is rebuilt")
    func indexSurvivesRelaunch() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Quarterly Launch Plan"))
        await fixture.engine.warmIndex()

        #expect(fixture.indexFileExists(), "The sidecar must be a real file, not an in-memory cache")

        // A fresh engine over the same file — what the next launch does.
        let relaunched = fixture.reopened()
        await relaunched.warmIndex()

        #expect(relaunched.status.isReady, "An index that is already complete must open ready")

        let results = try await relaunched.search(SearchQueryParser.parse("launch"), limit: 10)
        #expect(results.count == 1)
    }

    @Test("Deleting the index loses nothing")
    func deletingTheIndexLosesNothing() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Quarterly Launch Plan"))
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Book the venue"))
        await fixture.engine.warmIndex()

        try fixture.removeIndexFiles()
        #expect(!fixture.indexFileExists())

        let relaunched = fixture.reopened()
        await relaunched.warmIndex()

        #expect(try await relaunched.search(SearchQueryParser.parse("launch"), limit: 10).count == 1)
        #expect(try await relaunched.search(SearchQueryParser.parse("venue"), limit: 10).count == 1)
    }

    @Test("Rebuilding by hand produces the same answers")
    func invalidateAndRebuild() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Quarterly Launch Plan"))
        await fixture.engine.warmIndex()

        await fixture.engine.invalidateIndex()
        await fixture.engine.waitForIndexing()

        #expect(fixture.engine.status.isReady)
        #expect(try await fixture.search("launch").count == 1)
    }

    @Test("An item deleted while the index was closed does not survive as a result")
    func staleRowsAreSweptOnRebuild() async throws {
        let fixture = try IndexFixture()
        let doomed = try fixture.items.create(ItemDraft(kind: .note, title: "Obsolete launch note"))
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Current launch note"))
        await fixture.engine.warmIndex()

        // Deleted without telling the index — as a background merge or an import would.
        fixture.context.delete(doomed)
        try fixture.context.save()

        let relaunched = fixture.reopened()
        await relaunched.invalidateIndex()
        await relaunched.waitForIndexing()

        let results = try await relaunched.search(SearchQueryParser.parse("launch"), limit: 10)
        #expect(results.count == 1, "A rebuild must sweep rows whose item no longer exists")
        #expect(results.first?.item.title == "Current launch note")
    }
}

@Suite("Search matching")
@MainActor
struct SearchMatchingTests {
    @Test("A fragment inside a word still finds the item")
    func substringMatching() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Relaunch checklist"))
        await fixture.engine.warmIndex()

        // "launch" is not a prefix of "Relaunch", so only the trigram index can answer this.
        let results = try await fixture.search("launch")
        #expect(results.count == 1, "Substring matching must find a fragment inside a word")
        #expect(results.first?.item.title == "Relaunch checklist")
    }

    @Test("A substring hit never displaces a real word match")
    func wordMatchesOutrankSubstrings() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Relaunch checklist"))
        let exact = try fixture.items.create(ItemDraft(kind: .note, title: "Launch"))
        await fixture.engine.warmIndex()

        let results = try await fixture.search("launch")
        #expect(results.count == 2)
        #expect(results.first?.item.id == exact.id)
    }

    @Test("Search operators typed as text are searched for, not executed")
    func queryTextIsNeverSQL() async throws {
        let fixture = try IndexFixture()
        let awkward = try fixture.items.create(
            ItemDraft(kind: .note, title: "Notes on \"quotes\" and OR", body: "'; DROP TABLE entries; --")
        )
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Something else"))
        await fixture.engine.warmIndex()

        // If any of this reached the SQL or the FTS grammar as syntax, this either throws or
        // quietly returns the wrong set.
        #expect(try await fixture.search("\"quotes\"").map(\.item.id) == [awkward.id])
        #expect(try await fixture.search("DROP TABLE entries").map(\.item.id) == [awkward.id])

        // And the table is still there.
        #expect(try await fixture.search("something").count == 1)
    }

    @Test("Diacritics fold both ways")
    func diacriticsFold() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Café résumé"))
        await fixture.engine.warmIndex()

        #expect(try await fixture.search("cafe").count == 1)
        #expect(try await fixture.search("resume").count == 1)
        #expect(try await fixture.search("café").count == 1)
    }

    @Test("A body match carries an excerpt showing why it matched")
    func bodyExcerptExplainsTheMatch() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(
            ItemDraft(
                kind: .note,
                title: "Meeting notes",
                body: String(repeating: "Filler sentence about nothing much. ", count: 20)
                    + "The decision was to postpone the migration until March. "
                    + String(repeating: "More filler afterwards. ", count: 20)
            )
        )
        await fixture.engine.warmIndex()

        let result = try #require(try await fixture.search("migration").first)
        let excerpt = try #require(result.bodyExcerpt)
        #expect(excerpt.localizedCaseInsensitiveContains("migration"),
                "An excerpt that does not contain the match explains nothing")
        #expect(excerpt.count < 300, "An excerpt is a window, not the whole body")
    }

    @Test("Headings stay out of results unless named")
    func headingsAreStructural() async throws {
        let fixture = try IndexFixture()
        let project = try fixture.items.create(ItemDraft(kind: .project, title: "Launch"))
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Launch prep", parentID: project.id))
        await fixture.engine.warmIndex()

        let general = try await fixture.search("launch")
        #expect(general.allSatisfy { $0.item.kind != .heading })

        let named = try await fixture.search("launch type:heading")
        #expect(named.count == 1)
        #expect(named.first?.item.kind == .heading)
    }

    @Test("Archived items are excluded unless asked for")
    func archivedIsOptedInto() async throws {
        let fixture = try IndexFixture()
        let old = try fixture.items.create(ItemDraft(kind: .note, title: "Archived launch note"))
        try fixture.items.setArchived(old, true)
        await fixture.engine.warmIndex()

        #expect(try await fixture.search("launch").isEmpty)
        #expect(try await fixture.search("launch is:archived").count == 1)
    }
}

@Suite("Search filters")
@MainActor
struct SearchFilterTests {
    @Test("A tag prefix that is not a path component does not match")
    func tagPrefixIsNotSubstring() async throws {
        let fixture = try IndexFixture()
        let nested = try fixture.items.create(
            ItemDraft(kind: .note, title: "Client note", tagSlugs: ["work/clients"])
        )
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Woodwork note", tagSlugs: ["workshop"]))
        await fixture.engine.warmIndex()

        let results = try await fixture.search("tag:work")
        #expect(results.map(\.item.id) == [nested.id], "tag:work must match work/clients but never workshop")
    }

    @Test("A structural query with no words at all still works")
    func structuralOnlyQuery() async throws {
        let fixture = try IndexFixture()
        let flagged = try fixture.items.create(ItemDraft(kind: .task, title: "Important"))
        try fixture.items.update(flagged) { $0.isFavorite = true }
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Ordinary"))
        await fixture.engine.warmIndex()

        let results = try await fixture.search("is:favorite type:task")
        #expect(results.map(\.item.id) == [flagged.id])
    }

    @Test("person: finds what a person is involved in, in both directions")
    func personOperator() async throws {
        let fixture = try IndexFixture()
        let ana = try fixture.items.create(ItemDraft(kind: .person, title: "Ana Ferreira"))
        let meeting = try fixture.items.create(ItemDraft(kind: .meeting, title: "Kickoff"))
        fixture.context.insert(
            ItemLink(kind: .mentions, source: meeting, target: ana, createdAt: fixture.clock.now)
        )
        try fixture.context.save()

        _ = try fixture.items.create(ItemDraft(kind: .meeting, title: "Unrelated standup"))
        await fixture.engine.warmIndex()

        let results = try await fixture.search("person:ana")
        let titles = Set(results.map(\.item.title))
        #expect(titles.contains("Kickoff"), "A meeting linked to Ana is something Ana is involved in")
        #expect(titles.contains("Ana Ferreira"), "So is Ana's own page")
        #expect(!titles.contains("Unrelated standup"))
    }

    @Test("person: does not match a name that merely appears in prose")
    func personIsNotFullText() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(
            ItemDraft(kind: .note, title: "Random thought", body: "Ana Ferreira wrote something about this once.")
        )
        await fixture.engine.warmIndex()

        #expect(try await fixture.search("person:ana").isEmpty,
                "person: is about links, not about words")
        #expect(try await fixture.search("ana").count == 1, "Plain text search still finds the mention")
    }

    @Test("in: finds by container, whether the item is inside it or filed under it")
    func containerOperator() async throws {
        let fixture = try IndexFixture()
        let project = try fixture.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        let task = try fixture.items.create(ItemDraft(kind: .task, title: "Book the venue", parentID: project.id))

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Venue options"))
        try fixture.items.fileItem(note, under: project)

        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Unrelated errand"))
        await fixture.engine.warmIndex()

        let results = try await fixture.search("in:\"Q3 Launch\"")
        let found = Set(results.map(\.item.id))
        #expect(found.contains(task.id), "A task inside the project is in it")
        #expect(found.contains(note.id), "A note filed under the project is in it too")
        #expect(found.count == 2)
    }

    @Test("A date bound is applied by the database, not after the fact")
    func dateBounds() async throws {
        let fixture = try IndexFixture()
        let soon = try fixture.items.create(
            ItemDraft(kind: .task, title: "Due soon", dueAt: fixture.clock.startOfDay(daysFromToday: 2))
        )
        _ = try fixture.items.create(
            ItemDraft(kind: .task, title: "Due later", dueAt: fixture.clock.startOfDay(daysFromToday: 30))
        )
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "No date at all"))
        await fixture.engine.warmIndex()

        let bounded = try await fixture.search("due:<7d")
        #expect(bounded.map(\.item.id) == [soon.id])

        let undated = try await fixture.search("due:none type:task")
        #expect(undated.map(\.item.title) == ["No date at all"])
    }
}

@Suite("Search cost")
@MainActor
struct SearchCostTests {
    /// The behavioural performance criterion.
    ///
    /// Not a timing: a timer says "fast on this machine today". This says the result list is built
    /// without asking SwiftData anything at all, which is either true or false and gives the same
    /// answer on any hardware under any load. It is also the property that makes the *timing*
    /// budgets achievable, so if this regresses the timings will follow.
    @Test("Running a search and reading every result touches the store zero times")
    func searchDoesNotTouchTheStore() async throws {
        let fixture = try IndexFixture()
        for index in 0..<50 {
            _ = try fixture.items.create(
                ItemDraft(
                    kind: index.isMultiple(of: 2) ? .note : .task,
                    title: "Launch item \(index)",
                    body: "Body text for item \(index) mentioning shipping and timelines.",
                    tagSlugs: ["work"]
                )
            )
        }
        await fixture.engine.warmIndex()

        let (results, tally) = try await fixture.audit.measure {
            let results = try await fixture.search("launch", limit: 100)

            // Read everything a row draws, so a lazily-faulted relationship would be caught here
            // rather than showing up as a mysterious cost during scrolling.
            for result in results {
                _ = result.item.displayTitle
                _ = result.item.effectiveSymbolName
                _ = result.item.tagSlugs
                _ = result.item.parentTitle
                _ = result.item.dueAt
                _ = result.item.isActionable
                _ = result.bodyExcerpt
                _ = result.titleMatchRanges
            }
            return results
        }

        #expect(results.count == 50)
        #expect(tally.total == 0, "Search results must render from the index alone — saw \(tally.description)")
    }

    @Test("A search mid-rebuild returns what has been indexed, never a false empty state")
    func partialIndexIsHonest() async throws {
        let fixture = try IndexFixture()
        for index in 0..<200 {
            _ = try fixture.items.create(ItemDraft(kind: .note, title: "Launch item \(index)"))
        }

        // Start the rebuild but do not wait for it — exactly what launch does.
        await fixture.engine.openIndex()

        var sawResults = false
        for _ in 0..<40 {
            let results = try await fixture.search("launch", limit: 500)
            if !results.isEmpty { sawResults = true }
            if fixture.engine.status.isReady { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        await fixture.engine.waitForIndexing()

        #expect(sawResults, "A query during indexing must return partial results, not an empty list")
        #expect(try await fixture.search("launch", limit: 500).count == 200)
    }

    @Test("The status explains itself while indexing and says nothing when ready")
    func statusIsLegible() async throws {
        let fixture = try IndexFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "A note"))

        #expect(IndexStatus.opening.explanation != nil)
        #expect(IndexStatus.building(progress: RebuildProgress(indexed: 3, expected: 9, isRebuilding: true))
            .explanation?.contains("3 of 9") == true)

        await fixture.engine.warmIndex()
        #expect(fixture.engine.status.explanation == nil, "A ready index has nothing to explain")
    }
}
