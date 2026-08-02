import AppKit
import ElephruitCore
import SwiftUI

/// Where the caret should land inside a segment.
enum NoteCaretPlacement: Equatable {
    case start
    case end
    case characterIndex(Int)
}

/// One prose segment on the page: a run of paragraphs sharing one text view.
///
/// One of the sanctioned `NSViewRepresentable` bridges. The view sizes itself by answering
/// `sizeThatFits` from the layout manager's used rect — asked afresh every layout pass, never
/// cached — which is the fix the spec prescribes for the stale-height defect the block
/// architecture suffered.
struct NoteProseSegmentView: NSViewRepresentable {
    let model: NoteEditorModel
    let ordinal: Int
    var isEditable = true

    /// A `/` menu command was chosen, or a Markdown shortcut asked for an object.
    let onInsertionCommand: (NoteInsertionCommand, NotePieceLocation) -> Void

    /// A link in the text was clicked.
    let onOpenLink: (NoteInlineLink) -> Void

    func makeNSView(context: Context) -> NoteProseTextView {
        let view = NoteProseTextView()
        view.delegate = context.coordinator
        view.noteCoordinator = context.coordinator
        context.coordinator.textView = view

        view.isEditable = isEditable
        view.setAccessibilityIdentifier("\(AccessibilityID.Notes.segment).\(ordinal)")
        view.setAccessibilityLabel(String(localized: "Note text", comment: "Accessibility label for a prose segment"))

        context.coordinator.render(into: view)
        model.registry.register(view, ordinal: ordinal)
        return view
    }

    func updateNSView(_ view: NoteProseTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        model.registry.register(view, ordinal: ordinal)

        // Writes into the text view answer back with delegate callbacks on the same turn;
        // reporting those to SwiftUI mid-update is a state mutation during a view update.
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }

        if view.isEditable != isEditable {
            view.isEditable = isEditable
        }

        if coordinator.renderedRevision != model.renderRevision {
            coordinator.render(into: view)
        }

