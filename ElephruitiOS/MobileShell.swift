import ElephruitCore
import ElephruitFeaturesCore
import Foundation
import Observation

/// The iPhone's top-level places.
///
/// ### Why a sidebar rather than a tab bar
/// A tab bar holds five slots, and this app has thirteen places worth naming. The old shell
/// paid for that shortfall twice: four modules got a tab, and everything else — the calendar,
/// notes, time, bookmarks, the inbox, the archive, the trash — got filed behind a row called
/// "Library", which is not a place but an apology for the tab bar's arithmetic. A drawer has
/// no such ceiling, so the Mac's own module list can appear here unabridged, in the Mac's
/// order, wearing the Mac's names. Two apps that disagree about how many places exist are two
/// apps.
///
/// The drawer is also *behind* the screen rather than beside it, which gives back the one
/// thing the tab bar was buying: a way home that costs nothing. Swiping right pops the stack
/// until there is nothing left to pop and then reveals the drawer, and the chevron in the
/// upper left says the same thing in a control. "Keep going back" is one gesture, one glyph,
/// and one idea all the way to the top, instead of a stack gesture that stops one level short
/// of a tab bar that then switches instantly.
enum MobileDestination: String, Hashable, CaseIterable, Codable {
    case today
    case calendar
    case reminders
    case records
    case notes
    case time
    case areas
    case bookmarks
    case inbox
    case archive
    case trash
    case search
    case settings

    /// The drawer's rows, grouped as the Mac's sidebar groups them.
    ///
    /// Declared rather than sorted: the order is editorial. The day comes first because that is
    /// where sessions start; the modules a day is worked in follow; the holding pens — inbox,
    /// archive, trash — come after the work rather than among it; search and settings sit at the
    /// foot where a utility belongs.
    static let groups: [[MobileDestination]] = [
        [.today],
        [.calendar, .reminders, .records, .notes, .time, .areas, .bookmarks],
        [.inbox, .archive, .trash],
        [.search, .settings],
    ]

