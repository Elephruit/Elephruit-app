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

    /// The date after `!` or `due:`, unresolved. A deadline: it can become overdue.
    public var dueDate: DateExpression?

    /// The time of day given alongside ``dueDate``, as in `due:tomorrow 3pm`.
    public var dueTime: TimeOfDay?

    /// The date after `follow:`. A **start** date, not a deadline.
    ///
    /// It brings the item into Today on that day and never becomes overdue afterwards — the
    /// distinction the whole token exists for. Stored as `Item.deferUntil`.
    public var followDate: DateExpression?

    /// The priority after `!high`, `!medium` or `!low`. `nil` means none was given, which is not
    /// the same as `.normal` — the user said nothing rather than saying "normal".
    public var priority: Priority?

    /// A URL found in the text, which turns a capture into a bookmark.
    public var url: URL?

    /// What the user actually typed, verbatim.
    ///
    /// The title is rebuilt from the words the parser did not claim, which normalises runs of
    /// whitespace, so it is not the input. Anything that needs to show the user their own text back,
    /// or to re-parse it after an edit, needs this.
    public var originalText: String = ""

    /// Every token the parser recognised, with where it was.
    ///
    /// Ranges are character offsets into ``originalText``, so a field can underline what it
    /// understood without re-running the parser or guessing at positions.
    public var tokens: [CaptureToken] = []

    /// Sigil tokens that were *not* understood, kept so they can be pointed at.
    ///
    /// Their text is also still in the title — nothing is ever removed on the strength of not being
    /// recognised — so this is for explaining, never for recovering.
    public var unresolvedTokens: [CaptureToken] = []

    public init(
        kind: ItemKind = .note,
        title: String = "",
        body: String = "",
        tagSlugs: [String] = [],
        projectHint: String? = nil,
        personHints: [String] = [],
        dueDate: DateExpression? = nil,
        dueTime: TimeOfDay? = nil,
        followDate: DateExpression? = nil,
        priority: Priority? = nil,
        url: URL? = nil,
        originalText: String = "",
        tokens: [CaptureToken] = [],
        unresolvedTokens: [CaptureToken] = []
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.tagSlugs = tagSlugs
        self.projectHint = projectHint
        self.personHints = personHints
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.followDate = followDate
        self.priority = priority
        self.url = url
        self.originalText = originalText
        self.tokens = tokens
        self.unresolvedTokens = unresolvedTokens
    }

    /// The due date and its time together, when there is one.
    public var dueInterpretation: DateInterpretation? {
        dueDate.map { DateInterpretation(day: $0, time: dueTime) }
    }

    /// Whether there is anything worth saving.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One thing the parser found, and where.
