import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The iPhone shell: five tabs, system search, a capture button, and the running timer.
///
/// ### The ranking behind the tabs
/// Orient to the day, work the reminders, look a record up, find anything — those earn
/// tabs because they are where sessions start. Search gets the system's own position.
/// Capture is an action rather than a place, so it is the floating button, reachable by a
/// thumb from every tab. Notes, Calendar, Time, Inbox, Bookmarks, Archive, Trash and
/// Settings are all real and all rarer, and live one tap away in Library — a hierarchy,
/// not a demotion.
struct MobileRootView: View {
    @Environment(\.services) private var services

    @State private var shell = MobileShellModel()

    /// Navigation survives relaunch: the tab and each tab's drill-down.
    @SceneStorage("mobile.navigation") private var storedNavigation: String?
    @State private var hasRestored = false

    var body: some View {
        // The accessory is attached only while a timer runs: the modifier draws its
        // capsule even for empty content, and a permanent blank pill above the tab bar
        // would be chrome with nothing to say.
        if services?.timer.running != nil {
            tabShell.tabViewBottomAccessory {
                TimerAccessoryView()
            }
        } else {
            tabShell
        }
    }

    private var tabShell: some View {
        TabView(selection: $shell.selectedTab) {
            Tab(MobileTab.today.title, systemImage: MobileTab.today.symbolName, value: .today) {
                tabStack(for: .today) { TodayScreen() }
            }

            Tab(
                MobileTab.reminders.title,
                systemImage: MobileTab.reminders.symbolName,
                value: .reminders
            ) {
                tabStack(for: .reminders) { RemindersScreen() }
            }

            Tab(
                MobileTab.records.title,
                systemImage: MobileTab.records.symbolName,
                value: .records
            ) {
                tabStack(for: .records) { RecordsScreen() }
            }

            Tab(
                MobileTab.library.title,
                systemImage: MobileTab.library.symbolName,
                value: .library
            ) {
                tabStack(for: .library) { LibraryScreen() }
            }

            Tab(value: .search, role: .search) {
                tabStack(for: .search) { SearchScreen() }
            }
        }
        .environment(shell)
        .tabBarMinimizeBehavior(.onScrollDown)
        // The capture button rides above the tab bar, trailing — where a right thumb rests.
        // An overlay rather than a tab: capture is something you do, not somewhere you go,
        // and a tab that opens a sheet breaks the promise every other tab makes.
        .overlay(alignment: .bottomTrailing) {
            CaptureButton {
                shell.isCaptureVisible = true
            }
        }
        .sheet(isPresented: $shell.isCaptureVisible) {
            CaptureSheet()
        }
        .task {
            guard !hasRestored else { return }
            hasRestored = true
            if let storedNavigation {
                shell.restore(from: storedNavigation)
            }
        }
        .onChange(of: shell.restoration) {
            storedNavigation = shell.encodedRestoration
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    /// One tab's navigation stack, with the shared route table attached.
    private func tabStack<Root: View>(
        for tab: MobileTab,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(
            path: Binding(
                get: { shell.path(for: tab) },
                set: { shell.setPath($0, for: tab) }
            )
        ) {
            root()
                .navigationDestination(for: MobileRoute.self) { route in
                    MobileRouteView(route: route)
                }
        }
    }

    /// The `elephruit:` scheme, honoured on the same read-only terms as the Mac: every URL
    /// navigates, none mutates.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "elephruit" else { return }
        switch url.host() {
        case "today": shell.selectedTab = .today
        case "reminders": shell.popToRoot(of: .reminders); shell.selectedTab = .reminders
        case "records", "people": shell.popToRoot(of: .records); shell.selectedTab = .records
        case "library": shell.popToRoot(of: .library); shell.selectedTab = .library
        case "search": shell.selectedTab = .search
        case "inbox": shell.open(.inbox, in: .library)
        case "calendar": shell.open(.calendar, in: .library)
        case "time": shell.open(.time, in: .library)
        case "settings": shell.open(.settings, in: .library)
        case "trash": shell.open(.trash, in: .library)
        case "capture": shell.isCaptureVisible = true
        case "item":
            if let id = UUID(uuidString: url.lastPathComponent),
                let item = try? services?.items.item(id: id) {
                shell.open(MobileShellModel.route(for: item.kind, id: id), in: shell.selectedTab)
            }
        default: break
        }
    }
}

/// The floating quick-capture button.
struct CaptureButton: View {
    /// How far above the shell's bottom edge the button rests: clear of the tab bar in both
    /// its full and minimised states, where a right thumb naturally arrives. A size decision
    /// named once, like every `Theme.Size` value — not a spacing on the grid, which is why it
    /// is not a `Theme.Spacing` token.
    private static let tabBarClearance: CGFloat = 76

    /// The button's face: comfortably above the 44-point minimum target, matching the
    /// platform's floating-action convention.
    private static let diameter: CGFloat = 56

    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: Self.diameter, height: Self.diameter)
        }
        .buttonStyle(.glassProminent)
        .clipShape(Circle())
        .elevation(.floating)
        .padding(.trailing, Theme.Spacing.large)
        .padding(.bottom, Self.tabBarClearance)
        .accessibilityLabel("Quick capture")
        .accessibilityHint("Captures a reminder, note, or anything else into the Inbox")
        .accessibilityIdentifier("mobile.capture.button")
    }
}

/// The library could not open. Same information, same recovery honesty as the Mac.
struct MobileFailureView: View {
    let error: AppError
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.Text.heroGlyph)
                .foregroundStyle(Theme.Colors.warning)

            Text(error.errorDescription ?? "The library could not be opened.")
                .font(Theme.Text.title)
                .multilineTextAlignment(.center)

            if let reason = error.failureReason {
                Text(reason)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.generous)
    }
}
