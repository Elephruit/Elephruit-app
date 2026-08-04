import ElephruitCore
import Foundation
import Testing

@Suite("Quick Capture grammar")
struct CaptureParserTests {
    @Test("Plain text becomes a note titled with that text")
    func plainTextIsANote() {
        let draft = CaptureParser.parse("Think about the launch plan")

        #expect(draft.kind == .note)
        #expect(draft.title == "Think about the launch plan")
        #expect(draft.tagSlugs.isEmpty)
        #expect(draft.dueDate == nil)
    }

    @Test("A leading dash or checkbox makes it a task")
    func taskPrefixes() {
        #expect(CaptureParser.parse("- Call the bank").kind == .reminder)
        #expect(CaptureParser.parse("[] Call the bank").kind == .reminder)
        #expect(CaptureParser.parse("[ ] Call the bank").kind == .reminder)
        #expect(CaptureParser.parse("- [ ] Call the bank").kind == .reminder)
        #expect(CaptureParser.parse("- Call the bank").title == "Call the bank")
    }

    @Test("Tags are extracted and normalised, and leave the title clean")
    func extractsTags() {
        let draft = CaptureParser.parse("Draft the brief #Urgent #work/clients")

        #expect(draft.tagSlugs == ["urgent", "work/clients"])
        #expect(draft.title == "Draft the brief")
    }

    @Test("A project hint can be quoted for multiple words")
    func extractsProject() {
        #expect(CaptureParser.parse("Do it >Launch").projectHint == "Launch")

        let quoted = CaptureParser.parse("Do it >\"Q3 Launch\" and more")
        #expect(quoted.projectHint == "Q3 Launch")
        #expect(quoted.title == "Do it and more")
    }

    @Test("People are extracted")
    func extractsPeople() {
        let draft = CaptureParser.parse("Follow up with @Sarah and @Tom")
        #expect(draft.personHints == ["Sarah", "Tom"])
        #expect(draft.title == "Follow up with and")
    }

    @Test("A due date implies the capture is a task")
    func dueDateImpliesTask() {
        let draft = CaptureParser.parse("Send the invoice !tomorrow")

        #expect(draft.kind == .reminder)
        #expect(draft.dueDate == .tomorrow)
        #expect(draft.title == "Send the invoice")
    }

    @Test("An unrecognised sigil value stays in the title rather than being eaten")
    func unrecognisedTokensArePreserved() {
        let draft = CaptureParser.parse("Meeting !someday about #!!! things")

        #expect(draft.dueDate == nil)
        #expect(draft.title.contains("!someday"))
        #expect(draft.title.contains("#!!!"))
        #expect(draft.tagSlugs.isEmpty)
    }

    @Test("A bare URL becomes a bookmark titled by its host")
    func urlBecomesBookmark() {
        let draft = CaptureParser.parse("https://example.com/some/article")

        #expect(draft.kind == .bookmark)
        #expect(draft.url?.absoluteString == "https://example.com/some/article")
        #expect(draft.title == "example.com")
    }

    @Test("A URL with surrounding words keeps the words as the title")
    func urlWithContext() {
        let draft = CaptureParser.parse("Read this later https://example.com/article #reading")

        #expect(draft.kind == .bookmark)
        #expect(draft.url != nil)
        #expect(draft.title.contains("Read this later"))
        #expect(draft.tagSlugs == ["reading"])
    }

    @Test("A schemeless host is recognised; ordinary prose with a full stop is not")
    func urlDetectionIsConservative() {
        #expect(CaptureParser.parse("example.com/path").url != nil)
        #expect(CaptureParser.parse("Ends with a sentence.").url == nil)
        #expect(CaptureParser.parse("Version 1.2 shipped").url == nil)
    }

    @Test("The first line titles it and the rest is the body")
    func multilineSplitsTitleAndBody() {
        let draft = CaptureParser.parse("Meeting notes #work\nFirst point\nSecond point")

        #expect(draft.title == "Meeting notes")
        #expect(draft.body == "First point\nSecond point")
        #expect(draft.tagSlugs == ["work"])
    }

    @Test("A pasted paragraph still gets a title")
    func bodyOnlyGetsInferredTitle() {
        let draft = CaptureParser.parse("\nA pasted paragraph with no first line.")

        #expect(!draft.title.isEmpty)
        #expect(draft.title.contains("A pasted paragraph"))
    }

    @Test("Empty input is recognised as empty")
    func emptyInput() {
        #expect(CaptureParser.parse("").isEmpty)
        #expect(CaptureParser.parse("   \n  ").isEmpty)
        #expect(!CaptureParser.parse("x").isEmpty)
    }

