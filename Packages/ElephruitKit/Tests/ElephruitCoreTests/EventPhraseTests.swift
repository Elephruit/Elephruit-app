import ElephruitCore
import Foundation
import Testing

/// The phrases the calendar module was asked to understand, plus the ones that break parsers.
@Suite("Understanding a phrase")
struct EventPhraseTests {
    private static let clock = FixedDateProvider.reference
    private static var calendar: Calendar { clock.calendar }

    private static let maya = KnownPerson(id: UUID(), fullName: "Maya Chen", aliases: ["Maya"])
    private static let jordan = KnownPerson(id: UUID(), fullName: "Jordan Blake", aliases: ["Jordan"])

    private static var context: EventPhraseContext {
        EventPhraseContext(
            people: [maya, jordan],
            calendarNames: ["Work", "Personal", "Family"],
            timeZoneIdentifiers: ["Europe/London", "America/New_York"]
        )
    }

    private static func parse(_ input: String) -> EventPhraseInterpretation {
        EventPhraseParser.parse(input, context: context, calendar: calendar)
    }

    private static func draft(_ input: String) -> EventDraft? {
        parse(input).draft(
            defaultCalendarIdentifier: "work",
            calendars: [
                CalendarInfo(id: "work", title: "Work", accountKind: .iCloud),
                CalendarInfo(id: "personal", title: "Personal", accountKind: .iCloud),
            ],
            dateProvider: clock
        )
    }

    // MARK: The named examples

