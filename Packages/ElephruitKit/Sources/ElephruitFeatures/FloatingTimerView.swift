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
/// is away: pin it above everything, and put the app back. Both are revealed on hover, for the
/// reason the collapse button is — a surface whose whole point is that there is one thing to look at
/// cannot also carry five buttons.
///
/// When nothing is running it says so rather than disappearing. A window that vanished the moment a
/// timer stopped would take the only way back to the app with it.
struct MiniTimerView: View {
    @Environment(\.services) private var services

    let controller: MiniTimerController

    @State private var isHovering = false

    /// Red while tracking, amber while paused, quiet when neither — so the panel says which of the
    /// three it is before any of the words are read.
    private var tint: Color {
        if services?.timer.paused != nil { return Theme.Colors.warning }
        if services?.timer.running != nil { return Theme.Colors.destructive }
        return Theme.Colors.separator
    }

    var body: some View {
        // ### Why the window controls are on the left, and take no room until wanted
        // Two complaints, one cause. On the right they sat *after* Stop, so a pill whose whole job
        // is one clock and three timer buttons ended in a run of six — and holding their place while
        // invisible left a band of nothing on a surface small enough for it to be most of the width.
        //
        // Splitting them by what they act on fixes both. The right-hand group acts on the *timer*.
        // The left-hand group acts on the *window*: how wide, always on top, put it back. They
        // appear only on hover and are genuinely absent otherwise, so the pill is exactly as wide as
        // what it is saying. Growing leftwards is what makes that safe — the panel is anchored by
        // its right edge, so nothing under the pointer moves as they arrive.
        HStack(spacing: Theme.Spacing.small) {
            if isHovering {
                windowControls
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

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
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        // The panel is sized by hand, so it has to be told when the contents change shape.
        .onChange(of: isHovering) { _, _ in controller.contentSizeChanged() }
        .onChange(of: controller.isCompact) { _, _ in controller.contentSizeChanged() }
        .accessibilityIdentifier(AccessibilityID.Time.miniTimer)
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
                Image(systemName: controller.isCompact
                    ? "arrow.right.and.line.vertical.and.arrow.left"
                    : "arrow.left.and.line.vertical.and.arrow.right")
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
