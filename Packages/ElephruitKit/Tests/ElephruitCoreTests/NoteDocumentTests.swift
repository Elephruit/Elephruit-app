import ElephruitCore
import Foundation
import Testing

/// A note's contents, and the projection every other part of the app reads.
@Suite("Note document")
struct NoteDocumentTests {
    private func prose(_ kind: NoteParagraphKind, _ text: String, indent: Int = 0, ticked: Bool = false) -> NotePiece {
        .prose(NoteParagraph(kind: kind, text: NoteRichText(text), indent: indent, isTicked: ticked))
    }

    // MARK: A paragraph keeps only what its kind can use

    @Test("A kind that cannot use a field does not keep it")
    func normalizationDropsWhatTheKindCannotUse() {
        // A heading carrying a tick and an indent is a paragraph two pieces of code disagree about:
        // one asks the kind and ignores them, the other asks the fields and honours them.
        let heading = NoteParagraph(kind: .heading1, text: NoteRichText("Title"), indent: 3, isTicked: true)

        #expect(heading.indent == 0)
        #expect(heading.isTicked == false)
    }

    @Test("Turning a checklist item into something else loses the tick")
    func changingKindLosesTheTick() {
        let ticked = NoteParagraph(kind: .checklist, text: NoteRichText("done"), isTicked: true)
        #expect(ticked.isTicked)

        let asProse = NoteParagraph(kind: .paragraph, text: ticked.text, isTicked: ticked.isTicked)
        #expect(!asProse.isTicked, "it is not a checklist item any more")
    }

    @Test("Indent is bounded, and only lists have one")
    func indentIsBounded() {
        #expect(NoteParagraph(kind: .bulleted, indent: 99).indent == NoteParagraph.maximumIndent)
        #expect(NoteParagraph(kind: .bulleted, indent: -4).indent == 0)
        #expect(NoteParagraph(kind: .quote, indent: 2).indent == 0, "a quote does not nest")
    }

    @Test("A callout always has a tone, because it has to be tinted somehow")
    func calloutsAlwaysHaveATone() {
        #expect(NoteParagraph(kind: .callout).tone == .note)
        #expect(NoteParagraph(kind: .callout, tone: .warning).tone == .warning)
        #expect(NoteParagraph(kind: .paragraph, tone: .warning).tone == nil)
    }

    @Test("Code is not prose, and everything else is")
    func codeIsNotProse() {
        // Decides spell checking and smart substitution. Curling a quote inside code changes what
        // the code means; underlining every identifier makes the block unreadable.
        #expect(!NoteParagraphKind.code.isProse)
        for kind in NoteParagraphKind.allCases where kind != .code {
            #expect(kind.isProse, "\(kind.displayName)")
        }
    }

    @Test("Return continues a list and nothing else")
    func onlyListsContinue() {
        #expect(NoteParagraphKind.bulleted.continuationKind == .bulleted)
        #expect(NoteParagraphKind.numbered.continuationKind == .numbered)
        #expect(NoteParagraphKind.checklist.continuationKind == .checklist)
        #expect(NoteParagraphKind.heading1.continuationKind == .paragraph, "nobody writes two headings in a row")
        #expect(NoteParagraphKind.quote.continuationKind == .paragraph)
    }

    // MARK: Round trips

