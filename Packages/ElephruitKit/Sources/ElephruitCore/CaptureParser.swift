import Foundation

/// What a line of Quick Capture text means.
///
/// A value type with no side effects, so the capture field can show the user what it
/// understood *before* they commit, and so the whole grammar is unit-testable.
public struct CaptureDraft: Sendable, Hashable {
    public var kind: ItemKind
    public var title: String
    public var body: String

    /// Tag slugs, already normalised.
    public var tagSlugs: [String]

    /// The text after `>`, to be resolved against existing projects and areas. Left as
    /// text because resolution needs the store, and parsing must not.
    public var projectHint: String?

    /// The text after each `@`, to be resolved against existing people.
    public var personHints: [String]

    /// The date after `!`, unresolved.
    public var dueDate: DateExpression?

    /// A URL found in the text, which turns a capture into a bookmark.
    public var url: URL?

    public init(
        kind: ItemKind = .note,
        title: String = "",
        body: String = "",
        tagSlugs: [String] = [],
        projectHint: String? = nil,
        personHints: [String] = [],
        dueDate: DateExpression? = nil,
        url: URL? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.tagSlugs = tagSlugs
        self.projectHint = projectHint
        self.personHints = personHints
        self.dueDate = dueDate
        self.url = url
    }

    /// Whether there is anything worth saving.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Reads Quick Capture's inline grammar.
///
/// The grammar is four sigils, chosen to be typeable without modifiers changing hands
/// and unlikely to appear at the start of a word in ordinary prose:
///
/// | Sigil | Meaning | Example |
/// |---|---|---|
/// | `#` | tag | `#urgent`, `#work/clients` |
/// | `>` | project or area | `>Q3 Launch`, `>"Q3 Launch"` |
/// | `@` | person | `@Sarah` |
/// | `!` | due date | `!tomorrow`, `!+3d`, `!2026-08-14` |
///
/// A leading `- `, `[] `, or `[ ] ` makes the capture a task. A line that is only a URL
/// becomes a bookmark. Everything the parser does not claim stays in the title, so no
/// keystroke is ever silently eaten.
public enum CaptureParser {
    /// Parses one or more lines. The first line is the title; the remainder is the body.
    public static func parse(_ input: String) -> CaptureDraft {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let firstLine = lines.first.map(String.init) ?? ""
        let remainder = lines.dropFirst().joined(separator: "\n")

        var draft = parseFirstLine(firstLine)
        draft.body = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        // A body-only capture — the user pasted a paragraph — still deserves a title.
        if draft.title.isEmpty, !draft.body.isEmpty {
            draft.title = TextNormalizer.inferredTitle(fromBody: draft.body)
        }

        return draft
    }

