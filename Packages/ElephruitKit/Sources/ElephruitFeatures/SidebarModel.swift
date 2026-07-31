import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// One fixed row in the sidebar.
///
/// Fixed as opposed to *derived*: Today and Notes are declared here, whereas a pinned project or a tag
/// comes from the store. Both kinds of row render identically; only their source differs.
public struct SidebarDestination: Identifiable, Hashable, Sendable {
    /// Which band a destination belongs to.
    ///
    /// The bands are the whole point of the redesign: the previous sidebar mixed *where I work* with
    /// *where things are filed* in one undifferentiated list, which is what made it read as a file
    /// browser rather than a workspace.
    public enum Band: Int, Hashable, Sendable, CaseIterable {
        /// The three views a day is actually worked in. No header — it is simply where you are.
        case primary

        /// What the user chose to keep close. Absent entirely when empty.
        case pinned

        /// Everything else, collapsible.
        case library
    }

    public var id: String
    public var selection: SidebarSelection
    public var band: Band
    public var title: String
    public var symbolName: String

    /// The tooltip, shown once the pointer has rested on the row.
    ///
    /// It says what the destination *holds*, never what it is called — a tooltip that repeats the
    /// label already on screen is a delay followed by nothing. "Upcoming" is a word; "dated work,
    /// ahead of today" is the rule that decides what appears there, and that rule is the part a
    /// user cannot infer from the row.
    public var hint: String

    /// Whether this destination shows a count. Only Today and Inbox do.
    public var showsCount: Bool

    /// Whether the destination's title may be truncated at narrow widths.
    ///
    /// `false` for primary navigation: an ambiguous "Proj…" is worse than a wider sidebar, so the
    /// sidebar's minimum width is derived from these rather than these being cut to fit it.
    public var mayTruncate: Bool

    /// Whether this destination exists in this build.
    ///
    /// Unavailable destinations are **not enumerated anywhere** — not in the sidebar, not in a
    /// customisation screen, not in a menu. A roadmap is not something the interface should make the
    /// user look at.
    public var isAvailable: Bool

    public init(
        id: String,
        selection: SidebarSelection,
        band: Band,
        title: String,
        symbolName: String,
        hint: String,
        showsCount: Bool = false,
        mayTruncate: Bool = false,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.selection = selection
        self.band = band
        self.title = title
        self.symbolName = symbolName
        self.hint = hint
        self.showsCount = showsCount
        self.mayTruncate = mayTruncate
        self.isAvailable = isAvailable
    }
}

