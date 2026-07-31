import ElephruitCore
import Foundation
import Testing

@Suite("Laying out a day")
struct EventLayoutTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }()

    private static var day: Date {
        calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private static func event(
        _ title: String,
        from startHour: Double,
        to endHour: Double,
        allDay: Bool = false,
        availability: EventAvailability = .busy
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: day.addingTimeInterval(startHour * 3_600),
            endAt: day.addingTimeInterval(endHour * 3_600),
            isAllDay: allDay,
            availability: availability
        )
    }

    private static func positions(_ events: [CalendarEventSummary]) -> [PositionedEvent] {
        EventLayout.positions(for: events, on: day, calendar: calendar)
    }

    @Test("A single event fills the width and sits at its own time")
    func singleEvent() {
        let laid = Self.positions([Self.event("Standup", from: 9, to: 10)])

        #expect(laid.count == 1)
        let block = laid.first
        #expect(block?.width == 1)
        #expect(block?.leading == 0)
        #expect(abs((block?.top ?? 0) - 9.0 / 24) < 0.0001)
        #expect(abs((block?.height ?? 0) - 1.0 / 24) < 0.0001)
    }

    @Test("Two events at the same time each take half the column")
    func simpleOverlap() {
        let laid = Self.positions([
            Self.event("A", from: 9, to: 10),
            Self.event("B", from: 9, to: 10),
        ])

        #expect(laid.count == 2)
        #expect(laid.allSatisfy { $0.width < 0.6 })
        #expect(Set(laid.map(\.leading)).count == 2, "Two blocks on top of each other is not a layout")
    }

    @Test("An event that clashes with nothing keeps the full width, whatever else the day holds")
    func nonOverlappingEventsAreNotPunished() {
        // The naive layout — divide by the number of events in the day — draws this afternoon
        // meeting at a third of the width because of a clash that happened in the morning.
        let laid = Self.positions([
            Self.event("Morning A", from: 9, to: 10),
            Self.event("Morning B", from: 9, to: 10),
            Self.event("Morning C", from: 9, to: 10),
            Self.event("Afternoon", from: 15, to: 16),
        ])

        let afternoon = laid.first { $0.event.title == "Afternoon" }
        #expect(afternoon?.width == 1, "A meeting alone in its hour is not narrow")
    }

    @Test("Overlap is transitive, so a chain shares the width")
    func transitiveOverlap() {
        // A overlaps B, B overlaps C, A and C do not touch — but all three still have to fit.
        let laid = Self.positions([
            Self.event("A", from: 9, to: 10.5),
            Self.event("B", from: 10, to: 11.5),
            Self.event("C", from: 11, to: 12),
        ])

        #expect(laid.count == 3)
        // A and C do not clash, so they may share a column; B needs its own.
        #expect(Set(laid.map(\.leading)).count >= 2)
        #expect(laid.allSatisfy { $0.leading + $0.width <= 1.05 }, "Nothing may spill out of the column")
    }

    @Test("A column is reused once its event has finished")
    func columnsAreReclaimed() {
        let laid = Self.positions([
            Self.event("Long", from: 9, to: 17),
            Self.event("Early", from: 9, to: 10),
            Self.event("Late", from: 11, to: 12),
        ])

        let early = laid.first { $0.event.title == "Early" }
        let late = laid.first { $0.event.title == "Late" }
        #expect(early?.leading == late?.leading, """
            Two short meetings that do not overlap each other belong in the same column beside the \
            long one, rather than each taking a third of the day's width
            """)
    }

    @Test("A zero-length event still has a body to click")
    func zeroLengthEventsAreVisible() {
        let laid = Self.positions([Self.event("Moment", from: 9, to: 9)])
        #expect((laid.first?.height ?? 0) > 0, "A block with no height cannot be selected or read")
    }

    @Test("An event from the previous night is clipped to the top of the grid")
    func overnightEventsAreClipped() {
        var overnight = Self.event("Overnight", from: -4, to: 2)
        overnight.title = "Overnight"

        let laid = Self.positions([overnight])
        #expect(laid.first?.top == 0, "A negative offset would draw the block above the grid")
        #expect((laid.first?.height ?? 0) > 0)
    }

    @Test("Events outside the visible hours are dropped rather than squashed")
    func outsideVisibleHours() {
        let laid = EventLayout.positions(
            for: [Self.event("Dawn", from: 3, to: 4), Self.event("Meeting", from: 10, to: 11)],
            on: Self.day,
            visibleHours: 8..<20,
            calendar: Self.calendar
        )
        #expect(laid.map(\.event.title) == ["Meeting"])
    }

    @Test("A narrowed grid positions against the span it shows")
    func visibleHoursRescale() {
        let laid = EventLayout.positions(
            for: [Self.event("Meeting", from: 8, to: 9)],
            on: Self.day,
            visibleHours: 8..<20,
            calendar: Self.calendar
        )
        #expect(laid.first?.top == 0)
        #expect(abs((laid.first?.height ?? 0) - 1.0 / 12) < 0.0001)
    }
}

@Suite("All-day bars")
struct EventBarTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }()

    private static var week: [Date] {
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func event(_ title: String, dayOffset: Int, days: Int) -> CalendarEventSummary {
        let start = week[0].addingTimeInterval(Double(dayOffset) * 86_400)
        return CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(Double(days) * 86_400),
            isAllDay: true
        )
    }

    @Test("A multi-day event is one bar across the days it covers")
    func multiDayBar() {
        let bars = EventLayout.bars(
            for: [Self.event("Conference", dayOffset: 1, days: 3)],
            acrossDays: Self.week,
            calendar: Self.calendar
        )

        #expect(bars.count == 1)
        #expect(bars.first?.startColumn == 1)
        #expect(bars.first?.columnSpan == 3)
        #expect(bars.first?.continuesBefore == false)
        #expect(bars.first?.continuesAfter == false)
    }

    @Test("An event that began before the window says so")
    func continuationIsMarked() {
        let start = Self.week[0].addingTimeInterval(-2 * 86_400)
        let event = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "holiday"),
            title: "Holiday",
            startAt: start,
            endAt: start.addingTimeInterval(5 * 86_400),
            isAllDay: true
        )

        let bars = EventLayout.bars(for: [event], acrossDays: Self.week, calendar: Self.calendar)

        #expect(bars.first?.continuesBefore == true, """
            Drawing a two-week holiday as a fresh three-day event every Monday makes it read as a \
            different holiday each week
            """)
        #expect(bars.first?.startColumn == 0)
    }

    @Test("An event running past the window says so too")
    func trailingContinuation() {
        let bars = EventLayout.bars(
            for: [Self.event("Sabbatical", dayOffset: 5, days: 20)],
            acrossDays: Self.week,
            calendar: Self.calendar
        )
        #expect(bars.first?.continuesAfter == true)
        #expect(bars.first?.startColumn == 5)
    }

    @Test("Bars that overlap stack rather than collide")
    func overlappingBarsStack() {
        let bars = EventLayout.bars(
            for: [
                Self.event("Conference", dayOffset: 0, days: 4),
                Self.event("Visitor", dayOffset: 2, days: 2),
            ],
            acrossDays: Self.week,
            calendar: Self.calendar
        )

        #expect(Set(bars.map(\.row)).count == 2)
        #expect(bars.first { $0.event.title == "Conference" }?.row == 0,
                "The longest bar takes the top row so the shorter ones read as nested inside it")
    }

    @Test("Bars that do not overlap share a row")
    func disjointBarsShareARow() {
        let bars = EventLayout.bars(
            for: [
                Self.event("First", dayOffset: 0, days: 2),
                Self.event("Second", dayOffset: 4, days: 2),
            ],
            acrossDays: Self.week,
            calendar: Self.calendar
        )
        #expect(Set(bars.map(\.row)) == [0], "An empty band row for no reason costs a week view real height")
    }
}

@Suite("How busy a day was")
struct DayDensityTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static var days: [Date] {
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        return (0..<3).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private static func event(
        _ title: String,
        dayOffset: Int,
        fromHour: Double,
        hours: Double,
        availability: EventAvailability = .busy,
        allDay: Bool = false
    ) -> CalendarEventSummary {
        let start = days[0]
            .addingTimeInterval(Double(dayOffset) * 86_400)
            .addingTimeInterval(fromHour * 3_600)
        return CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(hours * 3_600),
            isAllDay: allDay,
            availability: availability
        )
    }

    @Test("Density measures time, not the number of meetings")
    func timeRatherThanCount() {
        let density = EventLayout.density(
            of: [
                Self.event("Workshop", dayOffset: 0, fromHour: 9, hours: 6),
                Self.event("A", dayOffset: 1, fromHour: 9, hours: 0.1),
                Self.event("B", dayOffset: 1, fromHour: 10, hours: 0.1),
                Self.event("C", dayOffset: 1, fromHour: 11, hours: 0.1),
                Self.event("D", dayOffset: 1, fromHour: 12, hours: 0.1),
            ],
            acrossDays: Self.days,
            workingHours: .standard,
            calendar: Self.calendar
        )

        #expect(density[0].busyHours > density[1].busyHours, """
            Six hours of workshop is a busier day than four five-minute check-ins, and a year view \
            that says otherwise is worse than no year view
            """)
        #expect(density[1].eventCount == 4)
    }

    @Test("Time marked free does not count as busy")
    func freeTimeIsNotBusy() {
        let density = EventLayout.density(
            of: [Self.event("Focus block", dayOffset: 0, fromHour: 9, hours: 4, availability: .free)],
            acrossDays: Self.days,
            workingHours: .standard,
            calendar: Self.calendar
        )
        #expect(density[0].busyHours == 0)
        #expect(density[0].eventCount == 1, "…but it is still an event on that day")
    }

    @Test("An all-day event counts as a working day, not twenty-four hours")
    func allDayEventsAreWeighted() {
        let density = EventLayout.density(
            of: [Self.event("Leave", dayOffset: 2, fromHour: 0, hours: 24, allDay: true)],
            acrossDays: Self.days,
            workingHours: .standard,
            calendar: Self.calendar
        )
        #expect(density[2].busyHours == 8)
        #expect(density[2].intensity == 1)
    }

    @Test("An empty day is empty rather than missing")
    func emptyDaysArePresent() {
        let density = EventLayout.density(
            of: [], acrossDays: Self.days, workingHours: .standard, calendar: Self.calendar
        )
        #expect(density.count == 3)
        #expect(density.filter(\.isEmpty).count == 3)
    }

    @Test("A multi-day event contributes to each day it touches")
    func multiDaySpread() {
        let density = EventLayout.density(
            of: [Self.event("Trip", dayOffset: 0, fromHour: 9, hours: 30)],
            acrossDays: Self.days,
            workingHours: .standard,
            calendar: Self.calendar
        )
        #expect(density[0].busyHours > 0)
        #expect(density[1].busyHours > 0)
    }
}

@Suite("Calendar sets")
struct CalendarSetTests {
    private static let available = [
        CalendarInfo(id: "work", title: "Work", accountName: "Acme", accountKind: .exchange),
        CalendarInfo(id: "home", title: "Home", accountName: "iCloud", accountKind: .iCloud),
    ]

    @Test("A set showing everything applies no filter at all")
    func everyCalendarMeansNoFilter() {
        let set = CalendarSetDefinition(name: "All")
        #expect(set.calendarIdentifiers(among: Self.available) == nil)
    }

    @Test("A set whose calendars are all offline shows nothing, not everything")
    func offlineCalendarsDoNotFallBackToEverything() {
        // The failure this prevents: an Exchange account drops off the network and the Work set
        // quietly starts showing the user's private calendar during a screen share.
        let set = CalendarSetDefinition(
            name: "Work",
            calendars: [CalendarReference(identifier: "gone", title: "Old", accountName: "Old")],
            showsEveryCalendar: false
        )
        #expect(set.calendarIdentifiers(among: Self.available) == [])
    }

    @Test("Missing calendars are reported rather than pruned")
    func missingCalendarsAreReported() {
        let set = CalendarSetDefinition(
            name: "Work",
            calendars: [
                CalendarReference(identifier: "work", title: "Work", accountName: "Acme"),
                CalendarReference(identifier: "gone", title: "Retired", accountName: "Acme"),
            ],
            showsEveryCalendar: false
        )

        #expect(set.calendarIdentifiers(among: Self.available) == ["work"])
        #expect(set.unavailableCalendars(among: Self.available).count == 1, """
            Silently dropping a calendar means the set shrinks every time the network does, with no \
            way to notice or undo it
            """)
    }

    @Test("Working hours shade rather than restrict, and know their own days")
    func workingHours() {
        let hours = WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60, weekdays: [2, 3, 4, 5, 6])
        #expect(hours.includes(weekday: 2))
        #expect(!hours.includes(weekday: 1))
        #expect(hours.summary == "9:00–17:00")
    }

    @Test("Working hours cannot end before they start")
    func workingHoursAreOrdered() {
        let backwards = WorkingHours(startMinutes: 17 * 60, endMinutes: 9 * 60)
        #expect(backwards.endMinutes >= backwards.startMinutes)
    }

    @Test("Each view knows its own shortcut and whether it draws a clock")
    func viewKinds() {
        #expect(CalendarViewKind.agenda.shortcutIndex == 1)
        #expect(CalendarViewKind.year.shortcutIndex == 6)
        #expect(CalendarViewKind.week.isTimeGrid)
        #expect(!CalendarViewKind.month.isTimeGrid)
        #expect(CalendarViewKind.quarter.isOverview && CalendarViewKind.year.isOverview)
        #expect(!CalendarViewKind.month.isOverview)
    }
}