        if let request = model.focusRequest, request.ordinal == ordinal {
            coordinator.applyFocus(request, to: view)
        }
    }

    static func dismantleNSView(_ view: NoteProseTextView, coordinator: Coordinator) {
        coordinator.parent.model.registry.unregister(ordinal: coordinator.parent.ordinal, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoteProseTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        guard let container = nsView.textContainer, let layoutManager = nsView.layoutManager else { return nil }

        if container.size.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)

        var height = layoutManager.usedRect(for: container).height
        if !layoutManager.extraLineFragmentRect.isEmpty {
            height = max(height, layoutManager.extraLineFragmentRect.maxY)
        }
        let minimum = NSFont.preferredFont(forTextStyle: .body).pointSize + 8
        return CGSize(width: width, height: max(height, minimum) + nsView.textContainerInset.height * 2)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NoteProseTextViewCoordinator {
        var parent: NoteProseSegmentView
        weak var textView: NoteProseTextView?

        var renderedRevision = -1
        var isApplyingUpdate = false
        private var appliedFocusToken = -1

        init(parent: NoteProseSegmentView) {
            self.parent = parent
        }

        /// Rebuilds the text from the document — a structural change or a fresh note.
        func render(into view: NoteProseTextView) {
            let paragraphs = parent.model.paragraphs(forProseOrdinal: parent.ordinal)
            let attributed = NoteProseConversion.attributedString(for: paragraphs)
            view.textStorage?.setAttributedString(attributed)

            if let last = paragraphs.last {
                let attribute = NoteParagraphAttribute(last)
                if attributed.length == 0 || last.isEmpty {
                    view.typingAttributes = NoteProseStyle.attributes(for: attribute)
                }
            }

            renderedRevision = parent.model.renderRevision
        }

        func applyFocus(_ request: NoteEditorModel.FocusRequest, to view: NoteProseTextView) {
            guard request.token != appliedFocusToken else { return }
            appliedFocusToken = request.token

            let length = (view.string as NSString).length
            let location: Int
            switch request.placement {
            case .start: location = 0
            case .end: location = length
            case .characterIndex(let index): location = max(0, min(index, length))
            }

            // The claim happens on the next tick: during `updateNSView` the window may still be
            // resolving the previous responder, and a refusal now would be discarded — the exact
            // caret-loss the spec documents.
            let model = parent.model
            Task { @MainActor in
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: location, length: 0))
                view.scrollRangeToVisible(NSRange(location: location, length: 0))
                model.clearFocusRequest(request)
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let view = textView else { return }
            view.reconcileAppearance()
            view.observeEditForTriggers()
            sync(view)
            view.reportSelectionState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingUpdate, let view = textView else { return }
            view.reportSelectionState()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let attribute = textView.textStorage?.attribute(.noteLink, at: charIndex, effectiveRange: nil)
                as? NoteLinkAttribute {
                parent.onOpenLink(attribute.link)
                return true
            }
            if let url = link as? URL {
                parent.onOpenLink(.url(url.absoluteString))
                return true
            }
            return false
        }

        // MARK: NoteProseTextViewCoordinator

        func proseDidChange(_ view: NoteProseTextView) {
            guard !isApplyingUpdate else { return }
            sync(view)
        }

        private func sync(_ view: NoteProseTextView) {
            guard let storage = view.textStorage else { return }
            let paragraphs = NoteProseConversion.paragraphs(
                from: storage,
                trailingEmpty: view.trailingEmptyParagraphAttribute
            )
            parent.model.syncProse(ordinal: parent.ordinal, paragraphs: paragraphs)
        }

        func prose(_ view: NoteProseTextView, requestsObject object: NoteObject, atCharacterIndex index: Int) {
            let location = pieceLocation(in: view, atCharacterIndex: index)
            parent.model.insertObject(object, at: location)
        }

        func prose(_ view: NoteProseTextView, slashQueryChanged query: String?, caretNear rect: NSRect) {
            guard let query else {
                parent.model.slashMenu = nil
                return
            }

            let matches = NoteInsertionCommand.matching(query)
            let highlighted: NoteInsertionCommand?
            if let current = parent.model.slashMenu?.highlighted, matches.contains(current) {
                highlighted = current
            } else {
                highlighted = matches.first
            }

            parent.model.slashMenu = NoteEditorModel.SlashMenuState(
                ordinal: parent.ordinal,
                query: query,
                anchor: pageRect(for: rect, in: view),
                highlighted: highlighted
            )
        }

        func prose(_ view: NoteProseTextView, slashCommand command: NoteSlashMenuCommand) -> Bool {
            guard var menu = parent.model.slashMenu, menu.ordinal == parent.ordinal else { return false }
            let matches = NoteInsertionCommand.matching(menu.query)

            switch command {
            case .moveUp, .moveDown:
                guard !matches.isEmpty else { return true }
                let current = menu.highlighted.flatMap { matches.firstIndex(of: $0) } ?? 0
                let next = command == .moveDown
                    ? min(current + 1, matches.count - 1)
                    : max(current - 1, 0)
                menu.highlighted = matches[next]
                parent.model.slashMenu = menu
                return true

            case .commit:
                guard let chosen = menu.highlighted ?? matches.first else { return true }
                perform(chosen, in: view)
                return true

            case .cancel:
                parent.model.slashMenu = nil
                return true
            }
        }

        /// Runs a chosen `/` command: eats the typed query, then applies a kind in place or asks
        /// the page for an object.
        func perform(_ command: NoteInsertionCommand, in view: NoteProseTextView) {
            parent.model.slashMenu = nil
            view.consumeSlashText()

            switch command {
            case .paragraph(let kind):
                view.applyParagraphKind(kind)
            default:
                let caret = view.selectedRange().location
                parent.onInsertionCommand(command, pieceLocation(in: view, atCharacterIndex: caret))
            }
        }

        func prose(_ view: NoteProseTextView, caretLeavesTowards edge: NoteProseTextView.Edge) {
            parent.model.moveFocus(from: parent.ordinal, towards: edge)
        }

        func proseBackspaceAtSegmentStart(_ view: NoteProseTextView) {
            let ranges = parent.model.proseSegmentRanges
            guard ranges.indices.contains(parent.ordinal) else { return }
            let previous = ranges[parent.ordinal].lowerBound - 1
            guard previous >= 0, !parent.model.document.pieces[previous].isProse else { return }
            parent.model.selectedObjectPiece = previous
        }

        func prose(_ view: NoteProseTextView, performsInsertion command: NoteInsertionCommand) {
            perform(command, in: view)
        }

        func proseSelectionDidChange(_ view: NoteProseTextView, state: NoteSelectionState) {
            guard !isApplyingUpdate else { return }
            parent.model.updateSelection(state)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.model.focusedProseOrdinal = parent.ordinal
        }

        // MARK: Geometry

        /// A UTF-16 character index turned into a document piece location: which paragraph of
        /// this segment, and how many Characters into it.
        private func pieceLocation(in view: NoteProseTextView, atCharacterIndex index: Int) -> NotePieceLocation {
            let text = view.string as NSString
            let clamped = max(0, min(index, text.length))

            var paragraphOrdinal = 0
            var paragraphStart = 0
            var scan = 0
            while scan < clamped {
                if text.character(at: scan) == 0x0A {
                    paragraphOrdinal += 1
                    paragraphStart = scan + 1
                }
                scan += 1
            }

            // Characters, not UTF-16 units — the conversion at the one boundary where the two
            // representations meet.
            let utf16Slice = text.substring(with: NSRange(location: paragraphStart, length: clamped - paragraphStart))
            let offset = utf16Slice.count

            let ranges = parent.model.proseSegmentRanges
            let base = ranges.indices.contains(parent.ordinal) ? ranges[parent.ordinal].lowerBound : 0
            return NotePieceLocation(pieceIndex: base + paragraphOrdinal, offset: offset)
        }

        /// A rect in the text view's coordinates, expressed in the page's named space.
        private func pageRect(for rect: NSRect, in view: NoteProseTextView) -> CGRect {
            guard let host = view.superview else { return rect }
            var converted = view.convert(rect, to: host)
            // The representable's host sits exactly where SwiftUI placed the segment, so the
            // page-space rect is the segment frame's origin plus the local offset. The page
            // stores segment frames keyed by ordinal.
            if let frame = parent.model.proseSegmentFrames[parent.ordinal] {
                converted.origin.x = frame.minX + rect.minX
                converted.origin.y = frame.minY + rect.minY
            }
            return converted
        }
    }
}

extension AccessibilityID {
    /// The notes workspace.
    public enum Notes {
        public static let page = "notes.page"
        public static let segment = "notes.segment"
        public static let slashMenu = "notes.slashMenu"
        public static let outline = "notes.outline"
        public static let inspector = "notes.inspector"
    }
}
