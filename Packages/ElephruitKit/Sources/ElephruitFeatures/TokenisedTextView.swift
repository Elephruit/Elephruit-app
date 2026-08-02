import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// A text view that knows which parts of itself are tokens.
///
/// ### Why the text is not replaced by attachments
/// The obvious way to make `#landscape` behave as one object is to swap it for an `NSTextAttachment`
/// the way a To: field does. That would be wrong here: the capture grammar is *text the user is
/// still writing*. They must be able to put the caret in the middle of a tag and fix a typo, select
/// across a tag and a word together, undo into a half-typed tag, and paste a line containing three
/// of them. An attachment ends all of that, and it would mean the string this field reports is no
/// longer the string the user typed — which is the one thing the parser needs.
///
/// So the text stays text, and only three things change: it is drawn with a fill behind it, one
/// press of Delete removes the whole of it, and a double-click selects the whole of it.
///
/// A token that has finished being typed leaves the field altogether and becomes a chip — but that
/// is ``CaptureLift``'s decision, taken above this view, and by the time it arrives here it is an
/// ordinary edit to the string.
final class TokenisedTextView: NSTextView {
    weak var coordinator: CaptureTitleField.Coordinator?

    /// The names the parser may read across a space. Kept in step with the field above.
    var vocabulary: CaptureVocabulary = .empty

    /// Shown when there is nothing typed. Drawn rather than made a subview, because a placeholder is
    /// not content and should not be in the accessibility tree twice.
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    /// What the parser made of the current string. Recomputed whenever the string changes.
    private var highlights: [CaptureHighlight] = []

    // MARK: - Highlighting

