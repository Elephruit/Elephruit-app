import Foundation

/// Turning the plain-text `body` a note has today into a document.
///
/// ### Why this checks its own work
/// ADR 0006's migration gate is exact character equality of the regenerated projection against the
/// original string, and the usual way to meet a gate like that is to write a careful parser and a
/// test with some examples in it. That is not enough here, because the corpus is somebody's real
/// notes and the examples are whatever they happened to type. A body containing `1. ` at the start
/// of three lines is a numbered list to a parser and possibly a sentence about version numbers to
/// its author, and the only honest way to tell is to convert it and look at what comes back.
///
/// So the gate runs *per note, at the moment of conversion*: structure is adopted only when
/// re-projecting the result gives back the original string exactly, character for character. When it
/// does not, the note becomes plain paragraphs, which cannot lose anything because the projection of
/// plain paragraphs is the lines they were made from. Nobody's note is silently rewritten in order
/// to look tidier, and no amount of Markdown this parser does not understand can cost a character.
public enum NoteBodyImport {
    /// A document from a note's existing body.
    public static func document(from body: String) -> NoteDocument {
        let structured = NoteDocument(pieces: parse(body))

        // The gate. Adopting structure is a convenience; keeping every character is not optional.
        guard structured.projectedBody == body else { return plain(body) }
        return structured
    }

    /// The lossless reading: every line is a paragraph and nothing is interpreted.
    static func plain(_ body: String) -> NoteDocument {
        let lines = body.components(separatedBy: "\n")
        guard !lines.isEmpty else { return .empty }
        return NoteDocument(pieces: lines.map { .prose(NoteParagraph(text: richText(from: $0))) })
    }

    // MARK: Lines

    private static func parse(_ body: String) -> [NotePiece] {
        var pieces: [NotePiece] = []
        var lines = body.components(separatedBy: "\n")[...]

        while let line = lines.first {
            lines = lines.dropFirst()

            // A fence opens a code block that runs to the next fence. Handled before anything else
            // because inside one, `# ` is a comment and `- ` is a subtraction.
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3))
                var body: [String] = []
                while let next = lines.first, !next.hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                // Drop the closing fence. An unterminated block runs to the end of the note, which
                // is what every Markdown renderer does and what the writer evidently meant.
                if lines.first != nil { lines = lines.dropFirst() }

                pieces.append(.prose(NoteParagraph(
                    kind: .code,
                    text: NoteRichText(body.joined(separator: "\n")),
                    language: language.isEmpty ? nil : language
                )))
                continue
            }

            pieces.append(piece(from: line))
        }

        return pieces
    }

    private static func piece(from line: String) -> NotePiece {
        if line == "---" { return .object(.divider) }

        // The indent is whatever pairs of spaces precede a list marker, because that is exactly what
        // the projection writes. Anything else — a tab, three spaces — is left alone and the line
        // stays prose, which the gate will then confirm was the right call.
        var remainder = Substring(line)
        var indent = 0
        while remainder.hasPrefix("  "), indent < NoteParagraph.maximumIndent {
            remainder = remainder.dropFirst(2)
            indent += 1
        }

        // Longest prefix first: `- [ ] ` is also `- `, and reading it as a bullet would leave the
        // checkbox sitting in the text.
        let prefixes: [(marker: String, kind: NoteParagraphKind, ticked: Bool)] = [
            ("- [x] ", .checklist, true),
            ("- [ ] ", .checklist, false),
            ("- ", .bulleted, false),
        ]

        for (marker, kind, ticked) in prefixes where remainder.hasPrefix(marker) {
            return .prose(NoteParagraph(
                kind: kind,
                text: richText(from: String(remainder.dropFirst(marker.count))),
                indent: indent,
                isTicked: ticked
            ))
        }

        // A numbered item, whatever number it was written with. The projection renumbers from one,
        // so a list that was typed `1. 1. 1.` comes back `1. 2. 3.` and fails the gate — correctly,
        // because that is a change to the text. A list already numbered in order passes.
        if let item = numberedItem(in: remainder) {
            return .prose(NoteParagraph(kind: .numbered, text: richText(from: item), indent: indent))
        }

        // The unindented kinds. Checked against the original line, since none of them nest.
        let unindented: [(marker: String, kind: NoteParagraphKind)] = [
            ("### ", .heading3),
            ("## ", .heading2),
            ("# ", .heading1),
            ("> ", .quote),
        ]

        for (marker, kind) in unindented where line.hasPrefix(marker) {
            return .prose(NoteParagraph(kind: kind, text: richText(from: String(line.dropFirst(marker.count)))))
        }

        return .prose(NoteParagraph(text: richText(from: line)))
    }

    /// The text after `12. `, or `nil` when the line does not start that way.
    private static func numberedItem(in line: Substring) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    // MARK: Inline

    /// One line's text, with the links it carries.
    ///
    /// Only the two forms the projection can write back: `[[Wiki Links]]` and `[text](url)`.
    /// Emphasis is deliberately *not* read. The projection has no way to write `**bold**` — marks
    /// live on runs, not in the text — so parsing it would turn four characters into a mark and then
    /// lose them, which the gate would catch and which would send an otherwise fine note down the
    /// plain path. Left alone, the asterisks survive as the characters they are.
    static func richText(from line: String) -> NoteRichText {
        var runs: [NoteTextRun] = []
        var plain = ""
        var index = line.startIndex

        func flush() {
            guard !plain.isEmpty else { return }
            runs.append(NoteTextRun(plain))
            plain = ""
        }

        while index < line.endIndex {
            let rest = line[index...]

            if rest.hasPrefix("[["), let close = rest.range(of: "]]") {
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
                if !inner.isEmpty, !inner.contains("[") {
                    let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let target = String(parts[0])
                    let shown = parts.count > 1 ? String(parts[1]) : target

                    flush()
                    runs.append(NoteTextRun(shown, link: .wiki(target)))
                    index = close.upperBound
                    continue
                }
            }

            if rest.hasPrefix("["), let link = markdownLink(in: rest) {
                flush()
                runs.append(NoteTextRun(link.label, link: .url(link.address)))
                index = link.end
                continue
            }

            plain.append(line[index])
            index = line.index(after: index)
        }

        flush()
        return NoteRichText(runs: runs)
    }

    private static func markdownLink(
        in text: Substring
    ) -> (label: String, address: String, end: String.Index)? {
        guard let labelEnd = text.firstIndex(of: "]") else { return nil }

        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        guard let addressEnd = text[afterLabel...].firstIndex(of: ")") else { return nil }

        let label = String(text[text.index(after: text.startIndex)..<labelEnd])
        let address = String(text[text.index(after: afterLabel)..<addressEnd])

        // An empty address would be written back as `[label]()`, which is what came in, but an empty
        // *label* would not round-trip at all — there would be no text to hang the link on.
        guard !label.isEmpty else { return nil }

        return (label, address, text.index(after: addressEnd))
    }
}
