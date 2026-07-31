import Foundation

/// How a calendar event repeats.
///
/// ### Why this is not ``RecurrenceRule``
/// ``RecurrenceRule`` describes how a *task* repeats, and its defining feature is
/// ``RecurrenceRule/Anchor`` — the distinction between "pay rent monthly" and "water the plants
/// three days after I last did". That distinction does not exist in a calendar: an event's next
/// occurrence is never computed from when you completed it, because you do not complete an event.
///
/// Conversely this needs everything RFC 5545 gives a calendar and a task does not: ordinal weekdays
/// ("the third Thursday"), months of the year, and a shape that maps onto `EKRecurrenceRule` without
/// loss in either direction. Forcing one type to serve both would mean a task growing fields it can
/// never use and an event losing the ones it needs, so they are two types with one shared vocabulary
/// of frequencies. Standing rule R5 asks for proof that the existing shape cannot do the job; the
/// missing anchor and the missing ordinal weekday are that proof.
public struct EventRecurrence: Sendable, Hashable, Codable {
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

        /// The singular unit name, for "every 2 weeks".
        public var unitName: String {
            switch self {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
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

    /// A weekday, optionally pinned to an ordinal position within the month or year.
    ///
    /// `weekNumber` is EventKit's own convention: `0` means every occurrence of that weekday,
    /// `1...5` counts from the start, and `-1...-5` counts from the end — so "the last Friday of the
    /// month" is `weekday: 6, weekNumber: -1`.
    public struct DayOfWeek: Sendable, Hashable, Codable, Identifiable {
        /// 1 is Sunday, matching `Calendar`'s numbering.
        public var weekday: Int
        public var weekNumber: Int

        public var id: String { "\(weekday):\(weekNumber)" }

        public init(_ weekday: Int, weekNumber: Int = 0) {
            self.weekday = min(max(weekday, 1), 7)
            self.weekNumber = min(max(weekNumber, -5), 5)
        }

        public var weekdayName: String {
            DateExpression.weekdayName(weekday) ?? "Day"
        }

        public var displayName: String {
            guard weekNumber != 0 else { return weekdayName }
            return "\(Self.ordinalName(weekNumber)) \(weekdayName)"
        }

        public static func ordinalName(_ position: Int) -> String {
            switch position {
            case 1: "first"
            case 2: "second"
            case 3: "third"
            case 4: "fourth"
            case 5: "fifth"
            case -1: "last"
            case -2: "second to last"
            default: "\(abs(position))th"
            }
        }
    }

    /// When the series stops.
    public enum End: Sendable, Hashable, Codable {
        case never
        case onDate(Date)
        case afterOccurrences(Int)

        public var isNever: Bool {
            if case .never = self { return true }
            return false
        }
    }

    public var frequency: Frequency

    /// Repeat every `interval` units. Always at least 1; clamped on init.
    public var interval: Int

    /// Which weekdays, for weekly rules and for ordinal monthly and yearly ones.
    public var daysOfWeek: [DayOfWeek]

    /// Which days of the month, 1–31 or −1 for the last day.
    public var daysOfMonth: [Int]

    /// Which months, 1–12. Only meaningful for a yearly rule.
    public var monthsOfYear: [Int]

    public var end: End

    public init(
        frequency: Frequency,
        interval: Int = 1,
        daysOfWeek: [DayOfWeek] = [],
        daysOfMonth: [Int] = [],
        monthsOfYear: [Int] = [],
        end: End = .never
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth.filter { (1...31).contains(abs($0)) && $0 != 0 }
        self.monthsOfYear = monthsOfYear.filter { (1...12).contains($0) }
        self.end = end
    }

    // MARK: - Presets

    /// The rules a picker offers before anyone reaches for "Custom…".
    ///
    /// Built from a start date because "every Tuesday" and "monthly on the third Thursday" are only
    /// expressible once you know which day the event is on.
    public static func presets(for start: Date, calendar: Calendar) -> [(label: String, rule: EventRecurrence)] {
        let weekday = calendar.component(.weekday, from: start)
        let day = calendar.component(.day, from: start)
        let ordinal = ordinalPosition(of: start, calendar: calendar)

        var presets: [(String, EventRecurrence)] = [
            ("Every Day", EventRecurrence(frequency: .daily)),
            ("Every Week", EventRecurrence(frequency: .weekly, daysOfWeek: [DayOfWeek(weekday)])),
            ("Every 2 Weeks", EventRecurrence(frequency: .weekly, interval: 2, daysOfWeek: [DayOfWeek(weekday)])),
            ("Every Month", EventRecurrence(frequency: .monthly, daysOfMonth: [day])),
        ]

        if let ordinal {
            presets.append((
                "Monthly on the \(DayOfWeek.ordinalName(ordinal)) \(DateExpression.weekdayName(weekday) ?? "day")",
                EventRecurrence(frequency: .monthly, daysOfWeek: [DayOfWeek(weekday, weekNumber: ordinal)])
            ))
        }

        presets.append(("Every Year", EventRecurrence(frequency: .yearly)))
        presets.append(("Every Weekday", EventRecurrence(
            frequency: .weekly,
            daysOfWeek: (2...6).map { DayOfWeek($0) }
        )))

        return presets.map { (label: $0.0, rule: $0.1) }
    }

    /// Which occurrence of its weekday within its month a date is — 1st, 2nd, …, or −1 for the last.
    ///
    /// The last-of-month reading wins when a date is both the fourth and the final one, because
    /// "the last Friday" is what a person means when they set up a monthly review on 29 August.
    public static func ordinalPosition(of date: Date, calendar: Calendar) -> Int? {
        let day = calendar.component(.day, from: date)
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return nil }

        let position = ((day - 1) / 7) + 1
        let isLast = day + 7 > range.count
        return isLast ? -1 : position
    }

    // MARK: - Occurrences

    /// The occurrence start dates of this series, beginning with `start` itself.
    ///
    /// Generated rather than fetched, so the recurrence editor can show what a rule will actually do
    /// before it is saved, and so the awkward cases — a 31st in February, a 29 February yearly, an
    /// hour that does not exist on the morning the clocks go forward — can be asserted in tests
    /// rather than discovered by a user.
    ///
    /// - Parameters:
    ///   - start: The series' first occurrence.
    ///   - calendar: Injected, so the answer does not depend on the machine's locale.
    ///   - limit: A hard ceiling. A malformed rule cannot spin, and an unbounded series is asked for
    ///     a page at a time.
    ///   - notAfter: Stops early once occurrences pass this date, for filling one visible window.
    public func occurrences(
        startingAt start: Date,
        calendar: Calendar,
        limit: Int = 200,
        notAfter: Date? = nil
    ) -> [Date] {
        guard limit > 0 else { return [] }

        var results: [Date] = []
        var cycle = 0
        // Enough cycles to fill any window a view asks for, without letting a rule that matches
        // nothing run away.
        let cycleCeiling = 1_200

        while results.count < limit, cycle < cycleCeiling {
            let candidates = occurrences(inCycle: cycle, startingAt: start, calendar: calendar)

            for candidate in candidates where candidate >= start {
                if let notAfter, candidate > notAfter { return trimmed(results) }
                if case .onDate(let last) = end, candidate > last { return trimmed(results) }

                results.append(candidate)
                if results.count >= limit { return trimmed(results) }
                if case .afterOccurrences(let count) = end, results.count >= count {
                    return trimmed(results)
                }
            }

            cycle += 1
        }

        return trimmed(results)
    }

    /// Applies the occurrence-count limit, which cannot be checked while candidates are still being
    /// gathered out of order within a cycle.
    private func trimmed(_ dates: [Date]) -> [Date] {
        let sorted = dates.sorted()
        guard case .afterOccurrences(let count) = end else { return sorted }
        return Array(sorted.prefix(max(0, count)))
    }

    /// Every occurrence produced by one turn of the rule — one day, one week, one month, one year.
    private func occurrences(inCycle cycle: Int, startingAt start: Date, calendar: Calendar) -> [Date] {
        switch frequency {
        case .daily:
            guard let date = calendar.date(byAdding: .day, value: cycle * interval, to: start) else { return [] }
            return [date]

        case .weekly:
            return weeklyOccurrences(inCycle: cycle, startingAt: start, calendar: calendar)

        case .monthly:
            return monthlyOccurrences(inCycle: cycle, startingAt: start, calendar: calendar)

        case .yearly:
            return yearlyOccurrences(inCycle: cycle, startingAt: start, calendar: calendar)
        }
    }

    private func weeklyOccurrences(inCycle cycle: Int, startingAt start: Date, calendar: Calendar) -> [Date] {
        guard let anchor = calendar.date(byAdding: .weekOfYear, value: cycle * interval, to: start) else {
            return []
        }
        guard !daysOfWeek.isEmpty else { return [anchor] }

        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [anchor] }

        return daysOfWeek
            .map(\.weekday)
            .compactMap { weekday -> Date? in
                let offset = (weekday - calendar.component(.weekday, from: weekStart) + 7) % 7
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                return Self.applyingTime(of: start, to: day, calendar: calendar)
            }
            .sorted()
    }

