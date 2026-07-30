import ElephruitCore
import Foundation

/// A parsed search query.
///
/// Deterministic and inspectable, which is the point: the user can see exactly what their
/// query means, a saved search stores the *text* rather than this structure, and there is no
/// model in the loop. `docs/adr/0004-search-is-derived.md` explains why the engine behind it
/// is a rebuildable cache.
public struct SearchQuery: Sendable, Hashable {
    /// Words to match against titles and bodies.
    public var terms: [String] = []

    /// `type:note`
    public var kinds: Set<ItemKind> = []

    /// `tag:work`, `tag:work/clients`
    public var tagSlugs: Set<String> = []

    /// `project:"Q3 Launch"` — matched against parent titles, resolved by the engine.
    public var containerTitles: Set<String> = []

    /// `is:open`, `is:favorite`, …
    public var states: Set<StateFilter> = []

    /// `due:<7d`, `due:today`, `due:>friday`
    public var due: DateConstraint?

    /// `created:>2026-01-01`
    public var created: DateConstraint?

    /// `updated:<7d`
    public var updated: DateConstraint?

    /// The text as the user typed it. Kept so a saved search round-trips exactly and an
    /// unparseable fragment can be shown in place.
    public var rawText: String = ""

    /// Fragments the parser did not understand.
    ///
    /// Surfaced to the user rather than discarded, because silently ignoring part of a query
    /// produces results that look right and are not.
    public var unrecognisedTokens: [String] = []

    public init() {}

    /// Whether this query would narrow anything at all.
    public var isEmpty: Bool {
        terms.isEmpty
            && kinds.isEmpty
            && tagSlugs.isEmpty
            && containerTitles.isEmpty
            && states.isEmpty
            && due == nil
            && created == nil
            && updated == nil
    }

    /// Whether anything beyond free text is being filtered.
    public var hasStructuralFilters: Bool {
        !kinds.isEmpty || !tagSlugs.isEmpty || !containerTitles.isEmpty
            || !states.isEmpty || due != nil || created != nil || updated != nil
    }
}

// MARK: - Filters

/// A lifecycle or flag filter — the `is:` token.
public enum StateFilter: String, Sendable, Hashable, CaseIterable {
    case open
    case completed
    case cancelled
    case favorite
    case pinned
    case archived
    case trashed
    case overdue
    case untagged
    case unfiled
    case linked
    case unlinked

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .favorite: "Favourite"
        case .pinned: "Pinned"
        case .archived: "Archived"
        case .trashed: "In Trash"
        case .overdue: "Overdue"
        case .untagged: "Untagged"
        case .unfiled: "Unfiled"
        case .linked: "Has links"
        case .unlinked: "No links"
        }
    }
}

/// A date comparison built from a ``DateExpression``, so `due:<friday` works and is testable
/// without a clock.
public enum DateConstraint: Sendable, Hashable {
    /// Strictly before the start of the expressed day.
    case before(DateExpression)
    /// On or after the start of the expressed day.
    case after(DateExpression)
    /// Within the expressed day.
    case on(DateExpression)
    /// Has no date at all — `due:none`.
    ///
    /// Named `absent` rather than `none` so it never has to be disambiguated from
    /// `Optional.none` at a call site.
    case absent

    /// Whether `date` satisfies this constraint.
    public func matches(_ date: Date?, using dateProvider: any DateProvider) -> Bool {
        guard case .absent = self else {
            guard let date else { return false }
            return compare(date, using: dateProvider)
        }
        return date == nil
    }

    private func compare(_ date: Date, using dateProvider: any DateProvider) -> Bool {
        switch self {
        case .before(let expression):
            guard let bound = expression.resolve(using: dateProvider) else { return false }
            return date < bound

        case .after(let expression):
            guard let bound = expression.resolve(using: dateProvider) else { return false }
            return date >= bound

        case .on(let expression):
            guard let start = expression.resolve(using: dateProvider),
                  let end = dateProvider.calendar.date(byAdding: .day, value: 1, to: start)
            else { return false }
            return date >= start && date < end

        case .absent:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .before(let expression): "before \(expression.summary)"
        case .after(let expression): "from \(expression.summary)"
        case .on(let expression): "on \(expression.summary)"
        case .absent: "with no date"
        }
    }
}

// MARK: - Parsing

