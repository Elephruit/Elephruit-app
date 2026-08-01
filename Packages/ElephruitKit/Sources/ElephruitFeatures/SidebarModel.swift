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
    /// The bands are the whole point of the redesign: the top of the sidebar answers *where am I in
    /// my day*, and everything else is inside a module. A destination in the `.module` band is
    /// **never** drawn at the top level — it appears only once its module has been entered, which is
    /// what keeps ten features' navigation from being on screen at the same time.
    public enum Band: Int, Hashable, Sendable, CaseIterable {
        /// The four destinations that belong to no module. No header — it is simply where you are.
        case primary

        /// What the user chose to keep close. Absent entirely when empty.
        case pinned

        /// Inside a module, and reachable only from within it.
        case module
    }

    public var id: String
    public var selection: SidebarSelection
    public var band: Band

    /// The module this destination lives in, for a `.module`-band row.
    ///
    /// `nil` for the primary band, which is what "belongs to no module" means here.
    public var module: AppModule?

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
        module: AppModule? = nil,
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
        self.module = module
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
        //
        // The two destinations that belong to no module, in the order they are read in. Everything
        // else moved inside a module when the sidebar was rebuilt around them.

        // First, because it answers the question you have when you open the app rather than one you
        // go looking for.
        SidebarDestination(
            id: "today",
            selection: .today,
            band: .primary,
            title: "Today",
            symbolName: "sun.max",
            hint: "Your day: what needs doing, who you are seeing, and what is coming.",
            showsCount: true
        ),

        // Superseded by the row above, which is the two of them joined.
        //
        // Declared rather than deleted, on the same terms as every other unavailable destination: a
        // scene restored from a build that had them still decodes, the accessors filter on
        // availability so neither is ever enumerated, and `SidebarSelection.canonical` lands anybody
        // who arrives by an old link on Today.
        SidebarDestination(
            id: "home",
            selection: .home,
            band: .primary,
            title: "Home",
            symbolName: "house",
            hint: "Where the day starts: what is due, what is running, and what came in.",
            isAvailable: false
        ),
        SidebarDestination(
            id: "upcoming",
            selection: .upcoming,
            band: .primary,
            title: "Upcoming",
            symbolName: "calendar",
            hint: "Dated work of every kind, ahead of today.",
            isAvailable: false
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

        // MARK: Inside a module
        //
        // Each of these is the front door of its module. It is drawn only once that module has been
        // entered, which is the difference between this sidebar and the one it replaced.

        SidebarDestination(
            id: "notes",
            selection: .kind(.note),
            band: .module,
            module: .notes,
            title: "All Notes",
            symbolName: "note.text",
            hint: "Every note in the library, newest first."
        ),
        SidebarDestination(
            id: "ideas",
            selection: .kind(.idea),
            band: .module,
            module: .notes,
            title: "Ideas",
            symbolName: "lightbulb",
            hint: "Half-formed on purpose. Nothing here is late."
        ),
        SidebarDestination(
            id: "references",
            selection: .kind(.reference),
            band: .module,
            module: .notes,
            title: "Reference",
            symbolName: "books.vertical",
            hint: "Kept to look up rather than to act on."
        ),
        SidebarDestination(
            id: "daily",
            selection: .kind(.dailyEntry),
            band: .module,
            module: .notes,
            title: "Daily Notes",
            symbolName: "sun.horizon",
            hint: "One entry per day, in the order the days happened."
        ),
        SidebarDestination(
            id: "projects",
            selection: .kind(.project),
            band: .module,
            module: .projects,
            title: "All Projects",
            symbolName: "square.stack.3d.up",
            hint: "Work with an outcome and an end."
        ),
        SidebarDestination(
            id: "areas",
            selection: .kind(.area),
            band: .module,
            module: .areas,
            title: "All Areas",
            symbolName: "square.grid.2x2",
            hint: "Standing responsibilities, which never finish."
        ),
        // Superseded by `PeopleSidebarSection`, which is the People module's own sidebar.
        //
        // Declared rather than deleted, on the same terms as every other unavailable destination: a
        // scene restored from a build that predates the People module still decodes, and the row is
        // never enumerated because the accessors filter on availability. A flat `.kind(.person)` list
        // answers "who do I know" and none of the questions people actually arrive with.
        SidebarDestination(
            id: "people",
            selection: .kind(.person),
            band: .module,
            module: .people,
            title: "People",
            symbolName: "person",
            hint: "Everybody in the library, as a flat list.",
            isAvailable: false
        ),
        SidebarDestination(
            id: "bookmarks",
            selection: .kind(.bookmark),
            band: .module,
            module: .bookmarks,
            title: "All Bookmarks",
            symbolName: "bookmark",
            hint: "Links kept for later."
        ),
        SidebarDestination(
            id: "archive",
            selection: .archive,
            band: .module,
            module: .archive,
            title: "Everything Archived",
            symbolName: "archivebox",
            hint: "Finished, kept, and out of the way of today."
        ),
        SidebarDestination(
            id: "trash",
            selection: .trash,
            band: .module,
            module: .trash,
            title: "Deleted Items",
            symbolName: "trash",
            hint: "Deleted, and recoverable until you empty it."
        ),
        SidebarDestination(
            id: "calendar",
            selection: .calendar,
            band: .module,
            module: .calendar,
            title: "Calendar",
            symbolName: "calendar.day.timeline.left",
            hint: "Your days, laid out, and everything you know about them."
        ),
        SidebarDestination(
            id: "time",
            selection: .time,
            band: .module,
            module: .time,
            title: "Tracked Time",
            symbolName: "timer",
            hint: "Tracked time, and what it went on."
        ),
    ]

    /// Available destinations in a band, in display order.
    public static func destinations(in band: SidebarDestination.Band) -> [SidebarDestination] {
        destinationsByBand[band] ?? []
    }

    /// The destinations a module draws at the top of its own sidebar, in display order.
    public static func destinations(in module: AppModule) -> [SidebarDestination] {
        destinationsByModule[module] ?? []
    }

    /// Every available destination, in display order.
    public static let available: [SidebarDestination] = SidebarDestination.Band.allCases
        .flatMap { band in allDeclared.filter { $0.isAvailable && $0.band == band } }

    // MARK: Derived once
    //
    // ``allDeclared`` is a constant, so every answer derived from it is one too. These were `filter`
    // calls behind function and computed-property faces, which read as free and were not: each
    // sidebar row asks for its band on every evaluation of its body, and the shell asks for
    // ``nonTruncatingTitles`` twice per evaluation of the window's. Deriving them once at first use
    // costs the same work one time and removes it from every frame.

    private static let destinationsByBand: [SidebarDestination.Band: [SidebarDestination]] =
        Dictionary(grouping: available, by: \.band)

    private static let destinationsByModule: [AppModule: [SidebarDestination]] = {
        var grouped: [AppModule: [SidebarDestination]] = [:]
        for destination in available {
            guard let module = destination.module else { continue }
            grouped[module, default: []].append(destination)
        }
        return grouped
    }()

    /// The destination a numeric shortcut selects, if any.
    ///
    /// Global destinations first, then one per module in module order, so the numbered shortcuts run
    /// Today, Inbox, and then the modules exactly as the sidebar lists them. Derived from the visible
    /// order, so the shortcut always matches what the user can see.
    public static func destination(forShortcutIndex index: Int) -> SidebarDestination? {
        let ordered = shortcutOrder
        guard index >= 1, index <= ordered.count else { return nil }
        return ordered[index - 1]
    }

    /// Global destinations, then each module's front door.
    public static let shortcutOrder: [SidebarDestination] = destinations(in: .primary)
        + AppModule.displayOrder.compactMap { destinations(in: $0).first }

    /// Titles that must never be truncated, so the sidebar's minimum width can be derived from them.
    ///
    /// Module names are included alongside the destinations: the module list is primary navigation
    /// now, and "Bookm…" would be exactly the ambiguity the rule exists to prevent.
    public static let nonTruncatingTitles: [String] =
        available.filter { !$0.mayTruncate }.map(\.title) + AppModule.displayOrder.map(\.title)
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
