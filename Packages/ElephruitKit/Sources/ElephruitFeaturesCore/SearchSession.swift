import ElephruitCore
import ElephruitSearch
import Foundation
import Observation

/// What a search covers.
///
/// Two scopes rather than two fields. The previous version had a "Filter this list" box *and* a
/// separate search sheet that looked the same and behaved differently — which is the confusion this
/// removes. One field; the scope is a visible, first-party control on it.
public enum SearchScope: String, Sendable, Hashable, CaseIterable {
    case everywhere
    case thisList

    public func displayName(listTitle: String) -> String {
        switch self {
        case .everywhere: "Everywhere"
        case .thisList: listTitle
        }
    }
}

/// One window's live search.
///
/// Separate from the view so that debouncing, staleness, scoping and grouping can be tested without
/// a window — and so the list view stays a rendering of state rather than a place where search
/// happens to be implemented.
@Observable
@MainActor
public final class SearchSessionModel {
    /// What the user has typed. The raw text, kept verbatim, so a saved search round-trips exactly.
    public var text = "" {
        didSet { if text != oldValue { textDidChange() } }
    }

    public var scope: SearchScope = .everywhere {
        didSet { if scope != oldValue { scheduleRun() } }
    }

    public private(set) var results: [SearchResult] = []

    /// True from the first keystroke until results for *that* text have landed.
    ///
    /// Distinct from "no results": a spinner and an empty state answer different questions, and
    /// showing the second while the first is true is how a user concludes their note is missing.
    public private(set) var isRunning = false

    /// True once a run has completed for the current text.
    public private(set) var hasRun = false

    public private(set) var lastError: AppError?

    /// Rejects a stale response.
    ///
    /// Queries are fired per keystroke and may return out of order — a broad "l" can easily finish
    /// after the narrow "launch" that followed it. Without this, results visibly flick backwards to
    /// a query the user has already moved past.
    private var generation = 0

    private var runTask: Task<Void, Never>?

    /// Identifiers of the current list, for ``SearchScope/thisList``.
    ///
    /// Supplied by the view because the list has already loaded them. Searching a scope should not
    /// mean fetching it a second time.
    public var listItemIDs: Set<UUID> = []

    private let engine: any SearchEngine
    private let limit: Int

    public init(engine: any SearchEngine, limit: Int = 200) {
        self.engine = engine
        self.limit = limit
    }

    // MARK: - Query

    public var query: SearchQuery {
        SearchQueryParser.parse(text)
    }

    /// Fragments the parser did not understand, for the amber note under the field.
    public var unrecognisedTokens: [String] {
        query.unrecognisedTokens
    }

    /// Whether the text is worth running.
    ///
    /// A single letter matches most of a library and ranks the whole match set to show two hundred
    /// rows — expensive, and never what anyone meant. Two characters is the threshold. A query made
    /// only of operators (`is:open`) is always worth running, however short.
    public var isRunnable: Bool {
        let parsed = query
        if parsed.hasStructuralFilters { return true }
        return parsed.terms.contains { $0.count >= 2 }
    }

    /// What to tell the user when there is nothing to show.
    public enum Vacancy: Sendable, Hashable {
        /// Nothing typed yet.
        case idle
        /// Typed, but not yet enough to run.
        case tooShort
        /// Ran, found nothing.
        case noMatches
        /// Not vacant — there are results, or a run is in flight.
        case none
    }

