import Foundation

/// The cursor the deterministic parser walks.
///
/// Split from the grammar because the two change for different reasons: the grammar gains verbs, and
/// this gains ways of recognising a phone number. Keeping them apart also means every `consume…`
/// method can be reasoned about on its own — each one either advances the cursor and records an
/// entity, or does neither.
struct ParseState {
    struct Token {
        var text: String
        /// Character offsets into the input, for the field's underline.
        var range: Range<Int>
    }

    let context: CommandContext

    private(set) var tokens: [Token]

    /// The first token not yet consumed.
    private var cursor = 0

    /// One past the last token still available. Shrinks when a trailing date is taken off the end.
    private var tail: Int

    private(set) var entities: [RecognizedEntity] = []

    let input: String

    init(input: String, context: CommandContext) {
        self.input = input
        self.context = context
        self.tokens = Self.tokenize(input)
        self.tail = tokens.count
    }

    // MARK: Reading

    var isExhausted: Bool { cursor >= tail }

    var leadingWord: String? {
        guard cursor < tail else { return nil }
        return tokens[cursor].text
    }

    /// Everything still unclaimed, rejoined with single spaces.
    var remainingText: String {
        guard cursor < tail else { return "" }
        return tokens[cursor..<tail].map(\.text).joined(separator: " ")
    }

    mutating func consumeLeadingWord() {
        guard cursor < tail else { return }
        cursor += 1
    }

    /// Records everything remaining as one entity, without consuming it.
    mutating func claimRemainder(as kind: RecognizedEntity.Kind) {
        guard cursor < tail else { return }
        let range = tokens[cursor].range.lowerBound..<tokens[tail - 1].range.upperBound
        entities.append(RecognizedEntity(kind: kind, text: remainingText, range: range))
    }

    // MARK: People and groups

    /// The longest known name starting at the cursor.
    ///
    /// Longest-first, so "Maya Chen" wins over "Maya" when both are known — otherwise a library with
    /// two Mayas would resolve the full name to the wrong one and look like it had understood.
    mutating func consumePerson() -> KnownPerson? {
        guard cursor < tail else { return nil }

        var best: (person: KnownPerson, length: Int)?

        for person in context.people {
            for key in person.matchKeys {
                let wordCount = key.split(separator: " ").count
                guard cursor + wordCount <= tail else { continue }

                let candidate = TextNormalizer.foldedForMatching(
                    tokens[cursor..<(cursor + wordCount)].map(\.text).joined(separator: " ")
                )
                guard candidate == key else { continue }

                if best == nil || wordCount > (best?.length ?? 0) {
                    best = (person, wordCount)
                }
            }
        }

        guard let best else { return nil }

        let range = tokens[cursor].range.lowerBound..<tokens[cursor + best.length - 1].range.upperBound
        entities.append(
            RecognizedEntity(kind: .person, text: best.person.fullName, range: range, resolvedID: best.person.id)
        )
        cursor += best.length
        return best.person
    }

    mutating func consumeGroup() -> KnownGroup? {
        guard cursor < tail else { return nil }

        for group in context.groups.sorted(by: { $0.name.count > $1.name.count }) {
            let key = TextNormalizer.foldedForMatching(group.name)
            let wordCount = key.split(separator: " ").count
            guard wordCount > 0, cursor + wordCount <= tail else { continue }

            let candidate = TextNormalizer.foldedForMatching(
                tokens[cursor..<(cursor + wordCount)].map(\.text).joined(separator: " ")
            )
            guard candidate == key else { continue }

            let range = tokens[cursor].range.lowerBound..<tokens[cursor + wordCount - 1].range.upperBound
            entities.append(
                RecognizedEntity(kind: .group, text: group.name, range: range, resolvedID: group.id)
            )
            cursor += wordCount
            return group
        }
        return nil
    }

