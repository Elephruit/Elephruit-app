import AppKit
import ElephruitCore
import Observation

/// The page's working state: the document, and everything the segments need to agree on.
///
/// ### Who owns what
/// The *document* is the truth for structure — which pieces exist, in what order. While the user
/// is typing inside one prose segment, that segment's text view is the truth for its own run and
/// reports back after every change; the model splices the result into the document without
/// re-rendering anything. Only *structural* changes — an object inserted, a piece removed, a new
/// note loaded, an undo — bump ``renderRevision``, which is the segments' signal to rebuild
/// themselves from the document.
@MainActor
@Observable
public final class NoteEditorModel {
    public private(set) var document: NoteDocument = .empty

    /// Bumped when the segments must re-read the document. Never bumped by typing.
    private(set) var renderRevision = 0

    /// What the selection looks like, for the inspector and the Format menu.
    private(set) var selection = NoteSelectionState()

    /// The piece index of the selected object, when an object is selected instead of text.
    var selectedObjectPiece: Int?

    /// Where the caret should go after a structural change, keyed by prose-segment ordinal.
    struct FocusRequest: Equatable {
        enum Placement: Equatable {
            case start
            case end
            case characterIndex(Int)
        }

        var ordinal: Int
        var placement: Placement
        var token: Int
    }

    private(set) var focusRequest: FocusRequest?
    private var focusToken = 0

    /// The `/` menu, when one is open.
    struct SlashMenuState: Equatable {
        var ordinal: Int
        var query: String
        /// The caret's rect in the page's coordinate space, for anchoring the menu.
        var anchor: CGRect
        /// The highlighted command — the *value*, never a row position. See the spec's trap list.
        var highlighted: NoteInsertionCommand?
    }

    var slashMenu: SlashMenuState?

    /// The outline row the viewport is currently reading, by ``NoteOutlineEntry/id``.
    var activeOutlineEntryID: String?

    /// The prose segment whose text view last held the caret, for commands that arrive from
    /// outside the text — the Format panel, the menu bar.
    var focusedProseOrdinal: Int?

    /// The text view commands from outside the text land in: the focused one, else the first.
    var commandTarget: NoteProseTextView? {
        if let ordinal = focusedProseOrdinal, let view = registry.view(forOrdinal: ordinal) {
            return view
        }
        return registry.view(forOrdinal: 0)
    }

    var slashMatches: [NoteInsertionCommand] {
        NoteInsertionCommand.matching(slashMenu?.query ?? "")
    }

    /// Live text views by prose-segment ordinal, for focus handoff and outline scrolling.
    let registry = NoteSegmentRegistry()

    /// The prose segments' frames in the page's scroll-content space, for anchoring the `/`
    /// menu. Written by the page's geometry observers; content-space frames do not move when
    /// the page scrolls, so this stays quiet outside layout changes.
    var proseSegmentFrames: [Int: CGRect] = [:]

    /// Called with the whole document after any change; the owner debounces the save.
    var onDocumentChange: ((NoteDocument) -> Void)?

    /// The window's undo manager, for structural changes. Text edits inside a segment undo
    /// through the text view's own machinery.
    weak var undoManager: UndoManager?

    public init() {}

    // MARK: - Segment geography

    /// The piece ranges of the prose segments, in order. A prose segment's *ordinal* — its
    /// position in this list — is its identity: stable across typing, recomputed on structure.
    var proseSegmentRanges: [Range<Int>] {
        document.segments.compactMap {
            if case .prose(let range) = $0 { return range }
            return nil
        }
    }

    func paragraphs(forProseOrdinal ordinal: Int) -> [NoteParagraph] {
        let ranges = proseSegmentRanges
        guard ranges.indices.contains(ordinal) else { return [NoteParagraph()] }
        return document.pieces[ranges[ordinal]].compactMap(\.paragraph)
    }

    /// The prose ordinal whose piece range contains a piece index, if any.
    func proseOrdinal(containingPiece index: Int) -> Int? {
        proseSegmentRanges.firstIndex { $0.contains(index) }
    }

    // MARK: - Loading

    /// Replaces the document wholesale — a different note, or an external change.
    public func load(_ document: NoteDocument) {
        self.document = document.pieces.isEmpty ? .empty : document
        renderRevision += 1
        selection = NoteSelectionState()
        selectedObjectPiece = nil
        slashMenu = nil
        focusRequest = nil
    }

    // MARK: - Typing sync

    /// One prose segment's paragraphs, read back from its text view.
    ///
    /// Structure inside the run may have changed — Return makes paragraphs — but the *segment
    /// boundaries* have not, so nothing re-renders and the caret stays where the user put it.
    func syncProse(ordinal: Int, paragraphs: [NoteParagraph]) {
        let ranges = proseSegmentRanges
        guard ranges.indices.contains(ordinal) else { return }

        let replacement = paragraphs.isEmpty ? [NoteParagraph()] : paragraphs
        let updated = document.replacingPieces(in: ranges[ordinal], with: replacement.map { .prose($0) })
        guard updated != document else { return }

        document = updated
        onDocumentChange?(document)
    }

