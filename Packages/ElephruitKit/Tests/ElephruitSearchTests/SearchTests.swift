import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import Foundation
import SwiftData
import Testing

@Suite("Search query grammar")
struct SearchQueryParserTests {
    @Test("Free text becomes terms")
    func freeText() {
        let query = SearchQueryParser.parse("launch plan")
        #expect(query.terms == ["launch", "plan"])
        #expect(!query.hasStructuralFilters)
    }

    @Test("Type and kind are the same token")
    func typeToken() {
        #expect(SearchQueryParser.parse("type:note").kinds == [.note])
        #expect(SearchQueryParser.parse("kind:task").kinds == [.task])
        #expect(SearchQueryParser.parse("type:note type:task").kinds == [.note, .task])
    }

    @Test("Tags are normalised in the query, as they are in the store")
    func tagToken() {
        #expect(SearchQueryParser.parse("tag:Work").tagSlugs == ["work"])
        #expect(SearchQueryParser.parse("tag:work/clients").tagSlugs == ["work/clients"])
    }

    @Test("Quoted values group across spaces")
    func quotedValues() {
        let query = SearchQueryParser.parse("project:\"Q3 Launch\" plan")
        #expect(query.containerTitles == ["q3 launch"])
        #expect(query.terms == ["plan"])
    }

    @Test("State filters")
    func stateTokens() {
        #expect(SearchQueryParser.parse("is:open").states == [.open])
        #expect(SearchQueryParser.parse("is:favorite is:pinned").states == [.favorite, .pinned])
    }

    @Test("Date comparisons in all three forms, plus none")
    func dateTokens() {
        #expect(SearchQueryParser.parse("due:<7d").due == .before(.dayOffset(7)))
        #expect(SearchQueryParser.parse("due:>today").due == .after(.today))
        #expect(SearchQueryParser.parse("due:friday").due == .on(.nextWeekday(6)))
        #expect(SearchQueryParser.parse("due:none").due == .absent)
        #expect(SearchQueryParser.parse("created:>2026-01-01").created == .after(.explicit(year: 2026, month: 1, day: 1)))
    }

    @Test("An unknown value for a known key is reported, not ignored")
    func unknownValuesAreReported() {
        let query = SearchQueryParser.parse("type:nonsense")
        #expect(query.kinds.isEmpty)
        #expect(query.unrecognisedTokens == ["type:nonsense"])

        let badDate = SearchQueryParser.parse("due:someday")
        #expect(badDate.due == nil)
        #expect(badDate.unrecognisedTokens == ["due:someday"])
    }

    @Test("An unknown key is treated as prose, so a colon does not break search")
    func unknownKeysBecomeText() {
        let query = SearchQueryParser.parse("note:something")
        #expect(query.unrecognisedTokens.isEmpty)
        #expect(query.terms.contains("note"))
        #expect(query.terms.contains("something"))
    }

    @Test("A key with no value is reported")
    func emptyValueIsReported() {
        let query = SearchQueryParser.parse("tag:")
        #expect(query.unrecognisedTokens == ["tag:"])
    }

    @Test("An empty query is empty")
    func emptyQuery() {
        #expect(SearchQueryParser.parse("").isEmpty)
        #expect(SearchQueryParser.parse("   ").isEmpty)
        #expect(!SearchQueryParser.parse("is:open").isEmpty)
    }

    @Test("The raw text is kept verbatim so a saved search round-trips")
    func rawTextIsPreserved() {
        let raw = "launch type:note tag:work due:<7d"
        #expect(SearchQueryParser.parse(raw).rawText == raw)
    }

    @Test("Descriptions read as English")
    func descriptions() {
        let query = SearchQueryParser.parse("launch type:task is:open")
        let description = SearchQueryParser.describe(query)

        #expect(description.contains("launch"))
        #expect(description.contains("Tasks"))
        #expect(description.contains("open"))
        #expect(SearchQueryParser.describe(SearchQuery()) == "Everything")
    }

