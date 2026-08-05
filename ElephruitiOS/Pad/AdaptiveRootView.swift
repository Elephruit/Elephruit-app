import ElephruitCore
import ElephruitFeaturesCore
import SwiftUI

/// Chooses the shell the window's width class deserves, and carries the journey across the
/// boundary.
///
/// Regular width gets the iPad shell — sidebar and stage; compact width gets the phone shell —
/// a drawer and one stack. A narrow Split View or a slim Stage Manager window on an iPad is
/// compact and gets the phone shell *deliberately*: the compact arrangement of this app is a
/// designed thing, and a desktop squeezed until its panes are slivers is not.
///
/// This view owns both models and both scene-storage keys, because a handoff needs one owner:
/// when the class changes mid-session, the departing shell's state is translated into the
/// arriving shell's — the place, the drill-down, and the open record all survive a drag through
/// the Split View grabber, in both directions. The translation is `PadShellModel.collapsed()` /
/// `init(expanding:)`, pure and testable.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.services) private var services

    /// Where a window opened by value lands — "Open in New Window" on a project. `nil` for the
    /// main window, whose place is its own restored one.
    var initialRoute: MobileRoute?

    @State private var shell = MobileShellModel()
    @State private var pad = PadShellModel()

    /// Navigation survives relaunch, per scene and per shell.
    @SceneStorage("mobile.navigation") private var storedMobileNavigation: String?
    @SceneStorage("pad.navigation") private var storedPadNavigation: String?
    @State private var hasRestored = false

    /// The running timer, as the Dynamic Island sees it.
    ///
    /// Here rather than inside `MobileRootView`, which is where it was written: that view was the
    /// app's root, and is now one of two. Left where it was, a timer started on an iPad in
    /// landscape would put nothing on the Lock Screen — a feature quietly turned off by a
    /// refactor rather than by anybody's decision.
    @State private var liveActivity = TimerLiveActivityController()

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isWide {
                PadRootView()
            } else {
                MobileRootView()
            }
        }
        .environment(shell)
        .environment(pad)
        // The focused window's models, for the keyboard commands — a shortcut in one window never
        // moves another.
        .focusedSceneValue(\.mobileShell, shell)
        .focusedSceneValue(\.padShell, isWide ? pad : nil)
        .focusedSceneValue(\.focusedServices, services)
        .task {
            guard !hasRestored else { return }
            hasRestored = true
            restore()
        }
        .onChange(of: sizeClass) { previous, current in
            guard hasRestored, let previous, let current, previous != current else { return }
            handoff(to: current)
        }
        .onChange(of: shell.restoration) {
            storedMobileNavigation = shell.encodedRestoration
        }
        .onChange(of: pad.restoration) {
            storedPadNavigation = pad.encodedRestoration
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        // The island is not driven by the commands that change the timer — see
        // `TimerLiveActivityController`. It is driven by *what the timer is*, read here on every
        // pass the observation system already wakes this view for, and compared with what the
        // system is currently showing.
        .task {
            liveActivity.adoptExisting()
            liveActivity.apply(timerActivityState)
        }
        .onChange(of: timerActivityState) { _, state in
            liveActivity.apply(state)
        }
    }

    /// What the Dynamic Island should be saying, or `nil` for nothing.
    private var timerActivityState: ElephruitTimerAttributes.ContentState? {
        .current(services)
    }

    // MARK: - Arrival

    private func restore() {
        if isWide {
            if let storedPadNavigation {
                pad.restore(from: storedPadNavigation)
            }
            // Development-only review routing, after restoration so it wins — the whole point is
            // opening the build onto the screen under review.
            if let requested = PadReviewLaunch.requestedRoot(services: services) {
                pad.select(requested)
                if let detail = PadReviewLaunch.requestedDetail(for: requested, services: services) {
                    pad.showDetail(detail)
                }
            }
            installPadRedirect()
            if let initialRoute {
                pad.route(initialRoute)
            }
        } else {
            if let storedMobileNavigation {
                shell.restore(from: storedMobileNavigation)
            }
            if let initialRoute {
                shell.open(initialRoute, in: initialRoute.owningDestinationForWindow)
            }
        }
    }

    private func handoff(to current: UserInterfaceSizeClass) {
        if current == .regular {
            let expanded = PadShellModel(expanding: shell.restoration)
            pad.root = expanded.root
            pad.contentPath = expanded.contentPath
            pad.detailPath = expanded.detailPath
            installPadRedirect()
        } else {
            shell.routeRedirect = nil
            let collapsed = pad.collapsed()
            shell.destination = collapsed.destination
            for (destination, path) in collapsed.paths {
                shell.setPath(path, for: destination)
            }
        }
    }

    /// While the iPad shell is up, every `shell.push(...)` in every screen is the iPad's to place —
    /// see `PadShellModel.route(_:)`.
    private func installPadRedirect() {
        shell.routeRedirect = { [weak pad] route in
            guard let pad else { return false }
            pad.route(route)
            return true
        }
    }

    // MARK: - Deep links

    /// The `elephruit:` scheme, honoured on the same read-only terms as the Mac: every URL
    /// navigates, none mutates.
    ///
    /// One handler for both shells, because a link means the same thing at either width. It names
    /// a place in the compact vocabulary — the one the Mac's own scheme uses — and the wide shell
    /// expands that place into a sidebar root rather than keeping a second table that could come
    /// to a different conclusion about where `elephruit://notes` goes.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "elephruit" else { return }

        if let host = url.host(), let destination = MobileDestination(rawValue: host) {
            go(to: destination)
            return
        }

        switch url.host() {
        case "people": go(to: .records)
        case "library": go(to: .notes)
        case "tasks": go(to: .reminders)
        case "capture":
            if isWide { pad.isCaptureVisible = true } else { shell.isCaptureVisible = true }
        case "item":
            if let id = UUID(uuidString: url.lastPathComponent),
                let item = try? services?.items.item(id: id) {
                let route = MobileShellModel.route(for: item.kind, id: id)
                if isWide {
                    pad.route(route)
                } else {
                    shell.open(route, in: route.owningDestinationForWindow)
                }
            }
        default: break
        }
    }

    private func go(to destination: MobileDestination) {
        if isWide {
            pad.select(PadShellModel.homeRoot(for: destination))
        } else {
            shell.select(destination)
        }
    }
}
