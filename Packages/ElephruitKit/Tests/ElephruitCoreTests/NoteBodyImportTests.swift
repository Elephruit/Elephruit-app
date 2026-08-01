import ElephruitCore
import Foundation
import Testing

/// Turning an existing note's plain body into a document.
///
/// ### What is actually being tested
/// Not "does the parser understand Markdown". The gate ADR 0006 sets is that no character of
/// anybody's note changes, and the parser meets it by checking its own work: structure is adopted
/// only when re-projecting gives the original string back exactly. So the property worth asserting
/// hardest is the one that holds for input nobody anticipated — including input designed to defeat
/// the parser.
@Suite("Note body import")
struct NoteBodyImportTests {
    /// The gate itself, as a function. Every test that matters ends here.
    private func survives(_ body: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let document = NoteBodyImport.document(from: body)
        #expect(
            document.projectedBody == body,
            "the projection differs from the body it came from",
            sourceLocation: sourceLocation
        )
    }

    // MARK: The gate

    @Test("Nothing a body can contain changes a character of it")
    func nothingIsEverLost() {
        for body in [
            "",
            "A single line.",
            "Two\nlines.",
            "# A heading\n\nSome prose beneath it.",
            "- one\n- two\n- three",
            "1. first\n2. second",
            "- [ ] undone\n- [x] done",
            "> a quotation",
            "```swift\nlet x = 1\n```",
            "---",
            "See [[Project Kittiwake]] for the detail.",
            "See [[Project Kittiwake|the kittiwake]] instead.",
            "Read [the manual](https://example.com/manual).",
            "  - indented once\n    - and twice",
            // Now the awkward ones, which is where a parser earns its keep or gets out of the way.
            "1. 1. 1.",
            "Versions 1. 2. and 3. are affected.",
            "**bold** and *italic* and `code`",
            "#hashtag not a heading",
            "#",
            "-",
            "- ",
            ">not a quote, no space",
            "```unterminated\nstill going",
            "text with [a bracket] but no link",
            "text with [an empty]() link",
            "a [[nested [[wiki]] link",
            "trailing spaces   \nand a line after",
            "\n\n\n",
            "emoji 👩‍👩‍👧‍👦 and accents é",
            "    four spaces of indent",
            "\ttab indented",
        ] {
            survives(body)
        }
    }

    @Test("A body the parser cannot represent still keeps every character")
    func theFallbackIsLossless() {
        // A list every one of whose items is numbered `1.` — which is legal Markdown and renders as
        // 1, 2, 3, but is not what the characters say. Re-projecting renumbers it, and renumbering
        // is a change to somebody's text, so the whole note goes down the plain path rather than
        // being tidied up on its author's behalf.
        let body = "1. first\n1. second\n1. third"
        let document = NoteBodyImport.document(from: body)

        #expect(document.projectedBody == body)
        #expect(document.paragraphs.allSatisfy { $0.kind == .paragraph }, "it declined to interpret")
    }

    @Test("A list that already counts correctly is adopted")
    func correctlyNumberedListsAreAdopted() {
        // The other side of the same rule, so the fallback cannot quietly become the only path.
        let document = NoteBodyImport.document(from: "1. first\n2. second\n3. third")

        #expect(document.paragraphs.allSatisfy { $0.kind == .numbered })
        #expect(document.paragraphs.map(\.plainText) == ["first", "second", "third"])
    }

    // MARK: What it does adopt

    @Test("Headings become headings, so an old note gains an outline")
    func headingsAreAdopted() {
        let document = NoteBodyImport.document(from: "# One\n## Two\n### Three\nProse.")

        #expect(document.paragraphs.map(\.kind) == [.heading1, .heading2, .heading3, .paragraph])
        #expect(document.headings.map(\.title) == ["One", "Two", "Three"])
    }

    @Test("Lists become lists, with their nesting")
    func listsAreAdopted() {
        let document = NoteBodyImport.document(from: "- top\n  - under\n    - deeper")

        #expect(document.paragraphs.map(\.kind) == [.bulleted, .bulleted, .bulleted])
        #expect(document.paragraphs.map(\.indent) == [0, 1, 2])
    }

    @Test("A checkbox is read as a checkbox and not as a bullet with brackets in it")
    func checklistsBeatBullets() {
        let document = NoteBodyImport.document(from: "- [x] done\n- [ ] not\n- plain")

        #expect(document.paragraphs.map(\.kind) == [.checklist, .checklist, .bulleted])
        #expect(document.paragraphs.map(\.isTicked) == [true, false, false])
        #expect(document.paragraphs[0].plainText == "done", "the checkbox is not part of the text")
    }

    @Test("A fenced block becomes code, keeps its language, and is not interpreted inside")
    func codeIsAdoptedWhole() {
        let body = "```swift\n# not a heading\n- not a list\n```"
        let document = NoteBodyImport.document(from: body)

        #expect(document.paragraphs.count == 1)
        #expect(document.paragraphs[0].kind == .code)
        #expect(document.paragraphs[0].language == "swift")
        #expect(document.paragraphs[0].plainText == "# not a heading\n- not a list")
        survives(body)
    }

    // MARK: Links

    @Test("A wiki link becomes a real link, which is the point of doing this at all")
    func wikiLinksBecomeLinks() {
        let document = NoteBodyImport.document(from: "See [[Project Kittiwake]] now.")
        let text = document.paragraphs[0].text

        #expect(text.plainText == "See Project Kittiwake now.")
        #expect(text.link(at: 6) == .wiki("Project Kittiwake"))
    }

    @Test("A wiki link with display text keeps both halves")
    func wikiLinksKeepDisplayText() {
        let document = NoteBodyImport.document(from: "See [[Project Kittiwake|the bird one]].")
        let text = document.paragraphs[0].text

        #expect(text.plainText == "See the bird one.")
        #expect(text.link(at: 6) == .wiki("Project Kittiwake"))
    }

    @Test("A Markdown link becomes a URL link")
    func markdownLinksBecomeLinks() {
        let document = NoteBodyImport.document(from: "Read [the manual](https://example.com).")
        let text = document.paragraphs[0].text

        #expect(text.plainText == "Read the manual.")
        #expect(text.link(at: 7) == .url("https://example.com"))
    }

    @Test("Emphasis is left as the characters it is")
    func emphasisIsNotRead() {
        // The projection cannot write `**bold**` — marks live on runs, not in the text — so reading
        // it would turn four characters into a mark and then lose them. Left alone, they survive.
        let document = NoteBodyImport.document(from: "**bold** text")

        #expect(document.paragraphs[0].plainText == "**bold** text")
    }

    // MARK: Wiki links keep working across the whole trip

    @Test("Links reconcile after a body has been through a document and back")
    func reconciliationStillWorks() {
        // The end-to-end version of the thing that would break silently: body → document → body,
        // and the parser that owns link reconciliation still finds what it found before.
        let body = "See [[One]] and [[Two|the second]] and http://plain.example.com"

        let before = WikiLinkParser.links(in: body).map(\.targetTitle)
        let after = WikiLinkParser.links(in: NoteBodyImport.document(from: body).projectedBody)

        #expect(before == ["One", "Two"])
        #expect(after.map(\.targetTitle) == before)
    }
}
