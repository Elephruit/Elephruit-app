import ElephruitCore
import Foundation
import Testing

@Suite("Calendar colours")
struct CalendarPaletteTests {
    @Test("A calendar's colour becomes the nearest palette name")
    func hueMapsToName() {
        #expect(CalendarPalette.name(red: 1, green: 0, blue: 0) == "red")
        #expect(CalendarPalette.name(red: 0, green: 0, blue: 1) == "blue")
        #expect(CalendarPalette.name(red: 0.1, green: 0.7, blue: 0.2) == "green")
        #expect(CalendarPalette.name(red: 0.6, green: 0.2, blue: 0.8) == "purple")
        // 260° is the blue side of violet, and calling it indigo is the reading a person would give.
        #expect(CalendarPalette.name(red: 0.4, green: 0.2, blue: 0.8) == "indigo")
    }

    @Test("A colour with no meaningful hue is grey rather than a guess")
    func greysAreNotRounded() {
        // The failure this prevents: a near-white calendar whose red channel leads by a hundredth
        // coming out "red", which then means a colour indicator that says something untrue.
        #expect(CalendarPalette.name(red: 0.5, green: 0.5, blue: 0.5) == "graphite")
        #expect(CalendarPalette.name(red: 0.52, green: 0.5, blue: 0.5) == "graphite")
        #expect(CalendarPalette.name(red: 0.02, green: 0.01, blue: 0.01) == "graphite")
    }

    @Test("A dark, muted orange is brown rather than orange")
    func brownIsDistinguished() {
        #expect(CalendarPalette.name(red: 0.45, green: 0.28, blue: 0.12) == "brown")
    }

    @Test("Every name produced is one the design system knows")
    func namesAreAllValid() {
        // Sampled across the hue circle, because the mapping is the one place a name could be
        // invented — and an unknown name silently falls back to the accent colour, which looks
        // deliberate and is not.
        for step in 0..<36 {
            let hue = Double(step) / 36
            let (red, green, blue) = Self.rgb(hue: hue)
            let name = CalendarPalette.name(red: red, green: green, blue: blue)
            #expect(CalendarPalette.names.contains(name), "\(name) is not in the palette")
        }
    }

    @Test("Out-of-range components do not produce a nonsense name")
    func componentsAreClamped() {
        let name = CalendarPalette.name(red: 3, green: -1, blue: 0.5)
        #expect(CalendarPalette.names.contains(name))
    }

    private static func rgb(hue: Double) -> (Double, Double, Double) {
        let sector = hue * 6
        let fraction = sector - sector.rounded(.down)
        let q = 1 - fraction
        switch Int(sector) % 6 {
        case 0: return (1, fraction, 0)
        case 1: return (q, 1, 0)
        case 2: return (0, 1, fraction)
        case 3: return (0, q, 1)
        case 4: return (fraction, 0, 1)
        default: return (1, 0, q)
        }
    }
}

@Suite("Finding a calendar again")
struct CalendarReferenceTests {
    private static let calendars = [
        CalendarInfo(id: "a1", title: "Work", accountName: "Acme", accountKind: .exchange),
        CalendarInfo(id: "b2", title: "Personal", accountName: "iCloud", accountKind: .iCloud),
        CalendarInfo(id: "c3", title: "Work", accountName: "iCloud", accountKind: .iCloud),
    ]

    @Test("An identifier that still exists resolves directly")
    func identifierWins() {
        let reference = CalendarReference(identifier: "b2", title: "Renamed", accountName: "Wrong")
        #expect(reference.resolve(among: Self.calendars)?.id == "b2",
                "The identifier is authoritative when it still matches something")
    }

    @Test("A re-added account is found again by title and account")
    func titleAndAccountFallback() {
        // What actually happens: removing a Google account and adding it back gives every calendar a
        // new identifier, and a Calendar Set that stored only identifiers silently empties itself.
        let reference = CalendarReference(identifier: "gone", title: "Work", accountName: "iCloud")
        #expect(reference.resolve(among: Self.calendars)?.id == "c3")
    }

    @Test("An ambiguous title is not guessed at")
    func ambiguousTitleRefuses() {
        // Two calendars called Work. Picking one would put private appointments in front of
        // colleagues, or the reverse, and the user would never be told which had happened.
        let reference = CalendarReference(identifier: "gone", title: "Work", accountName: "Neither")
        #expect(reference.resolve(among: Self.calendars) == nil)
    }

    @Test("An unambiguous title alone is enough")
    func uniqueTitleResolves() {
        let reference = CalendarReference(identifier: "gone", title: "Personal", accountName: "Renamed")
        #expect(reference.resolve(among: Self.calendars)?.id == "b2")
    }

    @Test("A calendar that is simply gone resolves to nothing")
    func missingCalendarIsNil() {
        let reference = CalendarReference(identifier: "gone", title: "Nowhere", accountName: "None")
        #expect(reference.resolve(among: Self.calendars) == nil)
    }
}