    /// Re-reads the text and restyles it.
    ///
    /// Attributes are written straight into the text storage rather than as *temporary* attributes,
    /// which is the usual advice for syntax colouring, because temporary attributes belong to
    /// TextKit 1's layout manager and this view is TextKit 2. Writing them directly is safe here for
    /// two reasons that are worth stating: the view is `isRichText = false`, so nothing the user can
    /// do introduces attributes of their own that this would trample; and attribute-only edits made
    /// outside `shouldChangeText(in:)` register no undo, so the undo stack still contains exactly the
    /// user's own edits.
    func applyHighlighting() {
        guard let storage = textStorage else { return }

        let updated = CaptureHighlight.spans(in: string, knowing: vocabulary)
        highlights = updated

        let whole = NSRange(location: 0, length: storage.length)
        let body = font ?? .preferredFont(forTextStyle: .body)

        storage.beginEditing()
        storage.setAttributes(
            [.font: body, .foregroundColor: NSColor.labelColor],
            range: whole
        )

        for span in updated {
            guard let range = clamped(span.utf16Range, within: storage.length) else { continue }

            switch span.standing {
            case .understood:
                storage.addAttributes(
                    [.foregroundColor: Theme.CaptureToken.foreground],
                    range: range
                )

            case .notUnderstood:
                storage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.patternDot.rawValue
                            | NSUnderlineStyle.single.rawValue,
                        .underlineColor: Theme.CaptureToken.unresolvedUnderline,
                    ],
                    range: range
                )
            }
        }
        storage.endEditing()

        // Otherwise the next character typed inherits whatever the character before it wore, so
        // typing on past the end of a tag continues the tag's colour.
        typingAttributes = [.font: body, .foregroundColor: NSColor.labelColor]

        needsDisplay = true
    }

    private func clamped(_ range: Range<Int>, within length: Int) -> NSRange? {
        guard range.lowerBound >= 0, range.upperBound <= length, !range.isEmpty else { return nil }
        return NSRange(location: range.lowerBound, length: range.count)
    }

    // MARK: - Drawing

    /// Draws the rounded fill behind every understood token, then lets the text view draw itself
    /// on top.
    ///
    /// ### Why here and not in `drawBackground(in:)`
    /// That is the method named for this, and it is not reliably called: its default implementation
    /// fills with `backgroundColor`, and this view has `drawsBackground = false` so that the panel's
    /// own material shows through. Hanging the token fills off a method AppKit may reasonably decide
    /// it has no work for is how they come to be missing in one appearance and present in another.
    /// `draw(_:)` is an `NSView` method and is always the entry point.
    ///
    /// A fill rather than `NSAttributedString`'s own `.backgroundColor`, which paints a hard-edged
    /// rectangle flush against the glyphs and reads as a highlighter pen rather than as an object.
    /// Selection is deliberately left to paint over the top of it: a selected token should look
    /// selected, and two fills competing would make it look like neither.
    override func draw(_ dirtyRect: NSRect) {
        drawTokenFills(in: dirtyRect)
        super.draw(dirtyRect)
        drawPlaceholder()
    }

    private func drawTokenFills(in rect: NSRect) {
        guard !highlights.isEmpty else { return }

        Theme.CaptureToken.fill.setFill()

        for span in highlights where span.standing == .understood {
            let range = NSRange(location: span.utf16Range.lowerBound, length: span.utf16Range.count)

            for frame in enclosingRects(of: range) where frame.intersects(rect) {
                let padded = frame.insetBy(
                    dx: -Theme.CaptureToken.padding.width,
                    dy: -Theme.CaptureToken.padding.height
                )
                NSBezierPath(
                    roundedRect: padded,
                    xRadius: Theme.CaptureToken.cornerRadius,
                    yRadius: Theme.CaptureToken.cornerRadius
                ).fill()
            }
        }
    }

    /// After the text, not before, so an empty field still shows a caret in front of the prompt.
    private func drawPlaceholder() {
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let origin = textContainerOrigin
        let inset = textContainerInset
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font ?? .preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        ).draw(at: NSPoint(x: origin.x + inset.width, y: origin.y + inset.height))
    }

    /// Where a range of characters is on screen — one rect per line it spans.
    ///
    /// ### Why TextKit 2 is asked first, and only then TextKit 1
    /// Merely *reading* `NSTextView.layoutManager` on a TextKit 2 view silently converts it back to
    /// TextKit 1 for the rest of its life. So the modern path has to be taken first and the legacy
    /// one reached only when there is genuinely no `textLayoutManager` — the opposite of the usual
    /// "try the old thing as a fallback" shape, where touching the fallback is itself the damage.
    private func enclosingRects(of range: NSRange) -> [NSRect] {
        let origin = textContainerOrigin

        if let layout = textLayoutManager, let content = layout.textContentManager {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return [] }

            var rects: [NSRect] = []
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
            return rects
        }

        guard let manager = layoutManager, let container = textContainer else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { frame, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    // MARK: - Deleting a token whole

    /// One press of Delete removes the whole tag.
    ///
    /// This is the behaviour the fill promises. Something drawn as a single object that then comes
    /// apart one letter at a time is worse than never having drawn it: it teaches the user that the
    /// fill means nothing.
    ///
    /// It goes through `shouldChangeText(in:)` and `didChangeText()` rather than editing the storage
    /// directly, which is what registers a single undo entry — so ⌘Z brings the whole tag back,
    /// rather than one letter of it.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0,
              let token = highlights.token(enclosing: selection.location)
        else {
            super.deleteBackward(sender)
            return
        }

        delete(token)
    }

    /// The mirror of ``deleteBackward(_:)`` for forward delete, which works on what is in front of
    /// the caret rather than behind it.
    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0,
              let token = highlights.token(startingFrom: selection.location)
        else {
            super.deleteForward(sender)
            return
        }

        delete(token)
    }

    private func delete(_ token: CaptureHighlight) {
        let range = NSRange(location: token.utf16Range.lowerBound, length: token.utf16Range.count)
        guard shouldChangeText(in: range, replacementString: "") else { return }

        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        applyHighlighting()
    }

    // MARK: - Selecting a token whole

    /// A double-click anywhere in a tag selects the tag, sigil included.
    ///
    /// AppKit's own word selection would stop at the `#`, or at the `/` inside `#work/clients`,
    /// leaving a selection that does not correspond to anything the user can see.
    override func selectionRange(
        forProposedRange proposedCharRange: NSRange,
        granularity: NSSelectionGranularity
    ) -> NSRange {
        guard granularity == .selectByWord,
              let token = highlights.token(
                  intersecting: proposedCharRange.location
                      ..< (proposedCharRange.location + proposedCharRange.length)
              )
        else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }

        return NSRange(location: token.utf16Range.lowerBound, length: token.utf16Range.count)
    }

    // MARK: - Keys AppKit does not report as commands

    override func keyDown(with event: NSEvent) {
        // ⌘↩ saves. Checked here because AppKit maps it to no standard editing selector, so
        // there is nothing for `doCommandBy` to report — and because plain Return is spoken for: in
        // a one-line field it moves to the notes.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            MainActor.assumeIsolated { coordinator?.parent.onSubmit() }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Accessibility

    /// What VoiceOver reads instead of the punctuation.
    ///
    /// `#landscape @Sarah due:friday` read literally is "number sign landscape at Sarah due colon
    /// friday", which describes the keystrokes rather than the meaning. Read as a value it becomes
    /// "Tag landscape, Person Sarah, Deadline Friday" — the same thing the chip row shows a sighted
    /// user, which is the standard being aimed at.
    override func accessibilityValueDescription() -> String? {
        guard !highlights.isEmpty else { return super.accessibilityValueDescription() }
        return highlights.map(\.spokenDescription).joined(separator: ", ")
    }
}
