import ElephruitCore
import Foundation
import Testing

/// Recurrence, tested against the cases that actually go wrong.
///
/// Every test here is a date arithmetic bug that ships in real calendars: an appointment that moves
/// by an hour twice a year, a monthly review that skips February, a birthday that vanishes in a
/// common year. None of them is caught by a test that repeats something weekly and counts to four.
@Suite("Event recurrence")
struct EventRecurrenceTests {
    /// A calendar in a zone that observes daylight saving, because a UTC calendar cannot show the
    /// bug these tests exist for.
    private static func newYork() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }

    private static func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 9, _ minute: Int = 0,
        in calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    // MARK: Daylight saving

    @Test("A daily 9am event stays at 9am across the spring-forward boundary")
    func dailyKeepsWallClockTimeAcrossSpringForward() {
        let calendar = Self.newYork()
        // Clocks go forward on 8 March 2026 in the United States.
        let start = Self.date(2026, 3, 6, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily)
            .occurrences(startingAt: start, calendar: calendar, limit: 6)

        #expect(occurrences.count == 6)
        for occurrence in occurrences {
            let hour = calendar.component(.hour, from: occurrence)
            #expect(hour == 9, """
                An event that slides to 8am or 10am when the clocks change is the single most \
                reported calendar bug there is: \(occurrence)
                """)
        }
    }

    @Test("A weekly event stays at its time across the autumn-back boundary")
    func weeklyKeepsWallClockTimeAcrossFallBack() {
        let calendar = Self.newYork()
        // Clocks go back on 1 November 2026.
        let start = Self.date(2026, 10, 20, 14, 30, in: calendar)

        let occurrences = EventRecurrence(frequency: .weekly, daysOfWeek: [.init(3)])
            .occurrences(startingAt: start, calendar: calendar, limit: 5)

        for occurrence in occurrences {
            let components = calendar.dateComponents([.hour, .minute], from: occurrence)
            #expect(components.hour == 14 && components.minute == 30)
        }
    }

    @Test("An event during the hour that does not exist lands on a real instant")
    func nonexistentLocalTimeResolves() {
        let calendar = Self.newYork()
        // 02:30 on 8 March 2026 never happens: the clock goes from 02:00 to 03:00.
        let start = Self.date(2026, 3, 7, 2, 30, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily)
            .occurrences(startingAt: start, calendar: calendar, limit: 3)

        #expect(occurrences.count == 3, "A missing hour must not silently drop an occurrence")
        // The one on the eighth is pushed to the next instant that exists rather than being invented.
        let eighth = occurrences.first { calendar.component(.day, from: $0) == 8 }
        #expect(eighth != nil)
        if let eighth {
            let hour = calendar.component(.hour, from: eighth)
            #expect(hour == 3, "The standard resolution is the next valid time, which is 3am")
        }
    }

    // MARK: End of month

    @Test("Monthly on the 31st lands on the last day of shorter months")
    func monthlyOnThe31stClamps() {
        let calendar = Self.utc()
        let start = Self.date(2026, 1, 31, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .monthly, daysOfMonth: [31])
            .occurrences(startingAt: start, calendar: calendar, limit: 4)

        let days = occurrences.map { calendar.component(.day, from: $0) }
        let months = occurrences.map { calendar.component(.month, from: $0) }

        #expect(months == [1, 2, 3, 4])
        #expect(days == [31, 28, 31, 30], """
            "The 31st" in February means the 28th. Rolling into March would move a rent payment \
            into the wrong month: \(days)
            """)
    }

    @Test("Monthly on the 31st reaches 29 February in a leap year")
    func monthlyClampsToLeapDay() {
        let calendar = Self.utc()
        let start = Self.date(2028, 1, 31, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .monthly, daysOfMonth: [31])
            .occurrences(startingAt: start, calendar: calendar, limit: 2)

        #expect(occurrences.count == 2)
        #expect(calendar.component(.day, from: occurrences[1]) == 29)
    }

    @Test("The last day of the month is expressible and follows the month's length")
    func lastDayOfMonth() {
        let calendar = Self.utc()
        let start = Self.date(2026, 1, 31, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .monthly, daysOfMonth: [-1])
            .occurrences(startingAt: start, calendar: calendar, limit: 3)

        let days = occurrences.map { calendar.component(.day, from: $0) }
        #expect(days == [31, 28, 31])
    }

    // MARK: Leap years

    @Test("A yearly event on 29 February happens only in leap years")
    func leapDayYearlySkipsCommonYears() {
        let calendar = Self.utc()
        let start = Self.date(2028, 2, 29, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .yearly)
            .occurrences(startingAt: start, calendar: calendar, limit: 3)

        let years = occurrences.map { calendar.component(.year, from: $0) }
        #expect(years == [2028, 2032, 2036], """
            A leap-day anniversary must not appear on 1 March in a common year — that is an \
            appointment nobody made: \(years)
            """)

        for occurrence in occurrences {
            #expect(calendar.component(.month, from: occurrence) == 2)
            #expect(calendar.component(.day, from: occurrence) == 29)
        }
    }

    // MARK: Weekdays

    @Test("Specific weekdays produce every chosen day of every week")
    func weeklyOnSeveralWeekdays() {
        let calendar = Self.utc()
        // A Monday.
        let start = Self.date(2026, 6, 15, 10, 0, in: calendar)

        let occurrences = EventRecurrence(
            frequency: .weekly,
            daysOfWeek: [.init(3), .init(5)]  // Tuesday and Thursday
        ).occurrences(startingAt: start, calendar: calendar, limit: 4)

        let weekdays = occurrences.map { calendar.component(.weekday, from: $0) }
        #expect(weekdays == [3, 5, 3, 5])
        #expect(occurrences[0] > start, "The first occurrence is the first matching day at or after the start")
    }

    @Test("Every weekday skips the weekend")
    func everyWeekday() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .weekly, daysOfWeek: (2...6).map { .init($0) })
            .occurrences(startingAt: start, calendar: calendar, limit: 7)

        let weekdays = Set(occurrences.map { calendar.component(.weekday, from: $0) })
        #expect(!weekdays.contains(1) && !weekdays.contains(7))
    }

    @Test("An interval of two weeks skips the week between")
    func fortnightly() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 16, 9, 0, in: calendar)  // Tuesday

        let occurrences = EventRecurrence(frequency: .weekly, interval: 2, daysOfWeek: [.init(3)])
            .occurrences(startingAt: start, calendar: calendar, limit: 3)

        #expect(occurrences.count == 3)
        let gaps = zip(occurrences, occurrences.dropFirst()).map { $1.timeIntervalSince($0) }
        for gap in gaps {
            #expect(abs(gap - 14 * 86_400) < 3_600, "Two weeks, give or take a daylight-saving hour")
        }
    }

    // MARK: Ordinal weekdays

    @Test("The third Thursday of every month")
    func thirdThursdayMonthly() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 18, 9, 0, in: calendar)  // The third Thursday of June 2026

        let occurrences = EventRecurrence(frequency: .monthly, daysOfWeek: [.init(5, weekNumber: 3)])
            .occurrences(startingAt: start, calendar: calendar, limit: 3)

        for occurrence in occurrences {
            #expect(calendar.component(.weekday, from: occurrence) == 5)
            let day = calendar.component(.day, from: occurrence)
            #expect((15...21).contains(day), "The third of any weekday always falls in that window")
        }
    }

    @Test("The last Friday of every month, including five-Friday months")
    func lastFridayMonthly() {
        let calendar = Self.utc()
        let start = Self.date(2026, 1, 30, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .monthly, daysOfWeek: [.init(6, weekNumber: -1)])
            .occurrences(startingAt: start, calendar: calendar, limit: 6)

        for occurrence in occurrences {
            #expect(calendar.component(.weekday, from: occurrence) == 6)

            guard let range = calendar.range(of: .day, in: .month, for: occurrence) else { continue }
            let day = calendar.component(.day, from: occurrence)
            #expect(day + 7 > range.count, "A last Friday has no Friday after it in the same month")
        }
    }

    @Test("An ordinal position reads the last occurrence as last, not as fourth")
    func ordinalPositionPrefersLast() {
        let calendar = Self.utc()

        // 26 June 2026 is the fourth *and* final Friday of the month.
        let lastFriday = Self.date(2026, 6, 26, 9, 0, in: calendar)
        #expect(EventRecurrence.ordinalPosition(of: lastFriday, calendar: calendar) == -1)

        // 11 June is unambiguously the second Thursday.
        let secondThursday = Self.date(2026, 6, 11, 9, 0, in: calendar)
        #expect(EventRecurrence.ordinalPosition(of: secondThursday, calendar: calendar) == 2)
    }

    // MARK: Ends

    @Test("A count limits the series exactly")
    func occurrenceCountEnds() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily, end: .afterOccurrences(3))
            .occurrences(startingAt: start, calendar: calendar, limit: 100)

        #expect(occurrences.count == 3, "Ten times means ten, and the first one counts")
    }

    @Test("A count is honoured when one cycle produces several occurrences")
    func occurrenceCountAcrossMultiDayCycles() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)

        // Three days a week, stopping after five — which falls in the middle of the second week.
        let occurrences = EventRecurrence(
            frequency: .weekly,
            daysOfWeek: [.init(2), .init(4), .init(6)],
            end: .afterOccurrences(5)
        ).occurrences(startingAt: start, calendar: calendar, limit: 100)

        #expect(occurrences.count == 5)
        #expect(occurrences == occurrences.sorted())
    }

    @Test("An end date excludes everything after it")
    func endDateEnds() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)
        let last = Self.date(2026, 6, 18, 23, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily, end: .onDate(last))
            .occurrences(startingAt: start, calendar: calendar, limit: 100)

        #expect(occurrences.count == 4)
        #expect(occurrences.allSatisfy { $0 <= last })
    }

    @Test("An unbounded series is bounded by the caller, not by luck")
    func neverEndingSeriesRespectsLimit() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily).occurrences(
            startingAt: start, calendar: calendar, limit: 12
        )
        #expect(occurrences.count == 12)
    }

    @Test("A window stops the generator early")
    func windowStopsGeneration() {
        let calendar = Self.utc()
        let start = Self.date(2026, 6, 15, 9, 0, in: calendar)
        let until = Self.date(2026, 6, 20, 9, 0, in: calendar)

        let occurrences = EventRecurrence(frequency: .daily).occurrences(
            startingAt: start, calendar: calendar, limit: 500, notAfter: until
        )
        #expect(occurrences.count == 6)
    }

    // MARK: Description

    @Test("A rule describes itself in a sentence somebody could have said")
    func summariesReadAsEnglish() {
        #expect(EventRecurrence(frequency: .daily).summary == "Daily")
        #expect(EventRecurrence(frequency: .weekly, interval: 2).summary == "Every 2 weeks")

        let tuesdays = EventRecurrence(frequency: .weekly, daysOfWeek: [.init(3)])
        #expect(tuesdays.summary.contains("Tuesday"))

        let thirdThursday = EventRecurrence(frequency: .monthly, daysOfWeek: [.init(5, weekNumber: 3)])
        #expect(thirdThursday.summary.contains("third Thursday"))

        let counted = EventRecurrence(frequency: .daily, end: .afterOccurrences(1))
        #expect(counted.summary.hasSuffix("1 time"), "One occurrence is not “1 times”")
    }

    @Test("A rule survives being stored and read back")
    func rulesRoundTrip() throws {
        let original = EventRecurrence(
            frequency: .monthly,
            interval: 3,
            daysOfWeek: [.init(2, weekNumber: -1)],
            end: .afterOccurrences(7)
        )
        let restored = EventRecurrence.decode(from: original.encoded())
        #expect(restored == original)
    }

    @Test("Unreadable stored recurrence is no recurrence rather than a failure")
    func corruptRecurrenceDecodesToNil() {
        #expect(EventRecurrence.decode(from: Data([0x00, 0x01])) == nil)
        #expect(EventRecurrence.decode(from: nil) == nil)
    }

    @Test("An interval below one is corrected rather than trusted")
    func intervalIsClamped() {
        #expect(EventRecurrence(frequency: .daily, interval: 0).interval == 1)
        #expect(EventRecurrence(frequency: .daily, interval: -4).interval == 1)
    }

    @Test("Presets are built from the day the event is actually on")
    func presetsFollowTheStartDate() {
        let calendar = Self.utc()
        let thursday = Self.date(2026, 6, 18, 9, 0, in: calendar)

        let presets = EventRecurrence.presets(for: thursday, calendar: calendar)
        #expect(presets.contains { $0.label == "Every Week" })

        let weekly = presets.first { $0.label == "Every Week" }?.rule
        #expect(weekly?.daysOfWeek.first?.weekday == 5, "“Every week” means every Thursday for a Thursday event")

        #expect(presets.contains { $0.label.contains("third Thursday") })
    }

    // MARK: Scope

    @Test("Every editing scope explains what it will actually do")
    func scopesExplainThemselves() {
        for scope in EventEditScope.offered {
            #expect(!scope.displayName.isEmpty)
            #expect(scope.explanation(deleting: true).contains("Removes"))
            #expect(scope.explanation(deleting: false).contains("Changes"))
        }
        #expect(EventEditScope.offered.first == .thisEvent, "The safest choice is offered first")
    }
}