@Suite("Alarms")
struct EventAlarmTests {
    @Test("An alarm says when it fires in plain words")
    func alarmsDescribeThemselves() {
        #expect(EventAlarm.minutesBefore(0).displayName == "At the time of the event")
        #expect(EventAlarm.minutesBefore(15).displayName == "15 minutes before")
        #expect(EventAlarm.minutesBefore(60).displayName == "1 hour before")
        #expect(EventAlarm.minutesBefore(90).displayName == "1 hour 30 min before")
        #expect(EventAlarm.minutesBefore(1_440).displayName == "1 day before")
        #expect(EventAlarm.minutesBefore(10_080).displayName == "1 week before")
    }

    @Test("A negative offset reads as after the event, not as a negative number of minutes")
    func alarmsAfterTheEvent() {
        let after = EventAlarm(relativeOffset: 600)
        #expect(after.displayName == "10 minutes after")
    }

    @Test("A relative alarm's fire time follows the event")
    func relativeAlarmsMoveWithTheEvent() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let alarm = EventAlarm.minutesBefore(30)
        #expect(alarm.fireDate(forEventStartingAt: start) == start.addingTimeInterval(-1_800))
    }

    @Test("An absolute alarm does not")
    func absoluteAlarmsStayPut() {
        let fixed = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let alarm = EventAlarm.at(fixed)
        #expect(alarm.fireDate(forEventStartingAt: Date()) == fixed)
    }
}

@Suite("Event drafts")
struct EventDraftTests {
    private static let clock = FixedDateProvider.reference

