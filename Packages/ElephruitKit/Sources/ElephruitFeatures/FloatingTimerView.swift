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

    @State private var isHovering = false

    var body: some View {
        if let state {
            content(state)
                .padding(.vertical, Theme.Spacing.small)
                .padding(.horizontal, Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .fill(Theme.Colors.contentBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(state.tint.opacity(0.35))
                }
                // Exactly one shadow, and a small one. This is the only surface in the app that
                // genuinely floats over another, and a glow here would read as an alert.
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(Theme.Spacing.large)
                .onHover { isHovering = $0 }
                .calmAnimation(value: isHovering)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Time.floatingTimer)
        }
    }

    // MARK: - Content

    private func content(_ state: State) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: state.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.title3)
                        .foregroundStyle(state.tint)
                        .symbolEffect(.pulse, options: state.isPaused ? .nonRepeating : .repeating)

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
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the Time log")

            clock(state)

            controls(state)
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
            .frame(width: 84, alignment: .trailing)
        } else {
            Text(TimeFormatting.stopwatch(state.accumulated))
                .font(clockFont)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 84, alignment: .trailing)
        }
    }

    private var clockFont: Font {
        .system(.title3, design: .rounded, weight: .medium)
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
