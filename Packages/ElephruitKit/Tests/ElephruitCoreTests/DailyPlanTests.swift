import ElephruitCore
import Foundation
import Testing

/// The rules that decide what a day is made of.
///
/// Every one of these is a sentence somebody could argue with — *that is a meeting, that is a clash,
/// you have three hours free* — and every one of them is wrong in a way that is invisible until
/// somebody plans against it. So they are values over a fixed clock rather than behaviour in a view.
@Suite("What a day is made of")
struct DailyPlanTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// A Wednesday, so the working-hours rules are exercised on a working day.
    static let today = Date(timeIntervalSinceReferenceDate: 757_382_400)

    static func at(_ hour: Double, dayOffset: Int = 0) -> Date {
        today.addingTimeInterval(Double(dayOffset) * 86_400 + hour * 3_600)
    }

    static func event(
        _ title: String,
        id: String? = nil,
        from start: Date,
        minutes: Int,
        attendees: [String] = [],
        availability: EventAvailability = .busy,
        allDay: Bool = false,
        status: EventStatus = .confirmed,
        participation: EventParticipation = .unknown
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: id ?? title),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: allDay,
            status: status,
            participation: participation,
            availability: availability,
            attendees: attendees.map { EventAttendee(name: $0) }
        )
    }

    // MARK: - What an entry actually is

    @Test("An entry with somebody else on it is a meeting; an entry with nobody on it is not")
    func attendeesDecideWhatIsAMeeting() {
        let review = Self.event("Design review", from: Self.at(10), minutes: 60, attendees: ["Maya"])
        let dentist = Self.event("Dentist", from: Self.at(15), minutes: 30)

        #expect(DayEventRules.kind(of: review) == .meeting)
        #expect(DayEventRules.kind(of: dentist) == .appointment)
        #expect(review.attendees.count == 1)
    }

    @Test("Only you on the invitation is not a meeting")
    func aRoomOfOneIsNotAMeeting() {
        let solo = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "solo"),
            title: "Blocked",
            startAt: Self.at(9),
            endAt: Self.at(10),
            attendees: [EventAttendee(name: "Alex", isCurrentUser: true)]
        )
        #expect(DayEventRules.kind(of: solo) == .appointment)
    }

    @Test("Attendees outrank shape, so an offsite is a meeting that happens to be all day")
    func attendeesOutrankAllDay() {
        let offsite = Self.event(
            "Team offsite", from: Self.at(0), minutes: 24 * 60, attendees: ["Maya", "Rosa"], allDay: true
        )
        #expect(DayEventRules.kind(of: offsite) == .meeting)
        #expect(offsite.occupiesAllDayRow(calendar: Self.calendar), "still belongs in the all-day band")
    }

    @Test("Availability, not the title, says what a block is")
    func availabilityDecidesTheRest() {
        #expect(
            DayEventRules.kind(of: Self.event("Focus", from: Self.at(14), minutes: 120, availability: .free))
                == .focusBlock
        )
        #expect(
            DayEventRules.kind(of: Self.event("Leave", from: Self.at(0), minutes: 24 * 60,
                                              availability: .unavailable, allDay: true))
                == .away
        )
        // The trap this rule exists to avoid: a title that reads like travel, marked ordinary busy.
        #expect(
            DayEventRules.kind(of: Self.event("Travel to Berlin", from: Self.at(8), minutes: 180))
                == .appointment
        )
    }

    @Test("Only a meeting has a guest list to show")
    func onlyMeetingsHaveAttendees() {
        for kind in DayEventKind.allCases {
            #expect(kind.hasAttendees == (kind == .meeting))
            #expect(kind.countsAsMeeting == (kind == .meeting))
        }
    }

    @Test("A declined invitation is out of the day; a cancelled meeting stays in it")
    func declinedLeavesAndCancelledStays() {
        let declined = Self.event("All-hands", from: Self.at(16), minutes: 60,
                                  attendees: ["Rosa"], participation: .declined)
        let cancelled = Self.event("Budget review", from: Self.at(14), minutes: 60,
                                   attendees: ["Rosa"], status: .cancelled)

        #expect(!DayEventRules.appearsInPlan(declined))
        #expect(DayEventRules.appearsInPlan(cancelled), "somebody remembers it being there")
        #expect(cancelled.isCancelled)
    }

    // MARK: - Clashes

    @Test("Two things wanting the same hour is a clash, and each says what it clashes with")
    func overlappingBusyEventsClash() {
        let review = Self.event("Design review", from: Self.at(10), minutes: 90, attendees: ["Maya"])
        let vendor = Self.event("Vendor call", from: Self.at(10.5), minutes: 30)

        let clashes = DayEventRules.conflicts(among: [review, vendor], calendar: Self.calendar)
        #expect(clashes[review.id] == [vendor.id])
        #expect(clashes[vendor.id] == [review.id])
    }

    @Test("A focus block being eaten by a meeting is not a clash")
    func freeTimeDoesNotClash() {
        let focus = Self.event("Focus", from: Self.at(14), minutes: 120, availability: .free)
        let meeting = Self.event("Sync", from: Self.at(14.5), minutes: 30, attendees: ["Rosa"])

        #expect(DayEventRules.conflicts(among: [focus, meeting], calendar: Self.calendar).isEmpty)
    }

    @Test("An all-day entry does not clash with the day it covers")
    func allDayDoesNotClashWithEverything() {
        let trip = Self.event("Berlin", from: Self.at(0), minutes: 24 * 60, allDay: true)
        let meeting = Self.event("Sync", from: Self.at(11), minutes: 30, attendees: ["Rosa"])

        #expect(DayEventRules.conflicts(among: [trip, meeting], calendar: Self.calendar).isEmpty)
    }

    @Test("A cancelled or declined meeting cannot make something else look double-booked")
    func absentEventsDoNotClash() {
        let real = Self.event("Design review", from: Self.at(10), minutes: 60, attendees: ["Maya"])
        let cancelled = Self.event("Budget", from: Self.at(10), minutes: 60,
                                   attendees: ["Rosa"], status: .cancelled)
        let declined = Self.event("All-hands", from: Self.at(10), minutes: 60,
                                  attendees: ["Rosa"], participation: .declined)

        #expect(DayEventRules.conflicts(among: [real, cancelled, declined], calendar: Self.calendar).isEmpty)
    }

    @Test("Back to back is not overlapping")
    func adjacentEventsDoNotClash() {
        let first = Self.event("One", from: Self.at(10), minutes: 60, attendees: ["Maya"])
        let second = Self.event("Two", from: Self.at(11), minutes: 60, attendees: ["Rosa"])

        #expect(DayEventRules.conflicts(among: [first, second], calendar: Self.calendar).isEmpty)
    }

    // MARK: - How much of the day is left

    static let workingHours = WorkingHours(
        startMinutes: 9 * 60, endMinutes: 17 * 60, weekdays: [1, 2, 3, 4, 5, 6, 7]
    )

    @Test("Free time is the working window minus what genuinely occupies it")
    func focusTimeSubtractsBusyEvents() {
        let events = [
            Self.event("Review", from: Self.at(10), minutes: 60, attendees: ["Maya"]),
            Self.event("Sync", from: Self.at(14), minutes: 30, attendees: ["Rosa"]),
        ]

        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: events, workingHours: Self.workingHours,
            // A day that is not today, so the window opens at nine rather than now.
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )

        // Eight hours, less ninety minutes.
        #expect(focus.available == 6.5 * 3_600)
        #expect(!focus.isClosed)
    }

    @Test("Today's free time starts now, because time already spent is not available")
    func todayCountsFromNow() {
        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: [], workingHours: Self.workingHours,
            now: Self.at(15), calendar: Self.calendar
        )
        #expect(focus.available == 2 * 3_600)
    }

    @Test("The longest single stretch is reported, because four gaps are not one afternoon")
    func longestStretchIsTheUsefulNumber() {
        let events = [
            Self.event("A", from: Self.at(10), minutes: 30, attendees: ["Maya"]),
            Self.event("B", from: Self.at(11), minutes: 30, attendees: ["Maya"]),
            Self.event("C", from: Self.at(12), minutes: 30, attendees: ["Maya"]),
        ]

        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: events, workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )

        // 12:30–17:00 is the longest unbroken run.
        #expect(focus.longestStretch?.lowerBound == Self.at(12.5))
        #expect(focus.longestStretch?.upperBound == Self.at(17))
    }

    @Test("A block marked free does not eat into free time, which is the point of it")
    func focusBlocksDoNotConsumeFocusTime() {
        let focus = FocusTimeRules.focusTime(
            on: Self.today,
            events: [Self.event("Focus", from: Self.at(14), minutes: 120, availability: .free)],
            workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1),
            calendar: Self.calendar
        )
        #expect(focus.available == 8 * 3_600)
    }

    @Test("A day the user does not work has no free-time figure at all")
    func nonWorkingDaysReportNothing() {
        let weekdaysOnly = WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60, weekdays: [])
        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: [], workingHours: weekdaysOnly,
            now: Self.at(9), calendar: Self.calendar
        )

        #expect(focus.isClosed)
        #expect(!focus.hasAny)
        #expect(focus.summary == "Day's done")
    }

    @Test("A day already over reports nothing rather than a negative")
    func pastDaysAreClosed() {
        let focus = FocusTimeRules.focusTime(
            on: Self.at(0, dayOffset: -3), events: [], workingHours: Self.workingHours,
            now: Self.today, calendar: Self.calendar
        )
        #expect(focus.isClosed)
        #expect(focus.available == 0)
    }

    // MARK: - Free time, named

    @Test("Every gap worth offering is handed back, in clock order, with its own times")
    func freeSlotsAreNamedRatherThanTotalled() {
        let events = [
            Self.event("Standup", from: Self.at(9.5), minutes: 30, attendees: ["Maya"]),
            Self.event("Review", from: Self.at(11), minutes: 60, attendees: ["Maya"]),
        ]

        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: events, workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )

        // 9:00–9:30, 10:00–11:00, 12:00–17:00.
        #expect(focus.slots.map(\.range.lowerBound) == [Self.at(9), Self.at(10), Self.at(12)])
        #expect(focus.slots.map(\.range.upperBound) == [Self.at(9.5), Self.at(11), Self.at(17)])
        #expect(focus.slots.allSatisfy { !$0.isCurrent }, "no stretch of a future day is under way")
    }

    @Test("A gap too short to use is not offered as free time")
    func shortGapsAreNotOpportunities() {
        let events = [
            Self.event("A", from: Self.at(9), minutes: 55, attendees: ["Maya"]),
            // Five minutes between them: walking, not free time.
            Self.event("B", from: Self.at(10), minutes: 420, attendees: ["Maya"]),
        ]

        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: events, workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )

        #expect(focus.slots.isEmpty)
        // The total still counts it, because it is genuinely unclaimed. The two numbers answer
        // different questions and are deliberately allowed to differ.
        #expect(focus.available == 5 * 60)
    }

    @Test("The stretch happening now says so, because a start time in the past means nothing")
    func theCurrentStretchIsMarked() {
        let focus = FocusTimeRules.focusTime(
            on: Self.today,
            events: [Self.event("Review", from: Self.at(15), minutes: 60, attendees: ["Maya"])],
            workingHours: Self.workingHours,
            now: Self.at(14), calendar: Self.calendar
        )

        #expect(focus.slots.count == 2)
        #expect(focus.slots[0].isCurrent)
        #expect(focus.slots[0].rangeSummary.hasPrefix("until"))
        #expect(!focus.slots[1].isCurrent, "16:00–17:00 has not started")
        #expect(focus.slots[1].durationSummary == "1h")
    }

    @Test("Free time is said as a fraction of the time it is free out of")
    func freeTimeCarriesItsDenominator() {
        let events = [Self.event("Review", from: Self.at(10), minutes: 60, attendees: ["Maya"])]

        let wholeDay = FocusTimeRules.focusTime(
            on: Self.today, events: events, workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )
        #expect(wholeDay.windowLength == 8 * 3_600)
        #expect(wholeDay.proportionSummary == "7h free of 8h")

        // Late in the day the denominator is what is left, not the eight hours mostly spent — "30m
        // free of 8h" at four in the afternoon is true and useless.
        let lateOn = FocusTimeRules.focusTime(
            on: Self.today, events: [], workingHours: Self.workingHours,
            now: Self.at(16), calendar: Self.calendar
        )
        #expect(lateOn.windowLength == 3_600)
        #expect(lateOn.proportionSummary == "1h free of 1h")
    }

    @Test("A day with nothing free says so rather than saying nothing of nothing")
    func anEmptyDenominatorFallsBack() {
        let focus = FocusTimeRules.focusTime(
            on: Self.today,
            events: [Self.event("All of it", from: Self.at(9), minutes: 480, attendees: ["Maya"])],
            workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1), calendar: Self.calendar
        )

        #expect(!focus.hasAny)
        #expect(focus.proportionSummary == focus.summary)
        #expect(focus.proportionSummary == "Nothing free")
    }

    @Test("A day with no working window offers nothing to fill")
    func closedDaysOfferNoSlots() {
        let weekdaysOnly = WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60, weekdays: [])
        let focus = FocusTimeRules.focusTime(
            on: Self.today, events: [], workingHours: weekdaysOnly,
            now: Self.at(9), calendar: Self.calendar
        )
        #expect(focus.slots.isEmpty)

        let past = FocusTimeRules.focusTime(
            on: Self.at(0, dayOffset: -3), events: [], workingHours: Self.workingHours,
            now: Self.today, calendar: Self.calendar
        )
        #expect(past.slots.isEmpty)
    }

    @Test("A block marked free is still free time somebody can be offered")
    func defendedBlocksStayOfferable() {
        let focus = FocusTimeRules.focusTime(
            on: Self.today,
            events: [Self.event("Focus", from: Self.at(14), minutes: 120, availability: .free)],
            workingHours: Self.workingHours,
            now: Self.at(9, dayOffset: -1),
            calendar: Self.calendar
        )

        #expect(focus.slots.count == 1)
        #expect(focus.slots[0].range == Self.at(9)..<Self.at(17))
    }

    // MARK: - Awareness

    @Test("What describes the day sits apart from what claims an hour of it")
    func awarenessIsSeparateFromTheSchedule() {
        let trip = DayEvent(
            event: Self.event("Berlin", from: Self.at(0), minutes: 4 * 24 * 60, allDay: true),
            kind: .allDay
        )
        let leave = DayEvent(
            event: Self.event("Leave", from: Self.at(9), minutes: 480, availability: .unavailable),
            kind: .away
        )
        let review = DayEvent(
            event: Self.event("Review", from: Self.at(10), minutes: 60, attendees: ["Maya"]),
            kind: .meeting
        )
        let dentist = DayEvent(
            event: Self.event("Dentist", from: Self.at(15), minutes: 30),
            kind: .appointment
        )

        let plan = DayPlan(
            date: Self.today,
            isToday: true,
            briefing: DayBriefing(date: Self.today, isToday: true),
            events: [trip, leave, review, dentist]
        )

        #expect(plan.awarenessEvents(calendar: Self.calendar).map(\.id) == ["Berlin", "Leave"])
        #expect(plan.scheduleEvents(calendar: Self.calendar).map(\.id) == ["Review", "Dentist"])
    }

    @Test("A week-long offsite is a meeting, not a fact about the week")
    func attendeesKeepAnEventOutOfAwareness() {
        let offsite = DayEvent(
            event: Self.event(
                "Offsite", from: Self.at(0), minutes: 4 * 24 * 60,
                attendees: ["Maya", "Rosa"], allDay: true
            ),
            kind: .meeting
        )

        let plan = DayPlan(
            date: Self.today,
            isToday: true,
            briefing: DayBriefing(date: Self.today, isToday: true),
            events: [offsite]
        )

        #expect(plan.awarenessEvents(calendar: Self.calendar).isEmpty, "it has a guest list to show")
        #expect(plan.allDayEvents(calendar: Self.calendar).count == 1, "it is still an all-day entry")
        #expect(
            plan.scheduleEvents(calendar: Self.calendar).map(\.id) == ["Offsite"],
            """
            refused by awareness for having attendees and by the timeline for being all-day, it \
            would otherwise appear nowhere at all
            """
        )
    }

    @Test("Awareness and the schedule together are every event, and share none")
    func theTwoHalvesAccountForTheWholeDay() {
        let events = [
            DayEvent(event: Self.event("Berlin", from: Self.at(0), minutes: 1_440, allDay: true), kind: .allDay),
            DayEvent(
                event: Self.event("Leave", from: Self.at(9), minutes: 480, availability: .unavailable),
                kind: .away
            ),
            DayEvent(event: Self.event("Review", from: Self.at(10), minutes: 60, attendees: ["Maya"]), kind: .meeting),
            DayEvent(event: Self.event("Focus", from: Self.at(14), minutes: 60, availability: .free), kind: .focusBlock),
            // The awkward one: all-day *and* a meeting, so each half has a reason to refuse it.
            DayEvent(
                event: Self.event(
                    "Offsite", from: Self.at(0), minutes: 2 * 24 * 60,
                    attendees: ["Rosa"], allDay: true
                ),
                kind: .meeting
            ),
        ]

        let plan = DayPlan(
            date: Self.today,
            isToday: true,
            briefing: DayBriefing(date: Self.today, isToday: true),
            events: events
        )

        let awareness = Set(plan.awarenessEvents(calendar: Self.calendar).map(\.id))
        let schedule = Set(plan.scheduleEvents(calendar: Self.calendar).map(\.id))

        #expect(awareness.isDisjoint(with: schedule), "nothing may be drawn twice")
        #expect(awareness.union(schedule) == Set(events.map(\.id)), "nothing may be dropped")
    }

    @Test("Durations are rounded down to five minutes rather than claiming a precision they lack")
    func durationsAreRounded() {
        #expect(DurationPhrase.rounded(3_797) == "1h")
        #expect(DurationPhrase.exact(3_797) == "1h 3m")
        #expect(DurationPhrase.exact(1_800) == "30m")
        #expect(DurationPhrase.exact(7_200) == "2h")
    }

    // MARK: - Joining the call

    @Test("A link in the URL field is offered whatever its host")
    func urlFieldWins() {
        var event = Self.event("Sync", from: Self.at(10), minutes: 30, attendees: ["Rosa"])
        event.url = URL(string: "https://acme.example/room/7")
        #expect(MeetingLink.url(in: event)?.absoluteString == "https://acme.example/room/7")
    }

    @Test("A conferencing link in the notes is found; a document link is not")
    func notesAreReadCarefully() {
        var call = Self.event("Roadmap", from: Self.at(16), minutes: 45, attendees: ["Rosa"])
        call.notes = "Agenda attached. Join at https://meet.google.com/abc-defg-hij"
        #expect(MeetingLink.url(in: call)?.host() == "meet.google.com")

        var reading = Self.event("Reading", from: Self.at(16), minutes: 45, attendees: ["Rosa"])
        reading.notes = "Read https://docs.example/spec first."
        #expect(MeetingLink.url(in: reading) == nil, "a spec is not a room")
    }

    @Test("A title that mentions a service is not a link")
    func titlesAreNeverParsed() {
        let event = Self.event("Zoom with Priya", from: Self.at(10), minutes: 30, attendees: ["Priya"])
        #expect(MeetingLink.url(in: event) == nil)
    }

    // MARK: - Why a task is on a day

    static func facts(
        deadline: Date? = nil,
        start: Date? = nil,
        committed: Date? = nil,
        reminder: Date? = nil,
        timedReminder: Bool = false,
        flagged: Bool = false,
        someday: Bool = false,
        waitingSince: Date? = nil,
        followUp: Date? = nil
    ) -> TaskFacts {
        var facts = TaskFacts(id: UUID(), title: "Something")
        facts.deadlineAt = deadline
        facts.startAt = start
        facts.todayCommittedOn = committed
        facts.reminderAt = reminder
        facts.reminderIsTimed = timedReminder
        facts.isFlagged = flagged
        facts.isSomeday = someday
        facts.waitingSince = waitingSince
        facts.followUpAt = followUp
        return facts
    }

    @Test("Overdue work belongs to today and to no other day")
    func overdueDoesNotRepeatAcrossTheWeek() {
        let late = Self.facts(deadline: Self.at(0, dayOffset: -3))

        let onToday = DayTaskRules.reasons(
            for: late, on: Self.today, now: Self.today, calendar: Self.calendar
        )
        #expect(onToday.contains { if case .overdue(let days) = $0 { return days == 3 } else { return false } })

        let onTomorrow = DayTaskRules.reasons(
            for: late, on: Self.at(0, dayOffset: 1), now: Self.today, calendar: Self.calendar
        )
        #expect(onTomorrow.isEmpty, "every future day would otherwise open as a crisis")
    }

    @Test("A deadline puts a task on its own day, and says so")
    func deadlinesLandOnTheirDay() {
        let due = Self.facts(deadline: Self.at(12, dayOffset: 2))
        let reasons = DayTaskRules.reasons(
            for: due, on: Self.at(0, dayOffset: 2), now: Self.today, calendar: Self.calendar
        )
        #expect(reasons == [.due])
    }

    @Test("A commitment carried over from an earlier day is still today's work")
    func carriedCommitmentsStay() {
        let carried = Self.facts(committed: Self.at(0, dayOffset: -2))
        let reasons = DayTaskRules.reasons(
            for: carried, on: Self.today, now: Self.today, calendar: Self.calendar
        )
        #expect(reasons == [.committed])

        // But it does not appear on the day it was originally committed to, once that day has gone.
        let onTomorrow = DayTaskRules.reasons(
            for: carried, on: Self.at(0, dayOffset: 1), now: Self.today, calendar: Self.calendar
        )
        #expect(onTomorrow.isEmpty)
    }

    @Test("A flag puts work on today only, and only when nothing else already did")
    func flagsAreABookmarkAndNotADate() {
        let flagged = Self.facts(flagged: true)
        #expect(
            DayTaskRules.reasons(for: flagged, on: Self.today, now: Self.today, calendar: Self.calendar)
                == [.flagged]
        )
        #expect(
            DayTaskRules.reasons(
                for: flagged, on: Self.at(0, dayOffset: 1), now: Self.today, calendar: Self.calendar
            ).isEmpty,
            "a flag is not a date and must not behave like one"
        )

        // Already here for a real reason: the flag adds nothing and does not become the headline.
        let alsoDue = Self.facts(deadline: Self.today, flagged: true)
        let reasons = DayTaskRules.reasons(
            for: alsoDue, on: Self.today, now: Self.today, calendar: Self.calendar
        )
        #expect(reasons == [.due])
    }

    @Test("Parked and finished work is on no day at all")
    func somedayNeverAppears() {
        let parked = Self.facts(deadline: Self.today, someday: true)
        #expect(
            DayTaskRules.reasons(for: parked, on: Self.today, now: Self.today, calendar: Self.calendar).isEmpty
        )
    }

    @Test("Only a timed reminder claims a place on the clock")
    func onlyTimedRemindersArePinned() {
        let timed = Self.facts(reminder: Self.at(16), timedReminder: true)
        #expect(DayTaskRules.pinnedTime(for: timed, on: Self.today, calendar: Self.calendar) == Self.at(16))

        // A deadline is a date. Drawing "finish the report by Thursday" as a nine-o'clock
        // appointment is how an agenda starts lying about how full a day is.
        let deadline = Self.facts(deadline: Self.at(9))
        #expect(DayTaskRules.pinnedTime(for: deadline, on: Self.today, calendar: Self.calendar) == nil)

        let allDayReminder = Self.facts(reminder: Self.at(9), timedReminder: false)
        #expect(DayTaskRules.pinnedTime(for: allDayReminder, on: Self.today, calendar: Self.calendar) == nil)
    }

    @Test("The most urgent reason is the one a row shows")
    func reasonsAreRanked() {
        let both = Self.facts(deadline: Self.at(0, dayOffset: -1), committed: Self.today, flagged: true)
        let task = DayTask(
            taskID: both.id,
            reasons: DayTaskRules.reasons(for: both, on: Self.today, now: Self.today, calendar: Self.calendar)
        )

        #expect(task.primaryReason?.rank == 0)
        #expect(task.needsAttention)
    }

    @Test("Needing attention is narrower than being on the day")
    func attentionIsASmallerListThanTheDay() {
        #expect(DayTaskReason.overdue(days: 1).needsAttention)
        #expect(DayTaskReason.due.needsAttention)
        #expect(DayTaskReason.followUp(personName: nil).needsAttention)

        #expect(!DayTaskReason.committed.needsAttention)
        #expect(!DayTaskReason.starts.needsAttention)
        #expect(!DayTaskReason.flagged.needsAttention)
        #expect(!DayTaskReason.meetingPrep(eventID: "x", eventTitle: "Review").needsAttention)
    }

    // MARK: - People, once each

    @Test("One person with three reasons is one entry")
    func theRosterDeduplicates() {
        let maya = UUID()
        var roster = DayPeopleRoster()

        roster.add(
            personID: maya, key: "maya@northwind.example", name: "Maya Chen",
            reason: .meeting(eventID: "e1", title: "1:1", startAt: Self.at(11), isAllDay: false)
        )
        roster.add(
            personID: maya, key: "person:\(maya.uuidString)", name: "Maya Chen",
            reason: .waitingOn(taskID: UUID(), title: "The pricing answer")
        )
        roster.add(
            personID: maya, key: "person:\(maya.uuidString)", name: "Maya Chen",
            reason: .followUpDue(days: 40)
        )

        let people = roster.people()
        #expect(people.count == 1)
        #expect(people[0].reasons.count == 3)
        // The meeting outranks everything, because it is the one happening in an hour.
        #expect(people[0].primaryReason?.rank == 0)
        #expect(people[0].isMeetingToday)
    }

    @Test("Somebody first seen as an address and later resolved is still one person")
    func resolutionSurvivesMerging() {
        let rosa = UUID()
        var roster = DayPeopleRoster()

        roster.add(
            personID: nil, key: "rosa@northwind.example", name: "rosa@northwind.example",
            reason: .meeting(eventID: "e1", title: "Roadmap", startAt: Self.at(16), isAllDay: false)
        )
        roster.add(
            personID: rosa, key: "person:\(rosa.uuidString)", name: "Rosa Iyer",
            reason: .celebration(
                UpcomingCelebration(
                    celebration: Celebration(
                        personID: rosa, personName: "Rosa Iyer", kind: .birthday,
                        date: PartialDate(month: 6, day: 1) ?? PartialDate(month: 1, day: 1)!
                    ),
                    occursOn: Self.today,
                    daysAway: 0
                )
            )
        )

        let people = roster.people()
        #expect(people.count == 2, "an unresolved address and a resolved record are different keys")

        // The other direction — resolved first — is the one the assembler actually produces, because
        // meetings are added before anything else and their participants carry the library's own
        // identifier wherever there is one.
        var ordered = DayPeopleRoster()
        ordered.add(
            personID: rosa, key: "person:\(rosa.uuidString)", name: "Rosa Iyer",
            reason: .meeting(eventID: "e1", title: "Roadmap", startAt: Self.at(16), isAllDay: false)
        )
        ordered.add(
            personID: rosa, key: "rosa@northwind.example", name: "Rosa Iyer",
            reason: .followUpDue(days: 40)
        )
        #expect(ordered.people().count == 1)
    }

    @Test("People are ordered by why they are here, then by when")
    func rosterOrdersByConsequence() {
        var roster = DayPeopleRoster()
        let later = UUID(), earlier = UUID(), quiet = UUID()

        roster.add(personID: quiet, key: "q", name: "Quiet", reason: .followUpDue(days: 60))
        roster.add(
            personID: later, key: "l", name: "Later",
            reason: .meeting(eventID: "e2", title: "Afternoon", startAt: Self.at(16), isAllDay: false)
        )
        roster.add(
            personID: earlier, key: "e", name: "Earlier",
            reason: .meeting(eventID: "e1", title: "Morning", startAt: Self.at(9), isAllDay: false)
        )

        #expect(roster.people().map(\.name) == ["Earlier", "Later", "Quiet"])
    }

    // MARK: - The briefing

    @Test("A figure only appears when it would change what somebody does")
    func briefingDropsEmptyFigures() {
        let clear = DayBriefing(date: Self.today, isToday: true)
        #expect(clear.figures.isEmpty)
        #expect(clear.isClear)

        let busy = DayBriefing(
            date: Self.today, isToday: true,
            overdueCount: 2, taskCount: 5, meetingCount: 3,
            focus: DayFocusTime(available: 3 * 3_600)
        )
        #expect(busy.figures.map(\.id) == ["overdue", "tasks", "meetings", "focus"])
        // Red is reserved for the one figure that is genuinely wrong.
        #expect(busy.figures.filter { $0.tone == .urgent }.map(\.id) == ["overdue"])
    }

    @Test("Something happening now outranks something happening sooner")
    func nextCommitmentPrefersWhatIsUnderWay() {
        let running = NextCommitment(
            subject: .event(id: "a", kind: .meeting), title: "Review",
            startAt: Self.at(9.5), isInProgress: true
        )
        #expect(running.relativeText(from: Self.at(10)) == "now")

        let soon = NextCommitment(subject: .event(id: "b", kind: .meeting), title: "Sync", startAt: Self.at(10.5))
        #expect(soon.relativeText(from: Self.at(10)) == "in 30m")

        // Past four hours a countdown stops being a useful way to say it.
        let distant = NextCommitment(subject: .event(id: "c", kind: .meeting), title: "Late", startAt: Self.at(17))
        #expect(distant.relativeText(from: Self.at(10)).hasPrefix("at "))
    }

    @Test("The greeting follows the hour and nothing else")
    func greetingFollowsTheClock() {
        #expect(DayBriefing.greeting(at: Self.at(8), calendar: Self.calendar) == "Good morning")
        #expect(DayBriefing.greeting(at: Self.at(13), calendar: Self.calendar) == "Good afternoon")
        #expect(DayBriefing.greeting(at: Self.at(19), calendar: Self.calendar) == "Good evening")
        #expect(DayBriefing.greeting(at: Self.at(2), calendar: Self.calendar) == "Still up")
    }

    // MARK: - The agenda

    @Test("Timed events and timed tasks interleave; everything else stays out of the timeline")
    func agendaHoldsOnlyWhatHasATime() {
        let review = DayEvent(
            event: Self.event("Review", from: Self.at(10), minutes: 60, attendees: ["Maya"]),
            kind: .meeting
        )
        let allDay = DayEvent(
            event: Self.event("Berlin", from: Self.at(0), minutes: 24 * 60, allDay: true),
            kind: .allDay
        )
        let pinned = DayTask(taskID: UUID(), reasons: [.reminder(at: Self.at(16))], pinnedAt: Self.at(16))
        let loose = DayTask(taskID: UUID(), reasons: [.committed])

        let plan = DayPlan(
            date: Self.today,
            isToday: true,
            briefing: DayBriefing(date: Self.today, isToday: true),
            events: [review, allDay],
            tasks: [pinned, loose]
        )

        let slots = DayAgenda.slots(for: plan, calendar: Self.calendar)
        #expect(slots.count == 2, "the all-day entry and the undated task are not on the clock")
        #expect(slots.map(\.startAt) == [Self.at(10), Self.at(16)])
        #expect(plan.untimedTasks.count == 1)
        #expect(plan.allDayEvents(calendar: Self.calendar).count == 1)
    }

    @Test("The now line goes before the first thing still to come")
    func nowMarkerFindsItsPlace() {
        let slots: [DayAgendaSlot] = [
            .event(DayEvent(event: Self.event("A", from: Self.at(9), minutes: 30), kind: .appointment)),
            .event(DayEvent(event: Self.event("B", from: Self.at(15), minutes: 30), kind: .appointment)),
        ]

        #expect(DayAgenda.nowMarkerIndex(in: slots, now: Self.at(12), isToday: true) == 1)
        #expect(DayAgenda.nowMarkerIndex(in: slots, now: Self.at(8), isToday: true) == 0)
        #expect(DayAgenda.nowMarkerIndex(in: slots, now: Self.at(20), isToday: true) == nil, "the day is behind you")
        #expect(DayAgenda.nowMarkerIndex(in: slots, now: Self.at(12), isToday: false) == nil)
    }

    // MARK: - Filters

    @Test("Filters say what they are hiding, and say nothing when they are hiding nothing")
    func filtersExplainThemselves() {
        #expect(!TodayFilters.standard.isFiltering)
        #expect(TodayFilters.standard.summary == nil)

        var filters = TodayFilters.standard
        filters.showsMeetings = false
        filters.hiddenCalendarIdentifiers = ["fixture.family"]
        #expect(filters.isFiltering)
        #expect(filters.summary == "Hiding meetings and 1 calendar")
    }

    @Test("Filters survive a round trip, because they outlive the session")
    func filtersEncodeAndDecode() throws {
        var filters = TodayFilters.standard
        filters.showsPeople = false
        filters.usesIntegratedAgenda = false
        filters.hiddenContainerIDs = [UUID()]

        let data = try JSONEncoder().encode(filters)
        #expect(try JSONDecoder().decode(TodayFilters.self, from: data) == filters)
    }

    /// The preference written by an older build, which knew nothing about free time.
    ///
    /// Synthesized `Decodable` throws on a missing key rather than taking the property's default, so
    /// without a hand-written initialiser adding one switch would have made every stored preference
    /// undecodable — and `TodayPreferences` would have silently reset everybody's filters on the
    /// next launch. The fallback there is for a corrupt preference, not for a field somebody added.
    @Test("A preference saved before a switch existed keeps every switch it did set")
    func olderPreferencesDecodeWithoutLosingWhatTheySaid() throws {
        let older = """
        {
            "showsTasks": true, "showsMeetings": false, "showsPeople": true,
            "showsDailyNote": true, "showsCompleted": false, "usesIntegratedAgenda": true,
            "hiddenCalendarIdentifiers": ["work"], "hiddenContainerIDs": []
        }
        """

        let decoded = try JSONDecoder().decode(TodayFilters.self, from: Data(older.utf8))

        #expect(!decoded.showsMeetings, "what they did say survives")
        #expect(!decoded.showsCompleted)
        #expect(decoded.hiddenCalendarIdentifiers == ["work"])
        #expect(decoded.showsFreeTime, "what they never said takes its default")
    }
}