    private static func parseFirstLine(_ line: String) -> CaptureDraft {
        var draft = CaptureDraft()
        var remaining = Substring(line)

        // Task prefixes.
        for prefix in ["- [ ] ", "- [x] ", "[] ", "[ ] ", "- ", "* "] where remaining.hasPrefix(prefix) {
            remaining = remaining.dropFirst(prefix.count)
            draft.kind = .task
            break
        }

        var titleWords: [String] = []

        for token in tokenize(remaining) {
            switch token {
            case .word(let word):
                if draft.url == nil, let url = bookmarkURL(from: word) {
                    draft.url = url
                    draft.kind = .bookmark
                    // The URL stays in the title only if there is nothing else to show.
                    titleWords.append(word)
                } else {
                    titleWords.append(word)
                }

            case .tag(let text):
                let slug = TextNormalizer.slug(text)
                if TextNormalizer.isValidSlug(slug) {
                    if !draft.tagSlugs.contains(slug) { draft.tagSlugs.append(slug) }
                } else {
                    titleWords.append("#" + text)  // Not a usable tag; keep the text.
                }

            case .project(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    titleWords.append(">")
                } else if draft.projectHint == nil {
                    draft.projectHint = trimmed
                } else {
                    titleWords.append(">" + trimmed)
                }

            case .person(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    titleWords.append("@")
                } else {
                    draft.personHints.append(trimmed)
                }

            case .date(let text):
                if let expression = NaturalDateParser.parse(text) {
                    draft.dueDate = expression
                    // A due date implies intent to act.
                    if draft.kind == .note { draft.kind = .task }
                } else {
                    titleWords.append("!" + text)
                }
            }
        }

        // A capture that is nothing but a URL reads better titled by its host.
        if draft.kind == .bookmark, titleWords.count == 1, let url = draft.url {
            draft.title = url.host() ?? url.absoluteString
        } else {
            draft.title = titleWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        return draft
    }

    // MARK: - Tokenizing

    private enum Token {
        case word(String)
        case tag(String)
        case project(String)
        case person(String)
        case date(String)
    }

    /// Splits on whitespace, except that a sigil followed by a double-quoted string
    /// consumes the whole quoted phrase — `>"Q3 Launch"`.
    private static func tokenize(_ input: Substring) -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex

        while index < input.endIndex {
            // Skip whitespace between tokens.
            guard !input[index].isWhitespace else {
                index = input.index(after: index)
                continue
            }

            let sigil = input[index]
            let isSigil = sigil == "#" || sigil == ">" || sigil == "@" || sigil == "!"

            if isSigil {
                let afterSigil = input.index(after: index)
                let (value, next) = readValue(in: input, from: afterSigil)
                index = next

                switch sigil {
                case "#": tokens.append(.tag(value))
                case ">": tokens.append(.project(value))
                case "@": tokens.append(.person(value))
                default: tokens.append(.date(value))
                }
            } else {
                let (word, next) = readPlainWord(in: input, from: index)
                index = next
                if !word.isEmpty { tokens.append(.word(word)) }
            }
        }

        return tokens
    }

    /// Reads a sigil's value: either a quoted phrase or a run of non-whitespace.
    private static func readValue(in input: Substring, from start: Substring.Index) -> (String, Substring.Index) {
        guard start < input.endIndex else { return ("", start) }

        if input[start] == "\"" {
            let contentStart = input.index(after: start)
            if let closing = input[contentStart...].firstIndex(of: "\"") {
                return (String(input[contentStart..<closing]), input.index(after: closing))
            }
            // Unterminated quote: take the rest of the line rather than dropping it.
            return (String(input[contentStart...]), input.endIndex)
        }

        return readPlainWord(in: input, from: start)
    }

    private static func readPlainWord(in input: Substring, from start: Substring.Index) -> (String, Substring.Index) {
        var end = start
        while end < input.endIndex, !input[end].isWhitespace {
            end = input.index(after: end)
        }
        return (String(input[start..<end]), end)
    }

    // MARK: - URLs

    /// A URL only if it is unambiguously one. `http`/`https` schemes, or a bare
    /// `host.tld/path`. Never guesses at things containing spaces.
    private static func bookmarkURL(from word: String) -> URL? {
        let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,.;"))
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }

        if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
            return URL(string: candidate)
        }

        // `example.com/x` — require a dot with letters either side and no scheme-like colon.
        guard !candidate.contains(":"),
              let dotIndex = candidate.firstIndex(of: "."),
              dotIndex > candidate.startIndex,
              candidate.index(after: dotIndex) < candidate.endIndex,
              candidate[candidate.index(before: dotIndex)].isLetter || candidate[candidate.index(before: dotIndex)].isNumber,
              candidate[candidate.index(after: dotIndex)].isLetter
        else { return nil }

        return URL(string: "https://" + candidate)
    }

    /// The grammar, for the capture panel's help row.
    public static let grammarHints: [(sigil: String, meaning: String, example: String)] = [
        ("#", "Tag", "#urgent"),
        (">", "Project", ">Q3 Launch"),
        ("@", "Person", "@Sarah"),
        ("!", "Due date", "!tomorrow"),
    ]
}
