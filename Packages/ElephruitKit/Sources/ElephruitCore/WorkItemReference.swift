import Foundation

/// Human-readable identifiers for work — `ELE-42`.
///
/// A UUID is the identity; this is the *handle*. It exists because people say identifiers out loud,
/// paste them into commit messages, and write them on whiteboards, and none of that survives
/// `9F3A1C0E-…`. The number is scoped to the project, so the key carries the context: `DEV-14` and
/// `MKT-14` are different work and read as different work.
public enum WorkItemReference {
    /// The separator. One place, so a future project that wants `ELE_42` is one edit.
    private static let separator = "-"

    /// `ELE` + `42` → `ELE-42`.
    public static func format(key: String, number: Int) -> String {
        "\(key)\(separator)\(number)"
    }

    /// `ELE-42` → `("ELE", 42)`, or `nil` if it is not one.
    ///
    /// Used by search and by paste, so it has to reject confidently: a note titled `Q3-2026` is not
    /// a reference to item 2026.
    public static func parse(_ text: String) -> (key: String, number: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let separatorIndex = trimmed.lastIndex(of: Character(separator)) else { return nil }

        let key = String(trimmed[trimmed.startIndex..<separatorIndex])
        let digits = String(trimmed[trimmed.index(after: separatorIndex)...])

        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber }),
              key.contains(where: \.isLetter),
              !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let number = Int(digits)
        else { return nil }

        return (key, number)
    }

    /// Forces arbitrary text into something usable as a key.
    ///
    /// Letters and digits only, uppercased, at most six characters, and never starting with a digit
    /// — otherwise `2026-14` parses as a date to every human who reads it. Returns `nil` when
    /// nothing usable survives, so the caller falls back rather than inventing a key from nothing.
    public static func normalise(key: String) -> String? {
        let stripped = key.uppercased().filter { $0.isLetter || $0.isNumber }
        let trimmed = stripped.drop(while: \.isNumber)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(6))
    }

    /// A key suggested from a project's name — "Design System" → `DS`, "Elephruit" → `ELE`.
    ///
    /// Initials when there are several words, because that is what people would have chosen; the
    /// first three letters when there is one, because `E` is not a key anybody can tell apart.
    public static func suggestedKey(forProjectNamed name: String) -> String? {
        let words = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.contains(where: \.isLetter) }

        guard !words.isEmpty else { return nil }

        if words.count == 1 {
            return normalise(key: String(words[0].prefix(3)))
        }
        return normalise(key: String(words.prefix(4).compactMap(\.first)))
    }

    /// A key not already taken, by appending digits.
    ///
    /// Two projects sharing a key would make `DEV-14` ambiguous, which defeats the entire purpose of
    /// having one.
    public static func uniqueKey(from candidate: String, taken: Set<String>) -> String {
        guard let base = normalise(key: candidate) else {
            return uniqueKey(from: "PRJ", taken: taken)
        }
        guard taken.contains(base) else { return base }

        // Trim before appending so the result still fits six characters.
        for suffix in 2...99 {
            let digits = String(suffix)
            let trimmed = String(base.prefix(max(1, 6 - digits.count)))
            let candidate = trimmed + digits
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    /// Sort key for reference strings, so `ELE-9` comes before `ELE-10`.
    ///
    /// A plain string sort puts `ELE-10` first, which is the kind of small wrongness that makes a
    /// table look broken without anybody being able to say why.
    public static func sortKey(_ reference: String?) -> (String, Int) {
        guard let reference, let parsed = parse(reference) else {
            // Unreferenced work sorts after everything referenced, rather than interleaving at the
            // top because an empty string sorts first.
            return ("\u{10FFFF}", Int.max)
        }
        return (parsed.key, parsed.number)
    }
}
