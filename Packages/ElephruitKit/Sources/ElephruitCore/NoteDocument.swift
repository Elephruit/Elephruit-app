import Foundation

/// What a paragraph *is*, as opposed to how it looks.
///
/// ### Why this is a paragraph's kind and not a block's type
/// Because a note is a continuous document, not a stack of blocks. The kind travels as an attribute
/// on a paragraph inside one text view, which is what lets a selection cross from a heading into the
/// prose beneath it, `⌘B` apply to both, and Return be nothing more than Return. The first attempt
/// gave every paragraph its own view; see `docs/31-notes-editor-spec.md` for the four separate
/// defects that cost.
public enum NoteParagraphKind: String, Codable, Sendable, CaseIterable, Hashable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case quote
    case code
    case callout
    case bulleted
    case numbered
    case checklist

    public var displayName: String {
        switch self {
        case .paragraph: "Text"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote: "Quote"
        case .code: "Code"
        case .callout: "Callout"
        case .bulleted: "Bulleted List"
        case .numbered: "Numbered List"
        case .checklist: "Checklist"
        }
    }

    public var symbolName: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .callout: "exclamationmark.bubble"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        }
    }

    /// What this kind does, for a menu's second line.
    ///
    /// A rule rather than a restatement of the name. "Quote: a quotation" says nothing; "somebody
    /// else's words" says when to reach for it. Matched against as well as displayed, so searching
    /// the insert menu for "tick" finds the checklist.
    public var hint: String {
        switch self {
        case .paragraph: "Ordinary prose."
        case .heading1: "A top-level section. Appears in the outline."
        case .heading2: "A section inside a section."
        case .heading3: "The smallest heading that still appears in the outline."
        case .quote: "Somebody else's words."
        case .code: "Preformatted, with a language. Never spell-checked."
        case .callout: "For the thing readers must not miss."
        case .bulleted: "An unordered list. Tab nests, Shift-Tab steps out."
        case .numbered: "Numbers are counted, so deleting one renumbers the rest."
        case .checklist: "Boxes to tick."
        }
    }

    public var isListItem: Bool {
        switch self {
        case .bulleted, .numbered, .checklist: true
        default: false
        }
    }

    /// 1, 2 or 3 for the headings, `nil` for everything else. The outline is built from this.
    public var headingLevel: Int? {
        switch self {
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: nil
        }
    }

    /// Whether Tab and Shift-Tab mean anything here.
    ///
    /// Only lists nest. On anything else Tab should do nothing rather than insert a tab character,
    /// because a tab in the middle of prose is never what the key was pressed for.
    public var acceptsIndent: Bool { isListItem }

    /// What pressing Return at the end of a paragraph of this kind produces.
    ///
    /// A list continues — that is the whole convenience of a list. A heading does not, because
    /// nobody writes two headings in a row, and a code block does not because Return inside code is
    /// a new line of code rather than a new block. Everything else becomes ordinary prose.
    public var continuationKind: NoteParagraphKind {
        switch self {
        case .bulleted, .numbered, .checklist: self
        default: .paragraph
        }
    }

    /// Whether text of this kind is prose that should be checked and smartened.
    ///
    /// Code is not. Substituting a straight quote for a curly one inside a code block silently
    /// changes what the code means, and spell-checking it underlines every identifier in the file.
    public var isProse: Bool { self != .code }
}

/// The tone of a callout, which is what decides its tint.
public enum NoteCalloutTone: String, Codable, Sendable, CaseIterable, Hashable {
    case note
    case tip
    case important
    case warning
    case aside

    public var displayName: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .aside: "Aside"
        }
    }

    /// The `Theme.Palette` name this resolves through. A name, never a colour — the design module
    /// owns what the name looks like, which is what keeps this readable in dark mode.
    public var paletteName: String {
        switch self {
        case .note: "blue"
        case .tip: "green"
        case .important: "indigo"
        case .warning: "orange"
        case .aside: "gray"
        }
    }
}

/// One paragraph: some text, and what sort of paragraph it is.
///
/// ### Why there is no identifier here
/// Because nothing needs one. A paragraph is not a view, so it has no view identity to keep stable;
/// the outline scrolls to a character range worked out from a position; and links point at *items*,
/// never at paragraphs. An identifier would have to survive being split by Return — which duplicates
/// every attribute across both halves — and minting fresh ones on the way back out is a whole class
/// of bug bought for nothing.
public struct NoteParagraph: Codable, Sendable, Hashable {
    public var kind: NoteParagraphKind
    public var text: NoteRichText

    /// How deeply a list item is nested. Zero for everything else.
    public var indent: Int

    /// Whether a checklist item is ticked. Meaningless on every other kind.
    public var isTicked: Bool

    /// A code block's language, for highlighting and for the fence in the export.
    public var language: String?

    public var tone: NoteCalloutTone?

    public static let maximumIndent = 5

