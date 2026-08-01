import SwiftUI

/// One choice in a rail of alternatives.
///
/// ### Why a chip and not a button or a menu
/// A menu hides its options until it is opened, which is right for a decision made once and wrong
/// for one somebody flips through — a period, a scope, a filter. A row of ordinary bordered buttons
/// is a toolbar, and a toolbar says *these are things you can do* rather than *exactly one of these
/// is true*. A chip rail says the second, which is what a filter is.
///
/// ### Why it is quiet until chosen
/// Because a rail of eight filled capsules is eight things demanding attention, and only one of them
/// is the answer to "what am I looking at". Unselected chips have no fill and no border — a row of
/// outlines reads as a row of empty fields — and get one only under the pointer. Exactly one chip is
/// ever filled, in the user's own accent, with ``Theme/Colors/onAccent`` on top of it so the label
/// stays legible under a yellow accent as well as a blue one.
///
/// The trait is `.isSelected` rather than a toggle's on/off, because that is what this is: one of a
/// set, not a switch. VoiceOver reads the rail as a set of choices and says which one is current.
public struct FilterChip: View {
    private let title: String
    private let hint: String
    private let isOn: Bool
    private let action: () -> Void

    @State private var isHovering = false

    /// - Parameters:
    ///   - title: the label, which is the whole control — no glyph, because a rail of eight icons is
    ///     a rebus.
    ///   - hint: what choosing this actually shows, for the tooltip and the accessibility hint.
    ///     Never a restatement of the title, on the same terms as every other hint in this app.
    public init(
        _ title: String,
        hint: String = "",
        isOn: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.hint = hint
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Text.chip)
                .foregroundStyle(isOn ? Theme.Colors.onAccent : Theme.Colors.primaryText)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.tight)
                .background {
                    if isOn {
                        Capsule().fill(Theme.Colors.selection)
                    } else {
                        Capsule().fill(isHovering ? Theme.Colors.hoverFill : Color.clear)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .calmAnimation(Theme.Motion.appearance, value: isOn)
        .calmAnimation(Theme.Motion.appearance, value: isHovering)
        .help(hint)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