    @Test("Date constraints evaluate against an injected clock")
    func dateConstraintEvaluation() {
        let clock = FixedDateProvider.reference  // Monday 2026-06-15
        let withinAWeek = DateConstraint.before(.dayOffset(7))

        #expect(withinAWeek.matches(clock.startOfDay(daysFromToday: 3), using: clock))
        #expect(!withinAWeek.matches(clock.startOfDay(daysFromToday: 10), using: clock))
        #expect(!withinAWeek.matches(nil, using: clock))

        #expect(DateConstraint.absent.matches(nil, using: clock))
        #expect(!DateConstraint.absent.matches(clock.now, using: clock))
    }
}

@Suite("Search index")
struct SearchIndexTests {
    private func snapshot(title: String, body: String = "", tags: [String] = []) -> ItemSnapshot {
        ItemSnapshot(kind: .note, title: title, body: body, tagSlugs: tags)
    }

    @Test("A cold index returns nil rather than an empty result")
    func coldIndexIsDistinguishable() async {
        let index = SearchIndex()

        // This distinction is what stops the first search after launch from showing "no
        // results" while the index is still building.
        #expect(await index.candidates(matchingAll: ["anything"]) == nil)
        #expect(await index.isWarm == false)
    }

    @Test("Terms are found after a build")
    func findsTerms() async {
        let index = SearchIndex()
        let launch = snapshot(title: "Launch Plan", body: "Details about shipping")
        let other = snapshot(title: "Grocery List")

        await index.rebuild(from: [launch, other])

        #expect(await index.candidates(matchingAll: ["launch"]) == [launch.id])
        #expect(await index.candidates(matchingAll: ["shipping"]) == [launch.id])
        #expect(await index.candidates(matchingAll: ["grocery"]) == [other.id])
        #expect(await index.candidates(matchingAll: ["absent"]) == [])
    }

    @Test("Multiple terms intersect")
    func termsIntersect() async {
        let index = SearchIndex()
        let both = snapshot(title: "Launch Plan")
        let onlyLaunch = snapshot(title: "Launch Party")

        await index.rebuild(from: [both, onlyLaunch])

        #expect(await index.candidates(matchingAll: ["launch", "plan"]) == [both.id])
        #expect(await index.candidates(matchingAll: ["launch"])?.count == 2)
    }

    @Test("Prefixes match, so search feels live while typing")
    func prefixMatching() async {
        let index = SearchIndex()
        let item = snapshot(title: "Launch")
        await index.rebuild(from: [item])

        #expect(await index.candidates(matchingAll: ["lau"]) == [item.id])
        #expect(await index.candidates(matchingAll: ["laun"]) == [item.id])
        #expect(await index.candidates(matchingAll: ["xyz"]) == [])
    }

    @Test("Matching folds case and diacritics")
    func matchingIsFolded() async {
        let index = SearchIndex()
        let item = snapshot(title: "Café Planning")
        await index.rebuild(from: [item])

        #expect(await index.candidates(matchingAll: ["cafe"]) == [item.id])
        #expect(await index.candidates(matchingAll: ["CAFE"]) == [item.id])
    }

    @Test("Tags are indexed alongside text")
    func tagsAreIndexed() async {
        let index = SearchIndex()
        let item = snapshot(title: "Note", tags: ["urgent"])
        await index.rebuild(from: [item])

        #expect(await index.candidates(matchingAll: ["urgent"]) == [item.id])
    }

    @Test("Updating replaces an item's postings rather than adding to them")
    func updateRemovesStalePostings() async {
        let index = SearchIndex()
        var item = snapshot(title: "Original Title")
        await index.rebuild(from: [item])

        item.title = "Replacement Title"
        await index.update(item)

        #expect(await index.candidates(matchingAll: ["original"]) == [], "The old term must not linger")
        #expect(await index.candidates(matchingAll: ["replacement"]) == [item.id])
    }

