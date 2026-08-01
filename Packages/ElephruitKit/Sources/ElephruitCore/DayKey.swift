import Foundation

/// Formats and reads `yyyy-MM-dd` day keys.
///
/// A day key is a *calendar day label* in the user's own calendar, not an instant. It is
/// built arithmetically rather than through a `DateFormatter` so it cannot shift with
/// locale, time zone, or calendar identifier, and so it sorts lexicographically in the
/// same order as chronologically — which is what makes it useful as a stored key.
public enum DayKey {
    /// Zero-padded `yyyy-MM-dd`.
    public static func string(year: Int, month: Int, day: Int) -> String {
        pad(year, width: 4) + "-" + pad(month, width: 2) + "-" + pad(day, width: 2)
    }

    /// Reads a key back into its components, or `nil` if it is not a well-formed key.
    public static func components(from key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        return (year, month, day)
    }

    /// Whether a string is a well-formed day key.
    public static func isValid(_ key: String) -> Bool {
        components(from: key) != nil
    }

    /// The start of the day a key names, in a given calendar.
    ///
    /// The inverse of ``string(year:month:day:)``, and the only place a key becomes an instant
    /// again. Needed by anything that has to *plot* days rather than list them — a chart axis wants
    /// dates, and a chart labelled with strings cannot space its bars by how far apart the days are.
    ///
    /// Takes the calendar rather than assuming one, because a key is a label in the user's calendar
    /// and reading it back in a different one would move it by up to a day.
    public static func date(from key: String, in calendar: Calendar = .current) -> Date? {
        guard let parts = components(from: key) else { return nil }
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        return calendar.date(from: components)
    }

    /// Two-digit zero padding, for clock faces and durations.
    ///
    /// Here rather than in a formatter for the same reason as the rest of this type: `String(format:)`
    /// takes `CVarArg`, which the strict-memory-safety checks flag, and a duration is arithmetic
    /// anyway.
    public static func padded(_ value: Int) -> String {
        pad(value, width: 2)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        let padding = max(0, width - digits.count)
        let sign = value < 0 ? "-" : ""
        return sign + String(repeating: "0", count: padding) + digits
    }
}
