import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitSearch
import Foundation
import Testing

/// A search engine whose timing the test controls.
///
/// Real engines are fast and finish in order, which is exactly why they cannot be used to prove
/// what happens when one does not.
@MainActor
final class ScriptedSearchEngine: SearchEngine {
    /// Results to return, keyed by the query's raw text.
    var responses: [String: [SearchResult]] = [:]

    /// How long each query takes, keyed by raw text. Absent means immediate.
    var delays: [String: Duration] = [:]

    /// Raw texts in the order they were asked for.
    private(set) var queriesRun: [String] = []

    var errorToThrow: AppError?

    func search(_ query: SearchQuery, limit: Int) async throws(AppError) -> [SearchResult] {
        queriesRun.append(query.rawText)

        if let delay = delays[query.rawText] {
            // Not cancellation-checked on purpose: the point is to model a slow query that
            // *completes* late, which is what produces an out-of-order response.
            try? await Task.sleep(for: delay)
        }

        if let errorToThrow { throw errorToThrow }
        return Array((responses[query.rawText] ?? []).prefix(limit))
    }

    func titleSuggestions(prefix: String, limit: Int) async -> [(id: UUID, title: String)] { [] }
    func warmIndex() async {}
    func indexDidChange(for item: Item) async {}
    func removeFromIndex(id: UUID) async {}
    func invalidateIndex() async {}

    /// Nothing here indexes, so there is nothing to report. Stated rather than defaulted on the
    /// protocol: a default implementation would let a real engine forget to answer and still compile.
    func indexStatistics() async -> (items: Int, terms: Int, isWarm: Bool) {
        (items: 0, terms: 0, isWarm: false)
    }
}

@MainActor
private func result(_ title: String, kind: ItemKind = .note, score: Double = 1) -> SearchResult {
    SearchResult(item: ItemSnapshot(kind: kind, title: title), score: score)
}

@Suite("Search session")
@MainActor
struct SearchSessionTests {
    private func makeSession(_ engine: ScriptedSearchEngine) -> SearchSessionModel {
        SearchSessionModel(engine: engine)
    }

    /// Waits for the session to settle, without asserting a duration.
    private func settle(_ session: SearchSessionModel, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while session.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("One letter does not run a search")
    func singleLetterDoesNotRun() async throws {
        let engine = ScriptedSearchEngine()
        let session = makeSession(engine)

        session.text = "l"
        await settle(session)

        #expect(engine.queriesRun.isEmpty, "One letter matches nearly everything and means nothing")
        #expect(session.vacancy == .tooShort)
    }

    @Test("An operator-only query runs however short it is")
    func operatorOnlyQueryRuns() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["is:open"] = [result("Something open")]
        let session = makeSession(engine)

        session.text = "is:open"
        await settle(session)

        #expect(engine.queriesRun == ["is:open"])
        #expect(session.results.count == 1)
    }

    @Test("Nothing typed, too short, and no matches are three different states")
    func vacancyStatesAreDistinct() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["nothing here"] = []
        let session = makeSession(engine)

        #expect(session.vacancy == .idle)

        session.text = "n"
        await settle(session)
        #expect(session.vacancy == .tooShort)

