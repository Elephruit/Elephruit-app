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

    /// A month and day with no year — "August 12".
    ///
    /// The year is deliberately not decided here. "August 12" typed in September means next year,
    /// and which year that is depends on the clock, which parsing does not get to see. Resolution
    /// picks the next occurrence, today included.
    case monthDay(month: Int, day: Int)

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
        case .monthDay(let month, let day):
            return Self.nextOccurrence(ofMonth: month, day: day, onOrAfter: today, calendar: calendar)
        }
    }

    /// Resolves to an instant on the intended day, at `time` if one was given.
    ///
    /// Built by adding hours and minutes to the start of the day rather than by assembling
    /// `DateComponents` wholesale, so a day on which the clock jumps forward still lands correctly:
    /// `Calendar` knows that 02:30 may not exist and this does not have to.
    public func resolve(using dateProvider: any DateProvider, at time: TimeOfDay?) -> Date? {
        guard let day = resolve(using: dateProvider) else { return nil }
        guard let time else { return day }

        let calendar = dateProvider.calendar
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
            ?? calendar.date(byAdding: .minute, value: time.hour * 60 + time.minute, to: day)
    }

    /// The next time this month and day come round, today included.
    static func nextOccurrence(ofMonth month: Int, day: Int, onOrAfter date: Date, calendar: Calendar) -> Date? {
        let thisYear = calendar.component(.year, from: date)

        for year in [thisYear, thisYear + 1] {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            // A day that does not exist in this year — 29 February — is skipped rather than
            // silently rolled into March.
            guard let candidate = calendar.date(from: components),
                  calendar.component(.month, from: candidate) == month,
                  calendar.component(.day, from: candidate) == day
            else { continue }

            if candidate >= date { return candidate }
        }
        return nil
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
        case .monthDay(let month, let day): Self.monthDayName(month: month, day: day)
        }
    }

    static func monthDayName(month: Int, day: Int) -> String {
        let names = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]
        guard (1...12).contains(month) else { return "\(day)" }
        return "\(names[month - 1]) \(day)"
    }

    static func weekdayName(_ weekday: Int) -> String? {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard (1...7).contains(weekday) else { return nil }
        return names[weekday - 1]
    }
}

/// A time of day, on no particular day.
///
/// Separate from ``DateExpression`` because the two are answers to different questions and are
/// usually given separately: `due:friday` is a day with no time, `from:9am` is a time with no day.
public struct TimeOfDay: Sendable, Hashable {
    /// 0–23.
    public let hour: Int
    /// 0–59.
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// `9:05`, `14:30` — always 24-hour, so it reads the same everywhere.
    public var summary: String {
        String(format: "%d:%02d", hour, minute)
    }
}

/// A day, optionally at a time — what a whole phrase such as `tomorrow 3pm` means.
public struct DateInterpretation: Sendable, Hashable {
    public var day: DateExpression
    public var time: TimeOfDay?

    public init(day: DateExpression, time: TimeOfDay? = nil) {
        self.day = day
        self.time = time
    }

    public func resolve(using dateProvider: any DateProvider) -> Date? {
        day.resolve(using: dateProvider, at: time)
    }

    public var summary: String {
        guard let time else { return day.summary }
        return "\(day.summary) at \(time.summary)"
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

    private static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6,
        "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// Interprets a whole phrase — `tomorrow 3pm`, `next Tuesday`, `in 2 weeks`, `August 12`.
    ///
    /// Returns `nil` unless a **day** was understood. A bare time is not a date, and treating
    /// `3pm` as "today at 3pm" would be a guess the user did not make.
    public static func interpret(_ phrase: String) -> DateInterpretation? {
        let words = phrase.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        // The time, if any, is at the end. Taking it off first leaves a clean day phrase.
        var dayWords = words
        var time: TimeOfDay?
        if let last = dayWords.last, let parsed = parseTimeOfDay(last) {
            time = parsed
            dayWords.removeLast()
            // "3pm" on its own, or "at 3pm".
            if dayWords.last == "at" { dayWords.removeLast() }
        }

        guard !dayWords.isEmpty, let day = parseDayPhrase(dayWords) else { return nil }
        return DateInterpretation(day: day, time: time)
    }

    /// `9am`, `3pm`, `10:30am`, `14:30`, `9.30pm`.
    public static func parseTimeOfDay(_ token: String) -> TimeOfDay? {
        var text = token.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
            break
        }

        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0])
        else { return nil }

        let minute = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        // Without am/pm a bare number is not a time — "3" in a sentence is not three o'clock.
        guard let meridiem else {
            guard parts.count == 2, text.contains(":") else { return nil }
            return TimeOfDay(hour: hour, minute: minute)
        }

        guard (1...12).contains(hour) else { return nil }
        if meridiem == "pm", hour != 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        return TimeOfDay(hour: hour, minute: minute)
    }

    /// The day half of a phrase, already lowercased and split.
    private static func parseDayPhrase(_ words: [String]) -> DateExpression? {
        if words.count == 1 { return parse(words[0]) }

        // "next tuesday", "next week"
        if words.count == 2, words[0] == "next" {
            if words[1] == "week" { return .weekOffset(1) }
            if let weekday = weekdayNames[words[1]] { return .nextWeekday(weekday) }
            return nil
        }

        // "in 2 weeks", "in 3 days"
        if words.count == 3, words[0] == "in", let magnitude = Int(words[1]), magnitude >= 0 {
            switch words[2] {
            case "day", "days": return .dayOffset(magnitude)
            case "week", "weeks": return .weekOffset(magnitude)
            default: return nil
            }
        }

        // "august 12" and "12 august", with an optional ordinal or comma — "august 12th".
        if words.count == 2 {
            let stripped = words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            if let month = monthNames[stripped[0]], let day = dayNumber(stripped[1]) {
                return .monthDay(month: month, day: day)
            }
            if let month = monthNames[stripped[1]], let day = dayNumber(stripped[0]) {
                return .monthDay(month: month, day: day)
            }
        }

        return nil
    }

    /// `12`, `12th`, `1st`, `3rd`.
    private static func dayNumber(_ token: String) -> Int? {
        var text = token
        for suffix in ["st", "nd", "rd", "th"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(2))
            break
        }
        guard let value = Int(text), (1...31).contains(value) else { return nil }
        return value
    }

    /// Interprets a token such as `today`, `tue`, `+3d`, `2w`, or `2026-08-14`.
    ///
    /// Returns `nil` for anything not in the vocabulary — the caller keeps the text.
    public static func parse(_ token: String) -> DateExpression? {
        let normalized = token
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        // A multi-word phrase reaching the single-token entry point still works.
        if normalized.contains(where: \.isWhitespace) {
            return interpret(normalized)?.day
        }

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
