import ElephruitCore
import Foundation
import Testing

/// The date vocabulary the expansion asks for, and the timezone cases nothing covered.
///
/// Every fixture the plan names — `today`, `tomorrow`, `Friday`, `next Tuesday`, `August 12`,
/// `2026-08-12`, `tomorrow 3pm`, `in 2 weeks` — has a deterministic test here.
@Suite("Natural date phrases")
struct NaturalDatePhraseTests {
    private let clock = FixedDateProvider.reference

    // MARK: - The plan's fixtures

    @Test("today")
    func today() {
        #expect(NaturalDateParser.interpret("today")?.day == .today)
    }

    @Test("tomorrow")
    func tomorrow() {
        #expect(NaturalDateParser.interpret("tomorrow")?.day == .tomorrow)
    }

    @Test("Friday")
    func friday() {
        #expect(NaturalDateParser.interpret("Friday")?.day == .nextWeekday(6))
    }

    @Test("next Tuesday")
    func nextTuesday() {
        #expect(NaturalDateParser.interpret("next Tuesday")?.day == .nextWeekday(3))
        #expect(NaturalDateParser.interpret("next week")?.day == .weekOffset(1))
    }

    @Test("August 12")
    func monthAndDay() {
        #expect(NaturalDateParser.interpret("August 12")?.day == .monthDay(month: 8, day: 12))
        #expect(NaturalDateParser.interpret("12 August")?.day == .monthDay(month: 8, day: 12))
        #expect(NaturalDateParser.interpret("aug 12th")?.day == .monthDay(month: 8, day: 12))
    }

    @Test("2026-08-12")
    func isoDate() {
        #expect(NaturalDateParser.interpret("2026-08-12")?.day == .explicit(year: 2026, month: 8, day: 12))
    }

    @Test("tomorrow 3pm")
    func tomorrowAtThree() throws {
        let interpretation = try #require(NaturalDateParser.interpret("tomorrow 3pm"))
        #expect(interpretation.day == .tomorrow)
        #expect(interpretation.time == TimeOfDay(hour: 15, minute: 0))
    }

    @Test("in 2 weeks")
    func inTwoWeeks() {
        #expect(NaturalDateParser.interpret("in 2 weeks")?.day == .weekOffset(2))
        #expect(NaturalDateParser.interpret("in 3 days")?.day == .dayOffset(3))
    }

    // MARK: - Times

    @Test("Times are read the way people write them")
    func timeForms() {
        #expect(NaturalDateParser.parseTimeOfDay("9am") == TimeOfDay(hour: 9, minute: 0))
        #expect(NaturalDateParser.parseTimeOfDay("10:30am") == TimeOfDay(hour: 10, minute: 30))
        #expect(NaturalDateParser.parseTimeOfDay("3pm") == TimeOfDay(hour: 15, minute: 0))
        #expect(NaturalDateParser.parseTimeOfDay("12am") == TimeOfDay(hour: 0, minute: 0))
        #expect(NaturalDateParser.parseTimeOfDay("12pm") == TimeOfDay(hour: 12, minute: 0))
        #expect(NaturalDateParser.parseTimeOfDay("14:30") == TimeOfDay(hour: 14, minute: 30))
        #expect(NaturalDateParser.parseTimeOfDay("9.30pm") == TimeOfDay(hour: 21, minute: 30))
    }

    /// A bare number in a sentence is not a time. "Review 3 documents" must not acquire a deadline.
    @Test("A bare number is not a time")
    func bareNumbersAreNotTimes() {
        #expect(NaturalDateParser.parseTimeOfDay("3") == nil)
        #expect(NaturalDateParser.parseTimeOfDay("2026") == nil)
        #expect(NaturalDateParser.parseTimeOfDay("25pm") == nil)
        #expect(NaturalDateParser.parseTimeOfDay("") == nil)
    }

    /// A time is not a date. Reading `3pm` as "today at 3pm" is a guess the user did not make.
    @Test("A time on its own is not a date")
    func timesAloneAreNotDates() {
        #expect(NaturalDateParser.interpret("3pm") == nil)
        #expect(NaturalDateParser.interpret("") == nil)
        #expect(NaturalDateParser.interpret("someday") == nil)
        #expect(NaturalDateParser.interpret("in 2 fortnights") == nil)
        #expect(NaturalDateParser.interpret("next someday") == nil)
    }

    // MARK: - Resolution