    @Test("A second project hint is kept as text rather than silently discarded")
    func secondProjectHintPreserved() {
        let draft = CaptureParser.parse("Task >First >Second")

        #expect(draft.projectHint == "First")
        #expect(draft.title.contains(">Second"))
    }
}

@Suite("Date shorthand")
struct NaturalDateParserTests {
    private let clock = FixedDateProvider.reference  // Monday 2026-06-15 09:00 GMT

    @Test("Named days")
    func namedDays() {
        #expect(NaturalDateParser.parse("today") == .today)
        #expect(NaturalDateParser.parse("Tomorrow") == .tomorrow)
        #expect(NaturalDateParser.parse("tmr") == .tomorrow)
        #expect(NaturalDateParser.parse("yesterday") == .yesterday)
    }

    @Test("Weekday names resolve to the next such day, never today")
    func weekdaysAlwaysLookForward() {
        // The reference date is a Monday. "monday" must mean next Monday.
        let monday = NaturalDateParser.parse("monday")
        #expect(monday == .nextWeekday(2))

        let resolved = monday?.resolve(using: clock)
        #expect(resolved == clock.startOfDay(daysFromToday: 7))

        let friday = NaturalDateParser.parse("fri")?.resolve(using: clock)
        #expect(friday == clock.startOfDay(daysFromToday: 4))
    }

    @Test("Thursday abbreviations all mean Thursday")
    func thursdayAbbreviations() {
        #expect(NaturalDateParser.parse("thu") == .nextWeekday(5))
        #expect(NaturalDateParser.parse("thur") == .nextWeekday(5))
        #expect(NaturalDateParser.parse("thurs") == .nextWeekday(5))
        #expect(NaturalDateParser.parse("thursday") == .nextWeekday(5))
    }

    @Test("Signed day and week offsets")
    func offsets() {
        #expect(NaturalDateParser.parse("+3d") == .dayOffset(3))
        #expect(NaturalDateParser.parse("3d") == .dayOffset(3))
        #expect(NaturalDateParser.parse("-2d") == .dayOffset(-2))
        #expect(NaturalDateParser.parse("2w") == .weekOffset(2))
        #expect(NaturalDateParser.parse("-1w") == .weekOffset(-1))

        #expect(NaturalDateParser.parse("+3d")?.resolve(using: clock) == clock.startOfDay(daysFromToday: 3))
    }

    @Test("Explicit dates in both separators")
    func explicitDates() {
        #expect(NaturalDateParser.parse("2026-08-14") == .explicit(year: 2026, month: 8, day: 14))
        #expect(NaturalDateParser.parse("2026/08/14") == .explicit(year: 2026, month: 8, day: 14))
    }

    @Test("Nonsense is rejected rather than guessed at")
    func rejectsNonsense() {
        #expect(NaturalDateParser.parse("someday") == nil)
        #expect(NaturalDateParser.parse("") == nil)
        #expect(NaturalDateParser.parse("13d4") == nil)
        #expect(NaturalDateParser.parse("2026-13-01") == nil, "Month 13 does not exist")
        #expect(NaturalDateParser.parse("26-08-14") == nil, "A two-digit year is ambiguous")
    }

    @Test("Every documented example parses")
    func documentedExamplesAllWork() {
        for example in NaturalDateParser.recognisedExamples {
            #expect(NaturalDateParser.parse(example) != nil, "\(example) is advertised in the UI")
        }
    }
}

@Suite("Recurrence")
struct RecurrenceRuleTests
{
    private let calendar: Calendar = {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        gregorian.firstWeekday = 1
        return gregorian
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("Daily and weekly intervals advance by whole units")
    func simpleIntervals() {
        let daily = RecurrenceRule(frequency: .daily)
        #expect(daily.nextOccurrence(after: date(2026, 6, 15), calendar: calendar) == date(2026, 6, 16))

        let everyThreeDays = RecurrenceRule(frequency: .daily, interval: 3)
        #expect(everyThreeDays.nextOccurrence(after: date(2026, 6, 15), calendar: calendar) == date(2026, 6, 18))

        let fortnightly = RecurrenceRule(frequency: .weekly, interval: 2)
        #expect(fortnightly.nextOccurrence(after: date(2026, 6, 15), calendar: calendar) == date(2026, 6, 29))
    }

    @Test("Interval is clamped to at least one, so a rule cannot fail to advance")
    func intervalIsClamped() {
        let rule = RecurrenceRule(frequency: .daily, interval: 0)
        #expect(rule.interval == 1)

        let negative = RecurrenceRule(frequency: .daily, interval: -5)
        #expect(negative.interval == 1)
    }

    @Test("Weekly with selected weekdays lands on the next chosen day")
    func selectedWeekdays() {
        // Mondays and Thursdays. 15 June 2026 is a Monday.
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [2, 5])

        let afterMonday = rule.nextOccurrence(after: date(2026, 6, 15), calendar: calendar)
        #expect(afterMonday == date(2026, 6, 18), "Thursday")

        let afterThursday = rule.nextOccurrence(after: date(2026, 6, 18), calendar: calendar)
        #expect(afterThursday == date(2026, 6, 22), "The following Monday")
    }