    public var vacancy: Vacancy {
        if !results.isEmpty || isRunning { return .none }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .idle }
        if !isRunnable { return .tooShort }
        return hasRun ? .noMatches : .idle
    }

    // MARK: - Running

    private func textDidChange() {
        scheduleRun(debounced: true)
    }

    /// Starts a run, optionally after letting the typing settle.
    ///
    /// Cancelling the previous task was never enough on its own: cancellation is cooperative,
    /// and a query handed to the search actor is already queued behind whatever else is in
    /// there. Typing eight characters put eight searches into that queue and cancelled seven of
    /// them too late to matter. Waiting first means only the query somebody stopped typing ever
    /// reaches the engine.
    ///
    /// A scope change is not debounced — that is one deliberate act, not a stream of them.
    private func scheduleRun(debounced: Bool = false) {
        runTask?.cancel()

        guard isRunnable else {
            // Cancelling leaves stale results on screen for a query that is no longer being run,
            // which would be a lie about what matched.
            results = []
            highlightedID = nil
            isRunning = false
            hasRun = false
            return
        }

        isRunning = true
        generation += 1
        let mine = generation

        runTask = Task { [weak self] in
            guard let self else { return }
            if debounced {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await run(generation: mine)
        }
    }

    private func run(generation mine: Int) async {
        let parsed = query
        let scope = scope

        do {
            // Over-fetch when scoped, because filtering to the list happens after ranking and would
            // otherwise return a short page that looks like the whole answer.
            let requested = scope == .thisList ? limit * 5 : limit
            var found = try await engine.search(parsed, limit: requested)

            if scope == .thisList {
                let allowed = listItemIDs
                found = found.filter { allowed.contains($0.id) }
            }

            guard mine == generation else { return }
            results = Array(found.prefix(limit))
            lastError = nil
            // A highlight that survives into a different result set points at a row that is no longer
            // there, and the next arrow press starts from nowhere.
            if let highlightedID, !results.contains(where: { $0.id == highlightedID }) {
                self.highlightedID = nil
            }
        } catch {
            guard mine == generation else { return }
            results = []
            highlightedID = nil
            lastError = error
        }

        guard mine == generation else { return }
        isRunning = false
        hasRun = true
    }

    /// Runs immediately, ignoring any in-flight query. For Return in the search field.
    public func runNow() {
        scheduleRun()
    }

    public func clear() {
        runTask?.cancel()
        runTask = nil
        text = ""
        results = []
        highlightedID = nil
        isRunning = false
        hasRun = false
        lastError = nil
    }

    // MARK: - Presentation

    /// Results grouped by kind, most relevant group first.
    ///
    /// Grouped rather than one flat list because the kinds mean different things: five tasks and one
    /// note is a different answer from six results, and the shape of the answer is information.
    public var groups: [ResultGroup] {
        Dictionary(grouping: results, by: \.item.kind)
            .map { ResultGroup(kind: $0.key, results: $0.value) }
            .sorted { left, right in
                let leftBest = left.results.first?.score ?? 0
                let rightBest = right.results.first?.score ?? 0
                return leftBest == rightBest
                    ? left.kind.rawValue < right.kind.rawValue
                    : leftBest > rightBest
            }
    }

    public struct ResultGroup: Identifiable, Sendable, Hashable {
        public let kind: ItemKind
        public let results: [SearchResult]
        public var id: ItemKind { kind }
    }

    /// The results in the order they appear on screen, for keyboard traversal.
    public var orderedResults: [SearchResult] {
        groups.flatMap(\.results)
    }

    // MARK: - Keyboard traversal

    /// The result the keyboard is on.
    ///
    /// Separate from whatever the detail pane is showing. Moving through results with the arrow keys
    /// should change what is highlighted here and what is shown there, and pressing Return should
    /// move *focus* into the detail — three things that are one thing only if the highlight and the
    /// selection are the same value, which is how arrowing to the second result used to hand focus
    /// away and strand the traversal after one step.
    public private(set) var highlightedID: UUID?

    public var highlightedResult: SearchResult? {
        guard let highlightedID else { return nil }
        return orderedResults.first { $0.id == highlightedID }
    }

    /// Puts the highlight on a specific result — for a click, or for the list's own selection.
    public func highlight(_ id: UUID?) {
        highlightedID = id
    }

    /// Moves the highlight `offset` rows through the flattened result order.
    ///
    /// Returns the result now highlighted, or `nil` when there is nothing to move to. Clamps at both
    /// ends rather than wrapping: a list that jumps from the last row back to the first loses the
    /// user's place, and there is no scrollbar in a keyboard traversal to tell them it happened.
    ///
    /// With nothing highlighted yet, the first press lands on the first row going down and the last
    /// row going up, so a single Down out of the search field always reaches the best match.
    @discardableResult
    public func moveHighlight(by offset: Int) -> SearchResult? {
        let ordered = orderedResults
        guard !ordered.isEmpty else {
            highlightedID = nil
            return nil
        }

        guard let current = highlightedID,
              let index = ordered.firstIndex(where: { $0.id == current })
        else {
            let landing = offset >= 0 ? ordered.startIndex : ordered.index(before: ordered.endIndex)
            highlightedID = ordered[landing].id
            return ordered[landing]
        }

        let next = min(max(index + offset, ordered.startIndex), ordered.index(before: ordered.endIndex))
        highlightedID = ordered[next].id
        return ordered[next]
    }

    /// A one-line summary of what the query means, for the field's subtitle.
    public var explanation: String {
        SearchQueryParser.describe(query)
    }

    public var resultSummary: String {
        switch results.count {
        case 0: "No results"
        case 1: "1 result"
        default: "\(results.count) results"
        }
    }
}
