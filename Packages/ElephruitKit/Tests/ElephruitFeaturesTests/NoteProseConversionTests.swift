import AppKit
@testable import ElephruitFeatures
import ElephruitCore
import Foundation
import Testing

/// The conversion between stored pieces and the editing surface — the only place the two
/// representations meet, and the thing the spec says to test hardest. Pieces → attributed string
/// → pieces must be the identity.
@Suite("Note prose conversion")
struct NoteProseConversionTests {
    private func roundTrip(_ paragraphs: [NoteParagraph], trailingEmpty: NoteParagraph? = nil) -> [NoteParagraph] {
        let attributed = NoteProseConversion.attributedString(for: paragraphs)
        return NoteProseConversion.paragraphs(
            from: attributed,
            trailingEmpty: trailingEmpty.map(NoteParagraphAttribute.init)
        )
    }

    // MARK: The identity, kind by kind

    @Test("Every kind survives the round trip")
    func everyKindRoundTrips() {
        for kind in NoteParagraphKind.allCases {
            let original = [NoteParagraph(kind: kind, text: NoteRichText("Some text"))]
            #expect(roundTrip(original) == original, "\(kind.displayName)")
        }
    }

    @Test("Every indent level survives the round trip")
    func everyIndentRoundTrips() {
        for indent in 0...NoteParagraph.maximumIndent {
            let original = [NoteParagraph(kind: .bulleted, text: NoteRichText("item"), indent: indent)]
            #expect(roundTrip(original) == original, "indent \(indent)")
        }
    }

    @Test("Every inline mark survives the round trip")
    func everyMarkRoundTrips() {
        let marks: [NoteInlineMarks] = [.bold, .italic, .underline, .strikethrough, .code]
        for mark in marks {
            let original = [NoteParagraph(text: NoteRichText("marked", marks: mark))]
            #expect(roundTrip(original) == original, "\(mark.names)")
        }

        let stacked = [NoteParagraph(text: NoteRichText("all of it", marks: [.bold, .italic, .underline, .strikethrough]))]
        #expect(roundTrip(stacked) == stacked)
    }

    @Test("Every kind of link survives the round trip")
    func everyLinkRoundTrips() {
        let links: [NoteInlineLink] = [
            .url("https://example.org/page"),
            .item(UUID()),
            .wiki("Some Note Title"),
        ]

        for link in links {
            let original = [NoteParagraph(text: NoteRichText("linked", link: link))]
            #expect(roundTrip(original) == original, "\(link)")
        }
    }

    @Test("A paragraph of mixed runs keeps its runs")
    func mixedRunsRoundTrip() {
        let text = NoteRichText(runs: [
            NoteTextRun("plain, then "),
            NoteTextRun("bold", marks: [.bold]),
            NoteTextRun(" and "),
            NoteTextRun("code", marks: [.code]),
            NoteTextRun(" and a "),
            NoteTextRun("link", link: .wiki("Target")),
            NoteTextRun("."),
        ])
        let original = [NoteParagraph(text: text)]
        #expect(roundTrip(original) == original)
    }

    @Test("The fields a kind carries survive: tick, language, tone")
    func kindFieldsRoundTrip() {
        let original = [
            NoteParagraph(kind: .checklist, text: NoteRichText("done"), isTicked: true),
            NoteParagraph(kind: .code, text: NoteRichText("let x = 1"), language: "swift"),
            NoteParagraph(kind: .callout, text: NoteRichText("mind"), tone: .warning),
        ]
        #expect(roundTrip(original) == original)
    }

    // MARK: The document shapes that break naive conversions

    @Test("An empty document is one empty paragraph, both ways")
    func emptyDocumentRoundTrips() {
        let original = [NoteParagraph()]
        #expect(roundTrip(original) == original)

        let attributed = NoteProseConversion.attributedString(for: original)
        #expect(attributed.string.isEmpty, "one empty paragraph needs no characters")
    }

    @Test("An empty paragraph in the middle keeps its kind, because it owns its newline")
    func emptyMiddleParagraphKeepsItsKind() {
        let original = [
            NoteParagraph(text: NoteRichText("before")),
            NoteParagraph(kind: .heading2, text: NoteRichText()),
            NoteParagraph(text: NoteRichText("after")),
        ]
        #expect(roundTrip(original) == original)
    }

