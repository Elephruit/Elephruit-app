import ElephruitCore
import Foundation
import Testing

/// What the capture field draws over, and where.
///
/// The interesting failures here are all silent ones: a highlight that is one code unit out looks
/// almost right, and a Delete rule that is one code unit out eats a letter that was not part of the
/// tag. Both are invisible in a screenshot and obvious in an assertion.
@Suite("Capture highlighting")
struct CaptureHighlightTests {
    @Test("A tag is one span, covering its sigil")
    func tagSpan() throws {
        let text = "#landscape and the rest"
        let span = try #require(CaptureHighlight.spans(in: text).first)

        #expect(span.standing == .understood)
        #expect(span.kind == .tag)
        #expect(span.text == "landscape")
        #expect(span.utf16Range == 0..<10, "the # belongs to the token, not to the sentence")
    }

    @Test("Every part of the grammar produces a span")
    func everySigil() {
        let spans = CaptureHighlight.spans(in: "#work @Sarah >Launch due:friday !high")
        let kinds = Set(spans.filter { $0.standing == .understood }.map(\.kind))

        #expect(kinds == [.tag, .person, .project, .dueDate, .priority])
    }

    @Test("Spans arrive in reading order, understood and not, interleaved")
    func ordering() {
        // `#!!` is not a usable slug, so it is syntax the parser could not use — and it sits
        // between two things it could. The two lists it comes back on are unsorted with respect
        // to each other, which is the whole reason this collapses them.
        let spans = CaptureHighlight.spans(in: "#alpha #!! #omega")
        let starts = spans.map(\.utf16Range.lowerBound)

        #expect(starts == starts.sorted())
        #expect(spans.count == 3)
        #expect(spans[1].standing == .notUnderstood)
    }

    /// The parser counts grapheme clusters; AppKit counts UTF-16. They agree until they do not, and
    /// when they stop agreeing every highlight after the emoji is drawn over the wrong letters.
    @Test("Offsets survive text that is not one code unit per character")
    func multiCodeUnitText() throws {
        let text = "👨‍👩‍👧‍👦 #landscape"
        let span = try #require(CaptureHighlight.spans(in: text).first)

        let start = String.Index(utf16Offset: span.utf16Range.lowerBound, in: text)
        let end = String.Index(utf16Offset: span.utf16Range.upperBound, in: text)
        #expect(String(text[start..<end]) == "#landscape")
    }

    @Test("Accented and non-Latin tags land on their own letters")
    func nonLatinText() throws {
        for text in ["#café stays", "#日本語 stays", "#straße stays"] {
            let span = try #require(CaptureHighlight.spans(in: text).first)
            let start = String.Index(utf16Offset: span.utf16Range.lowerBound, in: text)
            let end = String.Index(utf16Offset: span.utf16Range.upperBound, in: text)
            #expect(text[start..<end].hasPrefix("#"))
            #expect(!text[start..<end].contains(" "))
        }
    }

    /// A `#` three paragraphs down is a hash. Drawing it as a tag would promise something the save
    /// path does not do, because only the first line is parsed for grammar.
    @Test("Only the first line carries tokens")
    func firstLineOnly() {
        let spans = CaptureHighlight.spans(in: "#one\nnot #two")
        #expect(spans.count == 1)
        #expect(spans.first?.text == "one")
    }

    @Test("Nothing typed, nothing highlighted")
    func empty() {
        #expect(CaptureHighlight.spans(in: "").isEmpty)
        #expect(CaptureHighlight.spans(in: "just a sentence").isEmpty)
    }

    // MARK: - Deleting a token in one press

    @Test("A caret just after a tag is inside it")
    func caretAfterToken() throws {
        let spans = CaptureHighlight.spans(in: "#landscape ")
        let hit = try #require(spans.token(enclosing: 10))
        #expect(hit.text == "landscape")
    }