    /// Marks every known person named anywhere in what is left, without consuming anything.
    ///
    /// For a task, whose text mentions people rather than targeting one.
    mutating func markPeopleInRemainder() -> [KnownPerson] {
        var found: [KnownPerson] = []
        var seen = Set<UUID>()

        var index = cursor
        while index < tail {
            var matched = false
            for person in context.people {
                for key in person.matchKeys {
                    let wordCount = key.split(separator: " ").count
                    guard index + wordCount <= tail else { continue }
                    let candidate = TextNormalizer.foldedForMatching(
                        tokens[index..<(index + wordCount)].map(\.text).joined(separator: " ")
                    )
                    guard candidate == key else { continue }

                    if seen.insert(person.id).inserted { found.append(person) }
                    let range = tokens[index].range.lowerBound..<tokens[index + wordCount - 1].range.upperBound
                    entities.append(
                        RecognizedEntity(kind: .person, text: person.fullName, range: range, resolvedID: person.id)
                    )
                    index += wordCount
                    matched = true
                    break
                }
                if matched { break }
            }
            if !matched { index += 1 }
        }

        return found
    }

    // MARK: Dates

    /// A date phrase starting at the cursor, taking the longest reading that still parses.
    ///
    /// The same greedy-but-bounded approach `CaptureParser` uses: a word joins the phrase only when
    /// the phrase including it parses, so "Tuesday lunch" keeps "lunch".
    mutating func consumeDate() -> DateInterpretation? {
        guard cursor < tail else { return nil }

        var best: (interpretation: DateInterpretation, end: Int)?
        var phrase = ""

        for index in cursor..<tail {
            phrase = phrase.isEmpty ? tokens[index].text : phrase + " " + tokens[index].text
            if let parsed = NaturalDateParser.interpret(phrase) {
                best = (parsed, index + 1)
            }
            // Six words is more than any date phrase this grammar accepts and stops a long sentence
            // being re-parsed once per word.
            if index - cursor > 5 { break }
        }

        guard let best else { return nil }

        let range = tokens[cursor].range.lowerBound..<tokens[best.end - 1].range.upperBound
        entities.append(RecognizedEntity(kind: .date, text: best.interpretation.summary, range: range))
        cursor = best.end
        return best.interpretation
    }

    /// A date phrase at the *end* of the line, taken off the tail.
    ///
    /// `task introduce Maya to Danielle Friday` puts its date last, and consuming from the front
    /// would eat the task's own words. Searching backwards from the end and keeping the longest
    /// suffix that parses leaves the text intact.
    mutating func consumeTrailingDate() -> DateInterpretation? {
        guard cursor < tail else { return nil }

        // Try the longest suffix first: "next Tuesday at 2" beats "2".
        for start in cursor..<tail {
            let phrase = tokens[start..<tail].map(\.text).joined(separator: " ")
            // A bare number at the end of a task is a quantity far more often than a date.
            if start == tail - 1, Int(phrase) != nil { continue }
            guard let parsed = NaturalDateParser.interpret(phrase) else { continue }

            let range = tokens[start].range.lowerBound..<tokens[tail - 1].range.upperBound
            entities.append(RecognizedEntity(kind: .date, text: parsed.summary, range: range))
            tail = start
            return parsed
        }
        return nil
    }

    // MARK: Channels and charts

    /// `mobile` · `email` · `work` — a request to *see* a detail rather than to use it.
    mutating func consumeChannelWord() -> ContactChannel? {
        guard let word = leadingWord?.lowercased() else { return nil }

        let channel: ContactChannel? = switch word {
        case "mobile", "cell", "phone", "number": .call
        case "email", "address": word == "email" ? .email : .maps
        case "message", "text": .message
        case "facetime": .facetimeVideo
        case "website", "site", "web": .web
        case "home", "work": .maps
        default: nil
        }

        guard let channel, cursor + 1 >= tail else { return nil }
        entities.append(RecognizedEntity(kind: .phone, text: word, range: tokens[cursor].range))
        cursor += 1
        return channel
    }

    /// `family` · `'s family` · `household` · `org chart` · `network`.
    mutating func consumeChartKind() -> RelationshipChartKind? {
        guard cursor < tail else { return nil }

        // `Maya's family` tokenizes the possessive onto the name, which `consumePerson` has already
        // stripped; a bare `'s` left behind is skipped here.
        var index = cursor
        if tokens[index].text.lowercased() == "'s" || tokens[index].text.lowercased() == "s" {
            index += 1
        }
        guard index < tail else { return nil }

        let word = tokens[index].text.lowercased()
        let chart: RelationshipChartKind? = switch word {
        case "family", "relatives", "tree": .family
        case "household", "house", "home": .household
        case "org", "organisation", "organization", "team", "reports", "colleagues": .professional
        case "network", "connections", "relationships", "people": .network
        default: nil
        }

        guard let chart else { return nil }

        // `org chart` — swallow the noun so it does not read as leftover text.
        var end = index + 1
        if end < tail, tokens[end].text.lowercased() == "chart" { end += 1 }

        cursor = end
        return chart
    }

