import ElephruitCore
import ElephruitFeaturesCore
import ElephruitModel
import Foundation
import Observation

/// What the iPad's sidebar can select.
///
/// A superset of the drawer's fourteen places, because a resident sidebar can honestly hold what
/// a drawer cannot: the user's own project tree, every smart list by name, the library's kinds,
/// and the tags that reach across all of them — the Mac's own bands, in the Mac's order.
///
/// It is deliberately *not* the Mac's `SidebarSelection`. That vocabulary carries module entry,
/// and the iPad has no modules to enter: here the sidebar is always the global one, and a project
/// or a kind list is a place the stage shows rather than a mode the sidebar becomes. The Mac
/// reached the same conclusion for its own column — see `SidebarView.primaryList` on why the
/// second level is gone — so the two shells agree about what a sidebar is for.
///
/// `Codable` and `Hashable` for the same reasons `MobileRoute` is: scene restoration stores it,
/// equality drives selection, and a pure function translates it to and from the compact shell's
/// destination-and-stack state — which is what makes rotating an iPad through a narrow Split View
/// and back a round trip rather than a reset.
enum PadRoot: Hashable, Codable {
    case today
    case inbox
    case search

    /// The user's own structure, from the projects tree.
    case project(UUID)
    case area(UUID)

    case reminders
    case smartList(UUID)
    case builtInSmartList(String)

    /// A search the user named and kept.
    case savedSearch(UUID)

    case records(RecordsScope)

    case kindList(ItemKind)
    case tag(String)

    case calendar
    case time
    case archive
    case trash
    case settings

    /// The stage this root wants: a canvas that takes the whole width, or a list with a reading
    /// pane beside it.
    ///
    /// The same two shapes the Mac's `ModuleLayoutPolicy` resolves every module into, and mostly
    /// the same answers: a day, a board, a month and a report are canvases; everything that is a
    /// list of records you open one at a time reads better with the record beside the list.
    ///
    /// **Reminders is a canvas, and that is not an oversight.** Its screen is a list you write
    /// straight into — a tap on empty space opens a composer where the next reminder goes, and a
    /// chip on a row opens that row's editor in place. Putting a reading pane beside it would mean
    /// a tap had to choose between editing here and reading there, which is the one question that
    /// surface exists to never ask.
    var shape: PadStageShape {
        switch self {
        case .today, .search, .savedSearch, .project, .calendar, .time, .settings, .reminders:
            .canvas
        case .inbox, .smartList, .builtInSmartList, .area, .records, .kindList, .tag, .archive,
            .trash:
            .listDetail
        }
    }

    /// The route whose screen is this root's content column — `nil` for the roots whose screen is
    /// a destination rather than a drill-down, and so has no `MobileRoute` of its own.
    var route: MobileRoute? {
        switch self {
        case .today, .search, .reminders: nil
        case .inbox: .inbox
        case .project(let id): .project(id)
        case .area(let id): .item(id)
        case .smartList(let id): .smartList(id)
        case .builtInSmartList(let id): .builtInSmartList(id)
        case .savedSearch(let id): .savedSearch(id)
        case .records(let scope): .records(scope)
        case .kindList(let kind): .kindList(kind)
        case .tag(let slug): .tag(slug)
        case .calendar: .calendar
        case .time: .time
        case .archive: .archive
        case .trash: .trash
        case .settings: .settings
        }
    }

    /// The drawer destination that owns this root when the window collapses to the phone shell.
    ///
    /// Every root has to land somewhere the drawer actually lists, because the drawer is the only
    /// way back at compact width. Where the sidebar is finer-grained than the drawer, the root
    /// becomes a drill-down inside the destination that covers it: a smart list inside Reminders,
    /// a project inside Projects, an area inside Areas, and a tag inside Notes, whose drawer hint
    /// already claims "the tags that reach across it".
    var owningDestination: MobileDestination {
        switch self {
        case .today: .today
        case .inbox: .inbox
        case .search, .savedSearch: .search
        case .project: .projects
        case .area: .areas
        case .reminders, .smartList, .builtInSmartList: .reminders
        case .records: .records
        case .kindList(let kind): Self.destination(forKind: kind)
        case .tag: .notes
        case .calendar: .calendar
        case .time: .time
        case .archive: .archive
        case .trash: .trash
        case .settings: .settings
        }
    }

    /// The drawer row a kind list belongs under.
    ///
    /// Only three kinds have a row of their own; the rest of the library's kinds are written
    /// things, and Notes is the drawer row that holds everything written down.
    private static func destination(forKind kind: ItemKind) -> MobileDestination {
        switch kind {
        case .bookmark: .bookmarks
        case .area: .areas
        default: .notes
        }
    }

