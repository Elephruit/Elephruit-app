import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The notes editor, wherever the app edits prose.
///
/// ### Why this exists rather than a `MarkdownTextEditor` at each call site
/// Because there were five of them — the task detail, the note detail, a project's brief, a
/// bookmark's description, a person's body — each dropped straight into a `VStack` with a
/// `minHeight` and nothing else. The result was the same in all five and worst in the task
/// inspector: a large blank region below the title that accepted typing and said nothing about
/// itself. No heading, no placeholder, no border, no focus ring, no indication that anything typed
/// into it had been saved. It read as empty space that happened to swallow keystrokes, which is
/// exactly what it was.
///
/// This is the editor plus everything that makes it recognisable as one, in a single component, so
/// that fixing it fixes it everywhere and the five surfaces cannot drift apart again. What each call
/// site still chooses is what the region is *called* and what its empty state should invite —
/// "Add notes…" is right for a task and wrong for a project brief.
struct NotesField: View {
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    @Binding var text: String

    var title: String = "Notes"
    var systemImage: String? = "text.alignleft"
    var placeholder: String = "Add notes…"
    var isEditable: Bool = true
    var saveState: SaveState = .idle

    /// Wiki-link completion, for the surfaces that offer it.
    var pendingInsertion: Binding<WikiLinkInsertion?> = .constant(nil)
    var onCompletionContextChange: (WikiLinkCompletionContext?) -> Void = { _ in }

    @State private var isFocused = false

    var body: some View {
        EditingSurface(
            title: title,
            systemImage: systemImage,
            placeholder: placeholder,
            isEmpty: text.isEmpty,
            isFocused: isFocused,
            isEditable: isEditable,
            saveState: saveState
        ) {
            MarkdownTextEditor(
                text: $text,
                pendingInsertion: pendingInsertion,
                isMonospaced: prefersMonospaced,
                isEditable: isEditable,
                onCompletionContextChange: onCompletionContextChange,
                onFocusChange: { isFocused = $0 }
            )
            .frame(height: height)
            .accessibilityIdentifier(AccessibilityID.Detail.bodyEditor)
            .accessibilityLabel(title)
            .accessibilityHint(text.isEmpty ? placeholder : "")
        }
        .calmAnimation(Theme.Motion.standard, value: height)
    }

    /// Grows with the content, within bounds. See ``EditorHeight``.
    private var height: CGFloat {
        EditorHeight.height(
            forLines: EditorHeight.lineCount(of: text),
            isFocused: isFocused
        )
    }
}
