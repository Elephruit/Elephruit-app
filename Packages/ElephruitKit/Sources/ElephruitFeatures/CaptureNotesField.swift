import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Everything below the title.
///
/// ### Why this one is ordinary
/// The title field is an `NSTextView` with a coordinator, a caret in two coordinate systems and a
/// rule about when a word stops being a word. This is a `TextEditor`, because none of that applies
/// here: no grammar is read from the notes, so there is nothing to highlight, nothing to complete and
/// nothing to lift.
///
/// That is not a simplification made for convenience — it is the parser's own rule. Only the first
/// line has ever carried grammar, on the grounds that a `#` in the third paragraph of a jotted note is
/// a hash. A note that reads "ask her about the due: date" is describing a conversation, not setting
/// a deadline, and a field that took it for one would make the second paragraph of every note a place
/// where punctuation is dangerous.
///
/// Return therefore does what Return does. It is the only field in the card where it can.
struct CaptureNotesField: View {
    @Binding var text: String

    var onCancel: () -> Void

    var body: some View {
        TextEditor(text: $text)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.primaryText)
            .frame(minHeight: 44, maxHeight: 96)
            // `TextEditor` insets its text by five points that nothing else in the card has, which
            // would leave the notes hanging a character to the right of the title above them.
            .padding(.leading, -5)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Notes")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .allowsHitTesting(false)
                }
            }
            .onExitCommand(perform: onCancel)
            .accessibilityIdentifier(AccessibilityID.QuickCapture.notesField)
            .accessibilityLabel("Notes")
    }
}
