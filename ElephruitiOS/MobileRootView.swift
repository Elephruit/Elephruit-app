import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The iPhone shell: one stack, a drawer behind it, a capture button, and the running timer.
///
/// ### One way back
/// The screen is a single `NavigationStack`, and the drawer sits behind it. Going back is one
/// idea at every depth: swipe right, or tap the chevron in the upper left. Inside a stack that
/// pops a level; at the root it slides the screen aside and shows the drawer. There is no
/// point in the app where "back" means something else, and no destination that is reachable by
/// a different motion than every other destination.
///
/// ### Why the tab bar is gone
/// `MobileDestination` argues the case: five slots could not hold thirteen places, so seven of
/// them had been filed behind a row called "Library". The drawer holds all thirteen at their
/// real names, and gives the bottom of the screen back to the content and the thumb.
struct MobileRootView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shell = MobileShellModel()

    /// How far the content slides. Wide enough to read a thirteen-row list comfortably,
    /// narrow enough that the screen behind it stays visibly *there* rather than replaced —
    /// the drawer is a layer over the app, not another page of it.
    private static let sidebarWidth: CGFloat = 288

    /// The strip along the leading edge that starts the drawer. Matches the width the system's
    /// own interactive-pop gesture claims, so the two feel like one gesture at different
    /// depths rather than two gestures with different targets.
    private static let edgeGestureWidth: CGFloat = 20

    /// How far a drag must travel before it decides. Below this the drawer springs back, which
    /// keeps a hesitant thumb from committing to a screen change it did not mean.
    private static let dragCommitDistance: CGFloat = 60

    /// Navigation survives relaunch: the destination and each destination's drill-down.
    @SceneStorage("mobile.navigation") private var storedNavigation: String?
    @State private var hasRestored = false

    /// The live drag offset, in points, while a gesture is in flight.
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            contentLayer
            sidebarLayer
        }
        .background(Theme.Colors.windowBackground)
        .environment(shell)
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

    // MARK: - Layers

    /// The drawer, sliding into the strip the content vacates.
    ///
    /// Above the content in z-order rather than behind it, though it never overlaps: the two
    /// occupy the screen's width between them. A `NavigationStack` is a UIKit container that
    /// shadows its siblings in the accessibility tree, so a drawer *behind* one is a drawer
    /// VoiceOver and the UI tests cannot reach — visible, tappable by a sighted thumb, and
    /// absent from the only two readings of the app that check whether it is really there.
    ///
    /// It travels exactly as far as the content does, so the two move as one piece: the screen
    /// slides right and the drawer follows it in, occupying the strip the screen vacates and
    /// never overlapping it. A drawer that lagged or led would read as two layers arguing
    /// about one gesture.
    private var sidebarLayer: some View {
        MobileSidebar()
            .frame(width: Self.sidebarWidth)
            .offset(x: revealedWidth - Self.sidebarWidth)
            .accessibilityHidden(revealedWidth == 0)
    }

    private var contentLayer: some View {
        navigationStack
            .overlay {
                // The scrim both dims and disarms: while the drawer is open the screen behind
                // it is scenery, and a tap on scenery should close the drawer rather than
                // land on whatever control happens to be under the thumb.
                if revealedWidth > 0 {
                    Rectangle()
                        .fill(Theme.Colors.scrim.opacity(0.28 * revealProgress))
                        .contentShape(Rectangle())
                        .onTapGesture { setSidebar(open: false) }
                        .accessibilityLabel("Close the sidebar")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { setSidebar(open: false) }
                }
            }
            .offset(x: revealedWidth)
            .overlay(alignment: .leading) { edgeGestureCatcher }
            .gesture(shell.isSidebarOpen ? closeDrag : nil)
    }

    private var navigationStack: some View {
        NavigationStack(path: $shell.path) {
            MobileDestinationView(destination: shell.destination)
                .navigationDestination(for: MobileRoute.self) { route in
                    MobileRouteView(route: route)
                }
                .toolbar {
                    // At the root the stack has no back button of its own, so the shell
                    // supplies the same chevron pointing at the same idea: one more step back
                    // than this screen is the drawer.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            setSidebar(open: true)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Show the sidebar")
                        .accessibilityIdentifier("mobile.sidebar.button")
                    }
                }
        }
        .overlay(alignment: .bottomTrailing) {
            CaptureButton {
                shell.isCaptureVisible = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Attached only while a timer runs: a permanent blank bar would be chrome with
            // nothing to say, and it would cost every screen the height to say it.
            if services?.timer.running != nil {
                TimerAccessoryView()
                    .frame(height: 44)
                    .background(.bar)
            }
        }
    }

    /// The leading strip that starts the drawer, live only at the root of a stack.
    ///
    /// Above the root, the same strip belongs to the system's interactive pop — and it is the
    /// same gesture in the user's hand, so it must not be intercepted here. Popping the last
    /// route arms this again, which is what makes "keep swiping right" walk all the way home.
    @ViewBuilder
    private var edgeGestureCatcher: some View {
        if !shell.isSidebarOpen && !shell.canPop {
            Color.clear
                .frame(width: Self.edgeGestureWidth)
                .contentShape(Rectangle())
                .gesture(openDrag)
        }
    }

    // MARK: - The gesture

    private var openDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragTranslation = max(0, min(value.translation.width, Self.sidebarWidth))
            }
            .onEnded { value in
                let committed = value.translation.width > Self.dragCommitDistance
                    || value.predictedEndTranslation.width > Self.sidebarWidth / 2
                dragTranslation = 0
                setSidebar(open: committed)
            }
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragTranslation = max(-Self.sidebarWidth, min(0, value.translation.width))
            }
            .onEnded { value in
                let closed = value.translation.width < -Self.dragCommitDistance
                    || value.predictedEndTranslation.width < -Self.sidebarWidth / 2
                dragTranslation = 0
                setSidebar(open: !closed)
            }
    }

    /// How far the content currently sits from its home position: the settled state plus
    /// whatever the thumb is adding, clamped so no drag can push past either end.
    private var revealedWidth: CGFloat {
        let settled: CGFloat = shell.isSidebarOpen ? Self.sidebarWidth : 0
        return min(max(settled + dragTranslation, 0), Self.sidebarWidth)
    }

    private var revealProgress: Double {
        Double(revealedWidth / Self.sidebarWidth)
    }

    private func setSidebar(open: Bool) {
        withCalmAnimation(Theme.Motion.standard) {
            shell.isSidebarOpen = open
        }
    }

    /// The `elephruit:` scheme, honoured on the same read-only terms as the Mac: every URL
    /// navigates, none mutates.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "elephruit" else { return }

        // A destination named by a link is a destination, not a drill-down: the host alone is
        // enough to place the user, so the shell steps there and pops whatever was open.
        if let host = url.host(), let destination = MobileDestination(rawValue: host) {
            shell.select(destination)
            return
        }

        switch url.host() {
        case "people": shell.select(.records)
        case "library": shell.select(.today); shell.isSidebarOpen = true
        case "notes": shell.select(.notes)
        case "capture": shell.isCaptureVisible = true
        case "item":
            if let id = UUID(uuidString: url.lastPathComponent),
                let item = try? services?.items.item(id: id) {
                shell.open(MobileShellModel.route(for: item.kind, id: id), in: shell.destination)
            }
        default: break
        }
    }
}

/// One destination's root screen.
///
/// The companion to `MobileRouteView`: that table turns a drill-down into a screen, and this
/// one turns a place into a screen. Two tables, no third way to arrive anywhere.
struct MobileDestinationView: View {
    let destination: MobileDestination

    var body: some View {
        switch destination {
        case .today: TodayScreen()
        case .calendar: CalendarScreen()
        case .reminders: RemindersScreen()
        case .records: RecordsScreen()
        case .notes: ItemListScreen(source: .kind(.note))
        case .time: TimeScreen()
        case .areas: ItemListScreen(source: .kind(.area))
        case .bookmarks: ItemListScreen(source: .kind(.bookmark))
        case .inbox: InboxScreen()
        case .archive: ItemListScreen(source: .archive)
        case .trash: TrashScreen()
        case .search: SearchScreen()
        case .settings: SettingsScreen()
        }
    }
}

/// The floating quick-capture button.
struct CaptureButton: View {
    /// How far above the shell's bottom edge the button rests. The tab bar it used to clear is
    /// gone, so this is now the ordinary content inset — the button sits where the thumb
    /// already is instead of where the chrome used to be.
    private static let bottomClearance: CGFloat = Theme.Spacing.section

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
        .padding(.bottom, Self.bottomClearance)
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