    func updateSelection(_ state: NoteSelectionState) {
        selection = state
        if state.hasSelection || !state.kinds.isEmpty {
            selectedObjectPiece = nil
        }
    }

    // MARK: - Structural changes

    /// Applies a structurally different document, re-rendering every segment and registering
    /// the change with the window's undo stack.
    func applyStructural(_ new: NoteDocument) {
        guard new != document else { return }
        let old = document

        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.applyStructural(old)
            }
        }
        undoManager?.setActionName(String(localized: "Edit Note", comment: "Undo action name"))

        document = new
        renderRevision += 1
        selectedObjectPiece = nil
        slashMenu = nil
        onDocumentChange?(document)
    }

    /// Inserts an object at a location, and parks the caret on the prose that follows it.
    ///
    /// If the object would end the document, an empty paragraph is added after it — an editor
    /// with no paragraph after the last object has nowhere to put the caret, which is the same
    /// argument as `NoteDocument.empty`.
    func insertObject(_ object: NoteObject, at location: NotePieceLocation) {
        var updated = document.insertingObject(object, at: location)

        guard let objectIndex = firstDifferingObjectIndex(from: document, to: updated) else { return }

        if objectIndex == updated.pieces.count - 1 {
            updated.pieces.append(.prose(NoteParagraph()))
        }

        applyStructural(updated)

        if let ordinal = proseOrdinal(containingPiece: objectIndex + 1) {
            requestFocus(ordinal: ordinal, placement: .start)
        }
    }

    func removePiece(at index: Int) {
        applyStructural(document.removingPiece(at: index))
    }

    func movePiece(from source: Int, to destination: Int) {
        applyStructural(document.movingPiece(from: source, to: destination))
    }

    func toggleTick(atPiece index: Int) {
        applyStructural(document.togglingTick(at: index))
    }

    func updateObject(_ object: NoteObject, atPiece index: Int) {
        guard document.pieces.indices.contains(index), !document.pieces[index].isProse else { return }
        var updated = document
        updated.pieces[index] = .object(object)
        applyStructural(updated)
    }

    private func firstDifferingObjectIndex(from old: NoteDocument, to new: NoteDocument) -> Int? {
        for index in new.pieces.indices where !new.pieces[index].isProse {
            if index >= old.pieces.count || old.pieces[index] != new.pieces[index] {
                return index
            }
        }
        return nil
    }

    // MARK: - Focus

    func requestFocus(ordinal: Int, placement: FocusRequest.Placement) {
        focusToken += 1
        focusRequest = FocusRequest(ordinal: ordinal, placement: placement, token: focusToken)
    }

    func clearFocusRequest(_ request: FocusRequest) {
        if focusRequest == request {
            focusRequest = nil
        }
    }

    /// The caret walked off a segment's edge: put it in the neighbouring prose segment, past
    /// whatever objects sit between.
    func moveFocus(from ordinal: Int, towards edge: NoteProseTextView.Edge) {
        let count = proseSegmentRanges.count
        switch edge {
        case .up:
            guard ordinal > 0 else { return }
            requestFocus(ordinal: ordinal - 1, placement: .end)
        case .down:
            guard ordinal + 1 < count else { return }
            requestFocus(ordinal: ordinal + 1, placement: .start)
        }
    }

    // MARK: - The outline

    /// The headings with the prose ordinal and in-segment paragraph position each one lives at,
    /// so the outline can scroll to the exact paragraph rather than to a segment's top.
    var outline: [NoteOutlineEntry] {
        let ranges = proseSegmentRanges
        return document.headings.compactMap { heading in
            guard let ordinal = ranges.firstIndex(where: { $0.contains(heading.position) }) else { return nil }
            return NoteOutlineEntry(
                pieceIndex: heading.position,
                level: heading.level,
                title: heading.title,
                proseOrdinal: ordinal,
                paragraphOffset: heading.position - ranges[ordinal].lowerBound
            )
        }
    }
}

/// One row of the outline.
struct NoteOutlineEntry: Identifiable, Hashable {
    var pieceIndex: Int
    var level: Int
    var title: String
    var proseOrdinal: Int
    var paragraphOffset: Int

    /// Identified by position *and* title: two identical headings are two rows, and editing a
    /// title moves the highlight rather than orphaning it.
    var id: String { "\(pieceIndex)-\(title)" }
}

/// The live text views, by prose-segment ordinal.
///
/// Weak on purpose: the registry must never keep a torn-down segment alive, and a lookup that
/// finds nothing is a normal answer during a re-render.
@MainActor
final class NoteSegmentRegistry {
    private struct WeakBox {
        weak var view: NoteProseTextView?
    }

    private var boxes: [Int: WeakBox] = [:]

    func register(_ view: NoteProseTextView, ordinal: Int) {
        boxes[ordinal] = WeakBox(view: view)
    }

    func unregister(ordinal: Int, view: NoteProseTextView) {
        if boxes[ordinal]?.view === view {
            boxes[ordinal] = nil
        }
    }

    func view(forOrdinal ordinal: Int) -> NoteProseTextView? {
        boxes[ordinal]?.view
    }
}
