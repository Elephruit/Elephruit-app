import Foundation

/// A people search, taken apart.
///
/// ### Why this is not the existing search grammar
/// `SearchQuery` searches *content* — the text of notes and tasks. "People I met through Nisha" is
/// not a text search at all: it is a graph traversal, and expressing it as `introducedBy:nisha`
/// would mean teaching the FTS compiler about relationships it has no business knowing. So people
/// searches parse to this, which the person repository executes against the graph, and the two
/// grammars stay independent.
public struct PersonQuery: Sendable, Hashable {
    /// Words with no structural meaning — matched against names, roles, and fact values.
    public var freeText: String = ""

    /// `works at Acme` · `in Austin` · `likes natural wine`.
    public var attributeFilters: [AttributeFilter] = []

    /// `Maya's son` — somebody related to a named person.
    public var relatedTo: RelationFilter?

    /// `people I met through Nisha`.
    public var introducedBy: String?

    /// `birthdays next month` — a window in whole months from today.
    public var celebrationWindowMonths: Int?

    /// `haven't contacted in six months`.
    public var notContactedForDays: Int?

    /// `open promises`.
    public var hasOpenPromises = false

    /// `in the Family group`.
    public var groupName: String?

    public struct AttributeFilter: Sendable, Hashable {
        public var attribute: FactAttribute
        public var value: String

        public init(attribute: FactAttribute, value: String) {
            self.attribute = attribute
            self.value = value
        }
    }

    public struct RelationFilter: Sendable, Hashable {
        public var personName: String
        public var kind: RelationshipKind
        /// The word the user typed, kept so "son" is not answered with every child.
        public var label: String?

        public init(personName: String, kind: RelationshipKind, label: String? = nil) {
            self.personName = personName
            self.kind = kind
            self.label = label
        }
    }

    public init() {}

    /// Whether anything beyond free text was recognised.
    public var isStructural: Bool {
        !attributeFilters.isEmpty || relatedTo != nil || introducedBy != nil
            || celebrationWindowMonths != nil || notContactedForDays != nil
            || hasOpenPromises || groupName != nil
    }

    public var isEmpty: Bool {
        freeText.isEmpty && !isStructural
    }

    /// How the query reads back, for the results header.
    public var summary: String {
        var parts: [String] = []
        if !freeText.isEmpty { parts.append("“\(freeText)”") }
        for filter in attributeFilters {
            parts.append("\(filter.attribute.displayName.lowercased()) \(filter.value)")
        }
        if let relatedTo {
            parts.append("\(relatedTo.personName)'s \(relatedTo.label ?? relatedTo.kind.displayName)")
        }
        if let introducedBy { parts.append("met through \(introducedBy)") }
        if let months = celebrationWindowMonths {
            parts.append(months <= 1 ? "celebrations this month" : "celebrations in \(months) months")
        }
        if let days = notContactedForDays { parts.append("not contacted in \(days / 30) months") }
        if hasOpenPromises { parts.append("open tasks") }
        if let groupName { parts.append("in \(groupName)") }
        return parts.joined(separator: " · ")
    }
}

/// Reads a people search the way somebody would say it.
///
/// Deterministic and small. Every phrase it understands is listed in ``PersonQueryParser/examples``,
/// which is also what the empty search state shows — so the grammar and its documentation cannot
/// drift apart.
public enum PersonQueryParser {
    public static func parse(_ input: String) -> PersonQuery {
        var query = PersonQuery()
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return query }

        // A leading "people" is a noun, not a filter.
        for prefix in ["people who ", "people i ", "people ", "who "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }

        text = consumeOpenPromises(text, into: &query)
        text = consumeStaleContact(text, into: &query)
        text = consumeCelebrations(text, into: &query)
        text = consumeIntroduction(text, into: &query)
        text = consumeRelation(text, into: &query)
        text = consumeAttributes(text, into: &query)