        session.text = "nothing here"
        await settle(session)
        #expect(session.vacancy == .noMatches, "A finished search that found nothing is not 'idle'")
    }

    @Test("A slow earlier query cannot overwrite a fast later one")
    func staleResultsAreDiscarded() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["la"] = [result("Broad match")]
        engine.responses["launch"] = [result("Narrow match")]
        // The broad query finishes well after the narrow one that replaced it.
        engine.delays["la"] = .milliseconds(200)

        let session = makeSession(engine)

        session.text = "la"
        session.text = "launch"
        await settle(session)

        // Wait past the slow query's completion, so a stale write would have landed by now.
        try await Task.sleep(for: .milliseconds(300))

        #expect(session.results.map(\.item.title) == ["Narrow match"],
                "Results must never flick back to a query the user has moved past")
    }

    @Test("Scoping to the list keeps only what the list holds")
    func scopeFiltersToTheList() async throws {
        let engine = ScriptedSearchEngine()
        let inList = result("In this list")
        let elsewhere = result("Somewhere else")
        engine.responses["launch"] = [inList, elsewhere]

        let session = makeSession(engine)
        session.listItemIDs = [inList.item.id]
        session.text = "launch"
        await settle(session)
        #expect(session.results.count == 2, "Everywhere is the default")

        session.scope = .thisList
        await settle(session)
        #expect(session.results.map(\.item.id) == [inList.item.id])
    }

    @Test("Clearing removes the results as well as the text")
    func clearingResetsEverything() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["launch"] = [result("A match")]
        let session = makeSession(engine)

        session.text = "launch"
        await settle(session)
        #expect(!session.results.isEmpty)

        session.clear()
        #expect(session.text.isEmpty)
        #expect(session.results.isEmpty)
        #expect(session.vacancy == .idle)
    }

    @Test("Shortening the text below the threshold clears the results it no longer explains")
    func shorteningClearsStaleResults() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["launch"] = [result("A match")]
        let session = makeSession(engine)

        session.text = "launch"
        await settle(session)
        #expect(session.results.count == 1)

        session.text = "l"
        await settle(session)
        #expect(session.results.isEmpty, "Results left on screen for a query no longer being run are a lie")
    }

    @Test("Groups are ordered by their best result, not alphabetically")
    func groupsOrderByRelevance() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["launch"] = [
            result("Best task", kind: .task, score: 90),
            result("Good note", kind: .note, score: 40),
            result("Weaker task", kind: .task, score: 10),
        ]
        let session = makeSession(engine)

        session.text = "launch"
        await settle(session)

        #expect(session.groups.map(\.kind) == [.task, .note])
        #expect(session.orderedResults.map(\.item.title) == ["Best task", "Weaker task", "Good note"])
    }

    @Test("An unreadable fragment is reported rather than dropped")
    func unrecognisedTokensSurface() async throws {
        let engine = ScriptedSearchEngine()
        let session = makeSession(engine)

        session.text = "launch type:nonsense"
        await settle(session)

        #expect(session.unrecognisedTokens == ["type:nonsense"])
    }

    @Test("A failed search reports the error instead of showing an empty list as an answer")
    func failureIsReported() async throws {
        let engine = ScriptedSearchEngine()
        engine.errorToThrow = .invalidQuery(reason: "unreadable")
        let session = makeSession(engine)

        session.text = "launch"
        await settle(session)

        #expect(session.lastError != nil)
        #expect(session.results.isEmpty)
    }

    // MARK: - Keyboard traversal

    /// Three results the traversal tests can walk, in a known on-screen order.
    private func sessionWithResults() async -> SearchSessionModel {
        let engine = ScriptedSearchEngine()
        engine.responses["launch"] = [
            result("Launch plan", kind: .note, score: 3),
            result("Launch checklist", kind: .note, score: 2),
            result("Launch the thing", kind: .task, score: 1),
        ]
        let session = makeSession(engine)
        session.text = "launch"
        await settle(session)
        return session
    }

    @Test("The first press down lands on the best match, so one keystroke reaches it")
    func firstDownHighlightsFirstResult() async {
        let session = await sessionWithResults()
        #expect(session.highlightedID == nil)

        let landed = session.moveHighlight(by: 1)

        #expect(landed?.id == session.orderedResults.first?.id)
        #expect(session.highlightedResult?.id == session.orderedResults.first?.id)
    }

    @Test("The first press up lands on the last result")
    func firstUpHighlightsLastResult() async {
        let session = await sessionWithResults()

        let landed = session.moveHighlight(by: -1)

        #expect(landed?.id == session.orderedResults.last?.id)
    }

    @Test("The highlight walks the flattened order, across the group boundary")
    func highlightWalksAcrossGroups() async {
        let session = await sessionWithResults()
        let ordered = session.orderedResults
        #expect(ordered.count == 3)

        session.moveHighlight(by: 1)
        session.moveHighlight(by: 1)
        session.moveHighlight(by: 1)

        // The third result is a task and the first two are notes, so arriving there at all means the
        // traversal crossed a section header rather than stopping at the end of the first group.
        #expect(session.highlightedID == ordered[2].id)
        #expect(ordered[2].item.kind == .task)
    }

    @Test("The highlight clamps at both ends rather than wrapping and losing the user's place")
    func highlightClamps() async {
        let session = await sessionWithResults()
        let ordered = session.orderedResults

        for _ in 0..<10 { session.moveHighlight(by: 1) }
        #expect(session.highlightedID == ordered.last?.id)

        for _ in 0..<10 { session.moveHighlight(by: -1) }
        #expect(session.highlightedID == ordered.first?.id)
    }

    @Test("A highlight is dropped when the results it pointed into are replaced")
    func highlightIsDroppedWhenResultsChange() async throws {
        let engine = ScriptedSearchEngine()
        engine.responses["launch"] = [result("Launch plan")]
        engine.responses["migration"] = [result("Migration runbook")]
        let session = makeSession(engine)

        session.text = "launch"
        await settle(session)
        session.moveHighlight(by: 1)
        #expect(session.highlightedID != nil)

        session.text = "migration"
        await settle(session)

        // Otherwise the next arrow press starts from a row that is no longer on screen.
        #expect(session.highlightedID == nil)
        #expect(session.highlightedResult == nil)
    }

    @Test("Moving the highlight with nothing to move through does nothing rather than crashing")
    func highlightWithNoResults() async {
        let engine = ScriptedSearchEngine()
        let session = makeSession(engine)
        session.text = "nothing here"
        await settle(session)

        #expect(session.moveHighlight(by: 1) == nil)
        #expect(session.highlightedID == nil)
    }

    @Test("Clearing the session clears the highlight with it")
    func clearDropsHighlight() async {
        let session = await sessionWithResults()
        session.moveHighlight(by: 1)

        session.clear()

        #expect(session.highlightedID == nil)
    }
}
