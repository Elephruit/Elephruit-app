import ElephruitCore
import Foundation
import Testing

/// The inline text format.
///
/// ### Why this is tested this hard for something so small
/// Because it is the stored form. ADR 0006 rejected two formats that carry more than this one, on
/// the grounds that an explicit run list makes sanitisation structural and the bytes reviewable —
/// and both of those are claims about *this file*. If a mark can be lost across a round trip, or two
/// documents that read identically fail to compare equal, the whole argument for the format goes
/// with it, and it goes silently.
@Suite("Note rich text")
struct NoteRichTextTests {
    private func roundTrip(_ text: NoteRichText) throws -> NoteRichText {
        let data = try JSONEncoder().encode(text)
        return try JSONDecoder().decode(NoteRichText.self, from: data)
    }

    // MARK: Normalising

    @Test("Neighbouring runs that agree become one run")
    func adjacentRunsMerge() {
        let text = NoteRichText(runs: [
            NoteTextRun("Hello, "),
            NoteTextRun("world"),
        ])

        #expect(text.runs.count == 1)
        #expect(text.plainText == "Hello, world")
    }

    @Test("Runs that disagree stay apart")
    func differingRunsSurvive() {
        let text = NoteRichText(runs: [
            NoteTextRun("plain "),
            NoteTextRun("bold", marks: .bold),
        ])

        #expect(text.runs.count == 2)
    }

    @Test("An empty run is not a run")
    func emptyRunsAreDropped() {
        let text = NoteRichText(runs: [
            NoteTextRun(""),
            NoteTextRun("something"),
            NoteTextRun("", marks: .italic),
        ])

        #expect(text.runs.count == 1)
        #expect(text.plainText == "something")
    }

    @Test("Bolding a word and unbolding it leaves the document it started as")
    func markingIsReversible() {
        // The reason normalisation is not cosmetic. Without it this document renders identically to
        // the original and does not equal it — so the editor believes there is something to save,
        // and undo grows a step that changes nothing anybody can see.
        let original = NoteRichText("the quick brown fox")
        let bolded = original.togglingMark(.bold, in: 4..<9)
        let back = bolded.togglingMark(.bold, in: 4..<9)

        #expect(bolded != original)
        #expect(back == original, "same text, same marks, and so the same document")
        #expect(back.runs.count == 1)
    }

    // MARK: Round trips

    @Test("Every mark survives being stored and read back")
    func marksRoundTrip() throws {
        let text = NoteRichText(runs: [
            NoteTextRun("bold", marks: .bold),
            NoteTextRun("italic", marks: .italic),
            NoteTextRun("under", marks: .underline),
            NoteTextRun("struck", marks: .strikethrough),
            NoteTextRun("code", marks: .code),
            NoteTextRun("several", marks: [.bold, .italic, .code]),
        ])

        #expect(try roundTrip(text) == text)
    }

    @Test("Every kind of link survives being stored and read back")
    func linksRoundTrip() throws {
        let target = UUID()
        let text = NoteRichText(runs: [
            NoteTextRun("out", link: .url("https://example.com")),
            NoteTextRun("across", link: .item(target)),
            NoteTextRun("unresolved", link: .wiki("A Note That Does Not Exist Yet")),
        ])

        let read = try roundTrip(text)
        #expect(read == text)
        #expect(read.link(at: 4) == .item(target), "the target is the whole point of an item link")
    }

    @Test("An empty document round-trips as an empty document")
    func emptinessRoundTrips() throws {
        #expect(try roundTrip(NoteRichText()) == NoteRichText())
        #expect(try roundTrip(NoteRichText("")).isEmpty)
    }