    @Test("A caret in the middle of a tag is inside it")
    func caretWithinToken() throws {
        let spans = CaptureHighlight.spans(in: "#landscape")
        #expect(spans.token(enclosing: 5)?.text == "landscape")
    }

    /// Backspacing from immediately before a tag must take what is behind the caret, not reach
    /// forwards over the tag in front of it.
    @Test("A caret just before a tag is not inside it")
    func caretBeforeToken() {
        let spans = CaptureHighlight.spans(in: "#landscape")
        #expect(spans.token(enclosing: 0) == nil)
    }

    @Test("A caret past the end of the tag is outside it")
    func caretAfterTrailingSpace() {
        let spans = CaptureHighlight.spans(in: "#landscape x")
        #expect(spans.token(enclosing: 12) == nil)
    }

    /// Syntax the parser could not use stays ordinary text: deleting it a letter at a time is how
    /// the user fixes it, so it must not vanish in one press.
    @Test("Unrecognised syntax is not deletable as a unit")
    func unrecognisedIsNotAToken() {
        let spans = CaptureHighlight.spans(in: "#!!")
        #expect(spans.first?.standing == .notUnderstood)
        #expect(spans.token(enclosing: 2) == nil)
    }

    @Test("A double-click inside a tag resolves to the whole tag")
    func selectionGrowsToTheToken() throws {
        let spans = CaptureHighlight.spans(in: "#landscape and more")
        #expect(spans.token(intersecting: 3..<6)?.text == "landscape")
        #expect(spans.token(intersecting: 12..<15) == nil, "an ordinary word is an ordinary word")
    }

    // MARK: - The caret across the same boundary

    @Test("A caret in plain text is at the same offset in both counts")
    func caretIsUnchangedWithoutSurrogates() {
        let text = "Call the framer"
        #expect(CaptureHighlight.utf16Offset(ofCharacter: 5, in: text) == 5)
        #expect(CaptureHighlight.characterOffset(ofUTF16: 5, in: text) == 5)
    }

    /// The whole reason the pair exists. A caret reported by AppKit as 4 is, in the units the parser
    /// counts in, 2 — and treating one as the other puts the insertion point two words away.
    @Test("A caret after an emoji converts in both directions")
    func caretAcrossAnEmoji() {
        let text = "👨‍👩‍👧 party"
        let afterFamily = 1

        let utf16 = CaptureHighlight.utf16Offset(ofCharacter: afterFamily, in: text)
        #expect(utf16 > afterFamily)
        #expect(CaptureHighlight.characterOffset(ofUTF16: utf16, in: text) == afterFamily)
    }

    @Test("A caret at the very end converts to the very end")
    func caretAtTheEnd() {
        let text = "🎉 party"
        #expect(CaptureHighlight.characterOffset(ofUTF16: text.utf16.count, in: text) == text.count)
        #expect(CaptureHighlight.utf16Offset(ofCharacter: text.count, in: text) == text.utf16.count)
    }

    /// A caret has to be somewhere, so both directions clamp rather than returning nothing.
    @Test("An impossible caret lands inside the text rather than crashing")
    func caretIsClamped() {
        let text = "short"
        #expect(CaptureHighlight.utf16Offset(ofCharacter: 99, in: text) == 5)
        #expect(CaptureHighlight.characterOffset(ofUTF16: 99, in: text) == 5)
        #expect(CaptureHighlight.utf16Offset(ofCharacter: -3, in: text) == 0)
        #expect(CaptureHighlight.characterOffset(ofUTF16: -3, in: text) == 0)
    }

    /// AppKit will not normally produce one, but arithmetic on an offset might, and the answer has to
    /// be a whole character rather than a trap.
    @Test("A caret inside a surrogate pair reports the character it is inside")
    func caretInsideASurrogatePair() {
        let text = "🎉x"
        #expect(CaptureHighlight.characterOffset(ofUTF16: 1, in: text) == 0)
    }
}
