import Foundation

/// Renders a stored phone number the way somebody would write it down.
///
/// ### Presentation only
/// The stored value is never touched. What comes out of Contacts — `+19524526862` — is what dials,
/// what matches a duplicate, and what round-trips to the system; this is what appears on screen
/// beside it. Formatting the stored value instead would mean the app decided a number's canonical
/// spelling, which is the system's business and not this app's.
///
/// ### Why only North American numbers
/// A ten-digit number and an eleven-digit one beginning with 1 have exactly one conventional
/// grouping, and it is unambiguous. Nothing else does: a nine-digit number could be Dutch or
/// Norwegian, grouped differently in each, and there is no way to tell from the digits alone which
/// country a number without a dialling code belongs to.
///
/// So anything this cannot be certain about is returned exactly as it was given. A number shown
/// unformatted is mildly untidy; a French number regrouped as though it were American is wrong, and
/// wrong in a way that makes the reader distrust every other number on the page.
public enum PhoneNumberFormatting {
    /// The conventional spelling of `value`, or `value` unchanged when there is not exactly one.
    public static func display(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }

        // An extension, a letter, or anything else that is not punctuation means this is not a plain
        // number and regrouping it would lose part of it.
        let allowed = CharacterSet(charactersIn: "0123456789 ()-.+\u{00A0}\u{2011}\u{2013}")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return value }

        let digits = trimmed.filter(\.isNumber)
        let hasCountryCode = trimmed.hasPrefix("+")

        switch (digits.count, hasCountryCode, digits.first) {
        case (10, false, _):
            return grouped(digits)

        // `+1 952…` and `1952…` are the same number written two ways, and both have one grouping.
        case (11, _, "1"):
            return grouped(String(digits.dropFirst()))

        default:
            // Every other shape — an international number, a short code, a partial one somebody is
            // still typing — is left exactly as it is.
            return value
        }
    }

    /// `(952) 452-6862` from ten digits.
    private static func grouped(_ digits: String) -> String {
        let area = digits.prefix(3)
        let exchange = digits.dropFirst(3).prefix(3)
        let line = digits.suffix(4)
        return "(\(area)) \(exchange)-\(line)"
    }
}