    // MARK: Celebrations

    struct CelebrationDraft {
        var kind: CelebrationKind
        var date: PartialDate
    }

    /// `birthday October 12` · `anniversary June 3 2011`.
    mutating func consumeCelebration() -> CelebrationDraft? {
        guard let word = leadingWord?.lowercased() else { return nil }

        let kind: CelebrationKind? = switch word {
        case "birthday", "bday", "born": .birthday
        case "anniversary": .anniversary
        case "remembering", "memorial": .memorial
        default: nil
        }
        guard let kind else { return nil }

        let keywordRange = tokens[cursor].range
        cursor += 1

        guard let date = consumePartialDate() else {
            cursor -= 1
            return nil
        }

        entities.append(RecognizedEntity(kind: .date, text: date.displayText, range: keywordRange))
        return CelebrationDraft(kind: kind, date: date)
    }

    /// A date that may legitimately have no year — the shape a birthday usually arrives in.
    mutating func consumePartialDate() -> PartialDate? {
        guard cursor < tail else { return nil }

        var best: (date: PartialDate, end: Int)?
        var phrase = ""

        for index in cursor..<min(tail, cursor + 4) {
            phrase = phrase.isEmpty ? tokens[index].text : phrase + " " + tokens[index].text
            if let parsed = PartialDate.parse(phrase) {
                best = (parsed, index + 1)
            }
        }

        guard let best else { return nil }
        cursor = best.end
        return best.date
    }

    // MARK: Relationships

    struct RelationDraft {
        var kind: RelationshipKind
        /// The word the user actually used — "son" rather than "child".
        var label: String?
        var relatedName: String
        var observations: [ObservationDraft]
    }

    /// `son Jack age 6 entering second grade`.
    ///
    /// The relationship word, then a name, then anything said about that person in the same breath.
    /// Everything after the name becomes observations *about the related person*, which is the whole
    /// reason this is one command rather than three.
    mutating func consumeRelation() -> RelationDraft? {
        guard let word = leadingWord else { return nil }
        guard let kind = RelationshipKind.gendered(word)
            ?? RelationshipKind(rawValue: word.lowercased())
        else { return nil }

        let relationRange = tokens[cursor].range
        cursor += 1

        // The name is the run of words before the first thing that reads as an attribute.
        var nameWords: [String] = []
        while cursor < tail, !readsAsAttributeStart(tokens[cursor].text) {
            nameWords.append(tokens[cursor].text)
            cursor += 1
        }

        guard !nameWords.isEmpty else {
            cursor -= 1
            return nil
        }

        entities.append(RecognizedEntity(kind: .relationship, text: word, range: relationRange))

        return RelationDraft(
            kind: kind,
            label: word.lowercased() == kind.rawValue.lowercased() ? nil : word.lowercased(),
            relatedName: nameWords.joined(separator: " "),
            observations: consumeTrailingObservations()
        )
    }

    /// Whether a word starts something said *about* somebody rather than part of their name.
    private func readsAsAttributeStart(_ word: String) -> Bool {
        [
            "age", "aged", "is", "turns", "turning", "entering", "starts", "starting",
            "in", "likes", "loves", "hates", "dislikes", "prefers", "works", "lives", "moved",
        ].contains(word.lowercased())
    }

    /// Observations trailing a name — `age 6 entering second grade`.
    mutating func consumeTrailingObservations() -> [ObservationDraft] {
        var drafts: [ObservationDraft] = []

        while cursor < tail {
            if let age = consumeAge() {
                drafts.append(age)
                continue
            }
            if let grade = consumeGrade() {
                drafts.append(grade)
                continue
            }
            if let fact = consumeFact() {
                drafts.append(fact)
                continue
            }
            break
        }

        return drafts
    }