/// The declared set of fixed destinations.
///
/// Future destinations are declared here with `isAvailable: false` so that the phase which builds them
/// flips one flag rather than editing the sidebar. Because the accessors filter on availability, the
/// declaration never reaches the interface.
public enum SidebarRegistry {
    /// Every declared destination, available or not. For tests and for the phase that enables one.
    public static let allDeclared: [SidebarDestination] = [
        // MARK: Primary

        // Available as of Phase E, and first, because it answers the question you have when you
        // open the app rather than one you go looking for.
        SidebarDestination(
            id: "home",
            selection: .home,
            band: .primary,
            title: "Home",
            symbolName: "house",
            hint: "Where the day starts: what is due, what is running, and what came in."
        ),

        SidebarDestination(
            id: "today",
            selection: .today,
            band: .primary,
            title: "Today",
            symbolName: "circle.circle",
            hint: "Due today, plus anything already overdue.",
            showsCount: true
        ),
        SidebarDestination(
            id: "upcoming",
            selection: .upcoming,
            band: .primary,
            title: "Upcoming",
            symbolName: "calendar",
            hint: "Dated work, ahead of today."
        ),
        SidebarDestination(
            id: "inbox",
            selection: .inbox,
            band: .primary,
            title: "Inbox",
            symbolName: "tray",
            hint: "Captured and not yet filed. Empty is the goal.",
            showsCount: true
        ),

        // MARK: Library

        SidebarDestination(
            id: "notes",
            selection: .kind(.note),
            band: .library,
            title: "Notes",
            symbolName: "note.text",
            hint: "Every note in the library, newest first."
        ),
        SidebarDestination(
            id: "projects",
            selection: .kind(.project),
            band: .library,
            title: "Projects",
            symbolName: "square.stack.3d.up",
            hint: "Work with an outcome and an end."
        ),
        SidebarDestination(
            id: "areas",
            selection: .kind(.area),
            band: .library,
            title: "Areas",
            symbolName: "square.grid.2x2",
            hint: "Standing responsibilities, which never finish."
        ),
        // Superseded by `PeopleSidebarSection`, which is a band of its own.
        //
        // Declared rather than deleted, on the same terms as every other unavailable destination: a
        // scene restored from a build that predates the People module still decodes, and the row is
        // never enumerated because the accessors filter on availability. A flat `.kind(.person)` list
        // answers "who do I know" and none of the questions people actually arrive with.
        SidebarDestination(
            id: "people",
            selection: .kind(.person),
            band: .library,
            title: "People",
            symbolName: "person",
            hint: "Everybody in the library, as a flat list.",
            isAvailable: false
        ),
        SidebarDestination(
            id: "bookmarks",
            selection: .kind(.bookmark),
            band: .library,
            title: "Bookmarks",
            symbolName: "bookmark",
            hint: "Links kept for later."
        ),
        SidebarDestination(
            id: "archive",
            selection: .archive,
            band: .library,
            title: "Archive",
            symbolName: "archivebox",
            hint: "Finished, kept, and out of the way of today."
        ),
        SidebarDestination(
            id: "trash",
            selection: .trash,
            band: .library,
            title: "Trash",
            symbolName: "trash",
            hint: "Deleted, and recoverable until you empty it."
        ),

        // Available as of the calendar module. In the primary band, because a calendar is where a
        // day is worked rather than somewhere work is filed — the same argument that puts Today
        // above Notes.
        SidebarDestination(
            id: "calendar",
            selection: .calendar,
            band: .primary,
            title: "Calendar",
            symbolName: "calendar.day.timeline.left",
            hint: "Your days, laid out, and everything you know about them."
        ),

        // Available as of Phase C. In the Library band rather than the top one, by decision: time is
        // something you look *back* at, and the top band is for what you are doing now.
        SidebarDestination(
            id: "time",
            selection: .time,
            band: .library,
            title: "Time",
            symbolName: "timer",
            hint: "Tracked time, and what it went on."
        ),
    ]

    /// Available destinations in a band, in display order.
    public static func destinations(in band: SidebarDestination.Band) -> [SidebarDestination] {
        allDeclared.filter { $0.isAvailable && $0.band == band }
    }

    /// Every available destination, in display order. Drives `⌘1`–`⌘9`.
    public static var available: [SidebarDestination] {
        SidebarDestination.Band.allCases.flatMap { destinations(in: $0) }
    }

    /// The destination a numeric shortcut selects, if any.
    ///
    /// Derived from the visible order, so the shortcut always matches what the user can see.
    public static func destination(forShortcutIndex index: Int) -> SidebarDestination? {
        let ordered = destinations(in: .primary) + destinations(in: .library)
        guard index >= 1, index <= ordered.count else { return nil }
        return ordered[index - 1]
    }

    /// Titles that must never be truncated, so the sidebar's minimum width can be derived from them.
    public static var nonTruncatingTitles: [String] {
        available.filter { !$0.mayTruncate }.map(\.title)
    }
}

/// A row derived from the store rather than declared: a pinned item, a tag, or a saved search.
public struct SidebarDerivedRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var selection: SidebarSelection
    public var title: String
    public var symbolName: String
    public var colorName: String?
    public var count: Int?

    /// Indentation level, for hierarchical tags. Shown by inset rather than by repeating the path.
    public var depth: Int

    public init(
        id: String,
        selection: SidebarSelection,
        title: String,
        symbolName: String,
        colorName: String? = nil,
        count: Int? = nil,
        depth: Int = 0
    ) {
        self.id = id
        self.selection = selection
        self.title = title
        self.symbolName = symbolName
        self.colorName = colorName
        self.count = count
        self.depth = depth
    }
}

