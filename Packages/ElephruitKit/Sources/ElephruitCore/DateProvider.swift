import Foundation

/// Supplies "now" and the calendar to reason about it with.
///
/// Injected rather than read from `Date()` directly so that recurrence, "today", and
/// overdue calculations are testable without touching the machine's clock. Named
/// `DateProvider` rather than `Clock` to avoid shadowing the standard library's
/// `Clock` protocol, which serves an unrelated purpose.
public protocol DateProvider: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

extension DateProvider {
    /// Midnight at the start of today, in the provider's calendar.
    public var startOfToday: Date {
        calendar.startOfDay(for: now)
    }

    /// Midnight at the start of tomorrow — the exclusive upper bound for "today".
    public var startOfTomorrow: Date {
        calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
    }

    /// The half-open interval covering today.
    public var today: Range<Date> {
        startOfToday..<startOfTomorrow
    }

    /// Midnight `days` days from the start of today. Negative values look backwards.
    public func startOfDay(daysFromToday days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: startOfToday) ?? startOfToday
    }

    /// `yyyy-MM-dd` for the given date, used as `Item.dayKey` for daily entries.
    ///
    /// Deliberately not `ISO8601DateFormatter`: this is a *calendar day label* in the
    /// user's own calendar, not an instant, and must not shift with time zone.
    public func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DayKey.string(
            year: components.year ?? 0,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    /// Today's day key.
    public var todayKey: String {
        dayKey(for: now)
    }

    /// Whether `date` falls before the start of today.
    public func isOverdue(_ date: Date) -> Bool {
        date < startOfToday
    }

    /// Whether `date` falls inside today.
    public func isToday(_ date: Date) -> Bool {
        today.contains(date)
    }
}

/// The production provider: the real clock and the user's own calendar.
public struct SystemDateProvider: DateProvider {
    public var now: Date { Date() }
    public var calendar: Calendar { Calendar.autoupdatingCurrent }

    public init() {}
}

/// A provider frozen at a chosen instant, for tests and previews.
public struct FixedDateProvider: DateProvider {
    public let now: Date
    public let calendar: Calendar

    /// - Parameters:
    ///   - now: The instant to freeze at.
    ///   - calendar: Defaults to a Gregorian calendar in GMT with Sunday as the first
    ///     weekday, so tests give the same answer wherever they run.
    public init(now: Date, calendar: Calendar? = nil) {
        self.now = now
        if let calendar {
            self.calendar = calendar
        } else {
            var fixed = Calendar(identifier: .gregorian)
            fixed.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            fixed.firstWeekday = 1
            self.calendar = fixed
        }
    }

    /// A stable reference instant for fixtures: 2026-06-15 09:00:00 GMT, a Monday.
    public static let reference: FixedDateProvider = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 9
        components.timeZone = TimeZone(secondsFromGMT: 0)

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        gregorian.firstWeekday = 1

        // A literal fallback keeps this non-optional without a force unwrap; it is only
        // reached if the components above are made invalid by a future edit.
        let date = gregorian.date(from: components) ?? Date(timeIntervalSince1970: 1_781_514_000)
        return FixedDateProvider(now: date, calendar: gregorian)
    }()
}