    @Test("Removing an item removes every trace of it")
    func removalIsComplete() async {
        let index = SearchIndex()
        let item = snapshot(title: "Doomed Note")
        await index.rebuild(from: [item])

        await index.remove(id: item.id)

        #expect(await index.candidates(matchingAll: ["doomed"]) == [])
        #expect(await index.snapshot(id: item.id) == nil)
        #expect(await index.statistics().items == 0)
    }

    @Test("Invalidating returns the index to cold")
    func invalidateGoesCold() async {
        let index = SearchIndex()
        await index.rebuild(from: [snapshot(title: "Anything")])
        #expect(await index.isWarm)

        await index.invalidate()
        #expect(await index.isWarm == false)
        #expect(await index.candidates(matchingAll: ["anything"]) == nil)
    }

    @Test("Title suggestions rank prefix matches above contained matches")
    func titleSuggestionRanking() async {
        let index = SearchIndex()
        let prefixMatch = snapshot(title: "Launch Plan")
        let containedMatch = snapshot(title: "Product Launch Retrospective")
        await index.rebuild(from: [containedMatch, prefixMatch])

        let suggestions = await index.titles(matching: "launch")
        #expect(suggestions.count == 2)
        #expect(suggestions.first?.id == prefixMatch.id, "A title that begins with the query comes first")
    }

    @Test("Trashed items are excluded from title suggestions")
    func suggestionsSkipTrashed() async {
        let index = SearchIndex()
        var trashed = snapshot(title: "Trashed Note")
        trashed.deletedAt = Date()
        let live = snapshot(title: "Live Note")

        await index.rebuild(from: [trashed, live])

        let suggestions = await index.titles(matching: "note")
        #expect(suggestions.map(\.id) == [live.id])
    }
}

/// The engine end to end, against a real store.
@MainActor
@Suite("Search engine")
struct SearchEngineTests {
    private func makeFixture() throws -> (SearchFixture) {
        try SearchFixture()
    }

    /// The engine under test is the FTS5-backed one.
    ///
    /// Every test in this suite was written against the v1 engine and is unchanged. That is the
    /// point of having put ``SearchEngine`` behind a protocol: the behaviour these assert is the
    /// contract, and swapping the implementation underneath them is how the contract gets proven
    /// rather than assumed.
    @MainActor
    struct SearchFixture {
        let stack: PersistenceStack
        let context: ModelContext
        let items: SwiftDataItemRepository
        let tags: SwiftDataTagRepository
        let engine: FTSSearchEngine
        let indexURL: URL
        let clock = FixedDateProvider.reference

        init() throws {
            stack = try PersistenceStack.inMemory()
            context = ModelContext(stack.container)
            tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
            indexURL = URL.temporaryDirectory
                .appending(path: "ElephruitSearchTests", directoryHint: .isDirectory)
                .appending(path: "\(UUID().uuidString).sqlite", directoryHint: .notDirectory)
            engine = FTSSearchEngine(
                items: items,
                indexURL: indexURL,
                dateProvider: clock,
                container: stack.container
            )
        }
    }

    @Test("Free text finds items by title and body")
    func findsByText() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Launch Plan", body: "Shipping details"))
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Grocery List"))
        await fixture.engine.warmIndex()

        let byTitle = try await fixture.engine.search(SearchQueryParser.parse("launch"), limit: 50)
        #expect(byTitle.count == 1)
        #expect(byTitle.first?.item.title == "Launch Plan")