    private func monthlyOccurrences(inCycle cycle: Int, startingAt start: Date, calendar: Calendar) -> [Date] {
        guard let anchor = calendar.date(byAdding: .month, value: cycle * interval, to: start) else { return [] }

        if !daysOfWeek.isEmpty {
            return ordinalWeekdayOccurrences(inMonthOf: anchor, timeFrom: start, calendar: calendar)
        }

        let days = daysOfMonth.isEmpty ? [calendar.component(.day, from: start)] : daysOfMonth
        return days
            .compactMap { day in Self.date(day: day, inMonthOf: anchor, timeFrom: start, calendar: calendar) }
            .sorted()
    }

    private func yearlyOccurrences(inCycle cycle: Int, startingAt start: Date, calendar: Calendar) -> [Date] {
        guard let anchor = calendar.date(byAdding: .year, value: cycle * interval, to: start) else { return [] }

        let months = monthsOfYear.isEmpty ? [calendar.component(.month, from: start)] : monthsOfYear
        var results: [Date] = []

        for month in months {
            var components = calendar.dateComponents([.year], from: anchor)
            components.month = month
            components.day = 1
            guard let monthStart = calendar.date(from: components) else { continue }

            if !daysOfWeek.isEmpty {
                results.append(
                    contentsOf: ordinalWeekdayOccurrences(inMonthOf: monthStart, timeFrom: start, calendar: calendar)
                )
            } else {
                let day = daysOfMonth.first ?? calendar.component(.day, from: start)
                // A 29 February yearly event simply does not occur in a common year. Skipping it is
                // the only honest reading — rolling it to 1 March invents an appointment.
                if let date = Self.date(day: day, inMonthOf: monthStart, timeFrom: start, calendar: calendar, clamping: false) {
                    results.append(date)
                }
            }
        }

        return results.sorted()
    }

