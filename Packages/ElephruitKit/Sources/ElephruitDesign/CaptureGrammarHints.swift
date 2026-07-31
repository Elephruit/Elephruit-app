import SwiftUI

/// The one-line reminder of what the sigils mean.
///
/// ### Why this stays on screen while the user types
/// It used to appear only in an empty field, on the reasoning that somebody who has started typing
/// has evidently remembered the grammar. That is exactly backwards: the moment you need to be told
/// that `follow:` exists is the moment you have written the thing you want to come back to and are
/// wondering how to say so. Hiding the answer at the first keystroke withdraws it precisely when it
/// becomes useful.
///
/// It stays quiet rather than absent — tertiary text, no fills — so it reads as a reference rather
/// than as something asking to be dealt with.
public struct CaptureGrammarHints: View {
    private let hints: [(sigil: String, meaning: String, example: String)]

    public init(hints: [(sigil: String, meaning: String, example: String)]) {
        self.hints = hints
    }

    public var body: some View {
        FlowLayout(spacing: Theme.Spacing.medium, lineSpacing: Theme.Spacing.tight) {
            ForEach(hints, id: \.sigil) { hint in
                HStack(spacing: Theme.Spacing.hairline) {
                    Text(hint.sigil)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Theme.CaptureToken.accent)
                    Text(hint.meaning)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Grammar: " + hints.map { "\($0.sigil) \($0.meaning)" }.joined(separator: ", ")
        )
    }
}
