import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

// The two controls the stage floats over its content.
//
// Both of these used to be the phone's, and the phone has since replaced them: the plus now fans
// into what a day is made of (`MobileAddMenu`) and the timer is a pill that grows in place
// (`MobileTimerPill`). Neither of those is reusable here as it stands — the pill navigates
// through `MobileShellModel`'s stack, and the stage moves through `pad.contentPath` — so rather
// than delete these with the phone's copies and leave the iPad unbuildable, they moved here,
// where their only remaining caller is.
//
// That is a holding position, not a design. `PadStageView` argues that a plus meaning different
// things on an iPad and an iPhone would be two apps, and right now it does mean different things:
// the phone's fans, this one does not. Aligning them is worth doing on purpose, with the stage in
// front of you, rather than as a side effect of a phone change.

/// The running timer, floating over the stage. Tap for Time; the stop button is right
/// there, because "stop tracking" should never require a journey.
struct TimerAccessoryView: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    var body: some View {
        if let services, let running = services.timer.running {
            Button {
                shell.push(.time)
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    // No pulse: a repeating symbol effect keeps the display link alive for
                    // the whole session, and the timer's ticking digits already say "live".
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.Colors.recording)
                    Text(running.displayTitle)
                        .font(Theme.Text.rowSubtitle)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.small)
                    Text(services.timer.elapsedDisplay)
                        .font(Theme.Text.rowSubtitle)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button {
                        _ = services.timer.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop timer")
                }
                .padding(.horizontal, Theme.Spacing.medium)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Timer running: \(running.displayTitle), \(services.timer.elapsedDisplay)"
            )
        }
    }
}

/// The stage's floating button: whatever the surface under it means by "add".
struct CaptureButton: View {
    /// How far above the stage's bottom edge the button rests.
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
        // The name the phone's plus also answers to. The two shells are mutually exclusive — this
        // one is the regular-width stage, that one appears only when the window is compact — so
        // one name for "the shell's add button" is what lets a test say that without first asking
        // which device it is running on.
        .accessibilityIdentifier("mobile.capture.button")
    }
}
