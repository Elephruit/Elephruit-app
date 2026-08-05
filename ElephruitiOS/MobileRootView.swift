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

    /// Navigation survives relaunch: the destination and each destination's drill-down.
    @SceneStorage("mobile.navigation") private var storedNavigation: String?
    @State private var hasRestored = false

    var body: some View {
        MobileDrawer(
            isOpen: shell.isSidebarOpen,
            canPop: shell.canPop,
            width: Self.sidebarWidth,
            // Plain, because the drawer animates its own settle: a gesture that has just been
            // let go needs a spring that continues it, and only the view holding the gesture
            // knows that is what happened.
            setOpen: { applySidebar(open: $0) }
        ) {
            navigationStack
        } drawer: {
            MobileSidebar()
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
            // The keyboard's one-off setup cost, moved off the first tap that needs it.
            await Keyboard.warmAfterLaunch()
        }
        .onChange(of: shell.restoration) {
            storedNavigation = shell.encodedRestoration
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    // MARK: - Layers

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
        .overlay(alignment: .bottomTrailing) { primaryButton }
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

    /// The one button the shell floats over every screen — and the reason it is not always the
    /// same button.
    ///
    /// Quick capture is what a plus means on a screen with nothing to add to: it writes into the
    /// Inbox because the Inbox is where a thought with no home goes. On Reminders that is the
    /// wrong answer to a plus held over a list of reminders — the thing being added is a
    /// reminder, it belongs in the list under the thumb, and filing it in the Inbox for sorting
    /// later is an extra journey for a decision that has already been made.
    private var primaryButton: some View {
        CaptureButton(
            label: composesReminders ? "New reminder" : "Quick capture",
            hint: composesReminders
                ? "Opens a composer at the end of the list"
                : "Captures a reminder, note, or anything else into the Inbox"
        ) {
            if composesReminders {
                shell.requestNewReminder()
            } else {
                shell.isCaptureVisible = true
            }
        }
    }

    /// Whether the screen under the button is the reminders list itself. A drill-down from it —
    /// a smart list, one reminder's detail — is not, because the composer that would open lives
    /// on the screen that got left behind.
    private var composesReminders: Bool {
        shell.destination == .reminders && !shell.canPop
    }

    /// The chevron's version: the same change, animated, because nothing was already moving.
    private func setSidebar(open: Bool) {
        withCalmAnimation(Theme.Motion.drawer) {
            applySidebar(open: open)
        }
    }

    /// Opening the drawer is leaving the screen, so the keyboard goes with it.
    ///
    /// Both ways in run through here — the chevron and the edge swipe — because a keyboard left
    /// standing over a drawer is the same wrong picture however the drawer was asked for. It also
    /// answers a question the chevron used to leave hanging: tapped while writing a reminder, it
    /// slid the screen aside and left the keyboard sitting on top of the drawer.
    private func applySidebar(open: Bool) {
        if open { Keyboard.dismiss() }
        shell.isSidebarOpen = open
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

/// The shell's floating button: whatever the screen under it means by "add".
struct CaptureButton: View {
    /// How far above the shell's bottom edge the button rests. The tab bar it used to clear is
    /// gone, so this is now the ordinary content inset — the button sits where the thumb
    /// already is instead of where the chrome used to be.
    private static let bottomClearance: CGFloat = Theme.Spacing.section

    /// The glyph's box, which the glass grows by a little over a point: 40 here measures 41 on
    /// screen, against the 58 this used to draw.
    ///
    /// Two layers of padding had to be found before that number meant anything. It began as a
    /// 56-point box inside `.buttonStyle(.glassProminent)` — a style that pads what it is handed
    /// *and* refuses to go below its own minimum, so the button drew at 58 whatever this said,
    /// and taking it from 56 to 44 to 26 changed not one pixel. Applying the glass to the shape
    /// directly is what made the number load-bearing again.
    ///
    /// Smaller because this floats over lists whose content is the point, permanently, on every
    /// screen: the loudest object in the room should not be the one you use least.
    private static let glyphBox: CGFloat = 40

    var label: String
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: Self.glyphBox, height: Self.glyphBox)
                .glassEffect(
                    .regular.tint(Theme.Colors.selection).interactive(),
                    in: .circle
                )
                // A margin the eye cannot see and the thumb can: the drawn circle is 41 points,
                // and the target has to be 44 whatever the drawing does.
                .padding(Theme.Spacing.hairline)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .elevation(.floating)
        .padding(.trailing, Theme.Spacing.large)
        .padding(.bottom, Self.bottomClearance)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
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
