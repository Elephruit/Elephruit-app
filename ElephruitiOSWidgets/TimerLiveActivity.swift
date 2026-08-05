import ActivityKit
import SwiftUI
import WidgetKit

/// The running timer, on the Lock Screen and in the Dynamic Island.
///
/// ### Why a running timer belongs here at all
/// The point of a timer is that it runs while you are doing something else. On a Mac that
/// problem is answered by the menu bar; a phone has no menu bar, so a timer started here was
/// visible only inside the app that started it — which is precisely the timer somebody forgets
/// is running, and a forgotten timer is how four hours get billed to a phone call that took
/// twenty minutes. The island is the phone's answer to the same question: the elapsed time is
/// readable without unlocking anything, and one tap lands on the screen that can stop it.
///
/// ### What it does not do
/// It does not carry who was present, and it does not carry the note. A Lock Screen is visible
/// to whoever is holding the phone, and the calendar mirror already refuses to put a person's
/// name somewhere they never agreed to be — the same rule applies to a surface anybody standing
/// behind you can read. The title, the project and the clock are what this says.
struct TimerLiveActivity: Widget {
    /// Where a tap lands. The Time screen, because the reason to tap a running timer is to do
    /// something about it, and every control that can is there.
    private static let destination = URL(string: "elephruit://time")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ElephruitTimerAttributes.self) { context in
            lockScreen(context.state)
                .widgetURL(Self.destination)
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(from: context.state.startedAt)
                        .font(.system(.title2, design: .rounded, weight: .medium))
                        .monospacedDigit()
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        if let detail = context.state.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if context.state.isBillable {
                            Image(systemName: "dollarsign.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        focusLabel(context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } compactTrailing: {
                elapsed(from: context.state.startedAt)
                    .monospacedDigit()
                    // Wide enough for `1:04:09` and no wider: the compact region is shared with
                    // everything else the system wants to show, and a clock that grows past its
                    // frame is one that gets truncated rather than shrunk.
                    .frame(maxWidth: 58)
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
            .widgetURL(Self.destination)
            .keylineTint(.red)
        }
    }

    /// The Lock Screen banner, and the fallback on a phone with no Dynamic Island.
    private func lockScreen(_ state: ElephruitTimerAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let detail = state.detail {
                        Text(detail)
                            .lineLimit(1)
                    }
                    focusLabel(state)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            elapsed(from: state.startedAt)
                .font(.system(.title2, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
        .padding()
    }

    /// The clock, counting itself.
    ///
    /// `Text(timerInterval:)` is animated by the system from a start date, so a running clock
    /// costs no updates at all — which is the difference between a Live Activity that survives
    /// an afternoon and one the system throttles into stillness by lunchtime.
    private func elapsed(from startedAt: Date) -> Text {
        Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
    }

    @ViewBuilder
    private func focusLabel(_ state: ElephruitTimerAttributes.ContentState) -> some View {
        if let phase = state.focusPhase {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile")
                if let ends = state.focusEndsAt {
                    Text(timerInterval: Date.now ... ends, countsDown: true)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Text(phase)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