    @Test("Out-of-range weekdays are discarded on construction")
    func weekdaysAreValidated() {
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [0, 2, 8, 9])
        #expect(rule.weekdays == [2])
    }

    @Test("Monthly on the 31st clamps to a short month's last day")
    func monthDayClamping() {
        let rule = RecurrenceRule(frequency: .monthly, dayOfMonth: 31)

        // January to February 2026: February has 28 days.
        let fromJanuary = rule.nextOccurrence(after: date(2026, 1, 31), calendar: calendar)
        #expect(fromJanuary == date(2026, 2, 28))

        // And it does not get stuck at 28 — March has a 31st.
        let fromFebruary = rule.nextOccurrence(after: date(2026, 2, 28), calendar: calendar)
        #expect(fromFebruary == date(2026, 3, 31))
    }

    @Test("A leap year's February is handled")
    func leapYear() {
        let rule = RecurrenceRule(frequency: .monthly, dayOfMonth: 30)
        let next = rule.nextOccurrence(after: date(2028, 1, 30), calendar: calendar)
        #expect(next == date(2028, 2, 29), "2028 is a leap year")
    }

    @Test("Day of month is clamped to a valid range on construction")
    func dayOfMonthIsValidated() {
        #expect(RecurrenceRule(frequency: .monthly, dayOfMonth: 0).dayOfMonth == 1)
        #expect(RecurrenceRule(frequency: .monthly, dayOfMonth: 99).dayOfMonth == 31)
    }

    @Test("A series with an end date stops")
    func endDateStopsTheSeries() {
        let rule = RecurrenceRule(frequency: .daily, end: .onDate(date(2026, 6, 17)))

        #expect(rule.nextOccurrence(after: date(2026, 6, 15), calendar: calendar) == date(2026, 6, 16))
        #expect(rule.nextOccurrence(after: date(2026, 6, 17), calendar: calendar) == nil)
    }

    @Test("A series with an occurrence limit stops")
    func occurrenceLimitStopsTheSeries() {
        let rule = RecurrenceRule(frequency: .daily, end: .afterOccurrences(3))

        #expect(rule.nextOccurrence(after: date(2026, 6, 15), occurrencesSoFar: 0, calendar: calendar) != nil)
        #expect(rule.nextOccurrence(after: date(2026, 6, 15), occurrencesSoFar: 2, calendar: calendar) != nil)
        #expect(rule.nextOccurrence(after: date(2026, 6, 15), occurrencesSoFar: 3, calendar: calendar) == nil)
    }

    @Test("Rules survive a coding round trip")
    func codingRoundTrip() {
        let original = RecurrenceRule(
            frequency: .weekly,
            interval: 2,
            weekdays: [2, 4],
            anchor: .completion,
            end: .afterOccurrences(10)
        )

        let decoded = RecurrenceRule.decode(from: original.encoded())
        #expect(decoded == original)
    }

    @Test("Unreadable stored data reads as no recurrence rather than throwing")
    func corruptDataDegradesGracefully() {
        #expect(RecurrenceRule.decode(from: nil) == nil)
        #expect(RecurrenceRule.decode(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("Summaries read as English")
    func summariesAreReadable() {
        #expect(RecurrenceRule(frequency: .daily).summary == "Every day")
        #expect(RecurrenceRule(frequency: .weekly, interval: 2).summary == "Every 2 weeks")
        #expect(RecurrenceRule(frequency: .monthly, dayOfMonth: 15).summary.contains("day 15"))
        #expect(RecurrenceRule(frequency: .weekly, weekdays: [2]).summary.contains("Monday"))
        #expect(RecurrenceRule(frequency: .daily, end: .afterOccurrences(5)).summary.contains("5 times"))
    }
}
