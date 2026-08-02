import Foundation

// MARK: - Markdown shortcuts

/// What typing Markdown syntax at the start of a paragraph turns into.
///
/// Recognised only at a paragraph's start, so "1. " inside a sentence about version numbers stays
/// prose. This is the insertion route for someone who already knows what they want and does not
/// intend to lift their hands; the `/` menu and the Format menu serve the other two people.
public enum NoteMarkdownShortcut: Hashable, Sendable {
    /// The paragraph becomes this kind, with the syntax consumed.
    case paragraph(kind: NoteParagraphKind, ticked: Bool)

    /// The typed `---` becomes a divider object.
    case divider

    /// The prefix the shortcut consumes, in Characters, including its trailing space.
    ///
    /// Stored with the match rather than recomputed, because "how much to delete" and "what it
    /// meant" must be one answer: a second parse deciding differently is how a shortcut eats a
    /// letter of the sentence after it.
    public struct Match: Hashable, Sendable {
        public let shortcut: NoteMarkdownShortcut
        public let consumedLength: Int

        public init(shortcut: NoteMarkdownShortcut, consumedLength: Int) {
            self.shortcut = shortcut
            self.consumedLength = consumedLength
        }
    }

    /// The shortcut a paragraph-leading string spells, if any.
    ///
    /// `text` is everything from the paragraph's start up to and including what was just typed.
    /// The caller decides *when* to ask — on typing a space, which is how every one of these ends,
    /// except the code fence and the divider, which are complete the moment their last character
    /// lands.
    public static func match(_ text: String) -> Match? {
        // Longest spellings first, so "- [ ] " is a checklist and never a bulleted list whose text
        // begins with brackets.
        let fixed: [(prefix: String, shortcut: NoteMarkdownShortcut)] = [
            ("- [x] ", .paragraph(kind: .checklist, ticked: true)),
            ("- [ ] ", .paragraph(kind: .checklist, ticked: false)),
            ("### ", .paragraph(kind: .heading3, ticked: false)),
            ("## ", .paragraph(kind: .heading2, ticked: false)),
            ("# ", .paragraph(kind: .heading1, ticked: false)),
            ("> ", .paragraph(kind: .quote, ticked: false)),
            ("- ", .paragraph(kind: .bulleted, ticked: false)),
            ("* ", .paragraph(kind: .bulleted, ticked: false)),
        ]

        for candidate in fixed where text == candidate.prefix {
            return Match(shortcut: candidate.shortcut, consumedLength: candidate.prefix.count)
        }

        if text == "```" {
            return Match(shortcut: .paragraph(kind: .code, ticked: false), consumedLength: 3)
        }

        if text == "---" {
            return Match(shortcut: .divider, consumedLength: 3)
        }

        // Any run of digits followed by ". " — "1. ", "42. " — starts a numbered list.
        if text.hasSuffix(". "), text.count >= 3 {
            let digits = text.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return Match(shortcut: .paragraph(kind: .numbered, ticked: false), consumedLength: text.count)
            }
        }

        return nil
    }
}

// MARK: - The / menu

/// One thing the `/` menu can insert.
///
/// A closed set mirroring what a note can hold: every paragraph kind, and every kind of object.
/// The menu's rows are identified by *this value* and never by their position in the filtered
/// list — the first build identified rows by index and the menu rendered the wrong block for the
/// right match. See "Traps already paid for" in the spec.
public enum NoteInsertionCommand: Hashable, Sendable, CaseIterable {
    case paragraph(NoteParagraphKind)
    case divider
    case table
    case image
    case file
    case reference
    case page

    public static var allCases: [NoteInsertionCommand] {
        NoteParagraphKind.allCases.map { .paragraph($0) }
            + [.image, .file, .table, .reference, .page, .divider]
    }

    public var displayName: String {
        switch self {
        case .paragraph(let kind): kind.displayName
        case .divider: "Divider"
        case .table: "Table"
        case .image: "Image"
        case .file: "File"
        case .reference: "Link to Item"
        case .page: "Page"
        }
    }

    public var symbolName: String {
        switch self {
        case .paragraph(let kind): kind.symbolName
        case .divider: "minus"
        case .table: "tablecells"
        case .image: "photo"
        case .file: "paperclip"
        case .reference: "link"
        case .page: "doc"
        }
    }

    /// What this inserts, for the menu's second line — and for its search.
    public var hint: String {
        switch self {
        case .paragraph(let kind): kind.hint
        case .divider: "A horizontal rule between sections."
        case .table: "Rows and columns."
        case .image: "A picture, stored with the note."
        case .file: "Any attachment, kept as a file."
        case .reference: "A task, person, project or event — linked, never copied."
        case .page: "A nested note, opened in its own right."
        }
    }

    /// Which group the menu shows this under.
    public var group: NoteInsertionGroup {
        switch self {
        case .paragraph(let kind):
            switch kind {
            case .paragraph, .heading1, .heading2, .heading3: .text
            case .bulleted, .numbered, .checklist: .list
            case .quote, .code, .callout: .block
            }
        case .image, .file: .media
        case .table, .reference, .page, .divider: .structure
        }
    }
}

/// The `/` menu's section headers, in display order.
public enum NoteInsertionGroup: String, CaseIterable, Sendable {
    case text = "Text"
    case list = "Lists"
    case block = "Blocks"
    case media = "Media"
    case structure = "Structure"
}

extension NoteInsertionCommand {
    /// The commands a query matches, in menu order.
    ///
    /// A pure function with its own tests, kept apart from the view on purpose: "does searching
    /// for `code` find the code block" must have an answer that does not require a window.
    ///
    /// Matches against the name *and* the hint, so the menu answers for what a piece does as well
    /// as what it is called — "tick" finds the checklist. Word-prefix, not substring: "age" should
    /// not surface Page and Image ahead of anything, and a hint is a sentence, most of whose
    /// interiors are noise.
    public static func matching(_ query: String) -> [NoteInsertionCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allCases }

        return allCases.filter { command in
            let searchable = command.displayName + " " + command.hint
            let words = searchable.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.contains { $0.hasPrefix(trimmed) }
        }
    }
}