    /// `age 6` · `aged 6` · `is 6` · `turns 7`.
    mutating func consumeAge() -> ObservationDraft? {
        guard cursor < tail else { return nil }
        let word = tokens[cursor].text.lowercased()
        guard ["age", "aged", "is", "turns", "turning"].contains(word), cursor + 1 < tail else { return nil }
        guard let years = Int(tokens[cursor + 1].text), (0...130).contains(years) else { return nil }

        let range = tokens[cursor].range.lowerBound..<tokens[cursor + 1].range.upperBound
        entities.append(RecognizedEntity(kind: .age, text: "\(years)", range: range))
        cursor += 2

        return ObservationDraft(attribute: .observedAge, value: "\(years)")
    }

    /// `entering second grade` · `starts 3rd grade` · `in kindergarten`.
    ///
    /// The school year is *not* derived from today's date here — parsing has no clock. It is left
    /// `nil` and filled in by the caller, which does, and which knows that "entering" means the year
    /// about to begin rather than the one the calendar is currently in.
    mutating func consumeGrade() -> ObservationDraft? {
        guard cursor < tail else { return nil }
        let word = tokens[cursor].text.lowercased()
        guard ["entering", "starts", "starting", "in"].contains(word) else { return nil }

        var end = cursor + 1
        var phrase: [String] = []
        while end < tail, phrase.count < 3 {
            phrase.append(tokens[end].text)
            end += 1
            if let grade = SchoolGrade.parse(phrase.joined(separator: " ")) {
                let range = tokens[cursor].range.lowerBound..<tokens[end - 1].range.upperBound
                entities.append(RecognizedEntity(kind: .grade, text: grade.displayText, range: range))
                cursor = end

                return ObservationDraft(
                    attribute: .schoolGrade,
                    value: grade.displayText,
                    // "Entering" and "starts" mean the year that has not begun; "in" means now.
                    effective: ["entering", "starts", "starting"].contains(word) ? .today : nil
                )
            }
        }
        return nil
    }

    // MARK: Facts

    /// `moved to Austin` · `likes natural wine` · `works at Acme` · `is looking for a dog trainer`.
    mutating func consumeFact() -> ObservationDraft? {
        guard cursor < tail else { return nil }

        let phrases: [(words: [String], attribute: FactAttribute)] = [
            (["moved", "to"], .location),
            (["lives", "in"], .location),
            (["moving", "to"], .location),
            (["works", "at"], .employer),
            (["joined"], .employer),
            (["likes"], .like),
            (["loves"], .like),
            (["prefers"], .like),
            (["enjoys"], .like),
            (["dislikes"], .dislike),
            (["hates"], .dislike),
            (["avoids"], .dislike),
            (["wants"], .giftIdea),
            (["is", "looking", "for"], .lookingFor),
            (["looking", "for"], .lookingFor),
            (["needs"], .lookingFor),
        ]

        for phrase in phrases {
            guard cursor + phrase.words.count <= tail else { continue }
            let actual = tokens[cursor..<(cursor + phrase.words.count)].map { $0.text.lowercased() }
            guard actual == phrase.words else { continue }

            let valueStart = cursor + phrase.words.count
            guard valueStart < tail else { continue }

            let value = tokens[valueStart..<tail].map(\.text).joined(separator: " ")
            let range = tokens[cursor].range.lowerBound..<tokens[tail - 1].range.upperBound
            entities.append(RecognizedEntity(kind: .note, text: value, range: range))
            cursor = tail

            return ObservationDraft(attribute: phrase.attribute, value: value)
        }

        return nil
    }

    // MARK: Contact details