    @Test("A document survives being stored and read back")
    func documentRoundTrips() throws {
        let document = NoteDocument(pieces: [
            prose(.heading1, "The Title"),
            prose(.paragraph, "Some prose."),
            prose(.quote, "Somebody else's words."),
            .prose(NoteParagraph(kind: .code, text: NoteRichText("let x = 1"), language: "swift")),
            .prose(NoteParagraph(kind: .callout, text: NoteRichText("Mind this"), tone: .warning)),
            prose(.checklist, "done", ticked: true),
            prose(.bulleted, "nested", indent: 2),
            .object(.divider),
            .object(.image(attachmentID: UUID(), caption: NoteRichText("A picture"))),
            .object(.reference(itemID: UUID())),
            .object(.table(NoteTable(rows: [[NoteRichText("a"), NoteRichText("b")]]))),
        ])

        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(NoteDocument.self, from: data) == document)
    }

    @Test("A paragraph kind this version does not know about reads as prose")
    func unknownKindsDegradeToProse() throws {
        // The same choice `Item.kindRaw` makes: a note written by a newer build should still open,
        // and its text is the part that matters.
        let json = #"{"version":1,"pieces":[{"prose":{"_0":{"kind":"hologram","text":[{"text":"still readable"}]}}}]}"#
        let document = try JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8))

        #expect(document.paragraphs.count == 1)
        #expect(document.paragraphs[0].kind == .paragraph)
        #expect(document.paragraphs[0].plainText == "still readable")
    }

    @Test("An empty document has somewhere to put the caret")
    func emptyIsNotActuallyEmpty() {
        #expect(NoteDocument.empty.pieces.count == 1)
        #expect(NoteDocument.empty.isEffectivelyEmpty)
    }

    // MARK: The projection

    @Test("A wiki link survives the projection, because reconciliation parses it back out")
    func wikiLinksSurviveTheProjection() {
        // The failure this guards against is silent and total: `.wiki` lives as an attribute on a
        // run, so a projection that emitted only the visible text would drop the brackets,
        // `WikiLinkParser` would find nothing, and every link in every note would be unmade on the
        // next save.
        let document = NoteDocument(pieces: [
            .prose(NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("See "),
                NoteTextRun("Project Kittiwake", link: .wiki("Project Kittiwake")),
                NoteTextRun(" for the detail."),
            ]))),
        ])

        #expect(document.projectedBody == "See [[Project Kittiwake]] for the detail.")

        let found = WikiLinkParser.links(in: document.projectedBody)
        #expect(found.count == 1)
        #expect(found[0].targetTitle == "Project Kittiwake")
    }

    @Test("A wiki link with its own display text keeps both halves")
    func wikiLinksKeepTheirDisplayText() {
        let document = NoteDocument(pieces: [
            .prose(NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("the kittiwake project", link: .wiki("Project Kittiwake")),
            ]))),
        ])

        #expect(document.projectedBody == "[[Project Kittiwake|the kittiwake project]]")

        let found = WikiLinkParser.links(in: document.projectedBody)
        #expect(found[0].targetTitle == "Project Kittiwake")
        #expect(found[0].displayText == "the kittiwake project")
    }

    @Test("A deliberate item link is not written into the text")
    func itemLinksStayOutOfTheProjection() {
        // Links made through the inspector are modelled relationships, not text. Writing them into
        // the body would have reconciliation treat them as owned by the text and delete them when
        // the sentence around them was edited.
        let document = NoteDocument(pieces: [
            .prose(NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("Ask "),
                NoteTextRun("Sam", link: .item(UUID())),
            ]))),
        ])

        #expect(document.projectedBody == "Ask Sam")
    }

    @Test("Every kind projects as the Markdown it is")
    func kindsProjectAsMarkdown() {
        let document = NoteDocument(pieces: [
            prose(.heading1, "One"),
            prose(.heading2, "Two"),
            prose(.heading3, "Three"),
            prose(.paragraph, "Prose."),
            prose(.quote, "Quoted."),
            prose(.bulleted, "Bullet"),
            prose(.checklist, "Undone"),
            prose(.checklist, "Done", ticked: true),
            .object(.divider),
        ])

        #expect(document.projectedBody == """
        # One
        ## Two
        ### Three
        Prose.
        > Quoted.
        - Bullet
        - [ ] Undone
        - [x] Done
        ---
        """)
    }

    @Test("A code block is fenced, and keeps its language")
    func codeIsFenced() {
        let document = NoteDocument(pieces: [
            .prose(NoteParagraph(kind: .code, text: NoteRichText("let x = 1"), language: "swift")),
        ])

        #expect(document.projectedBody == "```swift\nlet x = 1\n```")
    }

    @Test("Numbers are counted, not stored")
    func numberingIsCounted() {
        let document = NoteDocument(pieces: [
            prose(.numbered, "first"),
            prose(.numbered, "second"),
            prose(.numbered, "third"),
        ])

        #expect(document.projectedBody == "1. first\n2. second\n3. third")
    }

    @Test("A list interrupted by prose starts again rather than resuming")
    func numberingRestarts() {
        let document = NoteDocument(pieces: [
            prose(.numbered, "first"),
            prose(.numbered, "second"),
            prose(.paragraph, "An aside."),
            prose(.numbered, "first again"),
        ])

        #expect(document.projectedBody.hasSuffix("1. first again"))
    }

    @Test("A nested list is indented, and counts at its own depth")
    func nestingIsProjected() {
        let document = NoteDocument(pieces: [
            prose(.bulleted, "top"),
            prose(.bulleted, "under", indent: 1),
            prose(.numbered, "one", indent: 2),
            prose(.numbered, "two", indent: 2),
        ])

        #expect(document.projectedBody == "- top\n  - under\n    1. one\n    2. two")
    }

    @Test("An attachment's identifier never reaches the projection")
    func attachmentIdentifiersStayOut() {
        // `body` is the text projection and feeds the search index. A UUID in it is a word the index
        // has to carry and nobody can search for.
        let id = UUID()
        let document = NoteDocument(pieces: [
            .object(.image(attachmentID: id, caption: NoteRichText("A kittiwake"))),
            .object(.file(attachmentID: id)),
        ])

        #expect(document.projectedBody == "A kittiwake")
        #expect(!document.projectedBody.contains(id.uuidString))
    }

    @Test("The object-replacement character never reaches the projection")
    func attachmentMarkersAreStripped() {
        let document = NoteDocument(pieces: [prose(.paragraph, "before\u{FFFC}after")])

        #expect(!document.projectedBody.contains("\u{FFFC}"))
        #expect(!document.plainText.contains("\u{FFFC}"))
    }

    // MARK: The outline

    @Test("The outline is the headings, in order, with their levels")
    func theOutlineIsTheHeadings() {
        let document = NoteDocument(pieces: [
            prose(.heading1, "First"),
            prose(.paragraph, "Prose."),
            prose(.heading2, "Second"),
            prose(.heading3, "Third"),
        ])

        let outline = document.headings
        #expect(outline.map(\.title) == ["First", "Second", "Third"])
        #expect(outline.map(\.level) == [1, 2, 3])
        #expect(outline.map(\.position) == [0, 2, 3])
    }

    @Test("An untitled heading is not an outline entry")
    func emptyHeadingsAreNotListed() {
        // A heading being typed is empty for as long as it takes to type it, and an outline that
        // grows a blank row per keystroke is an outline that moves while somebody is writing.
        let document = NoteDocument(pieces: [prose(.heading1, "   "), prose(.heading1, "Real")])

        #expect(document.headings.map(\.title) == ["Real"])
    }

    @Test("An outline earns its width only when there is structure to navigate")
    func theOutlineHasAThreshold() {
        #expect(!NoteDocument(pieces: [prose(.heading1, "Alone")]).hasUsefulOutline())
        #expect(NoteDocument(pieces: [prose(.heading1, "One"), prose(.heading2, "Two")]).hasUsefulOutline())
    }
}
