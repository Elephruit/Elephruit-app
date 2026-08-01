import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The focus cycle, while one is running.
///
/// ### Why a strip rather than a window
/// A pomodoro app is usually a floating clock, and a floating clock is a thing to look at instead of
/// working. This is a strip under the tracker: it says which phase you are in, how long is left, and
/// where you are in the set, and it is beside the work rather than on top of it. What is deliberately
/// absent is anything that congratulates — no streaks, no confetti, no history of how many blocks
/// you managed last Tuesday. The count of finished blocks is on the entry, where it can be reported
/// on honestly; it is not a score.
struct FocusStrip: View {
    @Environment(\.services) private var services

    let session: PomodoroSession

    var body: some View {
        // Redrawn on SwiftUI's own cadence rather than waiting to be told, for the same reason the
        // tracker's clock is: a countdown that only advances when something else invalidates the
        // view is a countdown that visibly stalls.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let moment = session.isPaused ? (session.runningSince ?? context.date) : context.date

            HStack(spacing: Theme.Spacing.medium) {
                phaseRing(at: moment)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.phase.displayName)
                        .font(Theme.Text.rowTitleEmphasised)

                    Text(subtitle)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer(minLength: Theme.Spacing.small)

                Text(TimeFormatting.stopwatch(session.remaining(at: moment)))
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(session.isPaused ? Theme.Colors.secondaryText : Theme.Colors.primaryText)

                controls
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        // A card under the tracker's card, not a strip across the window: the cycle belongs to the
        // thing being tracked, and a full-width band would read as something the window is saying
        // rather than something this entry is doing.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.focusStrip)
    }

    // MARK: - Parts

    /// A ring that fills as the phase runs.
    ///
    /// A ring rather than a bar because it sits beside a clock face and reads as one object with it;
    /// a horizontal bar here would compete with the day's progress bar in the summary below and the
    /// two would be read as the same measurement.
    private func phaseRing(at moment: Date) -> some View {
        let progress = session.progress(at: moment)

        return ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Image(systemName: session.phase.symbolName)
                .font(.caption)
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
        .calmAnimation(value: progress)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button {
                if session.isPaused {
                    services?.timer.resumeFocus()
                } else {
                    services?.timer.pauseFocus()
                }
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help(session.isPaused ? "Resume the cycle" : "Pause the cycle")
            .accessibilityLabel(session.isPaused ? "Resume focus" : "Pause focus")
            .accessibilityIdentifier(AccessibilityID.Time.focusPause)

            Button {
                services?.timer.skipFocusPhase()
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help(session.phase == .focus
                ? "Go to the break now. This block will not be counted."
                : "Get back to work now.")
            .accessibilityLabel("Skip to \(session.nextPhase.displayName)")
            .accessibilityIdentifier(AccessibilityID.Time.focusSkip)

            Button {
                services?.timer.endFocus()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("Stop counting blocks. Whatever is being timed keeps running.")
            .accessibilityLabel("End the focus cycle")
            .accessibilityIdentifier(AccessibilityID.Time.focusEnd)
        }
    }

    // MARK: - Values

    /// Amber for a break, accent for work.
    ///
    /// Never the only signal: the phase is also named in words and carries its own symbol, which is
    /// what makes the strip readable to somebody who cannot use the colour.
    private var tint: Color {
        session.phase.isBreak ? Theme.Colors.warning : Theme.Colors.selection
    }

    private var subtitle: String {
        if session.isPaused { return "Paused · \(session.roundDescription)" }
        if session.phase.isBreak { return "\(session.roundDescription) · nothing is being tracked" }
        return session.roundDescription
    }
}

// MARK: - Phase ended

/// The banner shown when a phase has run out and the next one is waiting on a decision.
///
/// A banner rather than an alert, on the same terms as every other banner in this module: it reports
/// something that has already happened, and an alert that blocks the window makes whichever answer
/// closes it fastest the one people give.
struct FocusPhaseBanner: View {
    let phase: PomodoroPhase
    let next: PomodoroPhase
    let isWaiting: Bool
    let onStartNext: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: phase.symbolName)
                .foregroundStyle(Theme.Colors.selection)

            Text(phase.completionMessage)
                .font(Theme.Text.rowSubtitle)

            Spacer(minLength: Theme.Spacing.small)

            if isWaiting {
                Button("Start \(next.displayName)", action: onStartNext)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button("OK", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.selection.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.focusBanner)
    }
}
