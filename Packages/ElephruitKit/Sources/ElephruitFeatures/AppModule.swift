import ElephruitCore
import Foundation

/// One of the focused applications inside the application.
///
/// ### Why a module rather than another band
/// The sidebar had grown to hold every destination of every feature at once — the day's work, the
/// task system's nine views, the People module's seven scopes, the library's kinds, tags, saved
/// searches, and the Trash — all visible simultaneously. That is not a navigation hierarchy; it is
/// an index. Nobody reads an index to find out where they are.
///
/// A module is the unit that fixes it. The top of the sidebar answers *where am I in my day*, and
/// beneath it is a short list of *which app am I in*. Entering one replaces the sidebar with that
/// module's own navigation, which is the only place a module's detail is ever shown.
///
/// ### Why this is not a second navigation system
/// A module owns no destinations of its own. It names an ordered slice of ``SidebarSelection`` that
/// already existed — Tasks *is* `.taskView`, `.smartList` and `.builtInSmartList`; Notes *is*
/// `.kind(.note)` — so entering a module changes which rows are drawn and nothing about what a
/// selection means. ``AppModule/module(for:)`` is the inverse, which is what lets a deep link, a
/// menu command, or a restored scene put the user inside the right module without anybody having to
/// remember to set it.
public enum AppModule: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case calendar
    case tasks
    case people
    case notes
    case time
    case projects
    case areas
    case bookmarks
    case archive
    case trash

    public var id: String { rawValue }

    /// The order the modules are listed in, which is the order they are declared in.
    ///
    /// Declared rather than sorted, because the order is an editorial decision — the modules a day
    /// is actually worked in come first — and an alphabetical list would put Archive above Calendar.
    public static var displayOrder: [AppModule] { allCases }

    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .people: "People"
        case .notes: "Notes"
        case .time: "Time"
        case .projects: "Projects"
        case .areas: "Areas"
        case .bookmarks: "Bookmarks"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }

    public var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .tasks: "checkmark.circle"
        case .people: "person.2"
        case .notes: "note.text"
        case .time: "timer"
        case .projects: "square.stack.3d.up"
        case .areas: "square.grid.2x2"
        case .bookmarks: "bookmark"
        case .archive: "archivebox"
        case .trash: "trash"
        }
    }

    /// What the module holds, for the tooltip and the accessibility hint.
    ///
    /// A rule rather than a restatement of the name — the same standard ``SidebarDestination/hint``
    /// is held to, and for the same reason: a tooltip that spells the label back is a delay followed
    /// by nothing.
    public var hint: String {
        switch self {
        case .calendar: "Your days, laid out, and everything you know about them."
        case .tasks: "What needs doing, when it becomes workable, and what you chose for today."
        case .people: "Who you know, what you owe them, and what is coming up for them."
        case .notes: "Everything written down, with the tags and searches that reach across it."
        case .time: "Tracked time, and what it went on."
        case .projects: "Work with an outcome and an end."
        case .areas: "Standing responsibilities, which never finish."
        case .bookmarks: "Links kept for later."
        case .archive: "Finished, kept, and out of the way of today."
        case .trash: "Deleted, and recoverable until you empty it."
        }
    }

    /// Where entering the module lands.
    public var defaultSelection: SidebarSelection {
        switch self {
        case .calendar: .calendar
        case .tasks: .taskView(.today)
        case .people: .people(.all)
        case .notes: .kind(.note)
        case .time: .time
        case .projects: .kind(.project)
        case .areas: .kind(.area)
        case .bookmarks: .kind(.bookmark)
        case .archive: .archive
        case .trash: .trash
        }
    }

    public var accessibilityIdentifier: String { "sidebar.module.\(rawValue)" }

    /// Whether this module's sidebar holds navigation beyond its own front door.
    ///
    /// Calendar offers six views, every calendar it can read, and the sets composed from them; Time
    /// offers two surfaces, a period and a grouping; Tasks and People build their columns from the
    /// store. None of them needs a row naming the module underneath a header naming the module —
    /// see ``SidebarRegistry/sidebarRows(in:)``, which is where the consequence is applied.
    ///
    /// Declared rather than inferred from the number of declared destinations, because the
    /// distinction is *whether the module navigates*, and three of these four modules navigate by
    /// rows that are not declared destinations at all.
    public var hasNavigationOfItsOwn: Bool {
        switch self {
        case .calendar, .time, .tasks, .people: true
        case .notes, .projects, .areas, .bookmarks, .archive, .trash: false
        }
    }

    /// The module a selection belongs to, or `nil` when it belongs to none.
    ///
    /// `nil` has two distinct meanings and both are correct here. A global destination — Home,
    /// Today, Upcoming, Inbox — genuinely belongs to no module and leaving one is what selecting it
    /// means. A pinned item, a tag, or a saved search belongs to *whichever* module you were in when
    /// you opened it, so the answer is "not mine to decide"; ``NavigationModel/select(_:)`` leaves
    /// the current module alone in that case rather than guessing.
    public static func module(for selection: SidebarSelection) -> AppModule? {
        switch selection {
        case .calendar:
            .calendar
        case .taskView, .smartList, .builtInSmartList:
            .tasks
        case .people:
            .people
        case .time:
            .time
        case .archive:
            .archive
        case .trash:
            .trash
        case .kind(let kind):
            module(for: kind)
        case .home, .today, .upcoming, .inbox:
            nil
        case .item, .tag, .savedSearch:
            nil
        }
    }

    /// The module that owns a kind's list.
    ///
    /// Only the kinds that have a module of their own answer. A meeting note or an idea is a note by
    /// every other measure in this app, so it belongs to Notes; a person belongs to People even
    /// though `.kind(.person)` is not the row the People module actually shows.
    private static func module(for kind: ItemKind) -> AppModule? {
        switch kind {
        case .task: .tasks
        case .project, .goal: .projects
        case .area: .areas
        case .person, .organization: .people
        case .bookmark: .bookmarks
        case .note, .idea, .reference, .meeting, .dailyEntry, .decision: .notes
        case .interaction, .list, .heading: nil
        }
    }

    /// Whether a selection is one this module draws in its own sidebar.
    ///
    /// Used to decide whether a restored or deep-linked selection can be shown as-is, rather than
    /// falling back to the module's default.
    public func contains(_ selection: SidebarSelection) -> Bool {
        Self.module(for: selection) == self
    }
}

/// The four destinations that are not inside any module.
///
/// Held as a type rather than as a filter over ``SidebarRegistry`` so that "what is global" has one
/// answer, and so that the order — which is the order they are read in — is declared once.
public enum GlobalDestination: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case home
    case today
    case upcoming
    case inbox

    public var id: String { rawValue }

    public var selection: SidebarSelection {
        switch self {
        case .home: .home
        case .today: .today
        case .upcoming: .upcoming
        case .inbox: .inbox
        }
    }

    /// Whether a selection is one of the four.
    public static func contains(_ selection: SidebarSelection) -> Bool {
        allCases.contains { $0.selection == selection }
    }
}
