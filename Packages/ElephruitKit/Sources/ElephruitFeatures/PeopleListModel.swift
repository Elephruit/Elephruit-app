import ElephruitCore
import ElephruitModel
import Foundation
import Observation

/// Everything the contact list needs to draw itself, computed when the inputs change and not before.
///
/// ### Why this is not computed in the view
/// Because a SwiftUI `body` runs whenever anything it reads changes — a selection, a hover, a window
/// resize, the ticking of the clock behind a relative date — and sorting and sectioning eight
/// thousand people on each of those is the difference between a list that scrolls and one that
/// stutters. The rule is stated in the brief and it is the right one: nothing here re-sorts on a
/// render, a keystroke, a selection change, or a synchronisation notification. It re-sorts when the
/// people change, when the order changes, or when the search changes what is in the list — and each
/// of those is an explicit call.
///
/// ### Why the search is cancellable and the sectioning is not
/// Search runs against an index and can take long enough to be worth interrupting; a keystroke that
/// arrives while the previous query is still running should abandon it rather than queue behind it.
/// Sectioning is arithmetic over an array that is already in memory and finishes in single-digit
/// milliseconds for a list nobody has, so making it asynchronous would buy latency and a class of
/// ordering bug in exchange for nothing.
@MainActor
@Observable
public final class PeopleListModel {
    /// The people in the scope, before any search.
    public private(set) var people: [Item] = []

    /// What the list is showing, cut into headed sections.
    public private(set) var sections: [PersonListSection] = []

    /// Why each person matched, when a search is what put them in the list.
    public private(set) var matchReasons: [UUID: String] = [:]

    public private(set) var isSearching = false

    /// The failure that stopped the last load, if one did.
    public private(set) var loadFailure: AppError?

    public var sort: PersonListSort = .firstName {
        didSet {
            guard sort != oldValue else { return }
            rebuildSections()
        }
    }

    /// The record behind each row, so the view does not have to look one up per row per render.
    private var peopleByID: [UUID: Item] = [:]

    /// When each person was last spoken to. Empty unless the list is ordered by it.
    private var lastInteraction: [UUID: Date] = [:]

    /// The search results in rank order, or `nil` when no search is running.
    private var searchResults: [UUID]?

    private let locale: Locale
    private let dateProvider: any DateProvider

    public init(locale: Locale = .current, dateProvider: any DateProvider = SystemDateProvider()) {
        self.locale = locale
        self.dateProvider = dateProvider
    }

    // MARK: - Input

    /// Replaces the scope's people and rebuilds.
    ///
    /// - Parameter lastInteraction: when each person was last spoken to, needed only by
    ///   ``PersonListSort/recentInteraction``. Passed in rather than looked up here because working
    ///   it out means walking everything that mentions somebody, and doing that for two thousand
    ///   people to draw a list ordered alphabetically would be a second of work nobody asked for.
    public func setPeople(
        _ people: [Item],
        failure: AppError? = nil,
        lastInteraction: [UUID: Date] = [:]
    ) {
        self.people = people
        self.loadFailure = failure
        self.lastInteraction = lastInteraction
        peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildSections()
    }

    /// Narrows the list to a ranked search result. `nil` clears the search.
    public func setSearchResults(_ results: [(id: UUID, reason: String?)]?) {
        guard let results else {
            searchResults = nil
            matchReasons = [:]
            isSearching = false
            rebuildSections()
            return
        }

        searchResults = results.map(\.id)
        matchReasons = Dictionary(
            results.compactMap { result in result.reason.map { (result.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        isSearching = true
        rebuildSections()
    }

    public func person(id: UUID) -> Item? { peopleByID[id] }

    // MARK: - Output

    /// Every heading, in order — what the jump strip shows.
    public var sectionTitles: [String] { sections.map(\.title) }

    public var isEmpty: Bool { sections.isEmpty }

    /// Every person on screen, in the order they are drawn.
    ///
    /// What arrow keys, Home, End and Page Up traverse: the sections are a visual grouping and the
    /// keyboard must not have to know about them.
    public var flattenedIDs: [UUID] { sections.flatMap { $0.entries.map(\.id) } }

    /// The person a typed prefix should reach.
    public func entry(matching typed: String) -> UUID? {
        PersonListOrganiser.entry(matching: typed, in: sections, sort: sort, locale: locale)?.id
    }

    /// The heading a jump should land on, which may not be the one under the pointer.
    public func section(nearest title: String) -> String? {
        PersonListOrganiser.section(nearest: title, in: sections, locale: locale)?.title
    }

    /// Which section a person is in, so a selection restored from elsewhere can be scrolled to.
    public func sectionTitle(containing id: UUID) -> String? {
        sections.first { section in section.entries.contains { $0.id == id } }?.title
    }

    // MARK: - Building

    private func rebuildSections() {
        // A search has already ranked its results, and re-sorting them alphabetically would throw
        // away the only thing that made them results. They stay in rank order under one heading that
        // says so — a list of matches is not an address book and should not pretend to be one.
        if let searchResults {
            let matched = searchResults.compactMap { peopleByID[$0] }.map(entry(for:))
            sections = matched.isEmpty ? [] : [PersonListSection(title: "Matches", entries: matched)]
            return
        }

        sections = PersonListOrganiser.sections(
            people.map(entry(for:)),
            by: sort,
            locale: locale,
            now: dateProvider.now
        )
    }

    private func entry(for person: Item) -> PersonListEntry {
        PersonListEntry(
            id: person.id,
            displayName: person.displayTitle,
            organizationName: person.personProfile?.organizationName,
            lastInteraction: lastInteraction[person.id]
        )
    }
}

/// Letters typed into a focused list, accumulated until the user stops.
///
/// ### Why a buffer rather than one keystroke at a time
/// Because `m`, `a`, `y` typed quickly means Maya and typed slowly means three separate attempts to
/// reach M, then A, then Y. Every list in macOS works this way and the interval is the same one the
/// system uses; getting it wrong in either direction is immediately obvious — too short and nobody
/// can type a whole name, too long and pressing `s` twice never reaches the second S.
///
/// A value type, so the timing rule can be asserted with a clock the test controls rather than
/// waited on.
public struct TypeToSelectBuffer: Sendable, Hashable {
    /// How long a keystroke keeps the buffer alive. AppKit's own type-select uses the same figure.
    public static let interval: TimeInterval = 0.75

    public private(set) var text: String = ""
    private var lastKeystroke: Date?

    public init() {}

    /// Adds a character and returns what should now be searched for.
    public mutating func append(_ character: Character, at time: Date) -> String {
        if let lastKeystroke, time.timeIntervalSince(lastKeystroke) > Self.interval {
            text = ""
        }
        lastKeystroke = time
        text.append(character)
        return text
    }

    /// Whether the buffer has gone stale, so the view can stop showing what was typed.
    public func hasExpired(at time: Date) -> Bool {
        guard let lastKeystroke else { return true }
        return time.timeIntervalSince(lastKeystroke) > Self.interval
    }

    public mutating func clear() {
        text = ""
        lastKeystroke = nil
    }
}