        query.freeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query
    }

    private static func consumeOpenPromises(_ text: String, into query: inout PersonQuery) -> String {
        for phrase in ["open tasks", "open task", "open promises", "open promise", "promises", "i promised", "owe"] {
            guard let range = wholePhraseRange(of: phrase, in: text) else { continue }
            query.hasOpenPromises = true
            return text.replacingCharacters(in: range, with: "")
        }
        return text
    }

    /// Finds a search-language keyword only when it stands on its own.
    ///
    /// Substring matching made `Howe` contain the promise keyword `owe`, turning a surname search
    /// into a structural query. Natural-language commands may sit inside a longer sentence, but
    /// they may never consume letters from an ordinary word.
    private static func wholePhraseRange(of phrase: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let beginsAtBoundary = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            let endsAtBoundary = range.upperBound == text.endIndex
                || !text[range.upperBound].isLetter

            if beginsAtBoundary, endsAtBoundary { return range }
            searchStart = range.upperBound
        }

        return nil
    }

    /// `haven't contacted in six months` · `not spoken to in a year`.
    private static func consumeStaleContact(_ text: String, into query: inout PersonQuery) -> String {
        let triggers = [
            "haven't contacted in", "havent contacted in", "have not contacted in",
            "haven't spoken to in", "havent spoken to in", "not spoken to in",
            "haven't heard from in", "out of touch for", "not contacted in",
        ]

        for trigger in triggers {
            guard let range = text.range(of: trigger) else { continue }
            let remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let days = durationInDays(remainder) else { continue }
            query.notContactedForDays = days.days
            return text.replacingCharacters(in: range.lowerBound..<text.endIndex, with: days.remainder)
        }
        return text
    }

    /// `birthdays next month` · `celebrations this month`.
    private static func consumeCelebrations(_ text: String, into query: inout PersonQuery) -> String {
        let triggers = ["birthdays", "birthday", "celebrations", "anniversaries", "anniversary"]
        guard let trigger = triggers.first(where: { text.contains($0) }) else { return text }

        let months: Int = if text.contains("next month") {
            2
        } else if text.contains("this month") || text.contains("this week") {
            1
        } else if text.contains("next three months") || text.contains("next 3 months") {
            3
        } else {
            2
        }

        query.celebrationWindowMonths = months
        return text
            .replacingOccurrences(of: trigger, with: "")
            .replacingOccurrences(of: "next three months", with: "")
            .replacingOccurrences(of: "next 3 months", with: "")
            .replacingOccurrences(of: "next month", with: "")
            .replacingOccurrences(of: "this month", with: "")
            .replacingOccurrences(of: "this week", with: "")
    }

    /// `met through Nisha` · `introduced by Nisha`.
    private static func consumeIntroduction(_ text: String, into query: inout PersonQuery) -> String {
        for trigger in ["met through ", "introduced by ", "introduced through ", "know through "] {
            guard let range = text.range(of: trigger) else { continue }
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            query.introducedBy = name
            return String(text[..<range.lowerBound])
        }
        return text
    }

    /// `maya's son` · `maya's family`.
    private static func consumeRelation(_ text: String, into query: inout PersonQuery) -> String {
        guard let possessive = text.range(of: "'s ") ?? text.range(of: "’s ") else { return text }

        let name = String(text[..<possessive.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[possessive.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !rest.isEmpty else { return text }

        let word = rest.split(separator: " ").first.map(String.init) ?? rest
        guard let kind = RelationshipKind.gendered(word) ?? RelationshipKind(rawValue: word) else { return text }

        query.relatedTo = PersonQuery.RelationFilter(
            personName: name,
            kind: kind,
            label: RelationshipKind(rawValue: word) == nil ? word : nil
        )
        return String(rest.dropFirst(word.count))
    }

    /// `works at Acme` · `in Austin` · `likes natural wine`.
    private static func consumeAttributes(_ text: String, into query: inout PersonQuery) -> String {
        let phrases: [(trigger: String, attribute: FactAttribute)] = [
            ("works at ", .employer),
            ("work at ", .employer),
            ("at ", .employer),
            ("lives in ", .location),
            ("live in ", .location),
            ("in ", .location),
            ("likes ", .like),
            ("like ", .like),
            ("dislikes ", .dislike),
            ("avoid ", .dislike),
            ("looking for ", .lookingFor),
        ]

        var remaining = text
        for phrase in phrases {
            guard let range = remaining.range(of: phrase.trigger),
                  // Only at a word boundary: "in" inside "Austin" is not a filter.
                  range.lowerBound == remaining.startIndex
                    || remaining[remaining.index(before: range.lowerBound)] == " "
            else { continue }

            let value = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            query.attributeFilters.append(
                PersonQuery.AttributeFilter(attribute: phrase.attribute, value: value)
            )
            remaining = String(remaining[..<range.lowerBound])
            break
        }

        return remaining
    }

    /// "six months" · "a year" · "90 days" → days, and whatever followed.
    private static func durationInDays(_ text: String) -> (days: Int, remainder: String)? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }

        let numbers = [
            "a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "eighteen": 18,
        ]

        guard let count = Int(words[0]) ?? numbers[words[0]] else { return nil }

        let unit = words[1]
        let perUnit: Int? = if unit.hasPrefix("day") {
            1
        } else if unit.hasPrefix("week") {
            7
        } else if unit.hasPrefix("month") {
            30
        } else if unit.hasPrefix("year") {
            365
        } else {
            nil
        }

        guard let perUnit else { return nil }
        return (count * perUnit, words.dropFirst(2).joined(separator: " "))
    }

    /// The searches the empty state offers, which are also the ones the parser is tested against.
    public static let examples: [String] = [
        "people in Austin",
        "Maya's son",
        "likes natural wine",
        "people I met through Nisha",
        "birthdays next month",
        "haven't contacted in six months",
        "works at Acme",
        "dog trainer",
        "open tasks",
    ]
}

