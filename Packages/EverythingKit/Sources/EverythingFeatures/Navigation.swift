import EverythingCore
import EverythingPersistence
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
    public var selectedItemID: UUID?

    /// The list's own filter field, distinct from the global search sheet.
    public var listFilterText = ""

    public var isInspectorVisible = false
    public var isQuickCaptureVisible = false
    public var isCommandPaletteVisible = false
    public var isSearchVisible = false

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
        selectedItemID = nil
        listFilterText = ""
        sortOverride = nil
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
        if !listFilterText.isEmpty {
            query.text = listFilterText
        }
        return query
    }
}
