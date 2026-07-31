import AppKit
import ElephruitCore
import SwiftUI

/// The note body editor.
///
/// ### Why AppKit here
/// SwiftUI's `TextEditor` exposes no selection, no caret position, no scroll control, and no find
/// bar. This editor needs the caret position to anchor `[[` completion, and a find bar is table
/// stakes for a note of any length. Neither is expressible in SwiftUI, so this is one of the four
/// sanctioned `NSViewRepresentable` bridges named in `docs/02-architecture.md`.
///
/// ### What it deliberately does not do
/// No syntax highlighting, no attributed storage, no rich text. The binding is a `String` and the
/// stored value is a `String` — always. That is the containment for risk **R5**: text editing on
/// Apple platforms is a tar pit, and a v1 that stores plain text cannot be corrupted by whatever
/// styling layer arrives later.
public struct MarkdownTextEditor: NSViewRepresentable {
    @Binding private var text: String

    /// Called when the caret moves, with the partial `[[…]]` link under it, if any.
    private let onCompletionContextChange: (WikiLinkCompletionContext?) -> Void

    /// A completion the caller wants inserted. Cleared by the coordinator once applied.
    @Binding private var pendingInsertion: WikiLinkInsertion?

    private let isMonospaced: Bool
    private let isEditable: Bool

    public init(
        text: Binding<String>,
        pendingInsertion: Binding<WikiLinkInsertion?> = .constant(nil),
        isMonospaced: Bool = false,
        isEditable: Bool = true,
        onCompletionContextChange: @escaping (WikiLinkCompletionContext?) -> Void = { _ in }
    ) {
        self._text = text
        self._pendingInsertion = pendingInsertion
        self.isMonospaced = isMonospaced
        self.isEditable = isEditable
        self.onCompletionContextChange = onCompletionContextChange
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            // `scrollableTextView()` always produces an `NSTextView`; if that ever changes, an
            // empty scroll view is a survivable outcome and a force cast is not.
            Diagnostics.features.error("Text view unavailable; editor will be empty")
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isRichText = false                  // Plain text, permanently.
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false   // Straight quotes in Markdown.
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 12)
        textView.string = text

        applyTypography(to: textView)

        // The accessibility identifier lives on the text view, which is what a UI test drives.
        textView.setAccessibilityIdentifier(AccessibilityID.Detail.bodyEditor)
        textView.setAccessibilityLabel("Note body")

        context.coordinator.textView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.parent = self

        // Only write when the value genuinely differs, or every keystroke would reset the caret to
        // the end of the document.
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        applyTypography(to: textView)

        if let insertion = pendingInsertion {
            context.coordinator.apply(insertion, to: textView)
            // Clearing on the next tick avoids mutating state during a view update.
            Task { @MainActor in pendingInsertion = nil }
        }
    }

    private func applyTypography(to textView: NSTextView) {
        let font = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)

        guard textView.font != font else { return }
        textView.font = font

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6
        textView.defaultParagraphStyle = paragraph
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Bridges `NSTextView`'s delegate callbacks back into SwiftUI state.
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?

        init(parent: MarkdownTextEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportCompletionContext(in: textView)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCompletionContext(in: textView)
        }

        /// Works out whether the caret sits inside an unterminated `[[`, and tells the caller.
        ///
        /// The caret offset is converted from UTF-16 — `NSTextView`'s unit — into a `String.Index`,
        /// because Swift string offsets and UTF-16 offsets diverge the moment a note contains an
        /// emoji, and silently mismatching them is how completion lands in the wrong place.
        private func reportCompletionContext(in textView: NSTextView) {
            let text = textView.string
            let selection = textView.selectedRange()

            guard selection.length == 0,
                  let caret = Range(NSRange(location: selection.location, length: 0), in: text)?.lowerBound,
                  let active = WikiLinkParser.activeCompletion(in: text, caretAt: caret)
            else {
                parent.onCompletionContextChange(nil)
                return
            }

            let replacementStart = text.distance(from: text.startIndex, to: active.replacementRange.lowerBound)
            let replacementLength = text.distance(
                from: active.replacementRange.lowerBound,
                to: active.replacementRange.upperBound
            )

            parent.onCompletionContextChange(
                WikiLinkCompletionContext(
                    query: active.query,
                    replacementOffset: replacementStart,
                    replacementLength: replacementLength
                )
            )
        }

        /// Replaces the partial link with the chosen title, through the undo manager so `⌘Z` works.
        func apply(_ insertion: WikiLinkInsertion, to textView: NSTextView) {
            let text = textView.string

            guard let start = text.index(
                text.startIndex,
                offsetBy: insertion.replacementOffset,
                limitedBy: text.endIndex
            ),
            let end = text.index(
                start,
                offsetBy: insertion.replacementLength,
                limitedBy: text.endIndex
            ) else { return }

            let utf16Start = text.utf16.distance(from: text.utf16.startIndex, to: start.samePosition(in: text.utf16) ?? text.utf16.startIndex)
            let utf16End = text.utf16.distance(from: text.utf16.startIndex, to: end.samePosition(in: text.utf16) ?? text.utf16.startIndex)
            let range = NSRange(location: utf16Start, length: utf16End - utf16Start)

            let replacement = WikiLinkParser.linkSyntax(forTitle: insertion.title)

            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()

            let caret = range.location + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: caret, length: 0))

            parent.text = textView.string
            parent.onCompletionContextChange(nil)
        }
    }
}

/// The state of an in-progress `[[` link.
public struct WikiLinkCompletionContext: Equatable, Sendable {
    /// What the user has typed after `[[`.
    public var query: String

    /// Character offsets of the text an accepted completion replaces, including the `[[`.
    public var replacementOffset: Int
    public var replacementLength: Int

    public init(query: String, replacementOffset: Int, replacementLength: Int) {
        self.query = query
        self.replacementOffset = replacementOffset
        self.replacementLength = replacementLength
    }
}

/// A completion the editor should insert.
public struct WikiLinkInsertion: Equatable, Sendable {
    public var title: String
    public var replacementOffset: Int
    public var replacementLength: Int

    public init(title: String, replacementOffset: Int, replacementLength: Int) {
        self.title = title
        self.replacementOffset = replacementOffset
        self.replacementLength = replacementLength
    }

    public init(title: String, context: WikiLinkCompletionContext) {
        self.title = title
        self.replacementOffset = context.replacementOffset
        self.replacementLength = context.replacementLength
    }
}
