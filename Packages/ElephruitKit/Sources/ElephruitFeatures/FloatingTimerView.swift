import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The running timer, floating over whatever else you are doing.
///
/// ### Why this exists when the sidebar already shows one
/// The sidebar row is only there while the Time module's sidebar is. Open Tasks, or People, or the
/// calendar, and the one thing that must never be forgotten disappears — and a forgotten timer is
/// how eleven hours get billed to a task that took two. This sits above every screen in the window,
/// so the answer to *is it still going* never requires navigation.
///
/// ### Why the lower right
/// Because it is the corner nothing else in this app puts anything in. The sidebar's own footer is
/// bottom-left, lists are read from the top-left, and a floating panel over the leading edge covers
/// navigation somebody is using to get somewhere. Bottom-right is out of the reading path and out of
/// the way of the scroll bar's useful half.
///
/// ### What it does not do
/// It does not edit. No description field, no pickers, no clock you can type into — all of that is
/// on the Time screen, and duplicating it here would be a second place for the same edit to be made
/// differently. This answers one question and offers the three actions that answer it: keep going,
/// hold on, stop.
struct FloatingTimerView: View {
    @Environment(\.services) private var services

    /// Takes the window to the Time module, so the widget is a way *in* rather than a dead end.
    let onOpen: () -> Void

    /// Puts the whole app away and leaves the clock. `nil` where there is nothing to collapse.
    var onCollapse: (() -> Void)?

    /// Whether this is inside the mini panel rather than overlaid on a window.
    ///
    /// The two need different chrome and it is not cosmetic: overlaid, the card supplies its own
    /// inset from the window edge and its own shadow because it is floating over content. Inside the
    /// panel, the *panel* is the floating thing — it has the shadow, and the inset would be a margin
    /// of nothing between the card and a window edge one point away.
    var isEmbedded = false

    /// Whether to drop the description and show only the clock and its buttons.
    ///
    /// The name is what makes a floating clock worth having — time passing is not news, time passing
    /// *on the client brief* is. But a description is as long as somebody typed it, and this is the
    /// opt-out for when you already know what you are doing and want the pixels back.
    var isCompact = false

    @State private var isHovering = false