        let byBody = try await fixture.engine.search(SearchQueryParser.parse("shipping"), limit: 50)
        #expect(byBody.count == 1)
    }

    @Test("A title match outranks a body match")
    func titleOutranksBody() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Mentions launch in body only", body: "launch"))
        let titled = try fixture.items.create(ItemDraft(kind: .note, title: "Launch"))
        await fixture.engine.warmIndex()

        let results = try await fixture.engine.search(SearchQueryParser.parse("launch"), limit: 50)
        #expect(results.count == 2)
        #expect(results.first?.item.id == titled.id)
    }

    @Test("Structural filters gate the results")
    func structuralFiltersApply() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Launch note"))
        let task = try fixture.items.create(ItemDraft(kind: .task, title: "Launch task"))
        await fixture.engine.warmIndex()

        let results = try await fixture.engine.search(SearchQueryParser.parse("launch type:task"), limit: 50)
        #expect(results.map(\.item.id) == [task.id])
    }

    @Test("A parent tag matches its descendants")
    func tagHierarchyMatches() async throws {
        let fixture = try makeFixture()
        let nested = try fixture.items.create(
            ItemDraft(kind: .note, title: "Client note", tagSlugs: ["work/clients/acme"])
        )
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Personal note", tagSlugs: ["home"]))
        await fixture.engine.warmIndex()

        let results = try await fixture.engine.search(SearchQueryParser.parse("tag:work"), limit: 50)
        #expect(results.map(\.item.id) == [nested.id], "tag:work must find work/clients/acme")
    }

    @Test("Trash is excluded unless asked for")
    func trashIsOptedInto() async throws {
        let fixture = try makeFixture()
        let doomed = try fixture.items.create(ItemDraft(kind: .note, title: "Doomed launch"))
        try fixture.items.moveToTrash(doomed)
        await fixture.engine.warmIndex()

        let normal = try await fixture.engine.search(SearchQueryParser.parse("launch"), limit: 50)
        #expect(normal.isEmpty)

        let inTrash = try await fixture.engine.search(SearchQueryParser.parse("launch is:trashed"), limit: 50)
        #expect(inTrash.map(\.item.id) == [doomed.id])
    }

    @Test("A cold index still returns correct results from the store")
    func coldIndexFallsBackToStore() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "Launch Plan"))

        // Deliberately not warmed.
        let results = try await fixture.engine.search(SearchQueryParser.parse("launch"), limit: 50)
        #expect(results.count == 1, "Correctness must not depend on the cache being warm")
    }

    @Test("Results carry title highlight ranges")
    func resultsCarryHighlights() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "The launch plan"))
        await fixture.engine.warmIndex()

        let result = try #require(try await fixture.engine.search(SearchQueryParser.parse("launch"), limit: 5).first)
        #expect(result.titleMatchRanges.count == 1)

        let range = try #require(result.titleMatchRanges.first)
        #expect(range.lowerBound == 4)
        #expect(range.count == 6)
    }

    @Test("Overdue is computed against the injected clock")
    func overdueFilterUsesClock() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(
            ItemDraft(kind: .task, title: "Overdue task", dueAt: fixture.clock.startOfDay(daysFromToday: -3))
        )
        _ = try fixture.items.create(
            ItemDraft(kind: .task, title: "Future task", dueAt: fixture.clock.startOfDay(daysFromToday: 3))
        )
        await fixture.engine.warmIndex()

        let results = try await fixture.engine.search(SearchQueryParser.parse("task is:overdue"), limit: 50)
        #expect(results.count == 1)
        #expect(results.first?.item.title == "Overdue task")
    }

    @Test("An empty query returns nothing rather than everything")
    func emptyQueryReturnsNothing() async throws {
        let fixture = try makeFixture()
        _ = try fixture.items.create(ItemDraft(kind: .note, title: "A note"))
        await fixture.engine.warmIndex()

        #expect(try await fixture.engine.search(SearchQuery(), limit: 50).isEmpty)
    }

    @Test("Saving an item keeps the index current without a rebuild")
    func incrementalIndexUpdate() async throws {
        let fixture = try makeFixture()
        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Original"))
        await fixture.engine.warmIndex()

        try fixture.items.update(note) { $0.title = "Renamed" }
        await fixture.engine.indexDidChange(for: note)

        #expect(try await fixture.engine.search(SearchQueryParser.parse("original"), limit: 5).isEmpty)
        #expect(try await fixture.engine.search(SearchQueryParser.parse("renamed"), limit: 5).count == 1)
    }
}