    public init(
        kind: NoteParagraphKind = .paragraph,
        text: NoteRichText = NoteRichText(),
        indent: Int = 0,
        isTicked: Bool = false,
        language: String? = nil,
        tone: NoteCalloutTone? = nil
    ) {
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isTicked = isTicked
        self.language = language
        self.tone = tone
        normalize()
    }

    /// Drops the fields this kind cannot use, and brings the indent into range.
    ///
    /// ### Why the paragraph does this to itself rather than trusting its callers
    /// Because a heading carrying a tick and an indent of nine is a paragraph two different pieces of
    /// code will disagree about: one asks the kind what to draw and ignores them, the other asks the
    /// stored fields and honours them. Turning a checklist item into a heading and back should lose
    /// the tick — it is not a checklist item any more — and it should lose it *here*, once, rather
    /// than at each of the places that could have remembered to.
    private mutating func normalize() {
        indent = kind.acceptsIndent ? max(0, min(indent, Self.maximumIndent)) : 0
        if kind != .checklist { isTicked = false }
        if kind != .code { language = nil }
        if kind != .callout { tone = nil }
        if kind == .callout, tone == nil { tone = .note }
    }

    public var plainText: String { text.plainText }
    public var isEmpty: Bool { text.isEmpty }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case indent
        case isTicked
        case language
        case tone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // A kind this build has never heard of reads as ordinary prose rather than refusing to open
        // the document. The same choice `Item.kindRaw` makes, for the same reason: a note written by
        // a newer version should still be readable, and its *text* is the part that matters.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? NoteParagraphKind.paragraph.rawValue

        self.init(
            kind: NoteParagraphKind(rawValue: rawKind) ?? .paragraph,
            text: try container.decodeIfPresent(NoteRichText.self, forKey: .text) ?? NoteRichText(),
            indent: try container.decodeIfPresent(Int.self, forKey: .indent) ?? 0,
            isTicked: try container.decodeIfPresent(Bool.self, forKey: .isTicked) ?? false,
            language: try container.decodeIfPresent(String.self, forKey: .language),
            tone: try container.decodeIfPresent(NoteCalloutTone.self, forKey: .tone)
        )
    }

    /// Written without its defaults, because most paragraphs are prose with none of these set and
    /// spelling them out on every one of them buries the text in fields that say nothing.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if kind != .paragraph { try container.encode(kind, forKey: .kind) }
        if !text.isEmpty { try container.encode(text, forKey: .text) }
        if indent != 0 { try container.encode(indent, forKey: .indent) }
        if isTicked { try container.encode(isTicked, forKey: .isTicked) }
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(tone, forKey: .tone)
    }
}

/// A table, as rows of cells.
public struct NoteTable: Codable, Sendable, Hashable {
    public var rows: [[NoteRichText]]
    public var hasHeaderRow: Bool

    public init(rows: [[NoteRichText]] = [[]], hasHeaderRow: Bool = true) {
        self.rows = rows
        self.hasHeaderRow = hasHeaderRow
    }
}

/// A piece of a note that is not text.
///
/// These are what a prose run flows *around*. They are the reason a note is a sequence of segments
/// rather than one text view — and the reason the list is this short is that the layout furniture
/// was cut: a toggle, a card and a set of columns are ways of assembling a page, and this is a
/// document.
public enum NoteObject: Codable, Sendable, Hashable {
    case image(attachmentID: UUID, caption: NoteRichText)
    case file(attachmentID: UUID)
    /// A sanitized, self-contained HTML snapshot whose text remains selectable.
    case webClip(attachmentID: UUID)
    case table(NoteTable)

    /// A task, person, project or event — linked, never copied.
    case reference(itemID: UUID)

    /// Another note, opened in its own right.
    case page(noteID: UUID)

    case divider
}

/// One piece of a note.
public enum NotePiece: Codable, Sendable, Hashable {
    case prose(NoteParagraph)
    case object(NoteObject)

    public var paragraph: NoteParagraph? {
        if case .prose(let paragraph) = self { return paragraph }
        return nil
    }

    public var isProse: Bool { paragraph != nil }
}

/// A note's contents.
///
/// The stored form, and the thing every other part of the app reads: the outline, the export, the
/// search projection and wiki-link reconciliation all speak this. The editor converts it to an
/// `NSAttributedString` to work on and back again to save, and that conversion is the only place the
/// two representations meet.
public struct NoteDocument: Codable, Sendable, Hashable {
    /// The version of this *format*, which is not the store's schema version.
    ///
    /// Separate on purpose, per ADR 0006: a run list with its own version number can change without
    /// a store migration, and a store migration can happen without touching this. Bumping it is for
    /// a change this decoder could not otherwise survive.
    public static let currentVersion = 2

    public var version: Int
    public var pieces: [NotePiece]

    public init(version: Int = NoteDocument.currentVersion, pieces: [NotePiece] = []) {
        self.version = version
        self.pieces = pieces
    }