    /// "The third Thursday" and "the last Friday", inside the month containing `anchor`.
    private func ordinalWeekdayOccurrences(inMonthOf anchor: Date, timeFrom start: Date, calendar: Calendar) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor),
              let dayCount = calendar.range(of: .day, in: .month, for: anchor)?.count
        else { return [] }

        var results: [Date] = []

        for entry in daysOfWeek {
            var matching: [Date] = []
            for offset in 0..<dayCount {
                guard let day = calendar.date(byAdding: .day, value: offset, to: monthInterval.start) else { continue }
                if calendar.component(.weekday, from: day) == entry.weekday { matching.append(day) }
            }

            let chosen: [Date]
            switch entry.weekNumber {
            case 0: chosen = matching
            case 1...: chosen = matching.count >= entry.weekNumber ? [matching[entry.weekNumber - 1]] : []
            default:
                let fromEnd = -entry.weekNumber
                chosen = matching.count >= fromEnd ? [matching[matching.count - fromEnd]] : []
            }

            results.append(contentsOf: chosen.compactMap { Self.applyingTime(of: start, to: $0, calendar: calendar) })
        }

        return results.sorted()
    }

    /// A given day within the month containing `anchor`, carrying `start`'s time of day.
    ///
    /// - Parameter clamping: When `true`, a day beyond the month's length lands on its last day —
    ///   which is what "monthly on the 31st" should do in February. When `false`, it produces nothing,
    ///   which is what a 29 February yearly event should do in a common year. The two cases genuinely
    ///   differ and one rule for both would be wrong for one of them.
    static func date(
        day: Int,
        inMonthOf anchor: Date,
        timeFrom start: Date,
        calendar: Calendar,
        clamping: Bool = true
    ) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: anchor) else { return nil }

        let resolved: Int
        if day < 0 {
            resolved = range.count + day + 1
        } else if day > range.count {
            guard clamping else { return nil }
            resolved = range.count
        } else {
            resolved = day
        }
        guard resolved >= 1 else { return nil }

        var components = calendar.dateComponents([.year, .month], from: anchor)
        components.day = resolved
        guard let base = calendar.date(from: components) else { return nil }
        return applyingTime(of: start, to: base, calendar: calendar)
    }

    /// Puts `source`'s wall-clock time onto `day`.
    ///
    /// Built by asking `Calendar` for that hour on that day rather than by adding seconds, so a day
    /// on which the clocks change keeps the appointment at nine in the morning rather than sliding it
    /// to eight or ten. When the hour genuinely does not exist — 02:30 on a spring-forward morning —
    /// `Calendar` returns the next valid instant, which is the standard and least surprising answer.
    static func applyingTime(of source: Date, to day: Date, calendar: Calendar) -> Date? {
        let time = calendar.dateComponents([.hour, .minute, .second], from: source)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day,
            matchingPolicy: .nextTime
        )
    }

    // MARK: - Description

    /// A sentence describing the rule — "Every 2 weeks on Tuesday and Thursday, 10 times".
    public var summary: String {
        var text = interval == 1
            ? frequency.displayName
            : "Every \(interval) \(frequency.unitName)s"

        switch frequency {
        case .weekly where !daysOfWeek.isEmpty:
            let names = daysOfWeek.sorted { $0.weekday < $1.weekday }.map(\.weekdayName)
            text += " on " + names.formatted(.list(type: .and))

        case .monthly where !daysOfWeek.isEmpty:
            text += " on the " + daysOfWeek.map { entry in
                entry.weekNumber == 0
                    ? entry.weekdayName
                    : "\(DayOfWeek.ordinalName(entry.weekNumber)) \(entry.weekdayName)"
            }.formatted(.list(type: .and))

        case .monthly where !daysOfMonth.isEmpty:
            text += " on the " + daysOfMonth.map(Self.ordinalDay).formatted(.list(type: .and))

        case .yearly where !monthsOfYear.isEmpty:
            let names = monthsOfYear.sorted().map { DateExpression.monthDayName(month: $0, day: 1) }
                .map { $0.split(separator: " ").first.map(String.init) ?? "" }
            text += " in " + names.formatted(.list(type: .and))

        default:
            break
        }

        switch end {
        case .never:
            break
        case .onDate(let date):
            text += ", until \(date.formatted(date: .abbreviated, time: .omitted))"
        case .afterOccurrences(let count):
            text += ", \(count) time\(count == 1 ? "" : "s")"
        }

        return text
    }

    static func ordinalDay(_ day: Int) -> String {
        if day < 0 { return day == -1 ? "last day" : "\(-day) days from the end" }

        let suffix: String
        switch day % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }
}

