import Foundation

/// Turns human text into forms that can be compared, matched, and indexed.
///
/// One home for all normalisation, because the alternative is three slightly different
/// slug functions that disagree at the edges and produce duplicate tags.
public enum TextNormalizer {
    /// A tag or title reduced to its matching form: case-folded, diacritic-stripped,
    /// whitespace collapsed to single hyphens, punctuation removed.
    ///
    /// `"Q3 Läunch — Planning!"` becomes `"q3-launch-planning"`. Path separators are
    /// preserved so hierarchical tags (`work/clients/acme`) survive.
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)

        var result = ""
        result.reserveCapacity(folded.count)
        var pendingSeparator = false

        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.append(character)
            } else if character == "/" {
                // Hierarchy separator survives normalisation.
                pendingSeparator = false
                if !result.isEmpty, result.last != "/" { result.append("/") }
            } else {
                pendingSeparator = true
            }
        }

        return result
    }

    /// Whether a slug is usable as a tag identity.
    public static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.contains { $0.isLetter || $0.isNumber }
    }

    /// The components of a hierarchical tag slug — `"work/clients/acme"` yields
    /// `["work", "clients", "acme"]`.
    public static func slugComponents(_ slug: String) -> [String] {
        slug.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    /// Text prepared for substring matching: case- and diacritic-insensitive, with
    /// whitespace runs collapsed to single spaces.
    public static func foldedForMatching(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The distinct search terms in a piece of text.
    ///
    /// Terms shorter than two characters are dropped: they match almost everything and
    /// cost the index more than they are worth.
    public static func searchTerms(in text: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []

        for rawTerm in foldedForMatching(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let term = String(rawTerm)
            guard term.count >= 2, seen.insert(term).inserted else { continue }
            terms.append(term)
        }

        return terms
    }

    /// A one-line preview of a body, for list rows.
    ///
    /// Strips Markdown's most common leading noise so a row shows content rather than
    /// syntax, without pretending to be a parser.
    public static func excerpt(from body: String, limit: Int = 180) -> String {
        var lines: [String] = []

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Leading heading marks, quote marks, and list bullets.
            while let first = line.first, first == "#" || first == ">" {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            for bullet in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(bullet) {
                line.removeFirst(bullet.count)
                break
            }
            // A fence line on its own carries no information.
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            lines.append(line)
            if lines.joined(separator: " ").count >= limit { break }
        }

        let joined = lines.joined(separator: " ")
        guard joined.count > limit else { return joined }

        let truncated = joined.prefix(limit)
        // Prefer to cut at a word boundary.
        if let lastSpace = truncated.lastIndex(of: " "), truncated.distance(from: truncated.startIndex, to: lastSpace) > limit / 2 {
            return String(truncated[truncated.startIndex..<lastSpace]) + "…"
        }
        return String(truncated) + "…"
    }

    /// A title inferred from a body, for items the user never titled.
    ///
    /// Uses the first non-empty line, so a note begun by typing straight into the body
    /// still has a usable name in lists.
    public static func inferredTitle(fromBody body: String, limit: Int = 80) -> String {
        let excerpt = excerpt(from: body, limit: limit)
        return excerpt.isEmpty ? "" : excerpt
    }
}