    /// A document with a single empty paragraph.
    ///
    /// Never genuinely empty: an editor with no paragraphs has nowhere to put the caret, so opening
    /// a new note would present a page that cannot be typed into.
    public static var empty: NoteDocument {
        NoteDocument(pieces: [.prose(NoteParagraph())])
    }

    public var paragraphs: [NoteParagraph] { pieces.compactMap(\.paragraph) }

    public var isEffectivelyEmpty: Bool {
        pieces.allSatisfy { $0.paragraph?.isEmpty ?? false }
    }

    // MARK: The outline

    /// The headings, with where they are, for the outline panel.
    public var headings: [(position: Int, level: Int, title: String)] {
        pieces.enumerated().compactMap { position, piece in
            guard let paragraph = piece.paragraph, let level = paragraph.kind.headingLevel else { return nil }
            let title = paragraph.plainText.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (position, level, title)
        }
    }

    /// Whether there is enough structure for an outline to be worth its width.
    public func hasUsefulOutline(minimumHeadings: Int = 2) -> Bool {
        headings.count >= minimumHeadings
    }

    // MARK: The projection

    /// What is written to `Item.body`.
    ///
    /// ### Why this is Markdown rather than bare text
    /// Because `Item.body` has three readers and they do not want the same thing. ADR 0006 keeps it
    /// as the projection precisely so those three keep working, and two of them need syntax: the
    /// Markdown export writes this, and **wiki-link reconciliation parses it**. A `.wiki` link lives
    /// as an attribute on a run, so if this emitted only the visible text the brackets would vanish,
    /// `WikiLinkParser` would find nothing, and every link in every note would be quietly unmade on
    /// the next save. That is the failure this property exists to prevent, and it has a test.
    ///
    /// The third reader is the search index, which gets a little syntax it did not ask for. That is
    /// the accepted cost and it is not new: `body` is Markdown today, typed by hand.
    public var projectedBody: String {
        var lines: [String] = []
        var numbering: [Int: Int] = [:]

        for piece in pieces {
            switch piece {
            case .prose(let paragraph):
                // Numbering is counted rather than stored, so deleting the first item renumbers the
                // rest — and it restarts at anything that is not a numbered item at that depth, so
                // two lists separated by a paragraph are two lists rather than one that resumes.
                if paragraph.kind == .numbered {
                    numbering[paragraph.indent, default: 0] += 1
                } else {
                    numbering.removeAll()
                }

                lines.append(contentsOf: Self.projected(paragraph, number: numbering[paragraph.indent] ?? 1))

            case .object(let object):
                numbering.removeAll()
                lines.append(contentsOf: Self.projected(object))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// The text with no syntax at all, for anything measuring or previewing rather than parsing.
    public var plainText: String {
        pieces.compactMap { $0.paragraph?.plainText }.joined(separator: "\n")
    }

    private static func projected(_ paragraph: NoteParagraph, number: Int) -> [String] {
        let text = markdown(for: paragraph.text)
        let padding = String(repeating: "  ", count: paragraph.indent)

        switch paragraph.kind {
        case .paragraph:
            return [text]
        case .heading1:
            return ["# " + text]
        case .heading2:
            return ["## " + text]
        case .heading3:
            return ["### " + text]
        case .quote, .callout:
            return ["> " + text]
        case .bulleted:
            return [padding + "- " + text]
        case .numbered:
            return [padding + "\(number). " + text]
        case .checklist:
            return [padding + (paragraph.isTicked ? "- [x] " : "- [ ] ") + text]
        case .code:
            // Fenced rather than indented, so the language survives the round trip through Markdown
            // and so a code block containing a blank line stays one block.
            return ["```" + (paragraph.language ?? ""), text, "```"]
        }
    }

    private static func projected(_ object: NoteObject) -> [String] {
        switch object {
        case .divider:
            return ["---"]
        case .image(_, let caption):
            // The caption and not the attachment's identifier. `body` is the *text* projection, and
            // a UUID in it would be a word the search index has to carry and nobody can search for.
            // Attachments are their own entity with their own place in the archive.
            let text = markdown(for: caption)
            return text.isEmpty ? [] : [text]
        case .file, .webClip, .reference, .page, .table:
            return []
        }
    }

    /// One paragraph's text, with the syntax its links need.
    private static func markdown(for text: NoteRichText) -> String {
        var result = ""

        for run in text.runs {
            let body = run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !body.isEmpty else { continue }

            switch run.link {
            case .wiki(let title):
                // Written back as it was typed. `[[Target|shown]]` when the run's text is not the
                // target's title, which is exactly the form `WikiLinkParser` reads.
                result += body == title ? "[[\(title)]]" : "[[\(title)|\(body)]]"
            case .url(let address):
                result += "[\(body)](\(address))"
            case .item, .none:
                // A deliberate link made through the inspector is a modelled relationship and is not
                // owned by the text, so it is not written into it. See `WikiLink`.
                result += body
            }
        }

        return result
    }
}