    @Test("“Lunch with Maya tomorrow at noon”")
    func lunchWithMaya() {
        let parsed = Self.parse("Lunch with Maya tomorrow at noon")

        #expect(parsed.title == "Lunch with Maya", """
            The person's name stays in the title. An event called just "Lunch" says nothing to \
            anybody looking at it later, and stripping the name is a change nobody asked for.
            """)
        #expect(parsed.day == .tomorrow)
        #expect(parsed.time == TimeOfDay(hour: 12, minute: 0))
        #expect(parsed.personID == Self.maya.id)
        #expect(!parsed.isAllDay)
    }

    @Test("“Dentist Friday at 9 for 45 minutes”")
    func dentistFriday() {
        let parsed = Self.parse("Dentist Friday at 9 for 45 minutes")

        #expect(parsed.title == "Dentist")
        #expect(parsed.day == .nextWeekday(6))
        #expect(parsed.time == TimeOfDay(hour: 9, minute: 0), "Nine o'clock for a dentist is the morning")
        #expect(parsed.durationMinutes == 45)

        let draft = Self.draft("Dentist Friday at 9 for 45 minutes")
        #expect(draft?.duration == TimeInterval(45 * 60))
    }

    @Test("“Vacation August 10 through August 17”")
    func vacationRange() {
        let parsed = Self.parse("Vacation August 10 through August 17")

        #expect(parsed.title == "Vacation")
        #expect(parsed.isAllDay)
        #expect(parsed.day == .monthDay(month: 8, day: 10))
        #expect(parsed.endDay == .monthDay(month: 8, day: 17))

        let draft = Self.draft("Vacation August 10 through August 17")
        #expect(draft?.isAllDay == true)
        // Eight days as a person counts them, which is nine days' worth of exclusive end.
        #expect(draft?.duration == TimeInterval(8 * 86_400))
    }

    @Test("“Team meeting every Tuesday at 10”")
    func recurringTeamMeeting() {
        let parsed = Self.parse("Team meeting every Tuesday at 10")

        #expect(parsed.title == "Team meeting")
        #expect(parsed.recurrence?.frequency == .weekly)
        #expect(parsed.recurrence?.daysOfWeek.first?.weekday == 3)
        #expect(parsed.time == TimeOfDay(hour: 10, minute: 0))
    }

    @Test("“Call with Jordan at 3 PM London time”")
    func callInAnotherZone() {
        let parsed = Self.parse("Call with Jordan at 3 PM London time")

        #expect(parsed.title == "Call with Jordan")
        #expect(parsed.time == TimeOfDay(hour: 15, minute: 0))
        #expect(parsed.timeZoneIdentifier == "Europe/London")
        #expect(parsed.personID == Self.jordan.id)
    }

    @Test("“Dinner at Aba Saturday at 7 on Personal”")
    func dinnerAtARestaurant() {
        let parsed = Self.parse("Dinner at Aba Saturday at 7 on Personal")

        #expect(parsed.title == "Dinner")
        #expect(parsed.location == "Aba", """
            “at” introduces both a time and a place, and the only thing that tells them apart is \
            whether what follows parses as a time
            """)
        #expect(parsed.day == .nextWeekday(7))
        #expect(parsed.time == TimeOfDay(hour: 19, minute: 0), "Seven for dinner is the evening")
        #expect(parsed.calendarName == "Personal")

        let draft = Self.draft("Dinner at Aba Saturday at 7 on Personal")
        #expect(draft?.calendarIdentifier == "personal")
    }

    // MARK: The ambiguous cases

    @Test("A bare number is not a time unless something makes it one")
    func bareNumbersStayInTheTitle() {
        let parsed = Self.parse("Review 3 documents tomorrow")
        #expect(parsed.title == "Review 3 documents")
        #expect(parsed.time == nil)
        #expect(parsed.day == .tomorrow)
    }

    @Test("A place that looks like nothing else is still a place")
    func plainLocations() {
        let parsed = Self.parse("Standup at Room 3 tomorrow")
        #expect(parsed.location == "Room 3")
        #expect(parsed.title == "Standup")
    }

    @Test("A time range gives an end rather than a duration")
    func timeRanges() {
        let parsed = Self.parse("Workshop tomorrow 9am to 5pm")
        #expect(parsed.time == TimeOfDay(hour: 9, minute: 0))
        #expect(parsed.endTime == TimeOfDay(hour: 17, minute: 0))
        #expect(parsed.durationMinutes == nil)

        let draft = Self.draft("Workshop tomorrow 9am to 5pm")
        #expect(draft?.duration == TimeInterval(8 * 3_600))
    }

    @Test("A range that crosses midnight is short, not negative")
    func rangesAcrossMidnight() {
        let draft = Self.draft("Party tonight 11pm to 1am")
        #expect(draft != nil)
        #expect((draft?.duration ?? 0) == TimeInterval(2 * 3_600), """
            An end before the start means the next day, not an event lasting minus twenty-two hours
            """)
    }

    @Test("An unknown name is offered rather than silently dropped")
    func unknownPeople() {
        let parsed = Self.parse("Coffee with Priya tomorrow")
        #expect(parsed.personName == "Priya")
        #expect(parsed.personID == nil, "Nobody is linked to somebody the library has never heard of")
        #expect(parsed.title == "Coffee with Priya")
    }

    @Test("A lowercase word after “with” is not a person")
    func lowercaseIsNotAName() {
        let parsed = Self.parse("Meeting with coffee tomorrow")
        #expect(parsed.personName == nil)
        #expect(parsed.title.contains("coffee"))
    }

    @Test("A reminder is understood in either order")
    func alarms() {
        #expect(Self.parse("Standup tomorrow at 9 remind me 10 minutes before").alarmMinutesBefore == 10)
        #expect(Self.parse("Standup tomorrow at 9 alert 15 min before").alarmMinutesBefore == 15)
        #expect(Self.parse("Standup tomorrow at 9 with a 30 minute reminder").alarmMinutesBefore == 30)
    }

    @Test("Compact durations are understood")
    func compactDurations() {
        #expect(Self.parse("Call tomorrow at 2 45min").durationMinutes == 45)
        #expect(Self.parse("Focus tomorrow at 9 2h").durationMinutes == 120)
        #expect(Self.parse("Break tomorrow at 3 for half an hour").durationMinutes == 30)
        #expect(Self.parse("Call tomorrow at 2 for an hour").durationMinutes == 60)
    }

    @Test("Every recurrence phrasing lands on the same rule")
    func recurrencePhrasings() {
        #expect(Self.parse("Standup every day").recurrence?.frequency == .daily)
        #expect(Self.parse("Standup daily").recurrence?.frequency == .daily)
        #expect(Self.parse("Review every 2 weeks").recurrence?.interval == 2)
        #expect(Self.parse("Rent every month").recurrence?.frequency == .monthly)
        #expect(Self.parse("Standup every weekday").recurrence?.daysOfWeek.count == 5)
    }

    @Test("A time zone abbreviation is recognised only when it is unambiguous")
    func zoneAbbreviations() {
        #expect(Self.parse("Call tomorrow at 3pm ET").timeZoneIdentifier == "America/New_York")
        #expect(Self.parse("Call tomorrow at 3pm UTC").timeZoneIdentifier == "GMT")
        // "IST" means Indian, Irish, and Israeli standard time. Guessing moves a meeting by hours.
        #expect(Self.parse("Call tomorrow at 3pm IST").timeZoneIdentifier == nil)
    }

    @Test("An empty phrase understands nothing and says so")
    func emptyPhrase() {
        #expect(Self.parse("").isEmpty)
        #expect(!Self.parse("").isUsable)
    }

    @Test("A title alone is enough to make an event")
    func titleAlone() {
        let parsed = Self.parse("Dentist")
        #expect(parsed.title == "Dentist")
        #expect(parsed.isUsable)

        let draft = Self.draft("Dentist")
        #expect(draft != nil, "A phrase with no date means today, which is what somebody typing one means")
        #expect(draft?.title == "Dentist")
    }

    @Test("Every recognised span reports where it was")
    func tokensCarryRanges() {
        let text = "Lunch with Maya tomorrow at noon"
        let parsed = Self.parse(text)

        #expect(!parsed.tokens.isEmpty)
        for token in parsed.tokens {
            #expect(token.range.lowerBound >= 0)
            #expect(token.range.upperBound <= text.count, """
                A range past the end of the text underlines nothing and can crash a view that trusts it
                """)
            #expect(token.range.lowerBound < token.range.upperBound)
        }

        // In reading order, so the chips under the field appear where the words are.
        let starts = parsed.tokens.map(\.range.lowerBound)
        #expect(starts == starts.sorted())
    }

    @Test("Nothing recognised is claimed twice")
    func spansDoNotOverlap() {
        let parsed = Self.parse("Dinner at Aba Saturday at 7 on Personal for 2 hours")

        let sorted = parsed.tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            // The one legitimate exception: a time range produces a start and an end from the same
            // words, and both point at the phrase they came from.
            let isTimeRange = left.kind == .time && right.kind == .endTime
            #expect(isTimeRange || left.range.upperBound <= right.range.lowerBound,
                    "\(left.kind) and \(right.kind) overlap")
        }
    }

    @Test("Parsing the same phrase twice gives the same answer")
    func parsingIsDeterministic() {
        let first = Self.parse("Team meeting every Tuesday at 10 on Work")
        let second = Self.parse("Team meeting every Tuesday at 10 on Work")

        #expect(first.title == second.title)
        #expect(first.recurrence == second.recurrence)
        #expect(first.calendarName == second.calendarName)
        #expect(first.tokens.map(\.range) == second.tokens.map(\.range))
    }

    @Test("Character offsets survive a phrase full of multi-byte characters")
    func unicodeOffsets() {
        // A parser that mixes up `Character` counts and UTF-8 offsets underlines the wrong words the
        // moment somebody types an accent or an emoji, and never before.
        let text = "Café ☕️ with Maya tomorrow at noon"
        let parsed = EventPhraseParser.parse(text, context: Self.context, calendar: Self.calendar)

        for token in parsed.tokens {
            #expect(token.range.upperBound <= text.count)
        }
        #expect(parsed.day == .tomorrow)
        #expect(parsed.title.contains("Café"))
    }

    @Test("Extra whitespace does not change what is understood")
    func whitespaceIsTolerated() {
        let spaced = Self.parse("  Lunch   with   Maya    tomorrow  at  noon ")
        #expect(spaced.day == .tomorrow)
        #expect(spaced.time == TimeOfDay(hour: 12, minute: 0))
        #expect(spaced.title == "Lunch with Maya")
    }

    @Test("A calendar named in the phrase beats the default")
    func calendarOverridesDefault() {
        let draft = Self.draft("Dentist tomorrow at 9 on Personal")
        #expect(draft?.calendarIdentifier == "personal")

        let plain = Self.draft("Dentist tomorrow at 9")
        #expect(plain?.calendarIdentifier == "work", "…and with nothing said, the default is used")
    }

    @Test("A calendar the phrase names but that no longer exists falls back rather than failing")
    func missingCalendarFallsBack() {
        var parsed = Self.parse("Dentist tomorrow at 9 on Personal")
        parsed.calendarName = "Retired Calendar"

        let draft = parsed.draft(
            defaultCalendarIdentifier: "work",
            calendars: [CalendarInfo(id: "work", title: "Work", accountKind: .iCloud)],
            dateProvider: Self.clock
        )
        #expect(draft?.calendarIdentifier == "work")
    }
}
