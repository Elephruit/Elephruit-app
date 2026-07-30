import Foundation

/// A date the user expressed in shorthand, not yet resolved to an instant.
///
/// Kept as an expression rather than resolved immediately so that a draft written
/// before midnight still means the right thing when it is saved after midnight, and so
/// that parsing is testable without a clock.
public enum DateExpression: Sendable, Hashable {
    case today
    case tomorrow
    case yesterday

    /// The next occurrence of a weekday, using `Calendar`'s 1-based numbering.
    case nextWeekday(Int)

    /// A signed offset in days from today.
    case dayOffset(Int)

    /// A signed offset in weeks from today.
    case weekOffset(Int)

    /// An explicit calendar date.
    case explicit(year: Int, month: Int, day: Int)

    /// Resolves to the start of the intended day.
    public func resolve(using dateProvider: any DateProvider) -> Date? {
        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday

        switch self {
        case .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today)
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: today)
        case .dayOffset(let days):
            return calendar.date(byAdding: .day, value: days, to: today)
        case .weekOffset(let weeks):
            return calendar.date(byAdding: .weekOfYear, value: weeks, to: today)
        case .nextWeekday(let weekday):
            return nextOccurrence(ofWeekday: weekday, after: today, calendar: calendar)
        case .explicit(let year, let month, let day):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components)
        }
    }

    private func nextOccurrence(ofWeekday weekday: Int, after date: Date, calendar: Calendar) -> Date? {
        guard (1...7).contains(weekday) else { return nil }

        var cursor = date
        // Strictly future: "Monday" typed on a Monday means the next one.
        for _ in 1...7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
            if calendar.component(.weekday, from: cursor) == weekday { return cursor }
        }
        return nil
    }

    /// How the expression reads back to the user, for the capture field's live hint.
    public var summary: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .yesterday: "Yesterday"
        case .nextWeekday(let weekday): Self.weekdayName(weekday) ?? "Weekday"
        case .dayOffset(let days): days == 1 ? "In 1 day" : (days < 0 ? "\(-days) days ago" : "In \(days) days")
        case .weekOffset(let weeks): weeks == 1 ? "In 1 week" : (weeks < 0 ? "\(-weeks) weeks ago" : "In \(weeks) weeks")
        case .explicit(let year, let month, let day): DayKey.string(year: year, month: month, day: day)
        }
    }

    static func weekdayName(_ weekday: Int) -> String? {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard (1...7).contains(weekday) else { return nil }
        return names[weekday - 1]
    }
}

/// Parses a small, fixed vocabulary of date shorthand.
///
/// Deliberately deterministic and deliberately small. It recognises what a user will
/// actually type into a one-line capture field and nothing more; anything it does not
/// understand is left in the text rather than guessed at. A larger natural-language
/// date parser is a Phase 5 concern, and would sit behind this same interface.
public enum NaturalDateParser {
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    /// Interprets a token such as `today`, `tue`, `+3d`, `2w`, or `2026-08-14`.
    ///
    /// Returns `nil` for anything not in the vocabulary — the caller keeps the text.
    public static func parse(_ token: String) -> DateExpression? {
        let normalized = token
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "today", "tod": return .today
        case "tomorrow", "tom", "tmr": return .tomorrow
        case "yesterday", "yest": return .yesterday
        case "nextweek": return .weekOffset(1)
        default: break
        }

        if let weekday = weekdayNames[normalized] {
            return .nextWeekday(weekday)
        }

        if let offset = parseOffset(normalized) {
            return offset
        }

        return parseExplicitDate(normalized)
    }

    /// `+3d`, `-2w`, `3d`, `2w`.
    private static func parseOffset(_ token: String) -> DateExpression? {
        var text = Substring(token)

        var sign = 1
        if text.hasPrefix("+") {
            text = text.dropFirst()
        } else if text.hasPrefix("-") {
            sign = -1
            text = text.dropFirst()
        }

        guard let unit = text.last, unit == "d" || unit == "w" else { return nil }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let magnitude = Int(digits) else { return nil }

        return unit == "d" ? .dayOffset(sign * magnitude) : .weekOffset(sign * magnitude)
    }

    /// `2026-08-14` and `2026/08/14`.
    private static func parseExplicitDate(_ token: String) -> DateExpression? {
        let separators: Set<Character> = ["-", "/"]
        let parts = token.split(whereSeparator: { separators.contains($0) })
        guard parts.count == 3 else { return nil }

        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[0].count == 4, (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        return .explicit(year: year, month: month, day: day)
    }

    /// The vocabulary, for the capture field's help text.
    public static let recognisedExamples = ["today", "tomorrow", "friday", "+3d", "2w", "2026-08-14"]
}
