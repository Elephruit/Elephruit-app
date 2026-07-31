import ElephruitCore
import ElephruitPersistence
import Foundation
import Observation

/// What the sidebar can select.
///
/// A value type rather than a view reference, so it can be stored for scene restoration, compared
/// for equality, and mapped to a query by a pure function that is unit-testable without a window.
public enum SidebarSelection: Hashable, Sendable, Codable {
    case today
    case upcoming
    case inbox
    case kind(ItemKind)
    case tag(slug: String)
    case savedSearch(id: UUID)
    case item(id: UUID)
    case archive
    case trash

    // Declared for destinations that later phases build. `SidebarRegistry` marks them unavailable, so
    // they are never enumerated and never reachable — but declaring them now means the phase that
    // builds one flips a flag instead of widening this enum, and a scene restored from a future
    // version decodes without loss.
    case home
    case calendar
    case time

    /// A slice of the People module — all, favourites, celebrations, a group.
    ///
    /// One case carrying a ``PeopleScope`` rather than seven cases, so adding a scope does not widen
    /// this enum and a scene restored from a newer version still decodes.
    case people(PeopleScope)

    /// The query this selection shows.
    ///
    /// Pure, so "what does Today mean?" is answered in one testable place rather than inside a view.
    public func query(using dateProvider: any DateProvider) -> ItemQuery {
        switch self {
        case .today:
            .today(using: dateProvider)
        case .upcoming:
            .upcoming(days: 14, using: dateProvider)
        case .inbox:
            .inbox()
        case .kind(let kind):
            .kind(kind, sort: Self.defaultSort(for: kind))
        case .tag(let slug):
            .tag(slug: slug)
        case .item(let id):
            .children(of: id)
        case .savedSearch:
            // Saved searches run through the search engine, not a store query.
            ItemQuery()
        case .archive:
            .archive()
        case .trash:
            .trash()
        case .home, .calendar, .time:
            // Unreachable while these destinations are unavailable; an empty query is the honest
            // answer rather than a crash if one is ever restored from a newer scene.
            ItemQuery()
        case .people:
            // People are fetched through `PersonRepository`, which knows about placeholders and
            // profiles. A kind query would return them but would also return the sketches nobody
            // asked to see.
            ItemQuery()
        }
    }

    private static func defaultSort(for kind: ItemKind) -> ItemQuery.Sort {
        switch kind {
        case .task: .dueSoonestFirst
        case .project, .area: .manual
        default: .updatedNewestFirst
        }
    }

    /// The kind a "New Item" action should create here, so `⌘N` does the obvious thing.
    public var defaultNewItemKind: ItemKind {
        switch self {
        case .today, .upcoming: .task
        case .inbox: .note
        case .kind(let kind): kind
        case .tag, .savedSearch, .item, .archive, .trash: .note
        case .home, .calendar, .time: .note
        case .people: .person
        }
    }

    public var title: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .inbox: "Inbox"
        case .kind(let kind): kind.pluralDisplayName
        case .tag(let slug): "#" + (TextNormalizer.slugComponents(slug).last ?? slug)
        case .savedSearch: "Saved Search"
        case .item: "Contents"
        case .archive: "Archive"
        case .trash: "Trash"
        case .home: "Home"
        case .calendar: "Calendar"
        case .time: "Time"
        case .people(let scope): scope.title
        }
    }

    public var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .inbox: "tray"
        case .kind(let kind): kind.symbolName
        case .tag: "number"
        case .savedSearch: "line.3.horizontal.decrease.circle"
        case .item: "square.stack.3d.up"
        case .archive: "archivebox"
        case .trash: "trash"
        case .home: "house"
        case .calendar: "calendar.day.timeline.left"
        case .time: "timer"
        case .people(let scope): scope.symbolName
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .today: AccessibilityID.Sidebar.today
        case .upcoming: "sidebar.upcoming"
        case .inbox: AccessibilityID.Sidebar.inbox
        case .kind(let kind): "sidebar.kind.\(kind.rawValue)"
        case .tag(let slug): AccessibilityID.Sidebar.tag(slug: slug)
        case .savedSearch(let id): AccessibilityID.Sidebar.savedSearch(name: id.uuidString)
        case .item(let id): "sidebar.item.\(id.uuidString)"
        case .archive: "sidebar.archive"
        case .trash: AccessibilityID.Sidebar.trash
        case .home: "sidebar.home"
        case .calendar: "sidebar.calendar"
        case .time: "sidebar.time"
        case .people(let scope): "sidebar.people.\(scope.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        }
    }

    /// Whether items shown here are in the Trash, which changes what actions are offered.
    public var showsTrashedItems: Bool {
        self == .trash
    }
}

