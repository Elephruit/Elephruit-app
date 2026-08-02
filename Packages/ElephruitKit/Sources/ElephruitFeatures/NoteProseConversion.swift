import AppKit
import ElephruitCore

/// The one place the stored pieces and the editing surface meet.
///
/// Prose paragraphs become one `NSAttributedString` — paragraphs joined by `\n`, the kind carried
/// as an attribute on every character — and come back the same way. The spec calls this the only
/// genuinely new thing in the editor and the thing to test hardest: **pieces → string → pieces
/// must be the identity**, for every kind, every indent, every mark, every link, and an empty
/// document.
///
/// ### The two characters that matter
/// - **`\n` separates paragraphs.** Never anything else. It always carries the attribute of the
///   paragraph it ends, so an empty paragraph in the middle of a document still owns one
///   attributed character.
/// - **`\u{2028}` is a line break *inside* a paragraph.** Return inside a code block, Shift-Return
///   anywhere. It is stored as `\n` inside the paragraph's text — a multi-line code block is one
///   piece, exactly as the projection's fenced form expects — and displayed as U+2028 so the
///   text view does not mistake it for a paragraph boundary. The swap happens here, both ways,
///   and nowhere else.
///
/// ### The one thing the string cannot carry
/// A final paragraph with no text owns no characters, so its kind has nowhere to live. The text
/// view knows the answer — its typing attributes — and passes it as `trailingEmpty`. Everywhere
/// else the conversion is total.
enum NoteProseConversion {
    /// A paragraph-internal line break as the text view displays it.
    static let displayLineBreak = "\u{2028}"

    // MARK: Pieces → string

    static func attributedString(for paragraphs: [NoteParagraph]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (index, paragraph) in paragraphs.enumerated() {
            let attribute = NoteParagraphAttribute(paragraph)

            for run in paragraph.text.runs {
                let display = run.text.replacingOccurrences(of: "\n", with: Self.displayLineBreak)
                result.append(NSAttributedString(
                    string: display,
                    attributes: NoteProseStyle.attributes(for: attribute, marks: run.marks, link: run.link)
                ))
            }

            // The newline carries the attribute of the paragraph it ends — no marks, no link,
            // because a mark on a separator would bleed into whatever gets typed at a boundary.
            if index < paragraphs.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: NoteProseStyle.attributes(for: attribute)
                ))
            }
        }

        return result
    }

    // MARK: String → pieces

    static func paragraphs(
        from attributed: NSAttributedString,
        trailingEmpty: NoteParagraphAttribute? = nil
    ) -> [NoteParagraph] {
        let string = attributed.string as NSString

        guard string.length > 0 else {
            return [trailingEmpty?.emptyParagraph ?? NoteParagraph()]
        }

        var result: [NoteParagraph] = []
        var paragraphStart = 0

        // Scan UTF-16 for the separator directly rather than using the system's paragraph
        // enumeration, which also breaks on U+2028 — the character this conversion uses precisely
        // because it is *not* a paragraph boundary here.
        var index = 0
        while index <= string.length {
            let isEnd = index == string.length
            let isSeparator = !isEnd && string.character(at: index) == 0x0A

            if isSeparator || isEnd {
                let contentRange = NSRange(location: paragraphStart, length: index - paragraphStart)
                let separatorIndex = isSeparator ? index : nil

                if isEnd, contentRange.length == 0, paragraphStart > 0 {
                    // Past the final newline with nothing after it: an empty final paragraph,
                    // the one shape the string cannot describe.
                    result.append(trailingEmpty?.emptyParagraph ?? NoteParagraph())
                } else {
                    result.append(paragraph(in: attributed, content: contentRange, separatorAt: separatorIndex))
                }

                paragraphStart = index + 1
            }

            if isEnd { break }
            index += 1
        }

        return result
    }

    /// One paragraph, read from its content range and (when the content is empty) its newline.
    private static func paragraph(
        in attributed: NSAttributedString,
        content: NSRange,
        separatorAt: Int?
    ) -> NoteParagraph {
        // The kind, from the first character that exists: content first, else the newline that
        // ends this paragraph. One of the two always exists here.
        let anchorIndex = content.length > 0 ? content.location : (separatorAt ?? content.location)
        let attribute = attributed.length > anchorIndex
            ? attributed.attribute(.noteParagraph, at: anchorIndex, effectiveRange: nil) as? NoteParagraphAttribute
            : nil
        let paragraphAttribute = attribute ?? NoteParagraphAttribute(kind: .paragraph)

        var runs: [NoteTextRun] = []

        if content.length > 0 {
            attributed.enumerateAttributes(in: content, options: []) { attributes, range, _ in
                let text = (attributed.string as NSString)
                    .substring(with: range)
                    .replacingOccurrences(of: Self.displayLineBreak, with: "\n")

                let marks: NoteInlineMarks
                if let number = attributes[.noteMarks] as? NSNumber {
                    marks = NoteInlineMarks(rawValue: number.intValue)
                } else {
                    marks = []
                }

                let link = (attributes[.noteLink] as? NoteLinkAttribute)?.link

                runs.append(NoteTextRun(text, marks: marks, link: link))
            }
        }

        return NoteParagraph(
            kind: paragraphAttribute.kind,
            text: NoteRichText(runs: runs),
            indent: paragraphAttribute.indent,
            isTicked: paragraphAttribute.isTicked,
            language: paragraphAttribute.language,
            tone: paragraphAttribute.tone
        )
    }
}