    var body: some View {
        if let state {
            // ### Why an embedded copy draws no card
            // Because the panel it sits in *is* the card, and it has to be drawn whether or not
            // anything is running — a panel that lost its background the moment a timer stopped was
            // text floating on the desktop with no way back into the app. Overlaid on a window the
            // opposite is true: there is no panel, so this supplies its own surface, its own inset
            // from the window edge, and the one shadow that says it is floating.
            content(state)
                .padding(.vertical, isEmbedded ? 0 : Theme.Spacing.small)
                .padding(.horizontal, isEmbedded ? 0 : Theme.Spacing.medium)
                .modifier(FloatingCard(tint: state.tint, isEnabled: !isEmbedded))
                .padding(isEmbedded ? 0 : Theme.Spacing.large)
                .onHover { isHovering = $0 }
                .calmAnimation(value: isHovering)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Time.floatingTimer)
        }
    }

    // MARK: - Content

    private func content(_ state: State) -> some View {
        HStack(spacing: isCompact ? Theme.Spacing.small : Theme.Spacing.medium) {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: state.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.title3)
                        .foregroundStyle(state.tint)
                        .symbolEffect(.pulse, options: state.isPaused ? .nonRepeating : .repeating)

                    if !isCompact {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(state.title)
                                .font(Theme.Text.rowSubtitle)
                                .lineLimit(1)
                                .foregroundStyle(Theme.Colors.primaryText)

                            Text(state.isPaused ? "Paused" : "Tracking")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(state.tint)
                        }
                        .frame(maxWidth: 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The dot keeps its job when the words are gone: it is still the way back into the app,
            // and it still says paused or running by its shape and colour.
            .help(isCompact ? "\(state.title) — open the Time log" : "Open the Time log")

            clock(state)

            controls(state)

            collapseButton
        }
    }

    /// Shrink the app to this.
    ///
    /// ### Why it only appears on hover
    /// Because it is not part of the answer. The widget exists to say what is running and let you
    /// stop it; collapsing the application is a thing you do occasionally and deliberately, and a
    /// permanently visible button for it would be a fourth control competing with the three that
    /// matter. Revealed on hover it costs nothing until the pointer is already here — which is the
    /// only moment anybody is going to press it.
    ///
    /// It holds its place in the layout while hidden, so the card does not change width under the
    /// pointer as it arrives.
    @ViewBuilder
    private var collapseButton: some View {
        if let onCollapse {
            Button(action: onCollapse) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(Theme.Text.metadata)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .opacity(isHovering ? 1 : 0)
            .help("Collapse Elephruit to just this timer")
            .accessibilityLabel("Collapse to the timer")
            .accessibilityIdentifier(AccessibilityID.Time.floatingCollapse)
        }
    }

    /// Counts the whole sitting — this stretch plus any before the last pause — so a pause does not
    /// look like an hour going missing.
    @ViewBuilder
    private func clock(_ state: State) -> some View {
        if let since = state.runningSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(TimeFormatting.stopwatch(state.accumulated + max(0, context.date.timeIntervalSince(since))))
                    .font(clockFont)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: clockWidth, alignment: .trailing)
        } else {
            Text(TimeFormatting.stopwatch(state.accumulated))
                .font(clockFont)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: clockWidth, alignment: .trailing)
        }
    }

    private var clockFont: Font {
        .system(.title3, design: .rounded, weight: .medium)
    }

    /// A fixed column while the description is showing, so the clock does not shuffle sideways as
    /// the digits change — and `nil` when compact, where a column wide enough for `10:05:59` around
    /// a reading of `2:56` is just a gap.
    private var clockWidth: CGFloat? {
        isCompact ? nil : 84
    }

    private func controls(_ state: State) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button {
                if state.isPaused {
                    services?.timer.resumeFromPause()
                } else {
                    services?.timer.pause()
                }
            } label: {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help(state.isPaused
                ? "Carry on with this"
                : "Hold on. The entry is closed and the gap is not tracked; carrying on opens another.")
            .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
            .accessibilityIdentifier(AccessibilityID.Time.floatingPause)

            Button {
                services?.timer.restart()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .disabled(state.isPaused)
            .help("Start this stretch again from zero. What has been worked so far is kept, not thrown away.")
            .accessibilityLabel("Restart")
            .accessibilityIdentifier(AccessibilityID.Time.floatingRestart)

            Button {
                services?.timer.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(Theme.Text.rowSubtitle)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.onAccent)
            .background(Circle().fill(Theme.Colors.destructive))
            .help(state.isPaused ? "Finish here" : "Stop and keep this time")
            .accessibilityLabel("Stop")
            .accessibilityIdentifier(AccessibilityID.Time.floatingStop)
        }
    }

    // MARK: - State

    /// What the widget is showing, whichever of the two ways there is something to show.
    private struct State {
        var title: String
        var isPaused: Bool

        /// When the current stretch began. `nil` while paused, which is what stops the clock.
        var runningSince: Date?

        /// Everything worked before the current stretch.
        var accumulated: TimeInterval

        var tint: Color {
            isPaused ? Theme.Colors.warning : Theme.Colors.destructive
        }
    }

    /// `nil` when nothing is running and nothing is paused — the case where the widget is absent
    /// entirely rather than present and empty.
    private var state: State? {
        guard let services else { return nil }

        if let running = services.timer.running {
            return State(
                title: running.displayTitle,
                isPaused: false,
                runningSince: running.startedAt,
                accumulated: services.timer.accumulatedBeforeCurrent
            )
        }

        if let paused = services.timer.paused {
            return State(
                title: paused.displayTitle,
                isPaused: true,
                runningSince: nil,
                accumulated: paused.accumulated
            )
        }

        return nil
    }
}

/// The surface a floating timer sits on: one fill, one hairline, one shadow.
///
/// Shared so the overlaid widget and the panel cannot drift apart, and so the "one of each" rule
/// `decorationDoesNotAccumulate` enforces is satisfied in a single place rather than twice.
struct FloatingCard: ViewModifier {
    let tint: Color

    /// `false` inside the mini panel, which supplies all three itself.
    var isEnabled = true

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .fill(Theme.Colors.contentBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(tint.opacity(0.35))
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else {
            content
        }
    }
}

// MARK: - Collapsed

/// What is left of Elephruit when it is collapsed.
///
/// The same three controls as the floating widget, plus the two that only make sense once the app
/// is away: pin it above everything, and put the app back. They live behind a menu, for the reason
/// the collapse button is hidden — a surface whose whole point is that there is one thing to look at
/// cannot also carry five buttons.
///
/// When nothing is running it says so rather than disappearing. A window that vanished the moment a
/// timer stopped would take the only way back to the app with it.
struct MiniTimerView: View {
    @Environment(\.services) private var services

