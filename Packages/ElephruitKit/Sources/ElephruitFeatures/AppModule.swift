import ElephruitCore
import Foundation

/// One of the focused applications inside the application.
///
/// ### Why a module rather than another band
/// The sidebar had grown to hold every destination of every feature at once — the day's work, the
/// task system's nine views, the Records module's scopes, the library's kinds, tags, saved
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
    case reminders
    case tasks
    case records
    case notes
    case time
    case projects
    case areas
    case bookmarks
    case archive
    case trash

    public var id: String { rawValue }

    /// The modules the sidebar lists, in declaration order.
    ///
    /// Declared rather than sorted, because the order is an editorial decision — the modules a day
    /// is actually worked in come first — and an alphabetical list would put Archive above Calendar.
    ///
    /// **Projects is absent, and the case still exists.** A module is somewhere you *enter*, which
    /// swaps the sidebar for its own navigation — and that is exactly wrong for projects, of which
    /// there are a dozen and between which people move constantly. Behind a row called "Projects",
    /// the user's own structure sat one level further away than the Trash, and the list you switch
    /// projects with had been swapped out by the act of opening one.
    ///
    /// So the tree lives at the top of the primary sidebar (see `ProjectsSidebarSection`) and the
    /// case stays for two jobs that are not the sidebar: `ModuleLayoutPolicy` still needs to say how
    /// wide a project workspace is, and ``module(for:)`` still has to answer which module owns a bug.
    public static var displayOrder: [AppModule] {
        allCases.filter { $0 != .projects }
    }

    /// Whether this module draws its own second-level sidebar when you are inside it.
    ///
    /// The rule: a module swaps the sidebar only when it has real navigation to put there.
    /// Calendar brings its views, calendars and sets; Tasks its system views and containers;
    /// Records its scopes and groups; Notes and Areas their kind rows. The rest were paying a
    /// whole column swap for almost nothing — Time for a two-button mode toggle whose job the
    /// toolbar already does, and Bookmarks, Archive and Trash for a single front-door row naming
    /// the module the header had just named. Projects is the founding case: its tree lives at the
    /// top level of the primary sidebar, and swapping that away was taking the navigation with it.
    public var hasOwnSidebar: Bool {
        switch self {
        case .calendar, .tasks, .records, .notes, .areas: true
        case .reminders, .projects, .time, .bookmarks, .archive, .trash: false
        }
    }

    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .tasks: "Tasks"
        case .records: "Records"
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
        case .reminders: "bell"
        case .tasks: "checkmark.circle"
        case .records: "circle.grid.2x2"
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
        case .reminders: "Small things to remember, captured without becoming tasks."
        case .tasks: "What needs doing, when it becomes workable, and what you chose for today."
        case .records: "People and things, with their notes, history, relationships, and shared work."
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
        case .reminders: .reminders
        case .tasks: .taskView(.today)
        case .records: .records(.all)
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
    /// offers two surfaces, a period and a grouping; Tasks and Records build their columns from the
    /// store. None of them needs a row naming the module underneath a header naming the module —
    /// see ``SidebarRegistry/sidebarRows(in:)``, which is where the consequence is applied.
    ///
    /// Declared rather than inferred from the number of declared destinations, because the
    /// distinction is *whether the module navigates*, and three of these four modules navigate by
    /// rows that are not declared destinations at all.
    public var hasNavigationOfItsOwn: Bool {
        switch self {
        case .calendar, .time, .tasks, .records: true
        case .reminders, .notes, .projects, .areas, .bookmarks, .archive, .trash: false
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
        case .reminders:
            .reminders
        case .taskView, .smartList, .builtInSmartList:
            .tasks
        case .records:
            .records
        case .time:
            .time
        case .archive:
            .archive
        case .trash:
            .trash
        case .kind(let kind):
            module(for: kind)
        case .project, .projectInbox:
            .projects
        case .home, .today, .upcoming, .inbox:
            nil
        case .item, .tag, .savedSearch:
            nil
        }
    }

    /// The module that owns a kind's list.
    ///
    /// Only the kinds that have a module of their own answer. A meeting note or an idea is a note by
    /// every other measure in this app, so it belongs to Notes; person and organization records
    /// belong to Records even though their kind rows are not the browser entry points.
    private static func module(for kind: ItemKind) -> AppModule? {
        switch kind {
        case .task, .reminder: .reminders
        case .project, .goal: .projects
        // A bug, a feature, a milestone and a release only ever exist inside a project, so the
        // module that owns their list is the one that owns the project — not Tasks, even though a
        // bug and a feature are work by every other measure in this app.
        case .bug, .feature, .milestone, .release: .projects
        case .area: .areas
        case .person, .organization: .records
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

/// The destinations that are not inside any module.
///
/// Held as a type rather than as a filter over ``SidebarRegistry`` so that "what is global" has one
/// answer, and so that the order — which is the order they are read in — is declared once.
///
/// ### Why there are two of these and not four
/// There were four: Home, Today, Upcoming and Inbox. Home and Upcoming were two views of the same
/// morning — one showing what is *happening*, one showing what is *dated* — and Today was a third,
/// a flat list of everything due. Three destinations answering one question is three places to look
/// before knowing what the day holds, and none of them could show how the three kinds of record
/// relate, because none of them had seen all three. They are now one destination that has.
///
/// Inbox stays, because it answers a genuinely different question: what has arrived and not yet been
/// filed. That is not a fact about a day.
public enum GlobalDestination: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case today
    case inbox

    public var id: String { rawValue }

    public var selection: SidebarSelection {
        switch self {
        case .today: .today
        case .inbox: .inbox
        }
    }

    /// Whether a selection belongs to no module.
    ///
    /// Asked of the *canonical* form, so a scene restored from a build that had Home or Upcoming is
    /// recognised as global rather than falling through to the "belongs to whichever module you were
    /// in" branch — which is what would strand a restored window inside People showing Today.
    public static func contains(_ selection: SidebarSelection) -> Bool {
        allCases.contains { $0.selection == selection.canonical }
    }
}
