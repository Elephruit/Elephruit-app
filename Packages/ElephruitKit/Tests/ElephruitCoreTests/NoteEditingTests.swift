import ElephruitCore
import Foundation
import Testing

/// The pure editing operations — where correctness is decided before any view exists.
@Suite("Note editing operations")
struct NoteEditingTests {
    private func prose(
        _ kind: NoteParagraphKind = .paragraph,
        _ text: String,
        indent: Int = 0,
        ticked: Bool = false
    ) -> NotePiece {
        .prose(NoteParagraph(kind: kind, text: NoteRichText(text), indent: indent, isTicked: ticked))
    }

    private func document(_ pieces: NotePiece...) -> NoteDocument {
        NoteDocument(pieces: pieces)
    }

    // MARK: Segments

    @Test("Consecutive prose is one segment; objects are their own")
    func segmentation() {
        let doc = document(
            prose(.heading1, "Title"),
            prose(.paragraph, "One."),
            .object(.divider),
            prose(.paragraph, "Two."),
            .object(.divider),
            .object(.divider),
            prose(.paragraph, "Three.")
        )

        #expect(doc.segments == [
            .prose(0..<2),
            .object(2),
            .prose(3..<4),
            .object(4),
            .object(5),
            .prose(6..<7),
        ])
    }

    @Test("A document that is all prose is one segment")
    func allProseIsOneSegment() {
        let doc = document(prose(.paragraph, "a"), prose(.paragraph, "b"), prose(.paragraph, "c"))
        #expect(doc.segments == [.prose(0..<3)])
    }

    @Test("An empty document has no segments")
    func emptyDocumentHasNoSegments() {
        #expect(NoteDocument().segments.isEmpty)
    }

    // MARK: Split and join

    @Test("Splitting keeps the kind on both halves and the tick on neither's second half")
    func splitKeepsKindAndDropsTick() {
        let doc = document(prose(.checklist, "buy milk", ticked: true))
        let split = doc.splittingParagraph(at: 0, offset: 3)

        #expect(split.pieces.count == 2)
        #expect(split.pieces[0].paragraph?.plainText == "buy")
        #expect(split.pieces[1].paragraph?.plainText == " milk")
        #expect(split.pieces[0].paragraph?.kind == .checklist)
        #expect(split.pieces[1].paragraph?.kind == .checklist)
        #expect(split.pieces[0].paragraph?.isTicked == true)
        #expect(split.pieces[1].paragraph?.isTicked == false, "splitting a done item does not mint a second done item")
    }

    @Test("Splitting preserves inline marks across the cut")
    func splitPreservesMarks() {
        let text = NoteRichText(runs: [
            NoteTextRun("plain "),
            NoteTextRun("bold", marks: [.bold]),
        ])
        let doc = NoteDocument(pieces: [.prose(NoteParagraph(text: text))])
        let split = doc.splittingParagraph(at: 0, offset: 8)

        #expect(split.pieces[0].paragraph?.text.plainText == "plain bo")
        #expect(split.pieces[0].paragraph?.text.marks(at: 8) == [.bold])
        #expect(split.pieces[1].paragraph?.text.plainText == "ld")
        #expect(split.pieces[1].paragraph?.text.marks(at: 1) == [.bold])
    }

    @Test("Joining keeps the earlier paragraph's kind")
    func joinKeepsEarlierKind() {
        let doc = document(prose(.quote, "As they said, "), prose(.paragraph, "so it went."))
        let joined = doc.joiningParagraphWithPrevious(at: 1)

        #expect(joined.pieces.count == 1)
        #expect(joined.pieces[0].paragraph?.kind == .quote)
        #expect(joined.pieces[0].paragraph?.plainText == "As they said, so it went.")
    }

    @Test("Joining across an object does nothing")
    func joinRefusesAcrossObjects() {
        let doc = document(prose(.paragraph, "before"), .object(.divider), prose(.paragraph, "after"))
        #expect(doc.joiningParagraphWithPrevious(at: 2) == doc)
    }

    // MARK: Kind, indent, tick

    @Test("Changing kind covers every prose piece in the range and steps over objects")
    func changeKindStepsOverObjects() {
        let doc = document(prose(.paragraph, "a"), .object(.divider), prose(.paragraph, "b"))
        let changed = doc.changingKind(to: .quote, in: 0..<3)

        #expect(changed.pieces[0].paragraph?.kind == .quote)
        #expect(changed.pieces[1] == .object(.divider), "the divider is left alone, not refused")
        #expect(changed.pieces[2].paragraph?.kind == .quote)
    }

    @Test("Changing a checklist to a heading loses the tick, by normalisation not by caller care")
    func changeKindNormalizes() {
        let doc = document(prose(.checklist, "done", ticked: true))
        let changed = doc.changingKind(to: .heading2, in: 0..<1)

        #expect(changed.pieces[0].paragraph?.isTicked == false)
        #expect(changed.pieces[0].paragraph?.indent == 0)
    }

    @Test("Indent moves only list items, and stays in bounds")
    func indentOnlyMovesLists() {
        let doc = document(
            prose(.bulleted, "listed", indent: 0),
            prose(.paragraph, "prose"),
            prose(.numbered, "deep", indent: NoteParagraph.maximumIndent)
        )
        let indented = doc.indenting(by: 1, in: 0..<3)

        #expect(indented.pieces[0].paragraph?.indent == 1)
        #expect(indented.pieces[1].paragraph?.indent == 0, "Tab on prose does nothing")
        #expect(indented.pieces[2].paragraph?.indent == NoteParagraph.maximumIndent, "already at the edge")

        let outdented = indented.indenting(by: -1, in: 0..<3)
        #expect(outdented.pieces[0].paragraph?.indent == 0)
    }

    @Test("Toggling a tick flips exactly the checklist item asked for")
    func toggleTick() {
        let doc = document(prose(.checklist, "a"), prose(.paragraph, "b"))

        let ticked = doc.togglingTick(at: 0)
        #expect(ticked.pieces[0].paragraph?.isTicked == true)
        #expect(ticked.togglingTick(at: 0).pieces[0].paragraph?.isTicked == false)
        #expect(doc.togglingTick(at: 1) == doc, "a paragraph has no tick to toggle")
    }

    // MARK: Moving

    @Test("Moving accounts for its own removal")
    func moveAccountsForRemoval() {
        let doc = document(prose(.paragraph, "a"), prose(.paragraph, "b"), prose(.paragraph, "c"))

        let movedDown = doc.movingPiece(from: 0, to: 2)
        #expect(movedDown.pieces.compactMap { $0.paragraph?.plainText } == ["b", "c", "a"])

        let movedUp = doc.movingPiece(from: 2, to: 0)
        #expect(movedUp.pieces.compactMap { $0.paragraph?.plainText } == ["c", "a", "b"])
    }

    // MARK: Inserting objects — the only place segment boundaries move

    @Test("Inserting an object mid-paragraph splits the prose segment, and that is the only split")
    func insertingObjectSplitsTheSegment() {
        let doc = document(prose(.paragraph, "before after"))
        #expect(doc.segments == [.prose(0..<1)])

        let inserted = doc.insertingObject(.divider, at: NotePieceLocation(pieceIndex: 0, offset: 6))

        #expect(inserted.pieces.count == 3)
        #expect(inserted.pieces[0].paragraph?.plainText == "before")
        #expect(inserted.pieces[1] == .object(.divider))
        #expect(inserted.pieces[2].paragraph?.plainText == " after")
        #expect(inserted.segments == [.prose(0..<1), .object(1), .prose(2..<3)])
    }

    @Test("Inserting at a paragraph's edge does not split it")
    func insertingAtEdgesDoesNotSplit() {
        let doc = document(prose(.paragraph, "text"))

        let before = doc.insertingObject(.divider, at: NotePieceLocation(pieceIndex: 0, offset: 0))
        #expect(before.pieces.count == 2)
        #expect(before.pieces[0] == .object(.divider))

        let after = doc.insertingObject(.divider, at: NotePieceLocation(pieceIndex: 0, offset: 4))
        #expect(after.pieces.count == 2)
        #expect(after.pieces[1] == .object(.divider))
    }

    @Test("Inserting past the end appends")
    func insertingPastTheEndAppends() {
        let doc = document(prose(.paragraph, "only"))
        let appended = doc.insertingObject(.divider, at: NotePieceLocation(pieceIndex: 9, offset: 0))
        #expect(appended.pieces.last == .object(.divider))
    }

    // MARK: Removal and replacement never empty the document

    @Test("Removing the last piece leaves an empty paragraph for the caret")
    func removalNeverEmptiesTheDocument() {
        let doc = document(.object(.divider))
        let removed = doc.removingPiece(at: 0)

        #expect(removed.pieces.count == 1)
        #expect(removed.pieces[0].paragraph?.isEmpty == true)
    }

    @Test("Replacing a run with nothing leaves an empty paragraph for the caret")
    func replacementNeverEmptiesTheDocument() {
        let doc = document(prose(.paragraph, "a"), prose(.paragraph, "b"))
        let replaced = doc.replacingPieces(in: 0..<2, with: [])

        #expect(replaced.pieces.count == 1)
        #expect(replaced.pieces[0].paragraph?.isEmpty == true)
    }

    @Test("Replacing a run splices in place")
    func replacementSplices() {
        let doc = document(prose(.paragraph, "a"), .object(.divider), prose(.paragraph, "b"))
        let replaced = doc.replacingPieces(in: 0..<1, with: [prose(.heading1, "A"), prose(.paragraph, "a2")])

        #expect(replaced.pieces.count == 4)
        #expect(replaced.pieces[0].paragraph?.kind == .heading1)
        #expect(replaced.pieces[1].paragraph?.plainText == "a2")
        #expect(replaced.pieces[2] == .object(.divider))
    }

    // MARK: Every operation is total

    @Test("Out-of-range indices answer with the document unchanged")
    func staleIndicesAreSurvivable() {
        let doc = document(prose(.paragraph, "only"))

        #expect(doc.splittingParagraph(at: 5, offset: 0) == doc)
        #expect(doc.joiningParagraphWithPrevious(at: 0) == doc, "nothing before the first")
        #expect(doc.changingKind(to: .quote, in: 4..<9) == doc)
        #expect(doc.indenting(by: 1, in: 4..<9) == doc)
        #expect(doc.movingPiece(from: 3, to: 0) == doc)
        #expect(doc.removingPiece(at: 3) == doc)
        #expect(doc.togglingTick(at: 3) == doc)
        #expect(doc.settingCalloutTone(.warning, at: 3) == doc)
        #expect(doc.settingCodeLanguage("swift", at: 3) == doc)
    }

    @Test("Tone and language apply only to the kinds that carry them")
    func toneAndLanguageAreKindBound() {
        let doc = document(
            .prose(NoteParagraph(kind: .callout, text: NoteRichText("mind"))),
            .prose(NoteParagraph(kind: .code, text: NoteRichText("let x = 1")))
        )

        #expect(doc.settingCalloutTone(.warning, at: 0).pieces[0].paragraph?.tone == .warning)
        #expect(doc.settingCalloutTone(.warning, at: 1) == doc, "code has no tone")
        #expect(doc.settingCodeLanguage("swift", at: 1).pieces[1].paragraph?.language == "swift")
        #expect(doc.settingCodeLanguage("swift", at: 0) == doc, "a callout has no language")
        #expect(doc.settingCodeLanguage("", at: 1).pieces[1].paragraph?.language == nil, "empty means none")
    }
}