// MARK: - Ranking

/// Why somebody came back from a search.
///
/// The reasons are shown. This is the alternative to a relevance score: the user sees "matched
/// *likes natural wine*" beside a result rather than a number, which is both more useful and
/// impossible to mistake for a judgement about the person.
public struct PersonMatchReason: Sendable, Hashable {
    public var text: String

    /// Where the match came from, for ordering.
    public var strength: Strength

    public enum Strength: Int, Sendable, Hashable, Comparable {
        /// The name itself, matched exactly.
        case exactName = 5
        /// The name, matched as a prefix.
        case namePrefix = 4
        /// A structural filter — an attribute, a relationship, a group.
        case structural = 3
        /// A recorded fact's value.
        case factValue = 2
        /// Body text of something linked to them.
        case linkedText = 1

        public static func < (lhs: Strength, rhs: Strength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public init(text: String, strength: Strength) {
        self.text = text
        self.strength = strength
    }
}

/// A search result.
public struct RankedPerson: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var reasons: [PersonMatchReason]

    /// Days since the last recorded contact. `nil` when there has never been any.
    public var daysSinceContact: Int?

    /// How many things in the library reference them.
    public var mentionCount: Int

    public init(
        id: UUID,
        name: String,
        reasons: [PersonMatchReason],
        daysSinceContact: Int? = nil,
        mentionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.reasons = reasons
        self.daysSinceContact = daysSinceContact
        self.mentionCount = mentionCount
    }

    public var bestReason: PersonMatchReason? {
        reasons.max { $0.strength < $1.strength }
    }
}

/// Puts search results in a useful order.
///
/// ### What this deliberately does not do
/// It does not compute a number describing a relationship and it does not remember which people the
/// user opens most. `docs/17` **P20** rejects relationship scoring on product grounds, and a ranking
/// that learned from behaviour would be exactly that with the number hidden.
///
/// What it uses instead is entirely explainable in one sentence each: how well the query matched,
/// how recently there was contact, and how much of the library references them. The first dominates;
/// the other two only break ties.
public enum PersonRanker {
    public static func rank(_ people: [RankedPerson]) -> [RankedPerson] {
        people.sorted { left, right in
            let leftStrength = left.bestReason?.strength.rawValue ?? 0
            let rightStrength = right.bestReason?.strength.rawValue ?? 0
            if leftStrength != rightStrength { return leftStrength > rightStrength }

            // More reasons is a better match than one.
            if left.reasons.count != right.reasons.count { return left.reasons.count > right.reasons.count }

            // Then recency of contact — somebody spoken to last week before somebody spoken to in
            // 2019. Never having spoken sorts last rather than first.
            switch (left.daysSinceContact, right.daysSinceContact) {
            case (let leftDays?, let rightDays?) where leftDays != rightDays:
                return leftDays < rightDays
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                break
            }

            if left.mentionCount != right.mentionCount { return left.mentionCount > right.mentionCount }
            return left.name < right.name
        }
    }
}
