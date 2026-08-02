import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// A note's rich text, against a real store.
///
/// ### Why this is not covered by the format's own tests
/// Because the format round-trips through `JSONEncoder` in those, and the questions here are about
/// the *column*: that a note which predates rich text still reads, that writing a document rewrites
/// every value derived from it in the same breath, and that a payload this build cannot understand
/// degrades to the body rather than to an empty note. Each of those is a way to lose somebody's
/// writing, and none of them is visible from the format.
@Suite("Note document persistence")
@MainActor
struct NoteDocumentPersistenceTests {
    private func note(_ body: String, in fixture: StoreFixture) throws -> Item {
        try fixture.items.create(ItemDraft(kind: .note, title: "A note", body: body))
    }

    // MARK: The legacy path

    @Test("A note written before rich text existed still reads")
    func legacyBodiesStillRead() throws {
        let fixture = try StoreFixture()
        let note = try note("# A heading\nAnd prose.", in: fixture)

        #expect(note.noteDocumentData == nil, "nothing has written a document for it")

        let document = note.noteDocument
        #expect(document.paragraphs.map(\.kind) == [.heading1, .paragraph])
        #expect(document.projectedBody == note.body, "the conversion cost nothing")
    }

    @Test("A note with neither a document nor a body still has somewhere to type")
    func emptyNotesAreEditable() throws {
        let fixture = try StoreFixture()
        let note = try note("", in: fixture)

        #expect(note.noteDocument.pieces.count == 1)
        #expect(note.noteDocument.isEffectivelyEmpty)
    }

    // MARK: Writing

    @Test("Writing a document rewrites the body and the search text with it")
    func writingRegeneratesEverythingDerived() throws {
        let fixture = try StoreFixture()
        let note = try note("old text", in: fixture)

        note.setNoteDocument(NoteDocument(pieces: [
            .prose(NoteParagraph(kind: .heading1, text: NoteRichText("Kittiwakes"))),
            .prose(NoteParagraph(text: NoteRichText("They nest on cliffs."))),
        ]))

        #expect(note.body == "# Kittiwakes\nThey nest on cliffs.")
        #expect(note.searchText.contains("kittiwakes"), "the search projection followed the body")
        #expect(!note.searchText.contains("old text"), "and the old body did not survive in it")
    }

    @Test("A document survives a save and a fresh read of the store")
    func documentsRoundTripThroughTheStore() throws {
        let fixture = try StoreFixture()
        let note = try note("", in: fixture)

        let written = NoteDocument(pieces: [
            .prose(NoteParagraph(kind: .quote, text: NoteRichText("Somebody else's words."))),
            .prose(NoteParagraph(kind: .code, text: NoteRichText("let x = 1"), language: "swift")),
            .prose(NoteParagraph(kind: .checklist, text: NoteRichText("done"), isTicked: true)),
            .prose(NoteParagraph(kind: .bulleted, text: NoteRichText("nested"), indent: 2)),
        ])
        note.setNoteDocument(written)
        try fixture.context.save()

        // A second context over the same container, so this asserts the bytes came back off the
        // store rather than out of the graph that wrote them.
        let reread = try #require(try SwiftDataItemRepository(
            context: fixture.freshContext(),
            dateProvider: fixture.dateProvider,
            tags: fixture.tags
        ).item(id: note.id))
        #expect(reread.noteDocument == written)
    }

    @Test("Marks and links survive the store, which is the whole reason for the column")
    func marksAndLinksSurvive() throws {
        let fixture = try StoreFixture()
        let note = try note("", in: fixture)
        let target = UUID()

        note.setNoteDocument(NoteDocument(pieces: [
            .prose(NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("bold", marks: .bold),
                NoteTextRun(" and "),
                NoteTextRun("linked", link: .item(target)),
            ]))),
        ]))
        try fixture.context.save()

        let text = try #require(try SwiftDataItemRepository(
            context: fixture.freshContext(),
            dateProvider: fixture.dateProvider,
            tags: fixture.tags
        ).item(id: note.id)).noteDocument.paragraphs[0].text
        #expect(text.runs[0].marks == .bold)
        #expect(text.link(at: 10) == .item(target))
    }

    // MARK: Wiki links, end to end

    @Test("A wiki link written as rich text is still reconciled from the body")
    func wikiLinksReachReconciliation() throws {
        // The failure this guards against would be invisible: reconciliation reads `body`, and a
        // rich-text link that never reached the body is a link the graph never hears about.
        let fixture = try StoreFixture()
        let note = try note("", in: fixture)

        note.setNoteDocument(NoteDocument(pieces: [
            .prose(NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("See "),
                NoteTextRun("Project Kittiwake", link: .wiki("Project Kittiwake")),
            ]))),
        ]))

        #expect(note.body == "See [[Project Kittiwake]]")
        #expect(WikiLinkParser.links(in: note.body).map(\.targetTitle) == ["Project Kittiwake"])
    }

    // MARK: Degrading

    @Test("A payload this build cannot read falls back to the body, not to nothing")
    func unreadablePayloadsDegradeToTheBody() throws {
        let fixture = try StoreFixture()
        let note = try note("The text is still here.", in: fixture)

        note.noteDocumentData = Data("this is not a document".utf8)

        let document = note.noteDocument
        #expect(document.plainText == "The text is still here.")
        #expect(!document.isEffectivelyEmpty, "an unreadable payload must not present as an empty note")
    }

    @Test("Reading a note does not write to it")
    func readingIsNotAWrite() throws {
        // A read that repaired the column would make opening a library in a newer build rewrite
        // every note in it before the user had touched one — on a path where a failure has nowhere
        // to be reported.
        let fixture = try StoreFixture()
        let note = try note("# Heading", in: fixture)

        _ = note.noteDocument
        _ = note.noteDocument

        #expect(note.noteDocumentData == nil)
        #expect(note.body == "# Heading")
    }
}
