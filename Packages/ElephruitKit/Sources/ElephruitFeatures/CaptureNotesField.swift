import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The multi-line half of Quick Jot.
///
/// This is an AppKit text view for the same narrow reason the title is: completion needs the real
/// caret and must be able to consume Tab while a suggestion is open. Return remains an ordinary
/// newline here.
struct CaptureNotesField: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int
    var vocabulary: CaptureVocabulary = .empty

    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMove: (Int) -> Bool
    var onAccept: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptureNotesScrollView {
        let scrollView = CaptureNotesScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = CaptureNotesTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.string = text
        textView.vocabulary = vocabulary
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Theme.AppKitText.captureSupportingInput
        textView.textColor = Theme.AppKitColors.primaryText
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        // Match the title editor's standard NSTextView inset exactly. The previous zero padding
        // put Notes five points to the left of the title above it.
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.placeholder = "Notes"
        textView.applyHighlighting()
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: CaptureNotesScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CaptureNotesTextView else { return }
        textView.vocabulary = vocabulary
        guard textView.string != text,
              text != context.coordinator.lastEditorText,
              !textView.hasMarkedText()
        else {
            textView.applyHighlighting()
            return
        }

        textView.string = text
        context.coordinator.lastEditorText = text
        let location = CaptureHighlight.utf16Offset(ofCharacter: caret, in: text)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.applyHighlighting()
        textView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureNotesField
        var lastEditorText: String

        init(_ parent: CaptureNotesField) {
            self.parent = parent
            self.lastEditorText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else {
                return
            }
            lastEditorText = textView.string
            parent.text = textView.string
            parent.caret = CaptureHighlight.characterOffset(
                ofUTF16: textView.selectedRange().location,
                in: textView.string
            )
            (textView as? CaptureNotesTextView)?.applyHighlighting()
            textView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.caret = CaptureHighlight.characterOffset(
                ofUTF16: textView.selectedRange().location,
                in: textView.string
            )
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.onAccept()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class CaptureNotesScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let textView = documentView as? NSTextView, let window else { return false }
        return window.makeFirstResponder(textView)
    }
}

final class CaptureNotesTextView: NSTextView {
    weak var coordinator: CaptureNotesField.Coordinator?
    var vocabulary: CaptureVocabulary = .empty

    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    /// Notes keep their prose, so tokens do not get the filled-object treatment used by the title.
    /// Colour is enough to confirm that the grammar was understood without making a paragraph look
    /// like a row of controls.
    func applyHighlighting() {
        guard let storage = textStorage else { return }
        let bodyFont = font ?? Theme.AppKitText.captureSupportingInput
        let whole = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(
            [.font: bodyFont, .foregroundColor: Theme.AppKitColors.primaryText],
            range: whole
        )

        var utf16Base = 0
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let text = String(line)
            for span in CaptureHighlight.spans(in: text, knowing: vocabulary) {
                let range = NSRange(
                    location: utf16Base + span.utf16Range.lowerBound,
                    length: span.utf16Range.count
                )
                guard range.location + range.length <= storage.length else { continue }

                switch span.standing {
                case .understood:
                    storage.addAttribute(
                        .foregroundColor,
                        value: Theme.CaptureToken.foreground,
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
            utf16Base += (text as NSString).length + 1
        }
        storage.endEditing()
        typingAttributes = [.font: bodyFont, .foregroundColor: Theme.AppKitColors.primaryText]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let fragmentPadding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font ?? Theme.AppKitText.captureSupportingInput,
                .foregroundColor: Theme.AppKitColors.placeholderText,
            ]
        ).draw(
            at: NSPoint(
                x: textContainerOrigin.x + fragmentPadding,
                y: textContainerOrigin.y
            )
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            MainActor.assumeIsolated { coordinator?.parent.onSubmit() }
            return
        }
        super.keyDown(with: event)
    }
}
