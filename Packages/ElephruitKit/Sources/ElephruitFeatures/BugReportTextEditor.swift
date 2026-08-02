import AppKit
import SwiftUI

/// Gives the four AppKit-backed report editors a direct, deterministic focus route.
///
/// SwiftUI focus remains the source of truth for styling and for the compact fields, but moving
/// between two `NSViewRepresentable`s cannot wait for two independent representable updates. The
/// source editor asks this registry for the already-mounted destination and AppKit transfers first
/// responder immediately.
@MainActor
final class BugReportFocusRegistry {
    private final class WeakEditor {
        weak var value: NSTextView?

        init(_ value: NSTextView) { self.value = value }
    }

    private var editors: [AnyHashable: WeakEditor] = [:]

    func register(_ editor: NSTextView, for key: AnyHashable) {
        editors[key] = WeakEditor(editor)
    }

    @discardableResult
    func focus(_ key: AnyHashable) -> Bool {
        guard let editor = editors[key]?.value, let window = editor.window else { return false }
        return window.makeFirstResponder(editor)
    }
}

/// A plain multiline editor whose placeholder and caret use the same AppKit text-container origin.
///
/// `TextEditor` draws its text in an `NSTextView`, but a SwiftUI overlay is laid out in a different
/// coordinate space. That made the empty-field caret appear above and to the left of its prompt.
/// Keeping both inside one `NSTextView` makes their alignment exact and also lets Tab participate in
/// form navigation instead of becoming a literal tab character.
struct BugReportTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isFocused: Bool
    var focusKey: AnyHashable? = nil
    var focusRegistry: BugReportFocusRegistry? = nil
    let onFocusChange: (Bool) -> Void
    let onTraverse: (_ backwards: Bool) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BugReportEditorScrollView {
        let scrollView = BugReportEditorScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = BugReportEditorTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
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
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scrollView.documentView = textView
        if let focusKey, let focusRegistry {
            focusRegistry.register(textView, for: focusKey)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: BugReportEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? BugReportEditorTextView else { return }
        if let focusKey, let focusRegistry {
            focusRegistry.register(textView, for: focusKey)
        }

        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }

        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
            textView.needsDisplay = true
        }

        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BugReportTextEditor

        init(_ parent: BugReportTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else {
                return
            }
            parent.text = textView.string
            textView.needsDisplay = true
        }

    }
}

final class BugReportEditorScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let textView = documentView as? NSTextView, let window else { return false }
        return window.makeFirstResponder(textView)
    }
}

final class BugReportEditorTextView: NSTextView {
    weak var coordinator: BugReportTextEditor.Coordinator?

    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        ).draw(at: textContainerOrigin)
    }

    override func insertTab(_ sender: Any?) {
        let handled = MainActor.assumeIsolated {
            coordinator?.parent.onTraverse(false) ?? false
        }
        if !handled { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        let handled = MainActor.assumeIsolated {
            coordinator?.parent.onTraverse(true) ?? false
        }
        if !handled { super.insertBacktab(sender) }
    }
}
