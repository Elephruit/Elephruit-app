import Foundation

/// How a repeating task repeats.
///
/// A value type, JSON-encoded into a single `Data` column, because recurrence is read
/// and written as a whole and is never queried field-by-field. Keeping it out of the
/// schema also means adding a frequency in a later version is not a migration.
///
/// Deliberately narrower than `RFC 5545`: no `BYSETPOS`, no `BYYEARDAY`, no
/// exceptions list. Those exist to describe other people's calendars; this describes
/// one person's habits, and the difference is a great deal of complexity.
public struct RecurrenceRule: Sendable, Hashable, Codable {
    /// How often the base unit repeats.
    public enum Frequency: String, Sendable, Hashable, Codable, CaseIterable {
        case daily
        case weekly
        case monthly
        case yearly

        public var displayName: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .daily: .day
            case .weekly: .weekOfYear
            case .monthly: .month
            case .yearly: .year
            }
        }
    }

    /// What the next occurrence is measured from.
    ///
    /// The distinction matters and most apps get it wrong. "Pay rent monthly" is
    /// anchored to the *schedule* — being late does not move next month's rent. "Water
    /// the plants every 3 days" is anchored to *completion* — the clock starts when you
    /// last did it.
    public enum Anchor: String, Sendable, Hashable, Codable, CaseIterable {
        /// Next occurrence is computed from the previous scheduled date.
        case schedule

        /// Next occurrence is computed from when the task was actually completed.
        case completion

        public var displayName: String {
            switch self {
            case .schedule: "From scheduled date"
            case .completion: "From completion date"
            }
        }
    }

    /// When the series stops.
    public enum End: Sendable, Hashable, Codable {
        case never
        case onDate(Date)
        case afterOccurrences(Int)
    }

    public var frequency: Frequency

    /// Repeat every `interval` units. Always at least 1; clamped on init.
    public var interval: Int

    /// For ``Frequency/weekly``: which weekdays, using `Calendar`'s 1-based numbering
    /// where 1 is Sunday. Empty means "the same weekday as the anchor date".
    public var weekdays: Set<Int>

    /// For ``Frequency/monthly``: which day of the month. `nil` means "the same day as
    /// the anchor date". Values beyond a month's length clamp to its last day, so
    /// "the 31st" behaves sensibly in February.
    public var dayOfMonth: Int?

    public var anchor: Anchor
    public var end: End

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: Set<Int> = [],
        dayOfMonth: Int? = nil,
        anchor: Anchor = .schedule,
        end: End = .never
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.dayOfMonth = dayOfMonth.map { min(max($0, 1), 31) }
        self.anchor = anchor
        self.end = end
    }

    // MARK: - Occurrence calculation

    /// The next occurrence strictly after `date`, or `nil` if the series has ended.
    ///
    /// - Parameters:
    ///   - date: The reference point — the previous scheduled date for
    ///     ``Anchor/schedule``, or the completion date for ``Anchor/completion``.
    ///   - occurrencesSoFar: How many occurrences the series has already produced,
    ///     used to evaluate ``End/afterOccurrences(_:)``.
    ///   - calendar: Injected so tests need not depend on the machine's locale.
    public func nextOccurrence(
        after date: Date,
        occurrencesSoFar: Int = 0,
        calendar: Calendar
    ) -> Date? {
        if case .afterOccurrences(let limit) = end, occurrencesSoFar >= limit {
            return nil
        }

        guard let candidate = computeNext(after: date, calendar: calendar) else { return nil }

        if case .onDate(let last) = end, candidate > last {
            return nil
        }

        return candidate
    }

    private func computeNext(after date: Date, calendar: Calendar) -> Date? {
        switch frequency {
        case .weekly where !weekdays.isEmpty:
            nextWeekdayOccurrence(after: date, calendar: calendar)
        case .monthly where dayOfMonth != nil:
            nextMonthDayOccurrence(after: date, calendar: calendar)
        default:
            calendar.date(byAdding: frequency.component, value: interval, to: date)
        }
    }

    /// Walks forward day by day to the next selected weekday, respecting `interval`
    /// weeks. Bounded to a year so a malformed rule cannot spin.
    private func nextWeekdayOccurrence(after date: Date, calendar: Calendar) -> Date? {
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: date)?.start
        var cursor = date

        for _ in 0..<366 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next

            guard weekdays.contains(calendar.component(.weekday, from: cursor)) else { continue }

            // With interval > 1, only accept days in an "on" week.
            guard interval > 1, let startOfWeek else { return cursor }

            guard let candidateWeekStart = calendar.dateInterval(of: .weekOfYear, for: cursor)?.start,
                  let weeksElapsed = calendar.dateComponents([.weekOfYear], from: startOfWeek, to: candidateWeekStart).weekOfYear
            else { return cursor }

            if weeksElapsed % interval == 0 { return cursor }
        }

        return nil
    }

    /// Advances whole months, then clamps the requested day to the month's length so
    /// "the 31st" lands on 28 or 29 February rather than vanishing.
    private func nextMonthDayOccurrence(after date: Date, calendar: Calendar) -> Date? {
        guard let requestedDay = dayOfMonth else { return nil }

        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let timeOfDay = (hour: components.hour ?? 0, minute: components.minute ?? 0, second: components.second ?? 0)

        // Try the requested day in the current month first; if it has already passed,
        // move on by `interval` months.
        components.day = 1
        guard let monthStart = calendar.date(from: components) else { return nil }

        var monthCursor = monthStart
        for _ in 0..<(12 * 20) {
            guard let range = calendar.range(of: .day, in: .month, for: monthCursor) else { return nil }
            let clampedDay = min(requestedDay, range.count)

            var candidateComponents = calendar.dateComponents([.year, .month], from: monthCursor)
            candidateComponents.day = clampedDay
            candidateComponents.hour = timeOfDay.hour
            candidateComponents.minute = timeOfDay.minute
            candidateComponents.second = timeOfDay.second

            if let candidate = calendar.date(from: candidateComponents), candidate > date {
                return candidate
            }

            guard let advanced = calendar.date(byAdding: .month, value: interval, to: monthCursor) else { return nil }
            monthCursor = advanced
        }

        return nil
    }

    // MARK: - Description

    /// A short human summary — "Every 2 weeks", "Monthly on the 15th".
    public var summary: String {
        let unit: String = switch frequency {
        case .daily: interval == 1 ? "day" : "days"
        case .weekly: interval == 1 ? "week" : "weeks"
        case .monthly: interval == 1 ? "month" : "months"
        case .yearly: interval == 1 ? "year" : "years"
        }

        var text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)"

        if frequency == .weekly, !weekdays.isEmpty {
            let names = weekdays.sorted().compactMap(Self.weekdayName)
            if !names.isEmpty {
                text += " on " + names.formatted(.list(type: .and))
            }
        }

        if frequency == .monthly, let dayOfMonth {
            text += " on day \(dayOfMonth)"
        }

        switch end {
        case .never: break
        case .onDate: text += ", until a set date"
        case .afterOccurrences(let count): text += ", \(count) times"
        }

        return text
    }

    private static func weekdayName(_ weekday: Int) -> String? {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard (1...7).contains(weekday) else { return nil }
        return names[weekday - 1]
    }
}

// MARK: - Coding

extension RecurrenceRule {
    /// Decodes a rule from its stored representation.
    ///
    /// Returns `nil` rather than throwing for absent or unreadable data: a task whose
    /// recurrence cannot be read is still a perfectly good task, and losing the rule is
    /// preferable to failing to show the task at all.
    public static func decode(from data: Data?) -> RecurrenceRule? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(RecurrenceRule.self, from: data)
    }

    /// Encodes for storage. Returns `nil` on failure, which the caller stores as "no
    /// recurrence" — never as a corrupt blob.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
