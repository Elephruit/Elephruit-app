import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The one line a Quick Jot is about.
///
/// An `NSTextView` rather than SwiftUI's `TextField` because this field needs four things SwiftUI
/// does not expose: the caret position, so it knows what is being completed; the keys, so Tab accepts
/// a suggestion instead of inserting a tab; the ability to draw *behind* stretches of its own text;
/// and `hasMarkedText()`, without which none of the rewriting below would be safe.
///
/// ### Two kinds of rewriting, and why only one of them is new
/// The field already replaced its own contents: one press of Delete inside `#landscape` removes all
/// ten characters, because something drawn as a single object that comes apart one letter at a time
/// teaches the user that the drawing means nothing. Lifting is the same capability with a second
/// trigger — a token that has plainly stopped being typed leaves the sentence and becomes a chip.
/// See ``CaptureLift`` for why that is right here and wrong in the other quick-entry surfaces.
///
/// What the field must never do is rewrite the token the user is *still* typing, and three guards
/// hold that line: nothing happens while `hasMarkedText()`, nothing happens with a selection open,
/// and the settling rule itself waits for evidence that the token has finished growing.
struct CaptureTitleField: NSViewRepresentable {
    /// The whole composition rather than just its text, because a lift moves something *out of* the
    /// text and *into* the draft. Two bindings would make that two updates, and a view that observed
    /// the first without the second would draw a moment where the tag exists nowhere.
    @Binding var composition: QuickJotComposition

    /// The insertion point, in **characters** — the unit the parser, the completion rule and the
    /// lifter all count in. AppKit counts UTF-16; the conversion happens at this boundary and nowhere
    /// else.
    @Binding var caret: Int

    /// The names the grammar may spell out without quotes, so a two-word project draws as one token.
    var vocabulary: CaptureVocabulary = .empty

    var placeholder: String

    /// `⌘↩`.
    var onSubmit: () -> Void
    /// Escape.
    var onCancel: () -> Void
    /// Tab with no suggestion open, and Return. There is nowhere else for a single line to go.
    var onMoveToNotes: () -> Void
    /// `-1` for up, `1` for down.
    var onMove: (Int) -> Void
    /// Returns whether a suggestion was accepted, so the key can be swallowed if it was.
    var onAccept: () -> Bool
    /// Backspace against the left edge. Returns whether a chip was removed.
    var onRemoveLastChip: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TokenisedTextView {
        let textView = TokenisedTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.string = composition.titleText
        textView.isRichText = false
        textView.allowsUndo = true
        // A field editor: one line, no wrapping, and Return arrives as `insertNewline:` for the
        // coordinator to redirect rather than as a character in the string.
        textView.isFieldEditor = true
        textView.font = .preferredFont(forTextStyle: .title3)
        textView.drawsBackground = false
        // Straight quotes and no substitutions. The grammar is punctuation, and a smart quote is not
        // the character the parser is looking for.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.vocabulary = vocabulary
        textView.placeholder = placeholder
        textView.applyHighlighting()

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return textView
    }

