import ElephruitCore
import Foundation

/// Searching and caching the calendar.
///
/// A protocol with one real implementation, on the same terms as ``SearchEngine``: the feature layer
/// depends on this rather than on SQLite, a test hands in a double, and a future engine is a second
/// conformance rather than a rewrite.
public protocol CalendarSearching: Sendable {
    /// Opens the index, creating it if this is the first run.
    func prepare() async

    /// Replaces the cache for a window with what the calendar currently holds.
    ///
    /// - Parameter calendarIdentifiers: Which calendars the events speak for, so a narrowed fetch
    ///   does not discard rows it never asked about.
    func absorb(
        _ events: [CalendarEventSummary],
        inWindow window: Range<Date>,
        calendarIdentifiers: [String]?,
        links: [String: IndexedEventLinks]
    ) async

    /// Updates one event, for a change that arrived on its own.
    func absorb(_ event: CalendarEventSummary, links: IndexedEventLinks?) async

    /// Removes an event from the cache.
    func forget(identityKey: String) async

    /// What the cache holds for a window, for showing something when the calendar cannot be read.
    func cachedEvents(in window: Range<Date>, calendarIdentifiers: [String]?) async -> [IndexedEvent]

    /// Runs a query.
    func search(_ text: String, now: Date, calendar: Calendar, limit: Int) async -> CalendarSearchResults

    /// Throws the cache away. The next absorb rebuilds it.
    func invalidate() async

    func statistics() async -> (events: Int, lastIndexedAt: Date?)
}

/// What a search found, and what it understood.
public struct CalendarSearchResults: Sendable, Hashable {
    public var query: EventSearchQuery
    public var events: [IndexedEvent]

    /// Whether the index was readable at all. `false` means the results are empty because something
    /// failed rather than because nothing matched — a distinction the empty state has to make.
    public var isIndexAvailable: Bool

    public init(query: EventSearchQuery, events: [IndexedEvent], isIndexAvailable: Bool = true) {
        self.query = query
        self.events = events
        self.isIndexAvailable = isIndexAvailable
    }

    public var isEmpty: Bool { events.isEmpty }
}

/// The FTS5 implementation.
public final class FTSCalendarSearchEngine: CalendarSearching {
    private let store: CalendarIndexStore

    public init(indexURL: URL) {
        self.store = CalendarIndexStore(url: indexURL)
    }

    public func prepare() async {
        do {
            try await store.open()
        } catch {
            Diagnostics.search.error("Calendar index could not be opened: \(error.summary, privacy: .public)")
        }
    }

    public func absorb(
        _ events: [CalendarEventSummary],
        inWindow window: Range<Date>,
        calendarIdentifiers: [String]?,
        links: [String: IndexedEventLinks]
    ) async {
        do {
            try await store.open()
            try await store.replace(
                events,
                inWindow: window,
                calendarIdentifiers: calendarIdentifiers,
                links: links,
                at: Date()
            )
        } catch {
            // A cache that could not be written is a slower app, not a broken one: the calendar
            // itself is unaffected and the next window refresh tries again.
            Diagnostics.search.error("Calendar index write failed: \(error.summary, privacy: .public)")
        }
    }

    public func absorb(_ event: CalendarEventSummary, links: IndexedEventLinks?) async {
        do {
            try await store.open()
            try await store.upsert(event, links: links, at: Date())
        } catch {
            Diagnostics.search.error("Calendar index update failed: \(error.summary, privacy: .public)")
        }
    }

    public func forget(identityKey: String) async {
        do {
            try await store.open()
            try await store.remove(identityKey: identityKey)
        } catch {
            Diagnostics.search.error("Calendar index removal failed: \(error.summary, privacy: .public)")
        }
    }

    public func cachedEvents(in window: Range<Date>, calendarIdentifiers: [String]?) async -> [IndexedEvent] {
        do {
            try await store.open()
            return try await store.events(in: window, calendarIdentifiers: calendarIdentifiers)
        } catch {
            Diagnostics.search.error("Calendar cache read failed: \(error.summary, privacy: .public)")
            return []
        }
    }

    public func search(
        _ text: String,
        now: Date,
        calendar: Calendar,
        limit: Int = 200
    ) async -> CalendarSearchResults {
        let query = EventSearchParser.parse(text, now: now, calendar: calendar)
        guard !query.isEmpty else { return CalendarSearchResults(query: query, events: []) }

        do {
            try await store.open()
            let events = try await store.search(query, now: now, limit: limit)
            return CalendarSearchResults(query: query, events: events)
        } catch {
            Diagnostics.search.error("Calendar search failed: \(error.summary, privacy: .public)")
            return CalendarSearchResults(query: query, events: [], isIndexAvailable: false)
        }
    }

    public func invalidate() async {
        do {
            try await store.destroy()
        } catch {
            Diagnostics.search.error("Calendar index could not be cleared: \(error.summary, privacy: .public)")
        }
    }

    public func statistics() async -> (events: Int, lastIndexedAt: Date?) {
        do {
            try await store.open()
            return try await store.statistics()
        } catch {
            return (0, nil)
        }
    }
}

// MARK: - Highlighting

extension IndexedEvent {
    /// The snippet's marked runs, as ranges into a plain string.
    ///
    /// FTS5 marks matches with sentinel characters chosen so they cannot occur in a calendar — the
    /// same arrangement `SearchResult` uses — and this turns them into ranges so a view can style
    /// them without parsing anything.
    public var highlightedSnippet: (text: String, matches: [Range<String.Index>])? {
        guard let snippet else { return nil }

        var plain = ""
        var matches: [Range<String.Index>] = []
        var openIndex: String.Index?

        for character in snippet {
            switch character {
            case "\u{2}":
                openIndex = plain.endIndex
            case "\u{3}":
                if let start = openIndex { matches.append(start..<plain.endIndex) }
                openIndex = nil
            default:
                plain.append(character)
            }
        }

        return (text: plain, matches: matches)
    }
}