public struct CaptureToken: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case tag
        case person
        case project
        case dueDate
        case followDate
        case priority
        /// A sigil or keyword that looked like syntax and was not understood.
        case unrecognised
    }

    public var kind: Kind

    /// The value, without its sigil or keyword.
    public var text: String

    /// Character offsets into ``CaptureDraft/originalText``, covering the whole token including
    /// its sigil — what a field would underline.
    public var range: Range<Int>

    public init(kind: Kind, text: String, range: Range<Int>) {
        self.kind = kind
        self.text = text
        self.range = range
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
        draft.originalText = input
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
        var base = 0

        // Task prefixes.
        for prefix in ["- [ ] ", "- [x] ", "[] ", "[ ] ", "- ", "* "] where remaining.hasPrefix(prefix) {
            remaining = remaining.dropFirst(prefix.count)
            base = prefix.count
            draft.kind = .task
            break
        }

        var titleWords: [String] = []
        let raw = tokenize(remaining, base: base)
        var index = 0

        while index < raw.count {
            let token = raw[index]
            index += 1

            switch token.kind {
            case .word:
                if draft.url == nil, let url = bookmarkURL(from: token.value) {
                    draft.url = url
                    draft.kind = .bookmark
                }
                titleWords.append(token.value)

            case .tag:
                let slug = TextNormalizer.slug(token.value)
                if TextNormalizer.isValidSlug(slug) {
                    if !draft.tagSlugs.contains(slug) { draft.tagSlugs.append(slug) }
                    draft.tokens.append(CaptureToken(kind: .tag, text: slug, range: token.range))
                } else {
                    titleWords.append("#" + token.value)  // Not a usable tag; keep the text.
                    draft.unresolvedTokens.append(
                        CaptureToken(kind: .unrecognised, text: token.value, range: token.range)
                    )
                }

            case .project:
                let trimmed = token.value.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    titleWords.append(">")
                } else if draft.projectHint == nil {
                    draft.projectHint = trimmed
                    draft.tokens.append(CaptureToken(kind: .project, text: trimmed, range: token.range))
                } else {
                    titleWords.append(">" + trimmed)
                    draft.unresolvedTokens.append(
                        CaptureToken(kind: .unrecognised, text: trimmed, range: token.range)
                    )
                }

            case .person:
                let trimmed = token.value.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    titleWords.append("@")
                } else {
                    draft.personHints.append(trimmed)
                    draft.tokens.append(CaptureToken(kind: .person, text: trimmed, range: token.range))
                }

            case .bang:
                // `!high` and friends first: a priority is not a date, and `!` carries both.
                if let priority = priorityValue(token.value) {
                    draft.priority = priority
                    draft.tokens.append(
                        CaptureToken(kind: .priority, text: priority.rawValue, range: token.range)
                    )
                } else {
                    index = applyDate(
                        role: .due, token: token, raw: raw, from: index,
                        draft: &draft, titleWords: &titleWords
                    )
                }

            case .due:
                index = applyDate(
                    role: .due, token: token, raw: raw, from: index,
                    draft: &draft, titleWords: &titleWords
                )

            case .follow:
                index = applyDate(
                    role: .follow, token: token, raw: raw, from: index,
                    draft: &draft, titleWords: &titleWords
                )
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

    private enum DateRole { case due, follow }

    /// Reads a date value, extending it over following words while the longer phrase still parses.
    ///
    /// `due:tomorrow 3pm` and `due:next Tuesday` are two words the tokenizer has already split, and
    /// requiring quotes for them would be a grammar that only its author can use. Extension is
    /// greedy but bounded and never speculative: a word is consumed only if the phrase including it
    /// parses, so `due:friday meeting` keeps "meeting" in the title.
    ///
    /// Returns the index to continue from.
    private static func applyDate(
        role: DateRole,
        token: RawToken,
        raw: [RawToken],
        from index: Int,
        draft: inout CaptureDraft,
        titleWords: inout [String]
    ) -> Int {
        var phrase = token.value
        var next = index
        var best: DateInterpretation? = NaturalDateParser.interpret(phrase)
        var bestEnd = token.range.upperBound
        var bestNext = index

        var lookahead = 0
        while next < raw.count, raw[next].kind == .word, lookahead < 2 {
            phrase += " " + raw[next].value
            lookahead += 1
            if let extended = NaturalDateParser.interpret(phrase) {
                best = extended
                bestEnd = raw[next].range.upperBound
                bestNext = next + 1
            }
            next += 1
        }

        guard let interpretation = best else {
            // Not a date. The text stays exactly as typed.
            titleWords.append(token.literal)
            draft.unresolvedTokens.append(
                CaptureToken(kind: .unrecognised, text: token.value, range: token.range)
            )
            return index
        }

        let range = token.range.lowerBound..<bestEnd
        switch role {
        case .due:
            draft.dueDate = interpretation.day
            draft.dueTime = interpretation.time
            draft.tokens.append(CaptureToken(kind: .dueDate, text: interpretation.summary, range: range))
            // A deadline implies intent to act.
            if draft.kind == .note { draft.kind = .task }

        case .follow:
            draft.followDate = interpretation.day
            draft.tokens.append(CaptureToken(kind: .followDate, text: interpretation.summary, range: range))
            if draft.kind == .note { draft.kind = .task }
        }

        return bestNext
    }

    private static func priorityValue(_ text: String) -> Priority? {
        switch text.lowercased() {
        case "high": .high
        case "medium", "med", "normal": .normal
        case "low": .low
        default: nil
        }
    }

    // MARK: - Tokenizing

    private struct RawToken {
        enum Kind { case word, tag, project, person, bang, due, follow }
        var kind: Kind
        /// The value, without sigil or keyword.
        var value: String
        /// What was typed, sigil and all — what goes back in the title if it is not understood.
        var literal: String
        /// Character offsets into the original input.
        var range: Range<Int>
    }

    /// The keyword tokens, which unlike the sigils are words followed by a colon.
    private static let keywords: [(prefix: String, kind: RawToken.Kind)] = [
        ("follow:", .follow),
        ("due:", .due),
    ]

    /// Splits on whitespace, except that a sigil or keyword followed by a double-quoted string
    /// consumes the whole quoted phrase — `>"Q3 Launch"`, `due:"next Tuesday"`.
    ///
    /// `base` is where `input` starts within the text the user typed, so the offsets recorded on
    /// each token point into that rather than into the substring left after a task prefix.
    private static func tokenize(_ input: Substring, base: Int) -> [RawToken] {
        var tokens: [RawToken] = []
        var index = input.startIndex
        var offset = base

        while index < input.endIndex {
            // Skip whitespace between tokens.
            guard !input[index].isWhitespace else {
                index = input.index(after: index)
                offset += 1
                continue
            }

            let start = offset
            let sigil = input[index]
            let isSigil = sigil == "#" || sigil == ">" || sigil == "@" || sigil == "!"

            if isSigil {
                let afterSigil = input.index(after: index)
                let (value, next) = readValue(in: input, from: afterSigil)
                offset += 1 + input.distance(from: afterSigil, to: next)
                index = next

                let kind: RawToken.Kind = switch sigil {
                case "#": .tag
                case ">": .project
                case "@": .person
                default: .bang
                }
                tokens.append(
                    RawToken(kind: kind, value: value, literal: String(sigil) + value, range: start..<offset)
                )
                continue
            }

            let (word, afterWord) = readPlainWord(in: input, from: index)

            if let keyword = keywords.first(where: { word.lowercased().hasPrefix($0.prefix) }) {
                let valueStart = input.index(index, offsetBy: keyword.prefix.count)
                let (value, next) = readValue(in: input, from: valueStart)
                offset += keyword.prefix.count + input.distance(from: valueStart, to: next)
                index = next
                tokens.append(
                    RawToken(
                        kind: keyword.kind,
                        value: value,
                        literal: keyword.prefix + value,
                        range: start..<offset
                    )
                )
                continue
            }

            offset += input.distance(from: index, to: afterWord)
            index = afterWord
            if !word.isEmpty {
                tokens.append(RawToken(kind: .word, value: word, literal: word, range: start..<offset))
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
        ("due:", "Deadline", "due:friday"),
        ("follow:", "Come back to it", "follow:next Tuesday"),
        ("!", "Priority", "!high"),
    ]
}
