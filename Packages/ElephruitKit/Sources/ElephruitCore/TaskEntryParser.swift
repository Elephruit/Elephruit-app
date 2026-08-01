import Foundation

/// One thing the task parser recognised, and where it was.
public struct TaskEntryToken: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case startDate
        case deadline
        case reminder
        case repeatRule
        case destination
        case tag
        case person
        case waiting
        case someday
        case flag
        case priority

        /// Something that looked like syntax and was not understood, or is understood and cannot be
        /// honoured. Both are shown; neither changes the text.
        case unsupported

        public var displayName: String {
            switch self {
            case .startDate: "Start"
            case .deadline: "Deadline"
            case .reminder: "Reminder"
            case .repeatRule: "Repeat"
            case .destination: "List"
            case .tag: "Tag"
            case .person: "Person"
            case .waiting: "Waiting for"
            case .someday: "Someday"
            case .flag: "Flag"
            case .priority: "Priority"
            case .unsupported: "Not understood"
            }
        }

        public var symbolName: String {
            switch self {
            case .startDate: "play.circle"
            case .deadline: "flag.pattern.checkered"
            case .reminder: "bell"
            case .repeatRule: "repeat"
            case .destination: "folder"
            case .tag: "number"
            case .person: "person"
            case .waiting: "hourglass"
            case .someday: "archivebox"
            case .flag: "flag"
            case .priority: "exclamationmark"
            case .unsupported: "questionmark.circle"
            }
        }
    }

    public var kind: Kind
    /// What the token means, in words — "Tomorrow at 10:00", "Every Friday".
    public var display: String
    /// Character offsets into the raw text, covering the whole phrase.
    public var range: Range<Int>
    /// Why this could not be honoured, for ``Kind/unsupported``.
    public var explanation: String?

    public var id: String { "\(kind.rawValue)-\(range.lowerBound)-\(range.upperBound)" }

    public init(kind: Kind, display: String, range: Range<Int>, explanation: String? = nil) {
        self.kind = kind
        self.display = display
        self.range = range
        self.explanation = explanation
    }
}

/// What a line of task entry means.
///
/// ### The raw text is never rewritten
/// ``rawText`` is exactly what the user typed, byte for byte, and the parser never edits the field
/// it read from. Everything else here is *interpretation*: a separate value, recomputed on every
/// keystroke, that a preview can draw beside the field. That separation is the whole design. A field
/// that rewrites itself as you type destroys marked text, undo, dictation, and the insertion point,
/// and there is no way to have it and also have a text field that behaves like a text field.
public struct TaskEntryDraft: Sendable, Hashable {
    public var rawText: String

    /// What is left after the recognised syntax is taken out. Never empty when the input was not.
    public var title: String

    /// Lines after the first.
    public var notes: String

    public var startDate: DateInterpretation?
    public var deadline: DateInterpretation?
    public var reminder: DateInterpretation?
    public var recurrence: RecurrenceRule?

    public var isSomeday: Bool
    public var isFlagged: Bool
    public var priority: Priority?

    public var tagSlugs: [String]

    /// A destination named by `>Name` or by a `/Area/Project` path, left as text because resolving
    /// it needs the store and parsing must not.
    public var destinationPath: [String]

    public var personHints: [String]

    /// Who the task is waiting on, when the text said so.
    public var waitingForHint: String?

    public var tokens: [TaskEntryToken]

    public init(
        rawText: String = "",
        title: String = "",
        notes: String = "",
        startDate: DateInterpretation? = nil,
        deadline: DateInterpretation? = nil,
        reminder: DateInterpretation? = nil,
        recurrence: RecurrenceRule? = nil,
        isSomeday: Bool = false,
        isFlagged: Bool = false,
        priority: Priority? = nil,
        tagSlugs: [String] = [],
        destinationPath: [String] = [],
        personHints: [String] = [],
        waitingForHint: String? = nil,
        tokens: [TaskEntryToken] = []
    ) {
        self.rawText = rawText
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.deadline = deadline
        self.reminder = reminder
        self.recurrence = recurrence
        self.isSomeday = isSomeday
        self.isFlagged = isFlagged
        self.priority = priority
        self.tagSlugs = tagSlugs
        self.destinationPath = destinationPath
        self.personHints = personHints
        self.waitingForHint = waitingForHint
        self.tokens = tokens
    }

