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

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        let padding = max(0, width - digits.count)
        let sign = value < 0 ? "-" : ""
        return sign + String(repeating: "0", count: padding) + digits
    }
}