// MARK: - Coding

extension EventRecurrence {
    /// Decodes a rule from its stored representation.
    ///
    /// `nil` for absent or unreadable data, on the same terms as ``RecurrenceRule/decode(from:)``:
    /// an event whose recurrence cannot be read is still a perfectly good event.
    public static func decode(from data: Data?) -> EventRecurrence? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(EventRecurrence.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

// MARK: - Editing scope

/// Which occurrences an edit or a deletion applies to.
///
/// Offered explicitly rather than inferred. Guessing here is how somebody loses a year of a series
/// they meant to change one instance of, and the guess is never recoverable because the edit went to
/// a server.
public enum EventEditScope: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case thisEvent
    case thisAndFuture
    case entireSeries

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .thisEvent: "This Event"
        case .thisAndFuture: "This and All Future Events"
        case .entireSeries: "All Events in the Series"
        }
    }

    /// What the choice actually does, for the sentence under the buttons.
    public func explanation(deleting: Bool) -> String {
        let verb = deleting ? "Removes" : "Changes"
        switch self {
        case .thisEvent:
            return "\(verb) only this occurrence. The rest of the series is untouched."
        case .thisAndFuture:
            return "\(verb) this occurrence and every one after it. Earlier occurrences stay as they are."
        case .entireSeries:
            return "\(verb) every occurrence, including ones that have already happened."
        }
    }

    /// The order the choices are offered in, safest first.
    public static var offered: [EventEditScope] {
        [.thisEvent, .thisAndFuture, .entireSeries]
    }
}