    let controller: MiniTimerController

    /// Whether the window controls are showing.
    @State private var isMenuOpen = false

    /// Whether they are showing because somebody clicked the dots rather than hovered them.
    ///
    /// Clicked open, they stay open until clicked shut. A menu that evaporated the moment the
    /// pointer wandered off would be one you have to keep re-opening to press two things in it.
    @State private var isMenuPinned = false

    /// The pending open or close, so the next hover can cancel it.
    @State private var menuTask: Task<Void, Never>?

    /// Long enough that a pointer crossing the dots on its way somewhere else does not open them,
    /// short enough that a pointer that stopped on them is not left waiting.
    private static let openDelay = Duration.milliseconds(180)

    /// The grace after the pointer leaves. Covers the gap between the pill and whatever the pointer
    /// clipped on the way past, so a hand that overshoots by two points does not lose the menu.
    private static let closeDelay = Duration.milliseconds(320)

    /// Red while tracking, amber while paused, quiet when neither — so the panel says which of the
    /// three it is before any of the words are read.
    private var tint: Color {
        if services?.timer.paused != nil { return Theme.Colors.warning }
        if services?.timer.running != nil { return Theme.Colors.destructive }
        return Theme.Colors.separator
    }

    var body: some View {
        // ### Why the window controls are on the left, and behind a menu
        // Three complaints, one cause. On the right they sat *after* Stop, so a pill whose whole job
        // is one clock and three timer buttons ended in a run of six — and holding their place while
        // invisible left a band of nothing on a surface small enough for it to be most of the width.
        // Revealing them on hover of the whole pill fixed the width and introduced the third: the
        // panel changed shape every time the pointer passed over it on its way to something else.
        //
        // Splitting them by what they act on fixes the first two. The right-hand group acts on the
        // *timer*. The left-hand group acts on the *window*: how wide, always on top, put it back.
        // The dots fix the third by making the pill's own hover mean nothing — expanding is now
        // something you aim at, on a target that says so.
        //
        // The dots sit *between* the controls and the clock rather than at the leading edge, so the
        // panel — anchored by its right edge — grows leftwards past them and the thing under the
        // pointer never moves out from under it.
        HStack(spacing: Theme.Spacing.small) {
            if isMenuOpen {
                windowControls
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            menuButton

            FloatingTimerView(
                onOpen: { controller.expand() },
                isEmbedded: true,
                isCompact: controller.isCompact
            )
            .fixedSize()

            if services?.timer.running == nil, services?.timer.paused == nil {
                idle
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .padding(.horizontal, Theme.Spacing.medium)
        .modifier(FloatingCard(tint: tint))
        .padding(Theme.Spacing.small)
        .fixedSize()
        // Only *leaving* the pill is the pill's business. Arriving anywhere on it means nothing,
        // which is the whole point of the dots; but once the menu is open the pointer has to be
        // free to travel from the dots to the buttons without the thing closing under it.
        .onHover { inside in
            if !inside { scheduleClose() }
        }
        .calmAnimation(value: isMenuOpen)
        // Both changes of shape animate, and for the same reason: the panel's right edge is pinned,
        // so every one of them is the left edge travelling. A width that jumped would read as the
        // window being replaced rather than as it opening up.
        .calmAnimation(value: controller.isCompact)
        .background {
            // ### Why the size is reported rather than measured from outside
            // The panel is sized by hand, and asking the hosting view how big it wants to be got the
            // answer for the *previous* contents every time — see `contentSizeChanged(to:)`. This
            // says how big it actually is, at the moment it is that big, including every step of an
            // animation. The window then tracks it frame by frame, which is what makes the left edge
            // slide rather than snap.
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in
                        controller.contentSizeChanged(to: size)
                    }
            }
        }
        .onDisappear { menuTask?.cancel() }
        .accessibilityIdentifier(AccessibilityID.Time.miniTimer)
    }

    /// The way in to everything that is not the timer.
    ///
    /// ### Why it is three dots and not one of the buttons
    /// Because it has to be legible as *there is more here* without being a fourth thing competing
    /// with Pause, Restart and Stop — and the vertical ellipsis is the one mark that says exactly
    /// that and nothing else. Hovering it opens the menu after a beat; clicking it opens the menu
    /// and leaves it open, for the times you want to change the width *and* pin it.
    private var menuButton: some View {
        Button(action: toggleMenu) {
            // Turned on its side rather than named vertically, because SF Symbols has no vertical
            // ellipsis to name — and the rotation is exact, so nothing is lost by asking for it.
            Image(systemName: "ellipsis")
                .font(Theme.Text.metadata)
                .rotationEffect(.degrees(90))
                .frame(width: 18, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isMenuOpen ? Theme.Colors.primaryText : Theme.Colors.secondaryText)
        .onHover { inside in
            if inside { scheduleOpen() } else { cancelPendingOpen() }
        }
        .help("Size, keep on top, and back to Elephruit")
        .accessibilityLabel("Window options")
        .accessibilityIdentifier(AccessibilityID.Time.miniTimerMenu)
    }

    // MARK: - Opening and closing

    /// Opens after a beat, unless the pointer has moved on by then.
    private func scheduleOpen() {
        guard !isMenuOpen else { return }

        menuTask?.cancel()
        menuTask = Task { @MainActor in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled else { return }
            isMenuOpen = true
        }
    }

    /// Drops a pending open when the pointer leaves the dots again.
    ///
    /// Without this the delay only moves the problem: a pointer crossing the dots on its way to Stop
    /// asked for nothing, and would still have the menu arrive on top of it a fifth of a second later.
    private func cancelPendingOpen() {
        guard !isMenuOpen else { return }
        menuTask?.cancel()
    }

    /// Closes after a grace, unless it was clicked open or the pointer comes back.
    private func scheduleClose() {
        menuTask?.cancel()
        guard isMenuOpen, !isMenuPinned else { return }

        menuTask = Task { @MainActor in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled else { return }
            isMenuOpen = false
        }
    }

    /// A click is the deliberate version of the hover: it opens immediately and stays.
    ///
    /// Clicking an already-open menu shuts it, whether it was opened by a click or by resting on the
    /// dots — the dots are the control for the menu, and a control that only works one way is a
    /// control somebody presses twice wondering why nothing happened.
    private func toggleMenu() {
        menuTask?.cancel()
        isMenuPinned = !isMenuOpen
        isMenuOpen = isMenuPinned
    }

    /// Shuts the menu outright, for the one control on it that puts the panel away.
    ///
    /// The panel is hidden rather than destroyed, so without this a menu left open — or worse,
    /// clicked open — would still be open the next time somebody collapsed the app.
    private func closeMenu() {
        menuTask?.cancel()
        isMenuPinned = false
        isMenuOpen = false
    }

    /// Shown when nothing is being tracked, so the panel still explains itself and still has a way
    /// back into the app.
    private var idle: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "timer")
                .foregroundStyle(Theme.Colors.secondaryText)

            Text("Nothing tracking")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    /// What acts on the window rather than on the timer.
    private var windowControls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button {
                controller.isCompact.toggle()
            } label: {
                // A button shows what pressing it will do, not what state it is in — the rule the
                // start/stop button on an item already follows. Compact, this widens: arrows apart.
                // Wide, this narrows: arrows together. They were the other way round, so the one
                // control on the panel whose meaning is carried entirely by its glyph was saying the
                // opposite of what it did.
                Image(systemName: controller.isCompact
                    ? "arrow.left.and.line.vertical.and.arrow.right"
                    : "arrow.right.and.line.vertical.and.arrow.left")
                    .font(Theme.Text.metadata)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help(controller.isCompact
                ? "Show what you are working on"
                : "Shrink to just the clock")
            .accessibilityLabel(controller.isCompact ? "Show the description" : "Hide the description")
            .accessibilityIdentifier(AccessibilityID.Time.miniTimerCompact)

            Button {
                controller.isPinned.toggle()
            } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(Theme.Text.metadata)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.isPinned ? Theme.Colors.selection : Theme.Colors.secondaryText)
            .help(controller.isPinned
                ? "Stop keeping this above other windows"
                : "Keep this above other windows, on every Space")
            .accessibilityLabel("Keep on top")
            .accessibilityValue(controller.isPinned ? "on" : "off")
            .accessibilityIdentifier(AccessibilityID.Time.miniTimerPin)

            Button {
                closeMenu()
                controller.expand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(Theme.Text.metadata)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("Back to Elephruit")
            .accessibilityLabel("Expand the app")
            .accessibilityIdentifier(AccessibilityID.Time.miniTimerExpand)
        }
    }
}