    @Test("The stored form is readable")
    func theEncodingIsDiffable() throws {
        // ADR 0006 chose this format partly because it can be reviewed in a diff. A bitfield would
        // round-trip just as well and tell a reader nothing, so the names are asserted rather than
        // left as an implementation detail.
        let data = try JSONEncoder().encode(NoteRichText("x", marks: [.bold, .code]))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"bold\""))
        #expect(json.contains("\"code\""))
    }

    @Test("A mark this version does not know about is dropped, not carried")
    func unknownMarksAreRefused() throws {
        // The allow-list, doing the job it exists for. A document written by a newer build loses
        // that build's marks here, which is the trade ADR 0006 makes on purpose: an attribute that
        // cannot be rendered, exported or searched is not worth keeping hold of.
        let json = #"[{"text":"x","marks":["bold","chartreuse"]}]"#
        let text = try JSONDecoder().decode(NoteRichText.self, from: Data(json.utf8))

        #expect(text.runs.count == 1)
        #expect(text.runs[0].marks == .bold)
    }

    @Test("A link this version does not know about is an error, not a silent loss")
    func unknownLinkKindsThrow() {
        // Unlike a mark, a link is a modelled relationship. Quietly dropping one would remove a
        // connection the user made, which is worth refusing to open the document over.
        let json = #"[{"text":"x","link":{"kind":"telepathy","value":"whatever"}}]"#

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NoteRichText.self, from: Data(json.utf8))
        }
    }

    // MARK: The projection

    @Test("The object-replacement character never reaches the projection")
    func attachmentMarkersAreStripped() {
        // Measured arriving from `NSAttributedString.string`, per ADR 0006 consequence 2. Left in,
        // every note with an image gains a junk character in the search index and in its export.
        let text = NoteRichText("before\u{FFFC}after")

        #expect(text.plainText == "beforeafter")
        #expect(!text.plainText.contains("\u{FFFC}"))
    }

    // MARK: Offsets

    @Test("Length and offsets count Characters, not UTF-16 units")
    func offsetsAreInCharacters() {
        // The distinction that decides whether a caret can land in the middle of a character. Both
        // of these are one Character and two UTF-16 units, or worse.
        #expect(NoteRichText("é").length == 1)
        #expect(NoteRichText("👩‍👩‍👧‍👦").length == 1)
        #expect(NoteRichText("a👩‍👩‍👧‍👦b").length == 3)
    }

    @Test("A slice keeps the marks that were on it")
    func slicingKeepsMarks() {
        let text = NoteRichText("the quick brown fox").togglingMark(.bold, in: 4..<9)
        let slice = text.slice(4..<9)

        #expect(slice.plainText == "quick")
        #expect(slice.runs.allSatisfy { $0.marks.contains(.bold) })
    }

    @Test("A slice across a mark boundary keeps both sides")
    func slicingSpansRuns() {
        let text = NoteRichText("the quick brown fox").togglingMark(.bold, in: 4..<9)
        let slice = text.slice(0..<15)

        #expect(slice.plainText == "the quick brown")
        #expect(slice.runs.count == 3, "plain, bold, plain")
    }

    @Test("Offsets outside the text are brought inside it rather than trapping")
    func offsetsAreClamped() {
        let text = NoteRichText("short")

        #expect(text.slice(0..<999).plainText == "short")
        #expect(text.slice(-5..<2).plainText == "sh")
        #expect(text.slice(10..<20).isEmpty)
        #expect(text.removing(3..<999).plainText == "sho")
        #expect(text.inserting(NoteRichText("!"), at: 999).plainText == "short!")
    }

    @Test("Inserting keeps the inserted text's own marks")
    func insertionKeepsItsOwnMarks() {
        let text = NoteRichText("the  fox")
        let inserted = text.inserting(NoteRichText("bold", marks: .bold), at: 4)

        #expect(inserted.plainText == "the bold fox")
        #expect(inserted.marks(at: 6) == .bold)
        #expect(inserted.marks(at: 2) == [])
    }

    @Test("Removing a range takes exactly that range")
    func removalIsExact() {
        let text = NoteRichText("the quick brown fox")

        #expect(text.removing(4..<10).plainText == "the brown fox")
        #expect(text.removing(0..<0) == text, "an empty range changes nothing")
    }

    @Test("The marks at a caret are the ones typing would continue")
    func marksAtACaretReadBackwards() {
        // Typing at the end of a bold word continues the bold word. Reading forwards instead would
        // make the last character of a bold run the one place where bold stops applying.
        let text = NoteRichText("plain bold").togglingMark(.bold, in: 6..<10)

        #expect(text.marks(at: 10) == .bold, "at the very end of the bold run")
        #expect(text.marks(at: 8) == .bold, "inside it")
        #expect(text.marks(at: 3) == [], "inside the plain run")
        #expect(text.marks(at: 0) == [], "at the start there is nothing behind, so it reads forwards")
    }

    // MARK: Toggling across a mixed selection

    @Test("A mixed selection is made uniform before it is flipped")
    func togglingAMixedSelectionAddsFirst() {
        // Pressing ⌘B on a selection that is half bold makes all of it bold. Flipping each run
        // independently would swap which half, and pressing it again would swap it back.
        let text = NoteRichText("the quick brown fox").togglingMark(.bold, in: 4..<9)
        let all = text.togglingMark(.bold, in: 0..<19)

        #expect(all.runs.count == 1)
        #expect(all.runs[0].marks == .bold)

        let none = all.togglingMark(.bold, in: 0..<19)
        #expect(none.runs[0].marks == [])
    }

    @Test("Links can be put on and taken off a range")
    func linksCanBeSetAndCleared() {
        let text = NoteRichText("see the manual")
        let linked = text.settingLink(.url("https://example.com"), in: 8..<14)

        #expect(linked.link(at: 10) == .url("https://example.com"))
        #expect(linked.link(at: 2) == nil)

        let cleared = linked.settingLink(nil, in: 0..<14)
        #expect(cleared.link(at: 10) == nil)
        #expect(cleared == text, "clearing every link returns the document it started as")
    }
}