/// Everything the sidebar needs, computed away from the view.
///
/// The view reads stored values and performs **no** store access while rendering. That is the primary
/// Phase A1 acceptance criterion, and `FetchAudit` is what proves it rather than a stopwatch.
@Observable
@MainActor
public final class SidebarModel {
    public private(set) var pinned: [SidebarDerivedRow] = []
    public private(set) var tags: [SidebarDerivedRow] = []
    public private(set) var savedSearches: [SidebarDerivedRow] = []

    /// How many tags the disclosure group shows before deferring to "All Tags…".
    ///
    /// Bounded on purpose: an unbounded list of every tag ever created turns the sidebar into a scroll
    /// pit, which is one of the things wrong with the current one.
    public static let visibleTagLimit = 8
    public static let visibleSavedSearchLimit = 6

    /// `true` when there are more tags than the disclosure group shows.
    public private(set) var hasMoreTags = false
    public private(set) var hasMoreSavedSearches = false

    @ObservationIgnored private let items: any ItemRepository
    @ObservationIgnored private let tagsRepository: TagRepository
    @ObservationIgnored private let savedSearchProvider: () -> [SavedSearch]

    public init(
        items: any ItemRepository,
        tags: TagRepository,
        savedSearchProvider: @escaping () -> [SavedSearch]
    ) {
        self.items = items
        self.tagsRepository = tags
        self.savedSearchProvider = savedSearchProvider
    }

    /// Recomputes the derived rows. Called on change, never during rendering.
    public func refresh() {
        pinned = computePinned()
        (tags, hasMoreTags) = computeTags()
        (savedSearches, hasMoreSavedSearches) = computeSavedSearches()
    }

    private func computePinned() -> [SidebarDerivedRow] {
        var query = ItemQuery()
        query.isPinned = true
        query.sort = .titleAscending

        guard let items = try? items.items(matching: query) else { return [] }

        return items.map { item in
            SidebarDerivedRow(
                id: "pin.\(item.id.uuidString)",
                selection: .item(id: item.id),
                title: item.displayTitle,
                symbolName: item.effectiveSymbolName,
                colorName: item.colorName
            )
        }
    }

    private func computeTags() -> ([SidebarDerivedRow], Bool) {
        guard let all = try? tagsRepository.allTags() else { return ([], false) }

        // Most-used first, then alphabetical — so the eight shown are the eight worth showing.
        let ranked = all
            .filter { $0.activeItemCount > 0 }
            .sorted { left, right in
                left.activeItemCount == right.activeItemCount
                    ? left.slug < right.slug
                    : left.activeItemCount > right.activeItemCount
            }

        let visible = ranked.prefix(Self.visibleTagLimit).map { tag in
            SidebarDerivedRow(
                id: "tag.\(tag.slug)",
                selection: .tag(slug: tag.slug),
                title: tag.leafName,
                symbolName: "number",
                colorName: tag.colorName,
                count: tag.activeItemCount,
                depth: 0
            )
        }

        return (Array(visible), ranked.count > Self.visibleTagLimit)
    }

    private func computeSavedSearches() -> ([SidebarDerivedRow], Bool) {
        let all = savedSearchProvider()

        let visible = all.prefix(Self.visibleSavedSearchLimit).map { search in
            SidebarDerivedRow(
                id: "search.\(search.id.uuidString)",
                selection: .savedSearch(id: search.id),
                title: search.displayName,
                symbolName: search.effectiveSymbolName,
                colorName: search.colorName
            )
        }

        return (Array(visible), all.count > Self.visibleSavedSearchLimit)
    }
}