/// One window's navigation and presentation state.
///
/// Per-window rather than global, so two windows can look at different things — which is most of
/// the point of supporting multiple windows.
@Observable
@MainActor
public final class NavigationModel {
    public var selection: SidebarSelection = .today

    /// Everything selected in the list.
    ///
    /// The set is the truth; ``selectedItemID`` is the one the detail pane shows. Keeping both means
    /// a multi-selection can act on twenty items while the editor still shows something coherent
    /// rather than going blank.
    public var selectedItemIDs: Set<UUID> = [] {
        didSet { reconcilePrimarySelection() }
    }

    /// The item the detail pane shows.
    public private(set) var selectedItemID: UUID?

    // MARK: Layout and focus

    public var layoutMode: LayoutMode = .full
    public var focusedPane: ShellPane = .list

    public var isInspectorVisible = false
    public var isQuickCaptureVisible = false
    public var isCommandPaletteVisible = false

    /// The People command bar, which is a different surface from the general ⌘K palette.
    ///
    /// Two bars rather than one because they answer different questions. The palette runs *commands*
    /// the app defines; this one reads a sentence about a person and shows what it understood before
    /// anything happens. Merging them would mean one field whose behaviour changes depending on what
    /// the first word turned out to be.
    public var isPeopleCommandBarVisible = false

    /// The full tag list, reached from the sidebar's bounded disclosure group.
    public var isTagBrowserVisible = false

    // MARK: Search as a mode

    /// Whether the list is currently showing search results rather than its usual contents.
    public private(set) var isSearchActive = false

    /// The live query while search is active.
    public var searchQuery = ""

    /// The query from the last search, kept so reopening search can offer it again.
    ///
    /// This is what lets one Escape leave search without losing what was typed. Clearing a query has
    /// its own familiar affordances — select and delete, or the clear button — and is not Escape's job.
    public private(set) var lastSearchQuery = ""

    /// Set when search opens with a restored query, so the field selects it and typing replaces it.
    public private(set) var shouldSelectSearchQuery = false

    /// What was selected before search began, restored when it ends.
    @ObservationIgnored private var selectionBeforeSearch: UUID?

    /// Sort override for the current list. Reset when the selection changes, because a sort that
    /// made sense for Tasks rarely makes sense for Notes.
    public var sortOverride: ItemQuery.Sort?

    /// Recent search queries, newest first. Session-scoped: a search history that outlives the
    /// session is a privacy liability nobody asked for.
    public private(set) var recentSearches: [String] = []

    public init() {}

    public func select(_ selection: SidebarSelection) {
        guard self.selection != selection else { return }
        self.selection = selection
        selectedItemIDs = []
        sortOverride = nil
    }

    /// Selects exactly one item.
    public func selectItem(_ id: UUID?) {
        selectedItemIDs = id.map { [$0] } ?? []
    }

    /// Whether a batch action bar should appear.
    public var hasMultipleSelection: Bool {
        selectedItemIDs.count > 1
    }