    func updateNSView(_ textView: TokenisedTextView, context: Context) {
        context.coordinator.parent = self
        textView.vocabulary = vocabulary
        textView.placeholder = placeholder

        // Write back only when something *other than typing* changed the text: a lift, an accepted
        // suggestion, a reset after saving. Never mid-edit, and never while an input method is
        // composing — replacing the string then destroys the marked text and the user's word with it.
        let cameFromOutsideEditor = composition.titleText != context.coordinator.lastEditorText
        if textView.string != composition.titleText,
           !context.coordinator.isEditing || context.coordinator.isApplyingLift || cameFromOutsideEditor,
           !textView.hasMarkedText() {
            textView.string = composition.titleText
            context.coordinator.lastEditorText = composition.titleText
            let location = CaptureHighlight.utf16Offset(ofCharacter: caret, in: composition.titleText)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        textView.applyHighlighting()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTitleField

        /// Set while the user is typing, so `updateNSView` never writes back during an edit.
        var isEditing = false

        /// Set while a lift is being written back, which is the one edit that must be allowed
        /// through mid-typing — it is a consequence of the keystroke, not a stale value racing it.
        var isApplyingLift = false

        /// The last value reported by this editor. A differing binding value therefore came from a
        /// completion or reset and is safe to apply even while the field remains first responder.
        var lastEditorText: String

        init(_ parent: CaptureTitleField) {
            self.parent = parent
            self.lastEditorText = parent.composition.titleText
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TokenisedTextView else { return }

            // Provisional text. Reading it would produce chips that flicker and a title that is
            // briefly wrong, and rewriting it would be worse.
            guard !textView.hasMarkedText() else { return }

            let selection = textView.selectedRange()
            let text = textView.string
            lastEditorText = text
            parent.composition.titleText = text
            parent.caret = CaptureHighlight.characterOffset(ofUTF16: selection.location, in: text)

            lift(in: textView)
            textView.applyHighlighting()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.caret = CaptureHighlight.characterOffset(
                ofUTF16: textView.selectedRange().location,
                in: textView.string
            )
        }

        /// Moves any settled token out of the text and into the draft, in one undoable edit.
        ///
        /// ### Undo
        /// The text removal goes through `shouldChangeText(in:)`/`didChangeText()`, which is what
        /// registers it; the *draft* change is registered alongside it and both are wrapped in one
        /// group. Without the grouping, ⌘Z would put `#urgent` back into the sentence while the chip
        /// stayed — and the item would then be tagged twice. A half-undone lift is worse than no undo
        /// at all, because it is invisible until the item is saved.
        private func lift(in textView: TokenisedTextView) {
            let before = parent.composition
            var composition = before

            let selection = textView.selectedRange()
            let caret = CaptureHighlight.characterOffset(ofUTF16: selection.location, in: textView.string)
            let selectionLength = selection.length

            guard let newCaret = composition.liftWhileTyping(
                caretAt: caret,
                selectionLength: selectionLength,
                knowing: parent.vocabulary,
                hasMarkedText: textView.hasMarkedText()
            ) else { return }

            let replacement = composition.titleText
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: whole, replacementString: replacement) else { return }

            let undoManager = textView.undoManager
            undoManager?.beginUndoGrouping()

            isApplyingLift = true
            defer { isApplyingLift = false }

            textView.textStorage?.replaceCharacters(in: whole, with: replacement)
            lastEditorText = replacement
            textView.didChangeText()
            textView.setSelectedRange(
                NSRange(location: CaptureHighlight.utf16Offset(ofCharacter: newCaret, in: replacement), length: 0)
            )

            parent.composition = composition
            parent.caret = newCaret

            // Restores the chips as well as the words. Registered against the coordinator rather than
            // the view so that it survives the view being rebuilt, which SwiftUI does freely.
            undoManager?.registerUndo(withTarget: self) { coordinator in
                MainActor.assumeIsolated { coordinator.parent.composition = before }
            }
            undoManager?.endUndoGrouping()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true

            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true

            case #selector(NSResponder.insertTab(_:)):
                // A suggestion first, because that is what the list is asking for. Failing that, the
                // notes field — which is where Tab goes in every other card of this shape.
                if parent.onAccept() { return true }
                parent.onMoveToNotes()
                return true

            case #selector(NSResponder.insertNewline(_:)):
                // A single-line field has nowhere to put a newline, and the notes field is where
                // newlines belong. ⌘↩ is what saves; see `TokenisedTextView.keyDown`.
                parent.onMoveToNotes()
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                // Only against the left edge, where there is no text left to delete. Anywhere else
                // Backspace is Backspace, including on a token, which the view removes whole.
                let selection = textView.selectedRange()
                guard selection.location == 0, selection.length == 0 else { return false }
                return parent.onRemoveLastChip()

            default:
                return false
            }
        }
    }
}
