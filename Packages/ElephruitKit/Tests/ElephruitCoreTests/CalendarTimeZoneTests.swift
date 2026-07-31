import ElephruitCore
import Foundation
import Testing

/// Time zones, tested against the boundaries where a calendar can lose somebody an appointment.
///
/// The invariant these exist around: **changing what zone the calendar is drawn in never changes a
/// stored date.** ``displayZoneNeverMovesAnEvent()`` is the direct statement of it, and
/// ``noMethodReturnsANewDate()`` is what keeps it true after later edits.
@Suite("Time zones")
struct CalendarTimeZoneTests {
    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
        zone: String
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: zone)
        return Calendar(identifier: .gregorian).date(from: components)
            ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func draft(start: Date, hours: Double, zone: String? = nil) -> EventDraft {
        EventDraft(
            calendarIdentifier: "work",
            title: "Call",
            startAt: start,
            endAt: start.addingTimeInterval(hours * 3_600),
            timeZoneIdentifier: zone
        )
    }

    // MARK: The invariant

    @Test("Changing the display zone never moves an event")
    func displayZoneNeverMovesAnEvent() {
        let instant = Self.date(2026, 6, 15, 15, zone: "America/New_York")
        let event = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "e"),
            title: "Call",
            startAt: instant,
            endAt: instant.addingTimeInterval(3_600)
        )

        let inNewYork = TimeZoneDisplay(deviceZoneIdentifier: "America/New_York")
        let inTokyo = TimeZoneDisplay(
            deviceZoneIdentifier: "America/New_York", displayZoneIdentifier: "Asia/Tokyo"
        )

        // The label changes. The instant does not, and that is the whole point.
        #expect(event.startAt == instant)
        #expect(
            event.timeSummary(in: inNewYork.displayZone, calendar: .current)
                != event.timeSummary(in: inTokyo.displayZone, calendar: .current)
        )
        #expect(event.startAt == instant, "Reading a time in another zone must not rewrite it")
    }

    @Test("Nothing in the display layer hands back a rewritten date")
    func noMethodReturnsANewDate() throws {
        // A source check, because the bug this prevents — a helper that "converts" an event into
        // another zone and is then used on a save path — looks entirely reasonable in review and
        // silently moves people's meetings.
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let file = url.deletingLastPathComponent()
            .appending(path: "Sources/ElephruitCore/TimeZoneDisplay.swift")

        let contents = try String(contentsOf: file, encoding: .utf8)
        var offenders: [String] = []

        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public func") || trimmed.hasPrefix("public static func") else { continue }
            // `-> Date?` is allowed only where it names what a nonexistent time *resolved to*, which
            // is a report about an instant rather than a conversion of one.
            guard trimmed.contains("-> Date") else { continue }
            // `nonexistentLocalTime` names what a skipped wall-clock time *became*, which is a
            // report about an instant rather than a conversion of one.
            guard trimmed.contains("nonexistentLocalTime") else {
                offenders.append("line \(index + 1): \(trimmed)")
                continue
            }
        }

        #expect(offenders.isEmpty, """
            A display-zone helper that returns a Date will eventually be called on a save path, and \
            an event will move: \(offenders)
            """)
    }

    // MARK: Nonexistent and ambiguous times

    @Test("A time the clocks skip is reported, with what it becomes")
    func nonexistentTimeIsFlagged() {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let calendar = Self.calendar("America/New_York")

        // 02:30 on 8 March 2026 does not exist: the clocks go 02:00 → 03:00.
        let day = Self.date(2026, 3, 8, 12, zone: "America/New_York")
        let resolved = TimeZoneInspector.nonexistentLocalTime(
            day: day, hour: 2, minute: 30, zone: zone, calendar: calendar
        )

        #expect(resolved != nil, "A meeting set for a time that never happens has to be said out loud")
        if let resolved {
            #expect(calendar.component(.hour, from: resolved) == 3)
        }

        let warning = TimeZoneInspector.warningForRequestedTime(
            day: day, hour: 2, minute: 30, zone: zone, calendar: calendar
        )
        #expect(warning?.isProminent == true)
    }

    @Test("An ordinary time is not reported as nonexistent")
    func ordinaryTimesAreQuiet() {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let calendar = Self.calendar("America/New_York")
        let ordinary = Self.date(2026, 6, 15, 9, zone: "America/New_York")

        #expect(TimeZoneInspector.nonexistentLocalTime(
            day: ordinary, hour: 9, minute: 0, zone: zone, calendar: calendar
        ) == nil)
        #expect(!TimeZoneInspector.isAmbiguous(ordinary, zone: zone))
        #expect(TimeZoneInspector.warningForRequestedTime(
            day: ordinary, hour: 9, minute: 0, zone: zone, calendar: calendar
        ) == nil)
    }

    @Test("A time that happens twice is reported as ambiguous")
    func ambiguousTimeIsFlagged() {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        // 01:30 on 1 November 2026 happens twice — once in daylight time and once in standard.
        let repeated = Self.date(2026, 11, 1, 1, 30, zone: "America/New_York")
        #expect(TimeZoneInspector.isAmbiguous(repeated, zone: zone))
    }

    @Test("A zone with no daylight saving has no ambiguous times at all")
    func zonesWithoutDaylightSaving() {
        let zone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        let calendar = Self.calendar("Asia/Tokyo")

        for month in 1...12 {
            let instant = Self.date(2026, month, 15, 1, 30, zone: "Asia/Tokyo")
            #expect(!TimeZoneInspector.isAmbiguous(instant, zone: zone))
            #expect(TimeZoneInspector.nonexistentLocalTime(
                day: instant, hour: 1, minute: 30, zone: zone, calendar: calendar
            ) == nil)
        }
    }

    // MARK: Crossing a transition

    @Test("An event spanning a clock change says how long it really is")
    func eventsCrossingTransitions() {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let overnight = Self.date(2026, 3, 8, 0, zone: "America/New_York")

        let change = TimeZoneInspector.daylightSavingChange(
            in: overnight..<overnight.addingTimeInterval(6 * 3_600), zone: zone
        )
        #expect(change == 3_600, "Spring forward raises the offset by an hour")

        let autumn = Self.date(2026, 11, 1, 0, zone: "America/New_York")
        let back = TimeZoneInspector.daylightSavingChange(
            in: autumn..<autumn.addingTimeInterval(6 * 3_600), zone: zone
        )
        #expect(back == -3_600)
    }

    @Test("An ordinary event crosses nothing")
    func ordinaryEventsCrossNothing() {
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let start = Self.date(2026, 6, 15, 9, zone: "America/New_York")
        #expect(TimeZoneInspector.daylightSavingChange(
            in: start..<start.addingTimeInterval(3_600), zone: zone
        ) == nil)
    }

    @Test("A warning is raised for an event that loses an hour to the clocks")
    func draftWarnings() {
        let start = Self.date(2026, 3, 8, 0, zone: "America/New_York")
        let warnings = TimeZoneInspector.warnings(
            for: Self.draft(start: start, hours: 6, zone: "America/New_York"),
            display: TimeZoneDisplay(deviceZoneIdentifier: "America/New_York"),
            calendar: Self.calendar("America/New_York")
        )

        #expect(warnings.contains { if case .crossesDaylightSaving = $0 { return true } else { return false } })
    }

    @Test("An all-day event with a zone is called out")
    func allDayWithZoneIsFlagged() {
        var draft = Self.draft(
            start: Self.date(2026, 6, 15, 0, zone: "Europe/London"), hours: 24, zone: "Europe/London"
        )
        draft.isAllDay = true

        let warnings = TimeZoneInspector.warnings(
            for: draft,
            display: TimeZoneDisplay(deviceZoneIdentifier: "Europe/London"),
            calendar: Self.calendar("Europe/London")
        )

        #expect(warnings.contains(.allDayWithZone), """
            An all-day event pinned to a zone starts on the previous day for somebody far enough \
            west, which is how a birthday lands on the wrong date
            """)
        #expect(TimeZoneWarning.allDayWithZone.isProminent)
    }

    @Test("Showing another zone is said permanently rather than once")
    func displayZoneIsAnnounced() {
        let display = TimeZoneDisplay(
            deviceZoneIdentifier: "Europe/London", displayZoneIdentifier: "Asia/Tokyo"
        )
        #expect(display.isShowingAnotherZone)

        let warnings = TimeZoneInspector.warnings(
            for: Self.draft(start: Self.date(2026, 6, 15, 9, zone: "Europe/London"), hours: 1),
            display: display,
            calendar: Self.calendar("Asia/Tokyo")
        )

        let announced = warnings.contains {
            if case .shownInAnotherZone = $0 { return true } else { return false }
        }
        #expect(announced, "A calendar quietly showing Tokyo time is a missed meeting waiting to happen")
    }

    @Test("A series crossing a clock change is mentioned once, not per occurrence")
    func seriesCrossingTransition() {
        let calendar = Self.calendar("America/New_York")
        let zone = TimeZone(identifier: "America/New_York") ?? .gmt
        let start = Self.date(2026, 2, 24, 9, zone: "America/New_York")

        let weekly = EventRecurrence(frequency: .weekly, daysOfWeek: [.init(3)])
        #expect(TimeZoneInspector.seriesCrossesTransition(weekly, from: start, zone: zone, calendar: calendar))

        // A series that ends before the transition does not need the warning.
        let brief = EventRecurrence(frequency: .weekly, daysOfWeek: [.init(3)], end: .afterOccurrences(1))
        #expect(!TimeZoneInspector.seriesCrossesTransition(brief, from: start, zone: zone, calendar: calendar))
    }

    // MARK: Dual display

    @Test("Two zones read as one sentence, and only when they differ")
    func dualLabels() {
        let display = TimeZoneDisplay(
            deviceZoneIdentifier: "America/Chicago", secondaryZoneIdentifier: "Europe/London"
        )
        let instant = Self.date(2026, 6, 15, 15, zone: "America/Chicago")

        let label = display.dualLabel(
            for: instant,
            otherZone: TimeZone(identifier: "Europe/London") ?? .gmt,
            otherLabel: "Maya"
        )
        #expect(label?.contains("for you") == true)
        #expect(label?.contains("for Maya") == true)

        let sameZone = display.dualLabel(
            for: instant,
            otherZone: TimeZone(identifier: "America/Chicago") ?? .gmt,
            otherLabel: "Jordan"
        )
        #expect(sameZone == nil, "Saying the same time twice is noise, not information")
    }

    @Test("The ruler's offset is read at the instant, not taken as a constant")
    func offsetFollowsTheDate() {
        let display = TimeZoneDisplay(
            deviceZoneIdentifier: "Europe/London", secondaryZoneIdentifier: "America/New_York"
        )

        // For two weeks each spring the gap between London and New York is four hours rather than
        // five, and a ruler built on a fixed five is wrong for exactly the fortnight most likely to
        // confuse somebody.
        // Both on standard time, and both on summer time, give the familiar five hours.
        let inFebruary = Self.date(2026, 2, 12, 12, zone: "Europe/London")
        let inJune = Self.date(2026, 6, 12, 12, zone: "Europe/London")

        #expect(display.secondaryOffsetHours(at: inFebruary) == -5)
        #expect(display.secondaryOffsetHours(at: inJune) == -5)

        // 22 March 2026: the United States has changed and the United Kingdom has not.
        let between = Self.date(2026, 3, 22, 12, zone: "Europe/London")
        #expect(display.secondaryOffsetHours(at: between) == -4)
    }

    @Test("A zone shows a name a person would recognise")
    func zoneNames() {
        let instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(TimeZoneDisplay.shortName(for: TimeZone(identifier: "America/New_York") ?? .gmt, at: instant)
            == "New York")
        #expect(TimeZoneDisplay.shortName(for: TimeZone(identifier: "Europe/London") ?? .gmt, at: instant)
            == "London")
    }

    @Test("Travel mode is something the user turns on, not something the network decides")
    func travelModeIsExplicit() {
        var display = TimeZoneDisplay(deviceZoneIdentifier: "Europe/London")
        #expect(!display.isTravelling)

        display.isTravelling = true
        display.displayZoneIdentifier = "Asia/Tokyo"
        #expect(display.displayZone.identifier == "Asia/Tokyo")
        #expect(display.deviceZone.identifier == "Europe/London", """
            Travel mode changes what is drawn, never where the Mac thinks it is — otherwise landing \
            somewhere would rewrite the calendar before anybody could check it
            """)
    }

    @Test("An unknown zone identifier falls back rather than failing")
    func unknownZonesFallBack() {
        let display = TimeZoneDisplay(
            deviceZoneIdentifier: "Europe/London", displayZoneIdentifier: "Mars/Olympus"
        )
        #expect(display.displayZone.identifier == "Europe/London")
    }
}
