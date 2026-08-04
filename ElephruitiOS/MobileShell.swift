import ElephruitCore
import ElephruitFeaturesCore
import Foundation
import Observation

/// The iPhone's top-level places.
///
/// Four tabs plus the system search position — five slots, which is all a tab bar honestly
/// holds. The Mac sidebar lists every module because a 27-inch window can afford to; a
/// thumb cannot, so the slots go to where sessions start: orienting to the day, working
/// the reminders, looking a record up, finding anything. The calendar's most frequent
/// use — *what is my day* — is already answered inline on Today, which is what lets the
/// full calendar live one tap deep in Library beside notes, time, and settings without
/// hiding the day. Capture is an action, not a place, so it is a button rather than a tab.
enum MobileTab: String, Hashable, CaseIterable, Codable {
    case today
    case reminders
    case records
    case library
    /// The system search position, separated from the other tabs by the platform itself.
    case search

    var title: String {
        switch self {
        case .today: "Today"
        case .reminders: "Reminders"
        case .records: "Records"
        case .library: "Library"
        case .search: "Search"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.horizon"
        case .reminders: "checkmark.circle"
        case .records: "person.2"
        case .library: "square.grid.2x2"
        case .search: "magnifyingglass"
        }
    }
}

/// One step of drill-down, on any tab.
///
/// A closed value type for the same reasons `SidebarSelection` is one on the Mac: it can be
/// encoded for state restoration, compared for equality, and reasoned about in a test. Every
/// way of arriving somewhere — a tap, a search result, a wiki link, a deep link, an intent —
/// lands on one of these, so all of them agree by construction.
enum MobileRoute: Hashable, Codable {
    /// Any item's detail: a note, a reminder, a bookmark, an area, a list.
    case item(UUID)
    /// A project's workspace — richer than a plain item detail.
    case project(UUID)
    /// A person's (or any record's) profile.
    case person(UUID)
    /// A saved smart list from the Reminders module.
    case smartList(UUID)
    /// A built-in smart list, by its stable string id.
    case builtInSmartList(String)
    /// A scoped slice of the Records module — pets, organizations, favorites.
    case records(RecordsScope)
    /// Everything carrying one tag.
    case tag(String)
    /// The flat list of one kind — notes, bookmarks, areas.
    case kindList(ItemKind)
    /// Unprocessed captures.
    case inbox
    case archive
    case trash
    /// A calendar event, by its identity storage key.
    case event(String)
    /// The full calendar — month plus agenda. Today's schedule is already on Today,
    /// which is what lets the calendar live one tap deep without hiding the day.
    case calendar
    /// The time log and reports.
    case time
    case settings
}

/// Where the shell is, and how it moves.
///
/// One per app. Each tab keeps its own `NavigationStack` path, so switching tabs never
/// throws away where you were — entering a project can never strand you, because Today,
/// Search, and the tab bar are all still one tap away, holding their own state.
@Observable
@MainActor
final class MobileShellModel {
    var selectedTab: MobileTab = .today

    /// Each tab's drill-down, kept when the user switches away.
    var paths: [MobileTab: [MobileRoute]] = [:]

    /// Whether the quick-capture sheet is up.
    var isCaptureVisible = false

    /// Whether search is front — bound to the system search tab's activation.
    var isSearchActive = false

    /// The one search session, kept when the user leaves and returns.
    var searchText = ""

    /// A path binding for one tab, for `NavigationStack`.
    func path(for tab: MobileTab) -> [MobileRoute] {
        paths[tab] ?? []
    }

    func setPath(_ path: [MobileRoute], for tab: MobileTab) {
        paths[tab] = path
    }

    /// Pushes a route onto the current tab's stack.
    ///
    /// Onto the *current* tab deliberately: a person opened from a search result or a
    /// project's team list is context inside the journey the user is on, and back must
    /// return to where they came from. Jumping tabs would answer "open Maya" by losing
    /// the search that found her.
    func push(_ route: MobileRoute) {
        var path = paths[selectedTab] ?? []
        path.append(route)
        paths[selectedTab] = path
    }

    /// Selects a tab and pushes, for arrivals that carry their own context — deep links
    /// and intents, which start from outside the app and have no journey to preserve.
    func open(_ route: MobileRoute, in tab: MobileTab) {
        selectedTab = tab
        paths[tab] = [route]
    }

    /// The route an item opens on, given what it is.
    static func route(for kind: ItemKind, id: UUID) -> MobileRoute {
        switch kind {
        case .project: .project(id)
        case .person, .organization: .person(id)
        default: .item(id)
        }
    }

    /// Pops the current tab to its root — the standard re-tap-the-tab gesture.
    func popToRoot(of tab: MobileTab) {
        paths[tab] = []
    }

    // MARK: - Restoration

    /// What survives relaunch: the tab and each tab's stack.
    struct Restoration: Codable, Hashable {
        var tab: MobileTab
        var paths: [MobileTab: [MobileRoute]]
    }

    var restoration: Restoration {
        Restoration(tab: selectedTab, paths: paths)
    }

    var encodedRestoration: String? {
        guard let data = try? JSONEncoder().encode(restoration) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func restore(from encoded: String) {
        guard let restored = try? JSONDecoder().decode(Restoration.self, from: Data(encoded.utf8))
        else { return }
        selectedTab = restored.tab
        paths = restored.paths
    }
}
