import AppKit
import ElephruitDesign
import SwiftUI

/// The capture field.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor` for the same reason the note editor is one:
/// `TextEditor` exposes no caret position and no key interception, and this field needs both —
/// the caret to know what is being completed, and the keys so that `Tab` accepts a suggestion
/// instead of inserting a tab character.
struct CaptureTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int

    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// `-1` for up, `1` for down.
    var onMove: (Int) -> Void
    /// Returns whether a suggestion was accepted, so the key can be swallowed if it was.
    var onAccept: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = InterceptingTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? InterceptingTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        // Straight quotes, because the grammar is punctuation and a smart quote is not the same
        // character the parser is looking for.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? InterceptingTextView else { return }

        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            // A programmatic change — accepting a suggestion — moves the caret deliberately.
            let target = min(caret, textView.string.count)
            textView.setSelectedRange(NSRange(location: target, length: 0))
            _ = ranges
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTextField

        init(_ parent: CaptureTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.caret = textView.selectedRange().location
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.caret = textView.selectedRange().location
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
                // Only swallowed when there was something to accept, so Tab still moves focus in an
                // empty field rather than doing nothing.
                return parent.onAccept()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    /// Catches the keys `doCommandBy` does not report usefully.
    final class InterceptingTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func keyDown(with event: NSEvent) {
            // ⌘↩ saves. Checked here because AppKit maps it to no standard editing selector, so
            // there is nothing for `doCommandBy` to report.
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn, event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { coordinator?.parent.onSubmit() }
                return
            }
            super.keyDown(with: event)
        }
    }
}