    var title: String {
        switch self {
        case .today: "Today"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .records: "Records"
        case .notes: "Notes"
        case .time: "Time"
        case .areas: "Areas"
        case .bookmarks: "Bookmarks"
        case .inbox: "Inbox"
        case .archive: "Archive"
        case .trash: "Trash"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    /// The Mac's symbols wherever the Mac names the same module, so the two shells cannot
    /// drift into two vocabularies for one place.
    var symbolName: String {
        switch self {
        case .today: "sun.horizon"
        case .calendar: "calendar"
        case .reminders: "bell"
        case .records: "person.text.rectangle"
        case .notes: "note.text"
        case .time: "timer"
        case .areas: "square.grid.2x2"
        case .bookmarks: "bookmark"
        case .inbox: "tray"
        case .archive: "archivebox"
        case .trash: "trash"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }

    /// What the place holds, for the accessibility hint — the Mac's `AppModule.hint` standard:
    /// a rule about what belongs here, never the label spelled back.
    var hint: String {
        switch self {
        case .today: "What today asks of you, most urgent first."
        case .calendar: "Your days, laid out, and everything you know about them."
        case .reminders: "Things to remember, when they matter, and what you chose for today."
        case .records: "People and things, with their notes, history, and shared work."
        case .notes: "Everything written down, with the tags that reach across it."
        case .time: "Tracked time, and what it went on."
        case .areas: "Standing responsibilities, which never finish."
        case .bookmarks: "Links kept for later."
        case .inbox: "Captured, and not yet given a home."
        case .archive: "Finished, kept, and out of the way of today."
        case .trash: "Deleted, and recoverable until you empty it."
        case .search: "Everything, by any word in it."
        case .settings: "How this app behaves, and what it is allowed to touch."
        }
    }
}

/// One step of drill-down, from any destination.
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
    /// The full calendar — month plus agenda.
    case calendar
    /// The time log and reports.
    case time
    case settings
}

/// Where the shell is, and how it moves.
///
/// One per app. Each destination keeps its own path, which is what lets a deep link, an intent
/// or a restored scene put someone back inside a drill-down rather than at a root.
///
/// It is deliberately *not* the tab bar's promise that a pushed screen survives going
/// elsewhere. The drawer sits above the deepest root, so leaving a pushed screen means popping
/// it — that is the cost of back meaning one thing at every depth, and it is the right cost:
/// the tab bar bought "leave without popping" by having a second way to move that the back
/// gesture knew nothing about.
@Observable
@MainActor
final class MobileShellModel {
    var destination: MobileDestination = .today

    /// Each destination's drill-down, kept when the user steps away.
    var paths: [MobileDestination: [MobileRoute]] = [:]

    /// Whether the drawer is showing.
    var isSidebarOpen = false

    /// Whether the quick-capture sheet is up.
    var isCaptureVisible = false

    /// How many times the shell's button has been asked for a new reminder.
    ///
    /// A count rather than a flag, because the interesting event is the *press* and a flag
    /// cannot report the second one: raising it twice in a row is one change, and the screen
    /// listening for it would open a composer for the first press and ignore every press after
    /// it until something else lowered the flag. Nobody reads the number; they watch it change.
    private(set) var newReminderRequests = 0

    /// Asks the Reminders screen for a composer. The shell does not know how to open one —
    /// the composer belongs to the list, at the end of it, where the next reminder goes.
    func requestNewReminder() {
        newReminderRequests += 1
    }

    /// The one search session, kept when the user leaves and returns.
    var searchText = ""

    /// The current destination's drill-down.
    var path: [MobileRoute] {
        get { paths[destination] ?? [] }
        set { paths[destination] = newValue }
    }

    /// A path for one destination, for tests and restoration.
    func path(for destination: MobileDestination) -> [MobileRoute] {
        paths[destination] ?? []
    }

    func setPath(_ path: [MobileRoute], for destination: MobileDestination) {
        paths[destination] = path
    }

    /// Whether going back means popping the stack rather than revealing the drawer.
    ///
    /// The single fact behind both the chevron and the swipe: one idea, read in one place, so
    /// the control and the gesture cannot come to different conclusions.
    var canPop: Bool { !path.isEmpty }

    /// Pushes a route onto the current destination's stack.
    ///
    /// Onto the *current* destination deliberately: a person opened from a search result or a
    /// project's team list is context inside the journey the user is on, and back must return
    /// to where they came from. Jumping elsewhere would answer "open Maya" by losing the
    /// search that found her.
    func push(_ route: MobileRoute) {
        var path = paths[destination] ?? []
        path.append(route)
        paths[destination] = path
    }

    /// Steps to a destination and closes the drawer — what tapping a drawer row means.
    ///
    /// Re-selecting where you already are pops that destination to its root, which is the
    /// re-tap gesture the tab bar used to own and the only way back out of a deep stack that
    /// does not require walking it.
    func select(_ destination: MobileDestination) {
        if destination == self.destination {
            paths[destination] = []
        }
        self.destination = destination
        isSidebarOpen = false
    }

    /// Selects a destination and pushes, for arrivals that carry their own context — deep
    /// links and intents, which start from outside the app and have no journey to preserve.
    func open(_ route: MobileRoute, in destination: MobileDestination) {
        self.destination = destination
        paths[destination] = [route]
        isSidebarOpen = false
    }

    /// One step back: out of the stack if there is stack, into the drawer if there is not.
    func goBack() {
        if canPop {
            paths[destination]?.removeLast()
        } else {
            isSidebarOpen = true
        }
    }

    /// The route an item opens on, given what it is.
    static func route(for kind: ItemKind, id: UUID) -> MobileRoute {
        switch kind {
        case .project: .project(id)
        case .person, .organization: .person(id)
        default: .item(id)
        }
    }

    /// Pops one destination to its root.
    func popToRoot(of destination: MobileDestination) {
        paths[destination] = []
    }

    // MARK: - Restoration

    /// What survives relaunch: the destination and each destination's stack.
    ///
    /// The drawer's own open/closed state is deliberately absent. Restoring a relaunch into an
    /// open drawer would answer "put me back where I was" with a menu.
    struct Restoration: Codable, Hashable {
        var destination: MobileDestination
        var paths: [MobileDestination: [MobileRoute]]
    }

    var restoration: Restoration {
        Restoration(destination: destination, paths: paths)
    }

    var encodedRestoration: String? {
        guard let data = try? JSONEncoder().encode(restoration) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func restore(from encoded: String) {
        guard let restored = try? JSONDecoder().decode(Restoration.self, from: Data(encoded.utf8))
        else { return }
        destination = restored.destination
        paths = restored.paths
    }
}