/// Reads the search grammar.
///
/// ```
/// launch plan type:note tag:work project:"Q3 Launch" is:open due:<7d
/// ```
///
/// Design rules:
/// - **Nothing is silently dropped.** An unknown key or an unparseable date is recorded in
///   ``SearchQuery/unrecognisedTokens`` and shown to the user.
/// - **Quotes group.** `project:"Q3 Launch"` and `tag:"work in progress"`.
/// - **Unknown keys become free text**, so typing a colon in prose does not break the search.
/// - **Deterministic.** No inference, no fuzzy interpretation of intent. Natural-language
///   search is a Phase 5 layer *over* this model, never a replacement for it.
public enum SearchQueryParser {
    /// Keys the grammar understands. Exposed so the UI can offer completions from the same
    /// source of truth the parser uses.
    public static let recognisedKeys = [
        "type", "kind", "tag", "project", "area", "in", "is", "due", "created", "updated",
    ]

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        query.rawText = input

        var freeTextWords: [String] = []

        for token in tokenize(input) {
            guard let separator = token.firstIndex(of: ":"), separator != token.startIndex else {
                freeTextWords.append(token)
                continue
            }

            let key = String(token[token.startIndex..<separator]).lowercased()
            let value = String(token[token.index(after: separator)...])

            guard recognisedKeys.contains(key) else {
                // A colon in ordinary prose is not a failed filter.
                freeTextWords.append(token)
                continue
            }

            guard !value.isEmpty else {
                query.unrecognisedTokens.append(token)
                continue
            }

            apply(key: key, value: value, token: token, to: &query)
        }

        query.terms = TextNormalizer.searchTerms(in: freeTextWords.joined(separator: " "))
        return query
    }

    private static func apply(key: String, value: String, token: String, to query: inout SearchQuery) {
        switch key {
        case "type", "kind":
            if let kind = ItemKind(rawValue: value.lowercased()) {
                query.kinds.insert(kind)
            } else {
                query.unrecognisedTokens.append(token)
            }

        case "tag":
            let slug = TextNormalizer.slug(value)
            if TextNormalizer.isValidSlug(slug) {
                query.tagSlugs.insert(slug)
            } else {
                query.unrecognisedTokens.append(token)
            }

        case "project", "area", "in":
            query.containerTitles.insert(TextNormalizer.foldedForMatching(value))

        case "is":
            if let state = StateFilter(rawValue: value.lowercased()) {
                query.states.insert(state)
            } else {
                query.unrecognisedTokens.append(token)
            }

        case "due":
            if let constraint = parseDateConstraint(value) {
                query.due = constraint
            } else {
                query.unrecognisedTokens.append(token)
            }

        case "created":
            if let constraint = parseDateConstraint(value) {
                query.created = constraint
            } else {
                query.unrecognisedTokens.append(token)
            }

        case "updated":
            if let constraint = parseDateConstraint(value) {
                query.updated = constraint
            } else {
                query.unrecognisedTokens.append(token)
            }

        default:
            query.unrecognisedTokens.append(token)
        }
    }

    /// `<7d`, `>today`, `friday`, `none`.
    private static func parseDateConstraint(_ value: String) -> DateConstraint? {
        if value.lowercased() == "none" { return .absent }

        if value.hasPrefix("<") {
            let remainder = String(value.dropFirst())
            guard let expression = NaturalDateParser.parse(remainder) else { return nil }
            return .before(expression)
        }

        if value.hasPrefix(">") {
            let remainder = String(value.dropFirst())
            guard let expression = NaturalDateParser.parse(remainder) else { return nil }
            return .after(expression)
        }

        guard let expression = NaturalDateParser.parse(value) else { return nil }
        return .on(expression)
    }

    /// Splits on whitespace, keeping double-quoted spans — including a quoted value after a
    /// key, as in `project:"Q3 Launch"`.
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var insideQuotes = false

        for character in input {
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }

            if character.isWhitespace, !insideQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A human summary of what a query will do, for the search field's subtitle.
    public static func describe(_ query: SearchQuery) -> String {
        var parts: [String] = []

        if !query.terms.isEmpty {
            parts.append("matching “\(query.terms.joined(separator: " "))”")
        }
        if !query.kinds.isEmpty {
            parts.append(query.kinds.map(\.pluralDisplayName).sorted().joined(separator: " or "))
        }
        if !query.tagSlugs.isEmpty {
            parts.append("tagged " + query.tagSlugs.sorted().joined(separator: " and "))
        }
        if !query.containerTitles.isEmpty {
            parts.append("in " + query.containerTitles.sorted().joined(separator: " or "))
        }
        if !query.states.isEmpty {
            parts.append(query.states.map(\.displayName).sorted().joined(separator: ", ").lowercased())
        }
        if let due = query.due {
            parts.append("due " + due.summary)
        }
        if let created = query.created {
            parts.append("created " + created.summary)
        }
        if let updated = query.updated {
            parts.append("updated " + updated.summary)
        }

        return parts.isEmpty ? "Everything" : parts.joined(separator: ", ")
    }
}
