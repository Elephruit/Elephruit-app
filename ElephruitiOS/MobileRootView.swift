import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitPersistence
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
/// `MobileDestination` argues the case: five slots could not hold fourteen places, so most of
/// them had been filed behind a row called "Library". The drawer holds all fourteen at their
/// real names, and gives the bottom of the screen back to the content and the thumb.
struct MobileRootView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Owned by `AdaptiveRootView`, not by this view. A window may change width class mid-session,
    /// and the journey has to survive the change — which needs one owner above both shells rather
    /// than a fresh model each time an arrangement appears.
    @Environment(MobileShellModel.self) private var shell

    /// How far the content slides. Wide enough to read a fourteen-row list comfortably,
    /// narrow enough that the screen behind it stays visibly *there* rather than replaced —
    /// the drawer is a layer over the app, not another page of it.
    private static let sidebarWidth: CGFloat = 288

    var body: some View {
        @Bindable var shell = shell

        return MobileDrawer(
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
        .sheet(isPresented: $shell.isCaptureVisible) {
            CaptureSheet()
        }
        // The two composers the fan can reach that have no screen of their own to open on. A
        // reminder and a note both land somewhere the app already draws — the list, the note's
        // own page — so they navigate. An event and an hour of tracked time are forms, and a form
        // opened from a floating button belongs over whatever the button was floating above.
        .sheet(isPresented: $shell.isEventEditorVisible) {
            EventEditorSheet(existing: nil, defaultDay: Date())
        }
        .sheet(isPresented: $shell.isManualTimeVisible) {
            ManualEntrySheet()
        }
        .task {
            // The keyboard's one-off setup cost, moved off the first tap that needs it.
            await Keyboard.warmAfterLaunch()
        }
    }

    // MARK: - Layers

    private var navigationStack: some View {
        @Bindable var shell = shell

        return NavigationStack(path: $shell.path) {
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
        // Three layers, in this order: the clock in the bottom-left, the scrim over the whole
        // screen, the fan in the bottom-right. All above the stack rather than inside it, so a
        // drill-down cannot scroll them away and a pushed screen cannot draw over them — and the
        // clock under the scrim rather than over it, because while the fan is open the clock is
        // part of the screen being asked about rather than part of the question.
        //
        // Not on the Time screen itself, where the tracker card is already showing the same clock
        // and a larger Stop a few points above it. Two stop buttons for one timer on one screen
        // is a question about which of them is the real one.
        .overlay(alignment: .bottomLeading) {
            if !isShowingTheTracker {
                MobileTimerPill()
            }
        }
        .overlay {
            MobileAddMenuScrim(isOpen: shell.isAddMenuOpen) {
                setAddMenu(open: false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            MobileAddMenu(
                isOpen: shell.isAddMenuOpen,
                setOpen: { setAddMenu(open: $0) },
                perform: { make($0) }
            )
        }
    }

    /// Whether the Time screen's own tracker card is the thing on screen.
    private var isShowingTheTracker: Bool {
        shell.destination == .time && shell.path.isEmpty
    }

    // MARK: - The plus

    /// Opens or folds the fan.
    ///
    /// The change is made plainly, without a transaction around it: the fan's controls each
    /// animate on their own curve and their own delay, and the scrim on a third — an enclosing
    /// `withAnimation` would be overridden by every one of them and would only misdescribe what
    /// happens. The motion lives with the views that own it; see ``MobileAddMenu``.
    ///
    /// A keyboard goes when the menu comes, for the same reason it goes when the drawer does —
    /// what is being asked for is somewhere other than the field currently being typed into.
    private func setAddMenu(open: Bool) {
        if open {
            Keyboard.dismiss()
            // The clock folds before the fan opens. Both live along the same bottom edge, and an
            // open card in one corner while an arc unrolls out of the other is two things asking
            // for the same attention — and the card would be answering a question the user has
            // just visibly moved on from.
            shell.isTimerExpanded = false
        }
        shell.isAddMenuOpen = open
    }

    /// What each of the fan's five means, in one table.
    ///
    /// The reminder and the note go to where the thing being made will live, and the event and
    /// the manual hour open over wherever the user already was. That split is not arbitrary: a
    /// reminder and a note are objects you go on to work with, so arriving beside them is part of
    /// making them, while an event and an hour of tracked time are facts you are recording about
    /// something else, and being moved to the calendar to record one is a journey the user did
    /// not ask for. Capture is the fifth because sometimes none of the four is the answer yet.
    private func make(_ action: MobileAddAction) {
        switch action {
        case .reminder: shell.requestNewReminder()
        case .event: shell.isEventEditorVisible = true
        case .note: createNote()
        case .time: shell.isManualTimeVisible = true
        case .capture: shell.isCaptureVisible = true
        }
    }

    /// A note, opened on its own page.
    ///
    /// Created before it is shown, rather than composed in a sheet and saved on the way out: a
    /// note is a page you write on until you leave, and there is no moment in that where it is
    /// still a draft waiting for a Save button to make it real.
    private func createNote() {
        guard let services else { return }
        services.perform {
            let created = try services.items.create(ItemDraft(kind: .note))
            services.noteChange(to: created)
            shell.push(.item(created.id))
        }
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
        case .projects: ProjectsScreen()
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