    /// Whether there is anything worth creating.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tokens the parser could not honour, for the preview's amber line.
    public var unsupportedTokens: [TaskEntryToken] {
        tokens.filter { $0.kind == .unsupported }
    }
}

/// Reads a line of task entry into an interpretation.
///
/// ### Two grammars, deliberately
/// **Sigils** — `#tag`, `>project`, `/area/project`, `@person`, `!high` — are precise, fast to type,
/// and unambiguous. **Phrases** — "tomorrow at 10", "by August 15", "every Friday", "waiting for
/// Jordan" — are what people write when they are not thinking about syntax. Supporting only the
/// first makes the field a command line; supporting only the second makes it guess. Both are here,
/// and everything the parser does not claim stays in the title exactly as typed.
///
/// ### What a bare date means, and why
/// A bare date phrase sets the **start date**: "next Monday" is when a task becomes worth thinking
/// about, not a commitment to finish by then. Turning it into a deadline would manufacture pressure
/// the user never asked for, which is the single most common way a task manager makes somebody feel
/// behind. A deadline needs a word that means one — `by`, `deadline`, `due`.
///
/// A time of day is different. `tomorrow at 10` names an instant, and the only thing an instant can
/// mean is an interruption, so it sets a reminder *as well as* the start date. That is not a
/// reminder created merely because a date exists — it is one created because the user typed a
/// clock time — and the preview shows both before anything is saved.
public enum TaskEntryParser {
    // MARK: - Entry point

    public static func parse(_ input: String) -> TaskEntryDraft {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let firstLine = lines.first.map(String.init) ?? ""

        var draft = parseFirstLine(firstLine)
        draft.rawText = input
        draft.notes = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if draft.title.isEmpty, !draft.notes.isEmpty {
            draft.title = TextNormalizer.inferredTitle(fromBody: draft.notes)
        }

        return draft
    }

    // MARK: - Words

    private struct Word {
        var text: String
        var lower: String
        var range: Range<Int>
    }

