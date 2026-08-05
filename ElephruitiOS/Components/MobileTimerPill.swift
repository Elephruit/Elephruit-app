import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitPersistence
import SwiftUI

/// The running timer, as a clock the size of a clock.
///
/// ### Why this is not a bar any more
/// It used to be a 44-point strip pinned across the bottom of every screen, and it charged every
/// screen that height for the whole time a timer ran — which is the time you are least interested
/// in looking at chrome, because you are working. The strip was mostly empty: a title nobody
/// reads while it is running, and a Stop button placed where it could be hit by accident more
/// easily than on purpose. What a running timer actually has to say from across the room is
/// *something is running, and for how long*, and that is two glyphs wide.
///
/// ### Why it grows rather than navigates
/// The moment you want the rest — pause it, stop it, see what it is filed against — you are
/// already looking at something else, and that something else is usually why you want to. Sending
/// you to the Time screen to pause a timer costs the page you were reading and a journey back.
/// So the clock stays where it is and the card grows *around* it: the pill does not move by one
/// point between the two states, which is what makes the larger thing read as the same object
/// rather than a panel that appeared over it.
struct MobileTimerPill: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    /// Wide enough for the longest clock it can show and not one point wider. A pill that is
    /// mostly padding stops reading as a readout and starts reading as a button with a number
    /// printed on it.
    private static let restingWidth: CGFloat = 112

    /// Wide enough for the clock, three controls, and a title with room to be a real title.
    /// Deliberately short of the screen: a card that reaches both edges is a sheet, and a sheet
    /// is the thing this exists in order not to be.
    private static let openWidth: CGFloat = 252

    /// The controls in the open state. Smaller than the 44 a standing target wants, because they
    /// only exist while the card is open and the card is opened deliberately — this is the
    /// second tap of a sequence, not something a thumb can find by accident.
    private static let controlBox: CGFloat = 40

    private var timer: TimerService? { services?.timer }
    private var running: RunningTimer? { timer?.running }
    private var paused: PausedTimer? { timer?.paused }

    private var isOpen: Bool { shell.isTimerExpanded }

    var body: some View {
        // A paused timer counts. It is the state most easily lost — the clock stops, and with it
        // every signal that there is unfinished work with your name on it — so the pill stays,
        // wearing a pause mark instead of a record light.
        if running != nil || paused != nil {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if isOpen { detail }
            clockRow
        }
        .padding(isOpen ? Theme.Spacing.medium : Theme.Spacing.small)
        .frame(width: isOpen ? Self.openWidth : Self.restingWidth, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.sheet))
        .elevation(.floating)
        // One radius across both states, so the corners have nothing to interpolate and the only
        // thing visibly changing is the size. A capsule that becomes a card has to redraw its
        // own outline mid-flight, and the seam that produces is the one frame where the eye
        // notices it is watching two shapes rather than one.
        .calmAnimation(Theme.Motion.expansion, value: isOpen)
        .padding(.leading, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.section)
        // Folded when the clock goes, and only then. Pausing deliberately does *not* fold it:
        // pause and resume are the same decision seen twice, and a card that closed itself on
        // the first would charge two taps to undo it. What has to be cleaned up is the timer
        // ending — otherwise the state survives to the next timer, which would then arrive
        // already open, over a screen nobody asked it to cover.
        .onDisappear { shell.isTimerExpanded = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.pill)
    }

    // MARK: - The pill itself

    /// The row that does not move. Collapsed it is the whole control; open it is the foot of the
    /// card, in the same place, at the same size, with the controls arriving beside it.
    private var clockRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                shell.isTimerExpanded.toggle()
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    // No pulse: a repeating symbol effect keeps the display link alive for the
                    // whole session, and ticking digits already say "live" for free.
                    Image(systemName: running != nil ? "record.circle" : "pause.circle.fill")
                        .foregroundStyle(Theme.Colors.recording)
                    clock
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryLabel)
            .accessibilityHint(isOpen ? "Folds the timer away" : "Opens the timer's controls")

            if isOpen {
                Spacer(minLength: 0)
                pauseOrResume
                stopButton
                openButton
            }
        }
    }

    /// Seconds while it runs, because a clock that only counts minutes leaves you watching a
    /// number that does not change and wondering whether anything is being recorded at all.
    @ViewBuilder
    private var clock: some View {
        if let running {
            TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                clockText(timer?.sittingElapsed(at: context.date) ?? 0)
            }
        } else if let paused {
            clockText(paused.accumulated)
        }
    }

    private func clockText(_ elapsed: TimeInterval) -> some View {
        Text(TimeFormatting.stopwatch(elapsed))
            .font(Theme.Text.rowSubtitle)
            .monospacedDigit()
            .contentTransition(.numericText())
            .lineLimit(1)
    }

    // MARK: - What the card adds

    /// What the timer is *for*, which is the question the pill cannot answer and the reason to
    /// open it. Filed detail second and quieter, because "which project" is a thing you check
    /// rather than a thing you read.
    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(Theme.Text.rowTitle)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let filing {
                Text(filing)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fade, not slide. The card is already growing underneath this, and content that also
        // travels turns one movement into two arguing about where the eye should be.
        .transition(.opacity)
    }

    private var pauseOrResume: some View {
        Button {
            if running != nil {
                timer?.pause()
            } else {
                timer?.resumeFromPause()
            }
        } label: {
            Image(systemName: running != nil ? "pause.fill" : "play.fill")
                .frame(width: Self.controlBox, height: Self.controlBox)
                .foregroundStyle(Theme.Colors.selection)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel(running != nil ? "Pause timer" : "Resume timer")
        .accessibilityIdentifier(
            running != nil ? AccessibilityID.Time.pillPause : AccessibilityID.Time.pillResume
        )
    }

    private var stopButton: some View {
        Button {
            timer?.stop()
        } label: {
            Image(systemName: "stop.fill")
                .frame(width: Self.controlBox, height: Self.controlBox)
                .foregroundStyle(Theme.Colors.recording)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel("Stop timer")
        .accessibilityIdentifier(AccessibilityID.Time.pillStop)
    }

    /// The one control here that does leave the page — kept, because filing a timer against a
    /// project, correcting its clock, or starting a focus cycle are the whole Time screen and
    /// putting them in a floating card would be rebuilding it at a third of the width.
    private var openButton: some View {
        Button {
            shell.isTimerExpanded = false
            shell.push(.time)
        } label: {
            Image(systemName: "arrow.up.forward")
                .frame(width: Self.controlBox, height: Self.controlBox)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel("Open Time")
        .accessibilityHint("Shows the full tracker, with filing and corrections")
        .accessibilityIdentifier(AccessibilityID.Time.pillOpen)
    }

    // MARK: - Words

    private var title: String {
        running?.displayTitle ?? paused?.displayTitle ?? "Untitled"
    }

    /// Where the time is going, in the order somebody would say it: the project first, because
    /// that is what a week is reported by, then the subject when it differs from the title.
    private var filing: String? {
        guard let running else { return nil }
        var parts: [String] = []
        if let project = running.projectTitle { parts.append("in \(project)") }
        if let subject = running.itemTitle, subject != running.displayTitle {
            parts.append("on \(subject)")
        }
        if !running.tagSlugs.isEmpty {
            parts.append(running.tagSlugs.map { "#\($0)" }.joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken as one sentence, because collapsed this is one control and VoiceOver should not
    /// have to read a record light and a number as two unrelated things.
    private var summaryLabel: String {
        if running != nil {
            "Timer running: \(title)"
        } else {
            "Timer paused: \(title)"
        }
    }
}