    /// Every email, phone, company, title, and address in what is left, removed as they are found.
    mutating func consumeContactDetails() -> PersonDraftFields {
        var fields = PersonDraftFields(name: "")
        var kept: [Token] = []
        var index = cursor

        while index < tail {
            let token = tokens[index]

            if ContactDetailRecognizer.isEmail(token.text) {
                fields.emails.append(token.text)
                entities.append(RecognizedEntity(kind: .email, text: token.text, range: token.range))
                index += 1
                continue
            }

            if let phone = ContactDetailRecognizer.phone(token.text) {
                fields.phones.append(phone)
                entities.append(RecognizedEntity(kind: .phone, text: phone, range: token.range))
                index += 1
                continue
            }

            // `at Acme` — a company, when a word follows.
            if token.text.lowercased() == "at", index + 1 < tail, fields.company == nil {
                let company = tokens[(index + 1)..<tail].map(\.text).joined(separator: " ")
                fields.company = company
                let range = token.range.lowerBound..<tokens[tail - 1].range.upperBound
                entities.append(RecognizedEntity(kind: .company, text: company, range: range))
                index = tail
                continue
            }

            kept.append(token)
            index += 1
        }

        // Rebuild the unclaimed run so the caller sees only what is left — the name, usually.
        if fields.detailCount > 0 {
            tokens.replaceSubrange(cursor..<tail, with: kept)
            tail = cursor + kept.count
        }

        return fields
    }

    // MARK: Building the result

    mutating func command(
        intent: CommandIntent,
        ambiguities: [CommandAmbiguity] = [],
        summary: String
    ) -> ParsedCommand {
        ParsedCommand(
            intent: intent,
            entities: entities,
            ambiguities: ambiguities,
            originalText: input,
            summary: summary
        )
    }

    /// A verb whose subject matched nobody.
    ///
    /// Returns a command rather than `nil`, so the preview can say *why* nothing will happen and
    /// offer to create the person — which is far better than silently falling through to a search
    /// that finds nothing either.
    mutating func unknownSubject(verb: String, channel: ContactChannel?) -> ParsedCommand? {
        let name = remainingText
        guard !name.isEmpty else { return nil }

        claimRemainder(as: .newPerson)
        return command(
            intent: .search(query: name),
            ambiguities: [.unknownPerson(name: name)],
            summary: "No one called “\(name)” to \(verb)"
        )
    }

    // MARK: Tokenizing

    /// Splits on whitespace, recording each word's character offsets, and lifts a trailing
    /// possessive so that `Maya's` matches the person called Maya.
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var current = ""
        var start = 0

        func flush() {
            guard !current.isEmpty else { return }
            let cleaned = current.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if cleaned.hasSuffix("'s") || cleaned.hasSuffix("’s") {
                let base = String(cleaned.dropLast(2))
                let split = start + base.count
                if !base.isEmpty {
                    tokens.append(Token(text: base, range: start..<split))
                    tokens.append(Token(text: "'s", range: split..<(start + cleaned.count)))
                    current = ""
                    return
                }
            }
            if !cleaned.isEmpty {
                tokens.append(Token(text: cleaned, range: start..<(start + cleaned.count)))
            }
            current = ""
        }

        for character in input {
            if character.isWhitespace {
                flush()
                offset += 1
                start = offset
            } else {
                current.append(character)
                offset += 1
            }
        }
        flush()

        return tokens
    }
}

/// Recognises the shapes contact details come in.
///
/// Deliberately strict. A parser that guesses turns `512` in "invite 512 people" into a phone
/// number, and a wrong phone number is worse than an unrecognised one — the second is visible in the
/// preview, the first is visible only when the call goes to a stranger.
public enum ContactDetailRecognizer {
    public static func isEmail(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>,;()"))
        guard !candidate.contains(" "), candidate.count >= 6 else { return false }

        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }

        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        let tld = domain[domain.index(after: dot)...]
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    /// A phone number, returned in the form the user typed.
    ///
    /// Requires at least seven digits and nothing but digits and the punctuation numbers are written
    /// with, so a year, a house number, and a quantity are all rejected.
    public static func phone(_ text: String) -> String? {
        let candidate = text.trimmingCharacters(in: CharacterSet(charactersIn: ",;()"))
        let digits = candidate.filter(\.isNumber)
        guard digits.count >= 7, digits.count <= 15 else { return nil }

        let allowed = CharacterSet(charactersIn: "+()- .0123456789")
        guard candidate.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        return candidate
    }

    /// Digits only, for comparing two numbers written differently.
    ///
    /// The last ten digits, so `+1 (512) 555-0192` and `512-555-0192` are recognised as the same
    /// number without this having to know anything about dialling codes.
    public static func normalizedPhone(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    public static func normalizedEmail(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