    /// Splits on whitespace, keeping each word's character offsets into the original line.
    ///
    /// Offsets rather than string indices so a token can be handed to a view that underlines a
    /// range, without that view holding a reference to the string the parser read.
    private static func words(in line: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        var start = 0

        for (offset, character) in line.enumerated() {
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(Word(text: current, lower: current.lowercased(), range: start..<offset))
                    current = ""
                }
                start = offset + 1
            } else {
                if current.isEmpty { start = offset }
                current.append(character)
            }
        }
        if !current.isEmpty {
            result.append(Word(text: current, lower: current.lowercased(), range: start..<line.count))
        }
        return result
    }

    // MARK: - The scan

    private static func parseFirstLine(_ line: String) -> TaskEntryDraft {
        var draft = TaskEntryDraft()
        let all = words(in: line)
        var titleWords: [String] = []
        var index = 0

        while index < all.count {
            let word = all[index]

            if let consumed = matchSigil(word, into: &draft, titleWords: &titleWords) {
                index += consumed
                continue
            }
            if let consumed = matchKeyword(all, at: index, into: &draft, titleWords: &titleWords) {
                index += consumed
                continue
            }
            if let consumed = matchPhrase(all, at: index, into: &draft, titleWords: &titleWords) {
                index += consumed
                continue
            }

            titleWords.append(word.text)
            index += 1
        }

        draft.title = titleWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        draft.tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        return draft
    }

    // MARK: - Sigils

    /// `#tag`, `@person`, `>destination`, `/segment`, `!priority`, `!!` for a flag.
    ///
    /// Returns how many words were consumed, or `nil` if this is not a sigil.
    private static func matchSigil(
        _ word: Word,
        into draft: inout TaskEntryDraft,
        titleWords: inout [String]
    ) -> Int? {
        guard let sigil = word.text.first else { return nil }
        let value = String(word.text.dropFirst())

        switch sigil {
        case "#":
            let slug = TextNormalizer.slug(value)
            guard TextNormalizer.isValidSlug(slug) else {
                // Not a usable tag. The text is kept exactly as typed and the token says why.
                titleWords.append(word.text)
                draft.tokens.append(
                    TaskEntryToken(
                        kind: .unsupported,
                        display: word.text,
                        range: word.range,
                        explanation: "That is not a tag name."
                    )
                )
                return 1
            }
            if !draft.tagSlugs.contains(slug) { draft.tagSlugs.append(slug) }
            draft.tokens.append(TaskEntryToken(kind: .tag, display: "#" + slug, range: word.range))
            return 1

        case "@":
            guard !value.isEmpty else { return nil }
            draft.personHints.append(value)
            draft.tokens.append(TaskEntryToken(kind: .person, display: value, range: word.range))
            return 1

        case ">":
            guard !value.isEmpty else { return nil }
            draft.destinationPath = [value]
            draft.tokens.append(TaskEntryToken(kind: .destination, display: value, range: word.range))
            return 1

        case "/":
            // `/Work /Acme` — a path, one segment per word, in the order written. A leading slash is
            // unambiguous at the start of a word and cannot collide with prose or with a URL, which
            // always carries a scheme or a dot before its first slash.
            guard !value.isEmpty, !value.contains("/") else { return nil }
            draft.destinationPath.append(value)
            draft.tokens.append(
                TaskEntryToken(
                    kind: .destination,
                    display: draft.destinationPath.joined(separator: " ▸ "),
                    range: word.range
                )
            )
            return 1

        case "!":
            if word.text == "!!" || word.lower == "!flag" {
                draft.isFlagged = true
                draft.tokens.append(TaskEntryToken(kind: .flag, display: "Flagged", range: word.range))
                return 1
            }
            guard let priority = priorityValue(value) else { return nil }
            draft.priority = priority
            draft.tokens.append(
                TaskEntryToken(kind: .priority, display: priority.displayName, range: word.range)
            )
            return 1

        default:
            return nil
        }
    }

    private static func priorityValue(_ text: String) -> Priority? {
        switch text.lowercased() {
        case "high", "h": .high
        case "medium", "med", "normal", "m": .normal
        case "low", "l": .low
        default: nil
        }
    }

    // MARK: - Keywords

    private static let dateKeywords: [(prefix: String, role: DateRole)] = [
        ("deadline:", .deadline),
        ("due:", .deadline),
        ("by:", .deadline),
        ("start:", .start),
        ("starts:", .start),
        ("on:", .start),
        ("defer:", .start),
        ("follow:", .start),
        ("remind:", .reminder),
        ("at:", .reminder),
    ]

    private enum DateRole { case start, deadline, reminder }

    /// `deadline:friday`, `start:"next Tuesday"`, `remind:tomorrow 9am`, `every:friday`,
    /// `waiting:Jordan`.
    private static func matchKeyword(
        _ all: [Word],
        at index: Int,
        into draft: inout TaskEntryDraft,
        titleWords: inout [String]
    ) -> Int? {
        let word = all[index]

        if let keyword = dateKeywords.first(where: { word.lower.hasPrefix($0.prefix) }) {
            let value = String(word.text.dropFirst(keyword.prefix.count))
            return claimDate(
                role: keyword.role,
                startingWith: value,
                all: all,
                at: index,
                into: &draft,
                titleWords: &titleWords
            )
        }

        if word.lower.hasPrefix("waiting:") {
            let name = String(word.text.dropFirst("waiting:".count))
            guard !name.isEmpty else { return nil }
            draft.waitingForHint = name
            draft.tokens.append(TaskEntryToken(kind: .waiting, display: name, range: word.range))
            return 1
        }

        if word.lower.hasPrefix("every:") {
            let value = String(word.text.dropFirst("every:".count))
            return claimRecurrence(startingWith: value, all: all, at: index, into: &draft, titleWords: &titleWords)
        }

        return nil
    }

    // MARK: - Phrases

    /// The words that introduce a phrase, and everything else the scanner recognises without one.
    private static func matchPhrase(
        _ all: [Word],
        at index: Int,
        into draft: inout TaskEntryDraft,
        titleWords: inout [String]
    ) -> Int? {
        let word = all[index]

        // "someday" — a marker, and the word reads as noise in the title once it has been honoured.
        if word.lower == "someday" {
            draft.isSomeday = true
            draft.tokens.append(TaskEntryToken(kind: .someday, display: "Someday", range: word.range))
            return 1
        }

        // "waiting for Jordan", "waiting on Jordan".
        if word.lower == "waiting", index + 2 < all.count,
           all[index + 1].lower == "for" || all[index + 1].lower == "on" {
            let name = all[index + 2].text
            draft.waitingForHint = name
            draft.tokens.append(
                TaskEntryToken(
                    kind: .waiting,
                    display: name,
                    range: word.range.lowerBound..<all[index + 2].range.upperBound
                )
            )
            // The phrase stays in the title. "Waiting for Jordan to approve the budget" is how the
            // task should read in a list; stripping it would leave "to approve the budget", which is
            // a fragment. Sigils and dates are removed because their meaning moves into a chip;
            // this one's meaning is the sentence.
            titleWords.append(contentsOf: [word.text, all[index + 1].text, all[index + 2].text])
            return 3
        }

        // "every Friday", "every 2 weeks", "every day after completion".
        if word.lower == "every", index + 1 < all.count {
            return claimRecurrence(
                startingWith: all[index + 1].text,
                all: all,
                at: index,
                into: &draft,
                titleWords: &titleWords,
                valueOffset: 1
            )
        }
        if let rule = singleWordRecurrence(word.lower) {
            draft.recurrence = rule
            draft.tokens.append(TaskEntryToken(kind: .repeatRule, display: rule.summary, range: word.range))
            return 1
        }

        // "by August 15", "deadline September 1", "due Friday".
        if ["by", "deadline", "due"].contains(word.lower), index + 1 < all.count {
            if let consumed = claimDate(
                role: .deadline,
                startingWith: all[index + 1].text,
                all: all,
                at: index,
                into: &draft,
                titleWords: &titleWords,
                valueOffset: 1,
                silentOnFailure: true
            ) { return consumed }
        }

        // "starting Monday", "starts next week", "from Friday".
        if ["starting", "starts", "start", "from"].contains(word.lower), index + 1 < all.count {
            if let consumed = claimDate(
                role: .start,
                startingWith: all[index + 1].text,
                all: all,
                at: index,
                into: &draft,
                titleWords: &titleWords,
                valueOffset: 1,
                silentOnFailure: true
            ) { return consumed }
        }

        // "remind me tomorrow at 9", "remind me at 3pm".
        if word.lower == "remind", index + 1 < all.count {
            var offset = 1
            if all[index + 1].lower == "me" { offset = 2 }
            guard index + offset < all.count else { return nil }

            // "remind me when I get home" — a location reminder. Recognised so it can be *declined*
            // out loud: EventKit's location alarms are not something this app can create, and
            // silently dropping the phrase would leave the user believing they had one.
            if all[index + offset].lower == "when" {
                let end = all[min(index + offset + 4, all.count - 1)].range.upperBound
                draft.tokens.append(
                    TaskEntryToken(
                        kind: .unsupported,
                        display: "Location reminder",
                        range: word.range.lowerBound..<end,
                        explanation: "Reminders tied to a place are not supported. The words are kept in the title."
                    )
                )
                titleWords.append(word.text)
                return 1
            }

            if let consumed = claimDate(
                role: .reminder,
                startingWith: all[index + offset].text,
                all: all,
                at: index,
                into: &draft,
                titleWords: &titleWords,
                valueOffset: offset,
                silentOnFailure: true
            ) { return consumed }
        }

        // A bare date phrase — "tomorrow", "next Monday", "in two weeks", "August 15".
        return claimDate(
            role: .start,
            startingWith: word.text,
            all: all,
            at: index,
            into: &draft,
            titleWords: &titleWords,
            valueOffset: 0,
            silentOnFailure: true
        )
    }

    // MARK: - Claiming a date

    /// Reads a date phrase, extending it word by word while the longer phrase still parses.
    ///
    /// Greedy but never speculative: a word joins the phrase only if the phrase *including* it
    /// parses, so "due Friday meeting" keeps "meeting" in the title. Bounded to four extra words,
    /// which covers everything the vocabulary can express — "in two weeks", "next Tuesday at 2pm".
    ///
    /// - Parameters:
    ///   - valueOffset: How many words the introducer took before the value starts.
    ///   - silentOnFailure: `true` for a bare phrase, where "this is not a date" is the ordinary
    ///     case and must not produce a token telling the user their own words were not understood.
    private static func claimDate(
        role: DateRole,
        startingWith firstValue: String,
        all: [Word],
        at index: Int,
        into draft: inout TaskEntryDraft,
        titleWords: inout [String],
        valueOffset: Int = 0,
        silentOnFailure: Bool = false
    ) -> Int? {
        guard !firstValue.isEmpty else { return nil }

        var phrase = normaliseNumberWords(firstValue)
        var best = NaturalDateParser.interpret(phrase)
        var bestEnd = all[min(index + valueOffset, all.count - 1)].range.upperBound
        var bestConsumed = valueOffset + 1

        var cursor = index + valueOffset + 1
        var lookahead = 0
        while cursor < all.count, lookahead < 4 {
            phrase += " " + normaliseNumberWords(all[cursor].text)
            lookahead += 1
            if let extended = NaturalDateParser.interpret(phrase) {
                best = extended
                bestEnd = all[cursor].range.upperBound
                bestConsumed = cursor - index + 1
            }
            cursor += 1
        }

        guard let interpretation = best else {
            guard !silentOnFailure else { return nil }
            // A word that promised a date and did not deliver one. The text is kept exactly as
            // typed; the token exists to explain, never to recover.
            titleWords.append(all[index].text)
            draft.tokens.append(
                TaskEntryToken(
                    kind: .unsupported,
                    display: all[index].text,
                    range: all[index].range,
                    explanation: "No date was recognized after this."
                )
            )
            return 1
        }

        let range = all[index].range.lowerBound..<bestEnd

        switch role {
        case .deadline:
            draft.deadline = interpretation
            draft.tokens.append(
                TaskEntryToken(kind: .deadline, display: interpretation.summary, range: range)
            )

        case .reminder:
            draft.reminder = interpretation
            draft.tokens.append(
                TaskEntryToken(kind: .reminder, display: interpretation.summary, range: range)
            )

        case .start:
            draft.startDate = DateInterpretation(day: interpretation.day)
            draft.tokens.append(
                TaskEntryToken(kind: .startDate, display: interpretation.day.summary, range: range)
            )
            // A clock time in a bare phrase is a request to be interrupted — see the note on
            // ``TaskEntryParser``. The start date keeps the day and the reminder takes the instant,
            // so both appear in the preview and neither is invented from the other.
            if let time = interpretation.time, draft.reminder == nil {
                draft.reminder = DateInterpretation(day: interpretation.day, time: time)
                draft.tokens.append(
                    TaskEntryToken(
                        kind: .reminder,
                        display: interpretation.summary,
                        range: range
                    )
                )
            }
        }

        return bestConsumed
    }

    /// Prepares one word for the date vocabulary.
    ///
    /// Two adjustments, both of which exist because people write sentences rather than arguments:
    ///
    /// - **Number words.** "two weeks" becomes "2 weeks", so the date vocabulary need not carry them.
    ///   Confined to the small set people actually spell out — beyond about ten nobody writes a
    ///   number in a capture field, and a longer table would start claiming words that are not
    ///   numbers.
    /// - **Trailing separators.** "next Monday, deadline September 1" puts a comma on the end of
    ///   "Monday", and a date parser that cannot see past it fails on the commonest sentence there
    ///   is. Only `,` and `;` are stripped: a full stop is load-bearing in `9.30pm`.
    ///
    /// The original word is what goes back into the title, so none of this reaches the user's text.
    private static func normaliseNumberWords(_ word: String) -> String {
        var text = word
        while let last = text.last, last == "," || last == ";" {
            text = String(text.dropLast())
        }
        guard !text.isEmpty else { return word }

        let numbers = [
            "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
            "a": "1", "an": "1", "couple": "2",
        ]
        return numbers[text.lowercased()] ?? text
    }

    // MARK: - Claiming a recurrence

    private static func claimRecurrence(
        startingWith firstValue: String,
        all: [Word],
        at index: Int,
        into draft: inout TaskEntryDraft,
        titleWords: inout [String],
        valueOffset: Int = 0
    ) -> Int? {
        // Longest match first: "2 weeks" must beat "2".
        var bestRule: RecurrenceRule?
        var bestConsumed = 0
        var bestEnd = all[index].range.upperBound
        var phrase: [String] = []

        var cursor = index + valueOffset
        while cursor < all.count, phrase.count < 3 {
            phrase.append(all[cursor].lower)
            if let rule = recurrencePhrase(phrase) {
                bestRule = rule
                bestConsumed = cursor - index + 1
                bestEnd = all[cursor].range.upperBound
            }
            cursor += 1
        }

        guard var rule = bestRule else { return nil }

        // "every 3 days after completion" — the suffix that changes what the interval is measured
        // from. Worth supporting because it is the distinction most repeat features get wrong.
        var consumed = bestConsumed
        let tail = index + consumed
        if tail + 1 < all.count, all[tail].lower == "after",
           ["completion", "completing", "done", "finishing"].contains(all[tail + 1].lower) {
            rule.anchor = .completion
            bestEnd = all[tail + 1].range.upperBound
            consumed += 2
        }

        draft.recurrence = rule
        draft.tokens.append(
            TaskEntryToken(
                kind: .repeatRule,
                display: rule.summary,
                range: all[index].range.lowerBound..<bestEnd
            )
        )
        return consumed
    }

    private static func singleWordRecurrence(_ word: String) -> RecurrenceRule? {
        switch word {
        case "daily": RecurrenceRule(frequency: .daily)
        case "weekly": RecurrenceRule(frequency: .weekly)
        case "fortnightly", "biweekly": RecurrenceRule(frequency: .weekly, interval: 2)
        case "monthly": RecurrenceRule(frequency: .monthly)
        case "yearly", "annually": RecurrenceRule(frequency: .yearly)
        default: nil
        }
    }

    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]

    /// The phrase after `every`.
    private static func recurrencePhrase(_ words: [String]) -> RecurrenceRule? {
        guard let first = words.first else { return nil }

        if words.count == 1 {
            switch first {
            case "day": return RecurrenceRule(frequency: .daily)
            case "week": return RecurrenceRule(frequency: .weekly)
            case "month": return RecurrenceRule(frequency: .monthly)
            case "year": return RecurrenceRule(frequency: .yearly)
            case "weekday": return RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
            case "morning", "night": return RecurrenceRule(frequency: .daily)
            default: break
            }
            if let weekday = weekdayNumbers[first] {
                return RecurrenceRule(frequency: .weekly, weekdays: [weekday])
            }
            if let day = ordinalDay(first) {
                return RecurrenceRule(frequency: .monthly, dayOfMonth: day)
            }
            return nil
        }

        if words.count == 2 {
            // "other week", "other day".
            if first == "other" {
                return unitRule(words[1], interval: 2)
            }
            // "2 weeks", "3 days".
            if let magnitude = Int(first), magnitude > 0 {
                return unitRule(words[1], interval: magnitude)
            }
            // "weekday morning" and the like: the second word adds nothing this model holds.
            if first == "weekday" {
                return RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
            }
        }

        // "monday and thursday", "monday, thursday".
        let weekdays = words
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .filter { $0 != "and" }
            .compactMap { weekdayNumbers[$0] }
        if weekdays.count == words.count(where: { $0 != "and" }), !weekdays.isEmpty {
            return RecurrenceRule(frequency: .weekly, weekdays: Set(weekdays))
        }

        return nil
    }

    private static func unitRule(_ unit: String, interval: Int) -> RecurrenceRule? {
        switch unit {
        case "day", "days": RecurrenceRule(frequency: .daily, interval: interval)
        case "week", "weeks": RecurrenceRule(frequency: .weekly, interval: interval)
        case "month", "months": RecurrenceRule(frequency: .monthly, interval: interval)
        case "year", "years": RecurrenceRule(frequency: .yearly, interval: interval)
        default: nil
        }
    }

    /// `15th`, `1st`, `3rd` — the day of a month.
    private static func ordinalDay(_ token: String) -> Int? {
        var text = token
        var hadSuffix = false
        for suffix in ["st", "nd", "rd", "th"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(2))
            hadSuffix = true
            break
        }
        guard hadSuffix, let value = Int(text), (1...31).contains(value) else { return nil }
        return value
    }

    // MARK: - Help

    /// What the entry surface shows beneath the field.
    ///
    /// Phrases first, sigils second, because the phrases are the part somebody can use without
    /// having read anything.
    public static let grammarHints: [(example: String, meaning: String)] = [
        ("tomorrow at 10", "Starts tomorrow, and reminds you at ten"),
        ("by August 15", "A deadline, not a start date"),
        ("every Friday", "Repeats"),
        ("every 3 days after completion", "Repeats from when you finish it"),
        ("waiting for Jordan", "Blocked on somebody"),
        ("someday", "Parked, and out of Today"),
        ("#groceries", "Tag"),
        ("/Work /Acme", "File it under an area and a project"),
        ("@Maya", "Link a person"),
        ("!high", "Priority"),
        ("!!", "Flag it"),
    ]
}