    private static func draft(
        calendar: String = "work",
        title: String = "Standup",
        minutes: Int = 30
    ) -> EventDraft {
        let start = clock.startOfToday.addingTimeInterval(9 * 3_600)
        return EventDraft(
            calendarIdentifier: calendar,
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    private static let writable = CalendarInfo(id: "work", title: "Work", accountKind: .iCloud)
    private static let readOnly = CalendarInfo(
        id: "holidays", title: "Holidays", accountKind: .subscribed, allowsModification: true
    )

    @Test("A complete draft has nothing wrong with it")
    func validDraftPasses() {
        #expect(Self.draft().problems(savingTo: Self.writable).isEmpty)
        #expect(Self.draft().canSave(to: Self.writable))
    }

    @Test("A missing title is worth mentioning but does not block saving")
    func untitledEventsAreAllowed() {
        let problems = Self.draft(title: "  ").problems(savingTo: Self.writable)
        #expect(problems == [.titleMissing])
        #expect(Self.draft(title: "").canSave(to: Self.writable), """
            Blocking an untitled event means someone who typed only a time cannot get it into their \
            calendar, which is worse than a row reading "Untitled event"
            """)
    }

    @Test("A read-only calendar blocks the save")
    func readOnlyCalendarBlocks() {
        let problems = Self.draft(calendar: "holidays").problems(savingTo: Self.readOnly)
        #expect(problems.contains(.calendarReadOnly))
        #expect(!Self.draft(calendar: "holidays").canSave(to: Self.readOnly))
    }

    @Test("An end before its start blocks the save")
    func backwardsEventBlocks() {
        var draft = Self.draft()
        draft.endAt = draft.startAt.addingTimeInterval(-600)
        #expect(!draft.canSave(to: Self.writable))
    }

    @Test("A very long event warns rather than refuses")
    func sabbaticalsAreAllowed() {
        var draft = Self.draft()
        draft.endAt = draft.startAt.addingTimeInterval(400 * 86_400)
        #expect(draft.problems(savingTo: Self.writable).contains(.implausiblyLong))
        #expect(draft.canSave(to: Self.writable), "A six-month sabbatical is a real thing to record")
    }

    @Test("Moving an event keeps its length")
    func movingPreservesDuration() {
        var draft = Self.draft(minutes: 45)
        let length = draft.duration
        draft.move(to: draft.startAt.addingTimeInterval(7_200))
        #expect(draft.duration == length)
    }

    @Test("A duration can never be shortened to nothing")
    func durationHasAFloor() {
        var draft = Self.draft()
        draft.setDuration(0)
        #expect(draft.duration >= 60, "A drag that overshoots must not produce a zero-length event")
    }

    @Test("Editing an existing event carries over only what a person decides")
    func editingDraftCopiesTheRightFields() {
        let event = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "x"),
            title: "Review",
            startAt: Self.clock.startOfToday,
            endAt: Self.clock.startOfToday.addingTimeInterval(3_600),
            calendarIdentifier: "work",
            locationName: "Room 2",
            notes: "Bring the numbers",
            availability: .tentative,
            alarms: [.minutesBefore(10)],
            attendees: [EventAttendee(name: "Maya Chen", emailAddress: "maya@example.com")],
            organizerName: "Someone Else",
            lastModifiedAt: Date()
        )

        let draft = EventDraft(editing: event)

        #expect(draft.title == "Review")
        #expect(draft.location == "Room 2")
        #expect(draft.availability == .tentative)
        #expect(draft.alarms.count == 1)
        // There is nowhere on a draft for an attendee, an organiser, or a modification date, which
        // is the guarantee rather than an omission.
        #expect(draft.calendarIdentifier == "work")
    }
}

@Suite("Changes that need confirming")
struct EventConfirmationTests {
    private static let names = ["work": "Work", "personal": "Personal"]

    private static func event(calendar: String, recurring: Bool = false) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "e", occurrenceDate: recurring ? Date() : nil),
            title: "Standup",
            startAt: Date(),
            endAt: Date().addingTimeInterval(1_800),
            calendarIdentifier: calendar,
            isRecurring: recurring
        )
    }

    private static func draft(calendar: String) -> EventDraft {
        EventDraft(
            calendarIdentifier: calendar,
            title: "Standup",
            startAt: Date(),
            endAt: Date().addingTimeInterval(1_800)
        )
    }

    @Test("An ordinary edit is not interrupted")
    func retitlingNeedsNoConfirmation() {
        let required = Self.draft(calendar: "work")
            .confirmationsRequired(replacing: Self.event(calendar: "work"), calendarNames: Self.names)
        #expect(required.isEmpty, "Interrupting every edit trains people to click through the ones that matter")
    }

    @Test("Moving between calendars is confirmed, with both names in the sentence")
    func calendarMoveIsConfirmed() {
        let required = Self.draft(calendar: "personal")
            .confirmationsRequired(replacing: Self.event(calendar: "work"), calendarNames: Self.names)

        #expect(required.count == 1)
        #expect(required.first?.message.contains("Work") == true)
        #expect(required.first?.message.contains("Personal") == true)
        #expect(required.first?.needsScopeChoice == false)
    }

    @Test("Changing a recurring event always asks which occurrences")
    func recurringEditAsksForScope() {
        let required = Self.draft(calendar: "work")
            .confirmationsRequired(replacing: Self.event(calendar: "work", recurring: true), calendarNames: Self.names)

        #expect(required.count == 1)
        #expect(required.first?.needsScopeChoice == true)
    }

    @Test("A drag that does both asks about both")
    func bothConfirmationsCanApply() {
        let required = Self.draft(calendar: "personal")
            .confirmationsRequired(
                replacing: Self.event(calendar: "work", recurring: true), calendarNames: Self.names
            )
        #expect(required.count == 2)
    }
}

@Suite("Events in a day")
struct CalendarEventShapeTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static func event(start: Date, hours: Double, allDay: Bool = false) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "e"),
            title: "Thing",
            startAt: start,
            endAt: start.addingTimeInterval(hours * 3_600),
            isAllDay: allDay
        )
    }

    private static var midnight: Date {
        calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test("An event ending exactly at midnight belongs to one day, not two")
    func midnightEndDoesNotClaimTheNextDay() {
        let event = Self.event(start: Self.midnight.addingTimeInterval(23 * 3_600), hours: 1)
        #expect(!event.spansMultipleDays(calendar: Self.calendar), """
            Every 11pm–midnight event would otherwise draw a multi-day bar across the following day
            """)
        #expect(event.days(in: Self.calendar).count == 1)
    }

    @Test("An event crossing midnight touches both days")
    func overnightEventsSpanTwoDays() {
        let event = Self.event(start: Self.midnight.addingTimeInterval(23 * 3_600), hours: 3)
        #expect(event.spansMultipleDays(calendar: Self.calendar))
        #expect(event.days(in: Self.calendar).count == 2)
    }

    @Test("A multi-day event belongs in the all-day band even when it has times")
    func multiDayEventsUseTheAllDayRow() {
        let conference = Self.event(start: Self.midnight.addingTimeInterval(9 * 3_600), hours: 50)
        #expect(conference.occupiesAllDayRow(calendar: Self.calendar), """
            A three-day conference drawn as a column would be taller than the grid it is in
            """)
    }

    @Test("A zero-length event still belongs to its day")
    func zeroLengthEventsAreVisible() {
        let moment = Self.event(start: Self.midnight, hours: 0)
        #expect(moment.occurs(on: Self.midnight, calendar: Self.calendar))
    }

    @Test("The day list is bounded, so a corrupt event cannot hang a view")
    func dayListIsBounded() {
        let absurd = Self.event(start: Self.midnight, hours: 24 * 5_000)
        #expect(absurd.days(in: Self.calendar, limit: 40).count == 40)
    }

    @Test("An event with no time zone floats")
    func floatingEvents() {
        var event = Self.event(start: Self.midnight, hours: 1)
        #expect(event.isFloating)

        event.timeZoneIdentifier = "Europe/London"
        #expect(!event.isFloating)
        #expect(event.timeZone?.identifier == "Europe/London")
    }

    @Test("Attendee names come from the attendee list and exclude the user")
    func attendeeNamesAreDerived() {
        var event = Self.event(start: Self.midnight, hours: 1)
        event.attendees = [
            EventAttendee(name: "Maya Chen", emailAddress: "maya@example.com"),
            EventAttendee(name: "You", emailAddress: "me@example.com", isCurrentUser: true),
        ]
        #expect(event.attendeeNames == ["Maya Chen"])
    }

    @Test("Initials fall back to an email address when there is no name")
    func initialsFromEmail() {
        let anonymous = EventAttendee(name: "", emailAddress: "jordan.blake@example.com")
        #expect(anonymous.initials == "JB")
        #expect(EventAttendee(name: "Maya Chen").initials == "MC")
    }

    // MARK: - Putting the organizer back

    /// The shape an Exchange invitation arrives in when it lands in an iCloud calendar: one attendee,
    /// who is you, and the person who called the meeting reachable only as the organizer.
    @Test("An organizer who is not on the attendee list is added to it")
    func organizerJoinsTheAttendeeList() {
        let merged = EventAttendee.merging(
            organizer: EventAttendee(
                name: "Harbinder Raina",
                emailAddress: "harbinder.raina@example.com",
                isOrganizer: true
            ),
            into: [EventAttendee(name: "me@example.com", emailAddress: "me@example.com", isCurrentUser: true)]
        )

        #expect(merged.count == 2)
        #expect(merged.first?.name == "Harbinder Raina")
        #expect(merged.first?.isOrganizer == true)
        #expect(merged.first?.isCurrentUser == false)
    }

    @Test("An organizer already on the attendee list is not duplicated")
    func organizerAlreadyInvited() {
        let attendees = [
            EventAttendee(name: "Maya Chen", emailAddress: "Maya@Example.com ", isOrganizer: true),
            EventAttendee(name: "You", emailAddress: "me@example.com", isCurrentUser: true),
        ]
        let merged = EventAttendee.merging(
            organizer: EventAttendee(name: "Maya Chen", emailAddress: "maya@example.com", isOrganizer: true),
            into: attendees
        )
        #expect(merged == attendees)
    }

    /// Some accounts hand over a name and no address at all, which is still enough to know the
    /// organizer is the person already sitting in the list.
    @Test("An organizer with no address is matched on name")
    func organizerMatchedOnName() {
        let attendees = [EventAttendee(name: "Maya Chen", emailAddress: "maya@example.com")]
        let merged = EventAttendee.merging(organizer: EventAttendee(name: "maya chen"), into: attendees)
        #expect(merged == attendees)
    }

    @Test("An event with no organizer is left alone")
    func noOrganizer() {
        let attendees = [EventAttendee(name: "Maya Chen", emailAddress: "maya@example.com")]
        #expect(EventAttendee.merging(organizer: nil, into: attendees) == attendees)
    }

    /// The whole point of the merge: this event is a meeting with somebody, and every surface
    /// downstream reads that from the attendee list.
    @Test("An invitation whose only listed attendee is the user is still a meeting")
    func organizerMakesItAMeeting() {
        var event = Self.event(start: Self.midnight, hours: 1)
        event.attendees = EventAttendee.merging(
            organizer: EventAttendee(
                name: "Harbinder Raina",
                emailAddress: "harbinder.raina@example.com",
                isOrganizer: true
            ),
            into: [EventAttendee(name: "me@example.com", emailAddress: "me@example.com", isCurrentUser: true)]
        )

        #expect(DayEventRules.kind(of: event) == .meeting)
        #expect(event.attendeeNames == ["Harbinder Raina"])
    }
}