    /// The root a route promotes to when it is selected somewhere a leaf would not do — a project
    /// tapped in a list is a place to go, not a record to read in a pane.
    init?(promoting route: MobileRoute) {
        switch route {
        case .project(let id): self = .project(id)
        case .smartList(let id): self = .smartList(id)
        case .builtInSmartList(let id): self = .builtInSmartList(id)
        case .savedSearch(let id): self = .savedSearch(id)
        case .records(let scope): self = .records(scope)
        case .kindList(let kind): self = .kindList(kind)
        case .tag(let slug): self = .tag(slug)
        case .inbox: self = .inbox
        case .calendar: self = .calendar
        case .time: self = .time
        case .archive: self = .archive
        case .trash: self = .trash
        case .settings: self = .settings
        // Groups is a management screen reached from the records list's own scope menu, not a
        // place the sidebar names — and tapping a group there opens `records(.group)`, which *is*
        // a root. So the legend stays beside the list it explains rather than becoming a rival to
        // it in the sidebar.
        case .groups: return nil
        case .item, .person, .event: return nil
        }
    }
}

extension MobileRoute {
    /// The drawer destination a window opened onto this route uses at compact width.
    var owningDestinationForWindow: MobileDestination {
        if let promoted = PadRoot(promoting: self) { return promoted.owningDestination }
        switch self {
        case .person, .groups: return .records
        case .event: return .calendar
        default: return .today
        }
    }
}

/// The two arrangements the stage draws.
enum PadStageShape: Hashable {
    /// One surface across the stage — a day, a board, a month, a report.
    case canvas
    /// A list with the selected record open beside it.
    case listDetail
}

/// Where the iPad shell is, and how it moves.
///
/// One per scene, beside the compact shell's `MobileShellModel` — each window may be a different
/// size and mid-transition between the two shells, so both models exist and the scene translates
/// between them when its width class changes. The translation is a pure function in both
/// directions (``collapsed()`` / ``init(expanding:)``), so "drag the window narrow and back" is a
/// value equality a test can assert rather than a hope.
@Observable
@MainActor
final class PadShellModel {
    /// The sidebar's selection.
    var root: PadRoot = .today

    /// Drill-down *within* the content column — a person's project list opened from their profile,
    /// say. Most navigation on the iPad replaces the root or the detail instead of pushing, so
    /// this is usually empty.
    var contentPath: [MobileRoute] = []

    /// The record open in the reading pane, with any drill-down inside that pane after it. Empty
    /// means nothing is selected and the pane says so.
    var detailPath: [MobileRoute] = []

    /// Whether the quick-capture sheet is up.
    var isCaptureVisible = false

    /// A new value for every keyboard request to toggle the sidebar.
    ///
    /// A counter rather than a Boolean, for the reason the Mac's search focus is one: a Boolean
    /// describes state, and "toggle it again" is an event. The shell view owns the actual
    /// visibility; commands cannot reach a view's state and should not.
    private(set) var sidebarToggleRequest = 0

    func requestSidebarToggle() {
        sidebarToggleRequest &+= 1
    }

    /// Whether the stage currently has a reading pane — written by the stage as it lays out, read
    /// by the route dispatcher. When the pane is gone, record leaves push in the content column
    /// instead, which is the compact behaviour arriving early rather than a separate rule.
    var isDetailPaneAvailable = true

    /// The one route dispatcher for the iPad shell.
    ///
    /// Every way of opening something funnels here — `shell.push(...)` through the redirect,
    /// `NavigationLink` values through the column bindings, deep links through the scene. A route
    /// that names a place the sidebar lists becomes the sidebar's selection; a record leaf becomes
    /// the reading pane's contents where the stage has one; everything else pushes in the content
    /// column. One function, so a tap, a context menu, a search result and a deep link cannot
    /// disagree about where things open.
    func route(_ route: MobileRoute) {
        if let promoted = PadRoot(promoting: route) {
            select(promoted)
        } else if root.shape == .listDetail, isDetailPaneAvailable {
            showDetail(route)
        } else if root.canvasInspectorWidth != nil, isDetailPaneAvailable {
            // A record beside the canvas, not over it — the side-by-side the width was for.
            showDetail(route)
        } else {
            contentPath.append(route)
        }
    }

    /// Where each root's stage was left, so returning to one resumes.
    ///
    /// Detail only: the content column is the root's own screen and rebuilding it is correct, but
    /// losing which record was open beside it on every sidebar round trip would make the sidebar
    /// destructive.
    private var rememberedDetails: [PadRoot: [MobileRoute]] = [:]

    /// Selects a sidebar root, remembering and restoring the reading pane per root.
    ///
    /// Re-selecting where you already are pops the content column to its root, which is the
    /// re-tap gesture the drawer owns on the phone and the only way out of a deep drill-down that
    /// does not require walking it.
    func select(_ newRoot: PadRoot) {
        guard newRoot != root else {
            contentPath = []
            return
        }
        rememberedDetails[root] = detailPath
        root = newRoot
        contentPath = []
        detailPath = rememberedDetails[newRoot] ?? []
    }

    /// Shows one record in the reading pane.
    func showDetail(_ route: MobileRoute) {
        detailPath = [route]
    }