    /// Keeps the detail pane pointed at something that is still selected.
    ///
    /// When a selection shrinks, the previously-shown item may no longer be in it; when it grows,
    /// the first one stays put rather than the pane jumping around as the user shift-clicks.
    private func reconcilePrimarySelection() {
        if let current = selectedItemID, selectedItemIDs.contains(current) { return }
        selectedItemID = selectedItemIDs.first
    }

    // MARK: - Search mode

    /// Enters search, offering the previous query back.
    public func beginSearch(clearingQuery: Bool = false) {
        if !isSearchActive {
            selectionBeforeSearch = selectedItemID
            isSearchActive = true
        }

        searchQuery = clearingQuery ? "" : lastSearchQuery
        shouldSelectSearchQuery = !searchQuery.isEmpty
        focusedPane = .list
    }

    /// Leaves search, restoring the previous list and selection.
    ///
    /// The query survives in ``lastSearchQuery``. Nothing the user typed is thrown away, and the
    /// selection they had before searching comes back — Escape never destroys work.
    public func endSearch() {
        guard isSearchActive else { return }

        if !searchQuery.isEmpty {
            lastSearchQuery = searchQuery
            recordSearch(searchQuery)
        }

        isSearchActive = false
        searchQuery = ""
        shouldSelectSearchQuery = false
        selectItem(selectionBeforeSearch)
        selectionBeforeSearch = nil
    }

    /// Called by the search field once it has consumed the select-all hint.
    public func didSelectSearchQuery() {
        shouldSelectSearchQuery = false
    }

    // MARK: - Layout and focus

    public var shellState: ShellState {
        ShellState(
            hasOverlay: isQuickCaptureVisible || isCommandPaletteVisible || isTagBrowserVisible,
            isSearchActive: isSearchActive,
            focusedPane: focusedPane,
            layoutMode: layoutMode
        )
    }

    /// Applies one rung of the Escape ladder. Returns whether anything happened, so the key event is
    /// only consumed when it did something.
    @discardableResult
    public func handleEscape() -> Bool {
        let outcome = EscapeLadder.outcome(for: shellState)

        switch outcome {
        case .dismissOverlay:
            isQuickCaptureVisible = false
            isCommandPaletteVisible = false
            isTagBrowserVisible = false

        case .leaveSearch:
            endSearch()

        case .leaveFocusMode:
            setLayoutMode(.full)

        case .focusList, .focusSidebar:
            guard let destination = EscapeLadder.destination(for: outcome) else { return false }
            focusedPane = destination

        case .nothing:
            return false
        }

        return true
    }

    /// Changes layout mode, keeping focus somewhere visible.
    public func setLayoutMode(_ mode: LayoutMode) {
        layoutMode = mode

        // Focus must never be left on a pane the mode has just hidden.
        if !mode.isVisible(focusedPane) {
            focusedPane = mode.showsList ? .list : .detail
        }
    }

    public func toggleSidebar() {
        setLayoutMode(layoutMode == .full ? .twoPane : .full)
    }

    public func toggleFocusMode() {
        setLayoutMode(layoutMode == .focus ? .full : .focus)
    }

    /// Moves focus to the next visible pane.
    public func advanceFocus(reversed: Bool = false) {
        focusedPane = PaneTraversal.next(
            after: focusedPane,
            layoutMode: layoutMode,
            isInspectorVisible: isInspectorVisible,
            reversed: reversed
        )
    }

    /// Moves focus to a pane, if that pane is on screen.
    public func focus(_ pane: ShellPane) {
        guard layoutMode.isVisible(pane) else { return }
        guard pane != .inspector || isInspectorVisible else { return }
        focusedPane = pane
    }

    public func recordSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 12 {
            recentSearches.removeLast(recentSearches.count - 12)
        }
    }

    public func clearRecentSearches() {
        recentSearches.removeAll()
    }

    /// The query for the current selection, with any sort override applied.
    public func currentQuery(using dateProvider: any DateProvider) -> ItemQuery {
        var query = selection.query(using: dateProvider)
        if let sortOverride {
            query.sort = sortOverride
        }
        return query
    }
}