    @Test("A month and day resolve to the next time they come round")
    func monthDayResolvesForward() throws {
        let calendar = clock.calendar
        // Reference is 2026-06-15.
        let august = try #require(DateExpression.monthDay(month: 8, day: 12).resolve(using: clock))
        #expect(calendar.component(.year, from: august) == 2026)
        #expect(calendar.component(.month, from: august) == 8)

        // January has already gone, so it means next year.
        let january = try #require(DateExpression.monthDay(month: 1, day: 5).resolve(using: clock))
        #expect(calendar.component(.year, from: january) == 2027)
    }

    @Test("A time is applied to the resolved day")
    func timeIsApplied() throws {
        let resolved = try #require(
            DateExpression.tomorrow.resolve(using: clock, at: TimeOfDay(hour: 15, minute: 30))
        )
        #expect(clock.calendar.component(.hour, from: resolved) == 15)
        #expect(clock.calendar.component(.minute, from: resolved) == 30)
    }

    @Test("A day with no time resolves to the start of that day")
    func noTimeMeansStartOfDay() throws {
        let resolved = try #require(DateExpression.tomorrow.resolve(using: clock, at: nil))
        #expect(resolved == DateExpression.tomorrow.resolve(using: clock))
    }

    // MARK: - Daylight saving and time zones

    /// The gap. `Calendar` is injected everywhere, so the arithmetic was *probably* right — and
    /// nothing proved it. These are the two days a year when "tomorrow" is not 24 hours away.
    private func provider(timeZone: String, date: DateComponents) -> FixedDateProvider {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        let now = calendar.date(from: date) ?? Date(timeIntervalSince1970: 0)
        return FixedDateProvider(now: now, calendar: calendar)
    }

    @Test("Tomorrow is the next calendar day across a spring-forward transition")
    func springForward() throws {
        // London loses an hour at 01:00 on 2026-03-29, so the 29th is a 23-hour day.
        let clock = provider(
            timeZone: "Europe/London",
            date: DateComponents(year: 2026, month: 3, day: 29, hour: 12)
        )
        let resolved = try #require(DateExpression.tomorrow.resolve(using: clock))

        #expect(clock.calendar.component(.day, from: resolved) == 30)
        #expect(clock.calendar.component(.hour, from: resolved) == 0, "still the start of the day")
        // 23 hours, not 24 — which is exactly why this goes through Calendar and not arithmetic.
        #expect(resolved.timeIntervalSince(clock.startOfToday) == 23 * 3600)
    }

    @Test("Tomorrow is the next calendar day across an autumn-back transition")
    func fallBack() throws {
        // London gains an hour at 02:00 on 2026-10-25, so the 25th is a 25-hour day.
        let clock = provider(
            timeZone: "Europe/London",
            date: DateComponents(year: 2026, month: 10, day: 25, hour: 12)
        )
        let resolved = try #require(DateExpression.tomorrow.resolve(using: clock))

        #expect(clock.calendar.component(.day, from: resolved) == 26)
        #expect(clock.calendar.component(.hour, from: resolved) == 0)
        #expect(resolved.timeIntervalSince(clock.startOfToday) == 25 * 3600)
    }

    /// 02:30 does not exist on the morning the clocks go forward. It must not silently become
    /// something else on the wrong day.
    @Test("A time inside the spring-forward gap still lands on the right day")
    func timeInsideTheGap() throws {
        let clock = provider(
            timeZone: "Europe/London",
            date: DateComponents(year: 2026, month: 3, day: 28, hour: 12)
        )
        let resolved = try #require(
            DateExpression.tomorrow.resolve(using: clock, at: TimeOfDay(hour: 2, minute: 30))
        )
        // 02:30 does not exist on the 29th. Whatever Calendar picks, it must still be the 29th.
        #expect(clock.calendar.component(.day, from: resolved) == 29)
    }

    @Test("A weekday resolves forward regardless of time zone")
    func weekdaysAcrossZones() throws {
        for zone in ["Pacific/Auckland", "America/Los_Angeles", "Asia/Kolkata"] {
            let clock = provider(
                timeZone: zone,
                date: DateComponents(year: 2026, month: 3, day: 15, hour: 23, minute: 30)
            )
            let friday = try #require(DateExpression.nextWeekday(6).resolve(using: clock))
            #expect(clock.calendar.component(.weekday, from: friday) == 6, "wrong weekday in \(zone)")
            #expect(friday > clock.startOfToday, "not in the future in \(zone)")
        }
    }
}