    // MARK: - Collapse and expansion

    /// This state, as the drawer shell would hold it.
    ///
    /// The linearisation is the honest one: the destination that owns the root, then the root's
    /// own screen where the destination does not already show it, then the drill-down, then
    /// whatever was open in the reading pane — which is exactly the order a phone user would have
    /// tapped through, so back walks it correctly.
    func collapsed() -> MobileShellModel.Restoration {
        let destination = root.owningDestination
        var path: [MobileRoute] = []
        // A root whose screen *is* the destination's screen must not be pushed on top of itself:
        // Notes' drawer row already draws `kindList(.note)`, and stacking one on the other would
        // cost a back tap that lands on the same pixels.
        if let route = root.route, route != Self.rootRoute(of: destination) {
            path.append(route)
        }
        path.append(contentsOf: contentPath)
        path.append(contentsOf: detailPath)
        return MobileShellModel.Restoration(destination: destination, paths: [destination: path])
    }

    /// The route a drawer destination already shows at its own root, or `nil` when its screen has
    /// no route of its own.
    private static func rootRoute(of destination: MobileDestination) -> MobileRoute? {
        switch destination {
        case .notes: .kindList(.note)
        case .areas: .kindList(.area)
        case .bookmarks: .kindList(.bookmark)
        case .inbox: .inbox
        case .archive: .archive
        case .trash: .trash
        case .calendar: .calendar
        case .time: .time
        case .settings: .settings
        // Projects' screen is the tree itself, which no route names — a project has a route, the
        // list of them does not — so nothing the sidebar sends there can land on top of itself.
        case .today, .projects, .reminders, .records, .search: nil
        }
    }

    /// Adopts the drawer shell's state on expansion.
    ///
    /// The selected destination's stack is split back into root, drill-down and reading pane: the
    /// deepest route that names a root becomes the sidebar selection, and the trailing run of
    /// record leaves becomes the pane. Other destinations' stacks are deliberately dropped — a
    /// sidebar has no second drawer row to keep them warm in, and keeping them invisibly would
    /// mean restoring them somewhere the user has no way to expect.
    convenience init(expanding restoration: MobileShellModel.Restoration) {
        self.init()

        let destination = restoration.destination
        var path = restoration.paths[destination] ?? []

        // The trailing run of leaves is the reading pane.
        var detail: [MobileRoute] = []
        while let last = path.last, PadRoot(promoting: last) == nil {
            detail.insert(last, at: 0)
            path.removeLast()
        }

        // The deepest promotable route is the root; anything between it and the leaves stays as
        // content drill-down.
        if let rootIndex = path.lastIndex(where: { PadRoot(promoting: $0) != nil }),
            let promoted = PadRoot(promoting: path[rootIndex]) {
            root = promoted
            contentPath = Array(path[(rootIndex + 1)...])
        } else {
            root = Self.homeRoot(for: destination)
            contentPath = path
        }

        // A pane can only hold what a pane draws; a leaf run belongs there. On a canvas stage the
        // leaves keep living in the content column instead — unless the canvas offers an
        // inspector, which is a pane by another name.
        if root.shape == .listDetail || root.canvasInspectorWidth != nil {
            detailPath = detail
        } else {
            contentPath.append(contentsOf: detail)
        }
    }

    /// The sidebar root a bare drawer destination expands to.
    static func homeRoot(for destination: MobileDestination) -> PadRoot {
        switch destination {
        case .today: .today
        // Projects has no root of its own here, and does not need one. The phone's Projects
        // screen exists because a drawer cannot hold a tree; the iPad's sidebar holds that tree
        // permanently, a few points from wherever the stage lands. Widening a window that was on
        // the list therefore does not lose the list — it promotes it out of the stage and into
        // the sidebar, which is where it wanted to be.
        case .projects: .today
        case .calendar: .calendar
        case .reminders: .reminders
        case .records: .records(.all)
        case .notes: .kindList(.note)
        case .time: .time
        case .areas: .kindList(.area)
        case .bookmarks: .kindList(.bookmark)
        case .inbox: .inbox
        case .archive: .archive
        case .trash: .trash
        case .search: .search
        case .settings: .settings
        }
    }

    // MARK: - Restoration

    /// What survives relaunch: the selection and both columns' paths.
    struct Restoration: Codable, Hashable {
        var root: PadRoot
        var contentPath: [MobileRoute]
        var detailPath: [MobileRoute]
    }

    var restoration: Restoration {
        Restoration(root: root, contentPath: contentPath, detailPath: detailPath)
    }

    var encodedRestoration: String? {
        guard let data = try? JSONEncoder().encode(restoration) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func restore(from encoded: String) {
        guard let restored = try? JSONDecoder().decode(Restoration.self, from: Data(encoded.utf8))
        else { return }
        root = restored.root
        contentPath = restored.contentPath
        detailPath = restored.detailPath
    }
}