    @Test("An empty final paragraph keeps its kind only through the typing-attributes hint")
    func emptyFinalParagraphNeedsTheHint() {
        let styledEnding = [
            NoteParagraph(text: NoteRichText("before")),
            NoteParagraph(kind: .checklist, text: NoteRichText()),
        ]

        // Without the hint the kind has nowhere to live — the documented loss.
        let withoutHint = roundTrip(styledEnding)
        #expect(withoutHint[1].kind == .paragraph)

        // The text view passes its typing attributes, and the kind survives.
        #expect(roundTrip(styledEnding, trailingEmpty: styledEnding[1]) == styledEnding)
    }

    @Test("A multi-line code block is one piece: stored newlines display as line separators")
    func multiLineCodeIsOnePiece() {
        let original = [
            NoteParagraph(kind: .code, text: NoteRichText("func a() {\n\n    return\n}"), language: "swift")
        ]

        let attributed = NoteProseConversion.attributedString(for: original)
        #expect(!attributed.string.contains("\n"), "a paragraph-internal break is not a paragraph boundary")
        #expect(attributed.string.contains(NoteProseConversion.displayLineBreak))

        #expect(roundTrip(original) == original)
    }

    @Test("A many-paragraph document with everything in it is the identity")
    func fullDocumentRoundTrips() {
        let original = [
            NoteParagraph(kind: .heading1, text: NoteRichText("Title")),
            NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("Prose with "),
                NoteTextRun("emphasis", marks: [.italic]),
                NoteTextRun("."),
            ])),
            NoteParagraph(kind: .quote, text: NoteRichText("Somebody else's words.")),
            NoteParagraph(kind: .bulleted, text: NoteRichText("first"), indent: 0),
            NoteParagraph(kind: .bulleted, text: NoteRichText("nested"), indent: 2),
            NoteParagraph(kind: .numbered, text: NoteRichText("counted"), indent: 0),
            NoteParagraph(kind: .checklist, text: NoteRichText("ticked"), isTicked: true),
            NoteParagraph(kind: .code, text: NoteRichText("a\nb"), language: "python"),
            NoteParagraph(kind: .callout, text: NoteRichText("important"), tone: .important),
            NoteParagraph(kind: .heading3, text: NoteRichText("Coda")),
            NoteParagraph(text: NoteRichText("The end.")),
        ]
        #expect(roundTrip(original) == original)
    }

    @Test("Emoji do not shift offsets: characters and UTF-16 diverge and the text survives")
    func emojiSurvive() {
        let original = [
            NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("family 👨‍👩‍👧‍👦 and flag 🏳️‍🌈 "),
                NoteTextRun("bold 🎉", marks: [.bold]),
            ])),
            NoteParagraph(kind: .heading2, text: NoteRichText("after 🚀")),
        ]
        #expect(roundTrip(original) == original)
    }

    // MARK: The attribute is authoritative, never the appearance

    @Test("A heading's weight is not a bold mark: appearance is derived, never read back")
    func appearanceIsNotReadBack() {
        let original = [NoteParagraph(kind: .heading1, text: NoteRichText("Heavy"))]
        let back = roundTrip(original)

        #expect(back == original)
        #expect(back[0].text.runs.allSatisfy { $0.marks.isEmpty }, "the font was bold; the text was not")
    }

    @Test("Fragmented attribute runs that agree come back as one run")
    func fragmentedRunsNormalize() {
        // Typing produces attribute runs cut wherever the caret happened to be. Two adjacent runs
        // with the same attributes are the same text, and NoteRichText's normalisation says so.
        let attribute = NoteParagraphAttribute(kind: .paragraph)
        let fragmented = NSMutableAttributedString()
        fragmented.append(NSAttributedString(string: "one ", attributes: NoteProseStyle.attributes(for: attribute)))
        fragmented.append(NSAttributedString(string: "two", attributes: NoteProseStyle.attributes(for: attribute)))

        let back = NoteProseConversion.paragraphs(from: fragmented)
        #expect(back == [NoteParagraph(text: NoteRichText("one two"))])
        #expect(back[0].text.runs.count == 1)
    }

    @Test("Text with no note attributes at all reads as plain prose rather than refusing")
    func unattributedTextIsProse() {
        let foreign = NSAttributedString(string: "pasted\nlines")
        let back = NoteProseConversion.paragraphs(from: foreign)

        #expect(back == [
            NoteParagraph(text: NoteRichText("pasted")),
            NoteParagraph(text: NoteRichText("lines")),
        ])
    }
}
