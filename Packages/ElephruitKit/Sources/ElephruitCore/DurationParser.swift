import Foundation

/// Reads a duration the way a person types one.
///
/// ### Why a typed duration is the whole point
/// A tracker that only lets you nudge a start time with a stepper makes the commonest correction —
/// *"that was about an hour and a half"* — into arithmetic. A typed duration field is the single
/// feature that removes it: you type `1:30`, or `1.5`, or `90m`, and the entry becomes that long.
/// Everything else about correcting time is downstream of being able to say how long it was.
///
/// So the grammar is deliberately generous. Every form below is one someone actually types, and
/// there is no combination of them that is ambiguous:
///
/// | Typed | Means | Rule |
/// |---|---|---|
/// | `1:30` | 1h 30m | a colon is `h:mm` |
/// | `1:30:15` | 1h 30m 15s | three parts are `h:mm:ss` |
/// | `1h30m` | 1h 30m | units are summed |
/// | `1h30` | 1h 30m | a trailing bare number after `h` is minutes |
/// | `90m` | 1h 30m | one unit is fine on its own |
/// | `45s` | 45s | seconds are accepted, though nothing writes them |
/// | `1.5` | 1h 30m | a decimal point with no unit means **hours** |
/// | `1,5` | 1h 30m | the comma decimal separator, for the rest of the world |
/// | `90` | 1h 30m | a bare integer means **minutes** |
///
/// ### The one rule worth arguing about
/// A bare `90` is ninety minutes, but a bare `1.5` is ninety minutes too — the same digits mean
/// different units depending on whether a decimal point is present. That looks inconsistent written
/// down and is not, because nobody types `1.5` meaning a minute and a half, and nobody types `90`
/// meaning ninety hours. The rule follows what the input can only have meant.
public enum DurationParser {
    /// The longest duration that can be typed: 999 hours.
    ///
    /// A cap rather than an unbounded parse, because the realistic way to exceed it is a typo — a
    /// stray digit turning `8` into `88888` — and an entry that swallows eleven years is one that
    /// wrecks every total until somebody finds it. Beyond this the input is rejected outright rather
    /// than clamped: silently keeping *some* of a number the user did not mean is worse than
    /// refusing it while they are still looking at the field.
    public static let maximum: TimeInterval = 999 * 3_600

    /// The duration `text` describes, or `nil` if it describes none.
    ///
    /// `nil` covers three different failures — empty input, unreadable input, and input past
    /// ``maximum`` — deliberately as one answer, because the field's only response to all three is
    /// the same: refuse to commit and leave what was typed alone.
    public static func parse(_ text: String) -> TimeInterval? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        let seconds: TimeInterval?
        if cleaned.contains(":") {
            seconds = parseClock(cleaned)
        } else if cleaned.contains(where: { $0 == "h" || $0 == "m" || $0 == "s" }) {
            seconds = parseUnits(cleaned)
        } else {
            seconds = parseBareNumber(cleaned)
        }

        guard let seconds, seconds >= 0, seconds <= maximum else { return nil }
        return seconds
    }

    // MARK: - Forms

    /// `h:mm` or `h:mm:ss`.
    ///
    /// The trailing parts are **not** required to be under sixty. `1:90` is two and a half hours,
    /// which is unambiguous and is what somebody adding half an hour to `1:60` in their head meant.
    /// Refusing it would leave them with a field that will not commit and no explanation of why.
    private static func parseClock(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }

        var values: [Double] = []
        for (index, part) in parts.enumerated() {
            // A leading `:30` is thirty minutes — the shorthand for "under an hour" — so only the
            // first part may be empty.
            if part.isEmpty {
                guard index == 0 else { return nil }
                values.append(0)
                continue
            }
            guard part.allSatisfy(\.isNumber), let value = Double(part) else { return nil }
            values.append(value)
        }

        let hours = values[0]
        let minutes = values[1]
        let seconds = values.count == 3 ? values[2] : 0
        return hours * 3_600 + minutes * 60 + seconds
    }

    /// `1h30m`, `90m`, `1h 30m 15s`, `1.5h`, `1h30`.
    private static func parseUnits(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var pending: Double?
        var seenHours = false
        var seenMinutes = false

        var digits = ""

        func takePending() -> Double? {
            defer { digits = "" }
            guard !digits.isEmpty else { return nil }
            return Double(digits.replacingOccurrences(of: ",", with: "."))
        }

        for character in text {
            switch character {
            case " ":
                // Whitespace between a number and its unit — `1 h 30 m` — is a separator, not a
                // terminator, so the digits collected so far stay pending.
                if pending == nil, let value = takePending() { pending = value }

            case _ where character.isNumber, ".", ",":
                // A digit arriving after a complete number with no unit — `1 30m` — is nonsense.
                if pending != nil { return nil }
                digits.append(character)

            case "h", "m", "s":
                let value = pending ?? takePending()
                pending = nil
                guard let value else { return nil }

                switch character {
                case "h":
                    guard !seenHours else { return nil }
                    seenHours = true
                    total += value * 3_600
                case "m":
                    guard !seenMinutes else { return nil }
                    seenMinutes = true
                    total += value * 60
                default:
                    total += value
                }

            default:
                return nil
            }
        }

        // `1h30` — a number left over after the units have been read. Minutes, and only when the
        // hours have been named and the minutes have not: anything else is a guess.
        if let trailing = pending ?? takePending() {
            guard seenHours, !seenMinutes else { return nil }
            total += trailing * 60
        }

        return total
    }

    /// A number with no unit and no colon: hours if it has a decimal point, minutes if it does not.
    private static func parseBareNumber(_ text: String) -> TimeInterval? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
        guard normalised.allSatisfy({ $0.isNumber || $0 == "." }),
              normalised.filter({ $0 == "." }).count <= 1,
              let value = Double(normalised)
        else { return nil }

        let isDecimal = normalised.contains(".")
        return isDecimal ? value * 3_600 : value * 60
    }
}
