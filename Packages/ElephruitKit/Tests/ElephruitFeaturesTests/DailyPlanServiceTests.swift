import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// Assembling a day out of the library and the calendar.
///
/// The rules themselves are tested against a fixed clock in `DailyPlanTests`. What is tested here is
/// the *joining*: that the same person reached through a meeting and through a task is one entry,
/// that a name the library cannot be certain about is left alone, and that nothing on this page is a
/// second copy of a record that lives somewhere else.
@MainActor
@Suite("Assembling a day")
struct DailyPlanServiceTests {
    /// The clock every fixture shares, so events can be built before the services that read them.
    static let clock = SystemDateProvider()

    static func at(_ hour: Int, dayOffset: Int = 0) -> Date {
        let day = clock.startOfDay(daysFromToday: dayOffset)
        return clock.calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    /// A library with a synthetic calendar attached.
    ///
    /// `EKEventStore` is never constructed: the fixture is the only implementation these tests can
    /// reach, which is what makes "no test touches the developer's real calendar" true by
    /// construction rather than by care. The defaults suite is a throwaway, so a filter switched off
    /// in one test does not leak into the next one or into the developer's own preferences.
    static func fixture(events: [CalendarEventSummary] = []) async -> AppServices {
        let defaults = UserDefaults(suiteName: "today.tests.\(UUID().uuidString)") ?? .standard
        let services = AppServices.inMemory(
            dateProvider: clock,
            populated: false,
            calendarProvider: { FixtureCalendarProvider(events: events, authorization: .authorized) },
            defaults: defaults
        )
        _ = await services.calendar.enable()
        return services
    }

    static func event(
        _ title: String,
        id: String,
        from start: Date,
        minutes: Int,
        attendees: [EventAttendee] = [],
        availability: EventAvailability = .busy,
        calendarIdentifier: String = "fixture.work"
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: id),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            calendarIdentifier: calendarIdentifier,
            calendarName: "Work",
            availability: availability,
            attendees: attendees
        )
    }

    /// The two steps the page takes: read the window, then assemble the day from what is in memory.
    private func plan(
        _ services: AppServices,
        on day: Date? = nil,
        filters: TodayFilters = .standard
    ) async throws -> DayPlan {
        let date = day ?? Self.clock.startOfToday
        await services.dailyPlan.loadCalendar(from: date, through: date)
        services.dailyPlan.invalidateCaches()
        return try services.dailyPlan.plan(for: date, filters: filters)
    }

    // MARK: - The join

    @Test("Somebody in a meeting and on a task appears once, with both reasons")
    func aPersonInTwoPlacesIsOneEntry() async throws {
        let services = await Self.fixture(events: [
            Self.event(
                "1:1", id: "one", from: Self.at(10), minutes: 30,
                attendees: [EventAttendee(name: "Maya Chen", emailAddress: "maya@northwind.example")]
            )
        ])

        let maya = try services.persons.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )

        let task = try services.items.create(ItemDraft(kind: .task, title: "Send Maya the pricing"))
        try services.items.link(task, to: maya, kind: .mentions)
        try services.reminderLifecycle.commit(task, to: Self.clock.startOfToday)

        let day = try await plan(services)

        let entries = day.people.filter { $0.personID == maya.id }
        #expect(entries.count == 1, "one person, one row")

        let entry = try #require(entries.first)
        #expect(entry.reasons.count == 2)
        #expect(entry.isMeetingToday)
        #expect(entry.reasons.contains { if case .taskAbout = $0 { return true } else { return false } })
    }

    @Test("An attendee the library has never heard of stays unlinked rather than being invented")
    func unknownAttendeesAreNotGivenRecords() async throws {
        let services = await Self.fixture(events: [
            Self.event(
                "Vendor call", id: "vendor", from: Self.at(10), minutes: 30,
                attendees: [EventAttendee(name: "Jordan Blake", emailAddress: "jordan@vendor.example")]
            )
        ])

        let day = try await plan(services)

        let jordan = try #require(day.people.first { $0.name == "Jordan Blake" })
        #expect(jordan.personID == nil)
        #expect(!jordan.isKnown)

        var query = ItemQuery()
        query.kinds = [.person]
        #expect(try services.items.count(matching: query) == 0, "nobody was created behind the user's back")
    }

    @Test("Two people with the same name resolve to neither")
    func ambiguousNamesAreNotGuessed() async throws {
        let services = await Self.fixture(events: [
            Self.event(
                "Review", id: "review", from: Self.at(10), minutes: 30,
                attendees: [EventAttendee(name: "James Wilson")]
            )
        ])

        _ = try services.persons.createPerson(PersonDraft(fullName: "James Wilson"))
        _ = try services.persons.createPerson(PersonDraft(fullName: "James Wilson"))

        let day = try await plan(services)

        let james = try #require(day.people.first { $0.name == "James Wilson" })
        #expect(james.personID == nil, "attaching somebody's history to a stranger is not recoverable")
    }

    @Test("An address resolves even when the display name does not match the record")
    func emailIsAnIdentityAndANameIsNot() async throws {
        let services = await Self.fixture(events: [
            Self.event(
                "Sync", id: "sync", from: Self.at(10), minutes: 30,
                attendees: [EventAttendee(name: "M. Chen", emailAddress: "maya@northwind.example")]
            )
        ])

        let maya = try services.persons.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "MAYA@Northwind.Example")]
            )
        )

        let day = try await plan(services)
        let participant = try #require(day.events.first?.participants.first)

        #expect(participant.personID == maya.id)
        #expect(participant.name == "Maya Chen", "the library's own name wins over the invitation's")
    }

    // MARK: - What a day counts

    @Test("Only entries with other people on them are counted as meetings")
    func theMeetingCountIsAboutPeople() async throws {
        let services = await Self.fixture(events: [
            Self.event("Review", id: "a", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")]),
            Self.event("Dentist", id: "b", from: Self.at(13), minutes: 30),
            Self.event("Focus", id: "c", from: Self.at(15), minutes: 90, availability: .free),
        ])

        let day = try await plan(services)

        #expect(day.briefing.meetingCount == 1)
        #expect(day.briefing.otherEventCount == 2)
        #expect(day.events.count == 3, "all three are still on the day")
        #expect(day.events.filter { $0.kind == .focusBlock }.count == 1)
        #expect(day.events.filter { $0.kind == .appointment }.count == 1)
    }

    @Test("Two meetings wanting the same hour each say what they clash with")
    func clashesAreReportedBothWays() async throws {
        let services = await Self.fixture(events: [
            Self.event("Design review", id: "review", from: Self.at(10), minutes: 90,
                       attendees: [EventAttendee(name: "Maya Chen")]),
            Self.event("Vendor call", id: "vendor", from: Self.at(11), minutes: 30),
        ])

        let day = try await plan(services)
        let review = try #require(day.events.first { $0.id == "review" })
        let vendor = try #require(day.events.first { $0.id == "vendor" })

        #expect(review.conflictingEventIDs == ["vendor"])
        #expect(vendor.conflictingEventIDs == ["review"])
    }

    @Test("Overdue work is counted apart from the rest of the day")
    func overdueIsItsOwnFigure() async throws {
        let services = await Self.fixture()

        let late = try services.items.create(ItemDraft(kind: .task, title: "The tax return"))
        try services.reminderLifecycle.setDeadline(Self.clock.startOfDay(daysFromToday: -4), on: late)

        let planned = try services.items.create(ItemDraft(kind: .task, title: "Write the brief"))
        try services.reminderLifecycle.commitToToday(planned)

        let day = try await plan(services)

        #expect(day.briefing.overdueCount == 1)
        #expect(day.briefing.taskCount == 1)
        #expect(day.needsAttention.count == 1)
        #expect(day.tasks.count == 2)
    }

    @Test("Finished work is collected separately and does not swell the day's counts")
    func completedWorkIsHistory() async throws {
        let services = await Self.fixture()

        let done = try services.items.create(ItemDraft(kind: .task, title: "Book the room"))
        try services.reminderLifecycle.commitToToday(done)
        _ = try services.reminderLifecycle.complete(done)

        let day = try await plan(services)

        #expect(day.tasks.isEmpty)
        #expect(day.completedTaskIDs == [done.id])
        #expect(day.briefing.completedTaskCount == 1)
        #expect(day.briefing.taskCount == 0)
    }

    // MARK: - What the reader has switched off

    @Test("Hiding meetings hides the events and the people they brought")
    func filtersReachTheWholeDay() async throws {
        let services = await Self.fixture(events: [
            Self.event(
                "Roadmap", id: "roadmap", from: Self.at(10), minutes: 45,
                attendees: [EventAttendee(name: "Rosa Iyer", emailAddress: "rosa@northwind.example")]
            )
        ])

        _ = try services.persons.createPerson(
            PersonDraft(
                fullName: "Rosa Iyer",
                emails: [LabelledValue(label: "work", value: "rosa@northwind.example")]
            )
        )

        let showing = try await plan(services)
        #expect(showing.events.count == 1)
        #expect(showing.people.count == 1)

        var filters = TodayFilters.standard
        filters.showsMeetings = false
        let hidden = try await plan(services, filters: filters)

        #expect(hidden.events.isEmpty)
        #expect(hidden.people.isEmpty, "a person shown only because of a meeting goes with the meeting")
        #expect(hidden.briefing.meetingCount == 0)
    }

    @Test("A calendar hidden here is hidden here only")
    func hidingACalendarIsScopedToThisPage() async throws {
        let services = await Self.fixture(events: [
            Self.event("School concert", id: "concert", from: Self.at(18), minutes: 90,
                       calendarIdentifier: "fixture.family")
        ])

        #expect(try await plan(services).events.count == 1)

        var filters = TodayFilters.standard
        filters.hiddenCalendarIdentifiers = ["fixture.family"]
        #expect(try await plan(services, filters: filters).events.isEmpty)

        // The calendar module's own visibility is untouched — this switch is about this page.
        #expect(services.calendar.visibleCalendarIdentifiers == nil)
    }

    @Test("Hiding a project takes its work off the day")
    func hidingAProjectHidesItsWork() async throws {
        let services = await Self.fixture()

        let project = try services.items.create(ItemDraft(kind: .project, title: "Pricing"))
        var draft = ItemDraft(kind: .task, title: "Draft the tiers")
        draft.parentID = project.id
        let task = try services.items.create(draft)
        try services.reminderLifecycle.commitToToday(task)

        #expect(try await plan(services).tasks.count == 1)

        var filters = TodayFilters.standard
        filters.hiddenContainerIDs = [project.id]
        #expect(try await plan(services, filters: filters).tasks.isEmpty)
    }

    // MARK: - Nothing here is a copy

    @Test("Completing a task from the day changes the task, not a copy of it")
    func thePageEditsTheRealRecord() async throws {
        let services = await Self.fixture()

        let task = try services.items.create(ItemDraft(kind: .task, title: "Send the invoice"))
        try services.reminderLifecycle.commitToToday(task)

        #expect(try await plan(services).tasks.map(\.taskID) == [task.id])

        _ = try services.reminderLifecycle.complete(task)
        // As every mutation in the app does — see `AppServices.noteChange(to:)`. It is what tells the
        // search index, the sidebar counts and this page that something moved, and the assembler's
        // library pass is keyed on it for the same reason `ItemListView`'s reload already was.
        services.noteChange(to: task)

        let after = try await plan(services)
        #expect(after.tasks.isEmpty)
        #expect(after.completedTaskIDs == [task.id])

        // And the change is visible everywhere else, because there was only ever one record.
        #expect(try services.items.item(id: task.id)?.status == .completed)
    }

    @Test("The same event arriving again from the calendar produces one row, not two")
    func repeatedLoadsDoNotAccumulate() async throws {
        let services = await Self.fixture(events: [
            Self.event("Review", id: "review", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")])
        ])

        let first = try await plan(services)
        #expect(first.events.count == 1)

        // A refresh, which is what an external sync looks like from here.
        let second = try await plan(services)
        #expect(second.events.count == 1)
        #expect(second.people.count == first.people.count)
    }

    @Test("Re-reading a window that has not changed is not news")
    func theCalendarRevisionSettles() async throws {
        // The loop this closes: Today reloads when the revision changes, and loads the calendar in
        // order to reload. A counter bumped on every load would mean load, bump, invalidate, load,
        // for as long as the page was on screen.
        let services = await Self.fixture(events: [
            Self.event("Review", id: "review", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")])
        ])

        await services.dailyPlan.loadCalendar(from: Self.clock.startOfToday, through: Self.clock.startOfToday)
        let afterFirst = services.calendar.revision

        await services.dailyPlan.loadCalendar(from: Self.clock.startOfToday, through: Self.clock.startOfToday)
        #expect(services.calendar.revision == afterFirst, "the same answer twice is one piece of news")

        await services.dailyPlan.loadCalendar(from: Self.clock.startOfToday, through: Self.clock.startOfToday)
        #expect(services.calendar.revision == afterFirst)
    }

    @Test("A window that comes back different does say so")
    func theCalendarRevisionMovesOnRealChange() async throws {
        let services = await Self.fixture(events: [
            Self.event("Review", id: "review", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")])
        ])

        await services.dailyPlan.loadCalendar(from: Self.clock.startOfToday, through: Self.clock.startOfToday)
        let before = services.calendar.revision

        // A different window is a different answer, which is exactly the case a page has to hear
        // about.
        await services.dailyPlan.loadCalendar(
            from: Self.clock.startOfDay(daysFromToday: 20), through: Self.clock.startOfDay(daysFromToday: 20)
        )
        #expect(services.calendar.revision != before)
    }

    @Test("A person linked by hand and invited by the calendar is still one person")
    func handLinkingDoesNotDuplicateAnAttendee() async throws {
        let event = Self.event(
            "1:1", id: "one", from: Self.at(11), minutes: 30,
            attendees: [EventAttendee(name: "Maya Chen", emailAddress: "maya@northwind.example")]
        )
        let services = await Self.fixture(events: [event])

        let maya = try services.persons.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )
        // Linked by hand as well, which is the other route somebody ends up on a meeting.
        _ = try services.eventLinks.link(person: maya, to: event)

        let day = try await plan(services)
        let meeting = try #require(day.events.first)

        #expect(meeting.participants.count == 1)
        #expect(day.people.filter { $0.personID == maya.id }.count == 1)
    }

    // MARK: - Preparation

    @Test("A meeting says what is still to be done before it, and what already was")
    func preparationCountsOpenWorkOnly() async throws {
        let event = Self.event(
            "Design review", id: "review", from: Self.at(10), minutes: 60,
            attendees: [EventAttendee(name: "Maya Chen")]
        )
        let services = await Self.fixture(events: [event])

        let meeting = try #require(try services.eventLinks.meetingItem(for: event))
        let open = try services.items.create(ItemDraft(kind: .task, title: "Print the comparison"))
        try services.items.link(open, to: meeting, kind: .related)

        let done = try services.items.create(ItemDraft(kind: .task, title: "Book Room 2"))
        try services.items.link(done, to: meeting, kind: .related)
        _ = try services.reminderLifecycle.complete(done)

        let day = try await plan(services)
        let preparation = try #require(day.events.first?.preparation)

        #expect(preparation.openPreparationTaskIDs == [open.id])
        #expect(preparation.completedPreparationTaskCount == 1)
        #expect(preparation.summary == "1 thing to prepare")
    }

    @Test("A preparation task says which meeting it is for")
    func preparationTasksCarryTheirMeeting() async throws {
        let event = Self.event(
            "Design review", id: "review", from: Self.at(10), minutes: 60,
            attendees: [EventAttendee(name: "Maya Chen")]
        )
        let services = await Self.fixture(events: [event])

        let meeting = try #require(try services.eventLinks.meetingItem(for: event))
        let prepare = try services.items.create(ItemDraft(kind: .task, title: "Print the comparison"))
        try services.items.link(prepare, to: meeting, kind: .related)
        try services.reminderLifecycle.commitToToday(prepare)

        let day = try await plan(services)
        let task = try #require(day.tasks.first { $0.taskID == prepare.id })

        #expect(
            task.reasons.contains {
                if case .meetingPrep(_, let title) = $0 { return title == "Design review" }
                return false
            }
        )
    }

    @Test("A preparation task with no date of its own still reaches the day")
    func undatedPreparationTasksAreFound() async throws {
        // The library read is windowed on the day-relevance key, and a task attached to a meeting
        // has no date to be windowed by — it is read by identifier off the meeting instead. This
        // is the case that would silently vanish if that rescue ever regressed.
        let event = Self.event(
            "Board prep", id: "board", from: Self.at(14), minutes: 30,
            attendees: [EventAttendee(name: "Maya Chen")]
        )
        let services = await Self.fixture(events: [event])

        let meeting = try #require(try services.eventLinks.meetingItem(for: event))
        let prepare = try services.items.create(ItemDraft(kind: .task, title: "Print the pack"))
        try services.items.link(prepare, to: meeting, kind: .related)

        let day = try await plan(services)
        let task = try #require(day.tasks.first { $0.taskID == prepare.id })
        #expect(
            task.reasons.contains {
                if case .meetingPrep = $0 { return true }
                return false
            }
        )
    }

    @Test("A flagged task with no date still earns its place on today")
    func undatedFlaggedTasksAreFound() async throws {
        // A flag is not a date, so it is outside the windowed fetch and arrives through a fetch of
        // its own. Losing that second fetch would lose exactly the tasks whose only claim is the
        // flag the user set.
        let services = await Self.fixture()

        let flagged = try services.items.create(ItemDraft(kind: .task, title: "Come back to this"))
        try services.reminderLifecycle.setFlagged(true, on: flagged)

        let day = try await plan(services)
        let task = try #require(day.tasks.first { $0.taskID == flagged.id })
        #expect(task.reasons == [.flagged])
    }

    // MARK: - What it costs

    /// The regression that shipped once and must not again.
    ///
    /// Drawing five days ran a full scan of the meeting table **twice per day** — once for the
    /// annotations and once for the preparation — and walked every open task once per day on top,
    /// because none of the scheduling rules translate to a predicate. With a real calendar attached
    /// that was several seconds to open the page and several more to toggle a filter.
    ///
    /// This asserts the shape rather than a duration: adding four days must not multiply the work.
    /// A stopwatch would give a different answer on a different machine and would have passed on a
    /// fast one, which is the whole argument behind `FetchAudit`.
    @Test("Drawing five days costs barely more than drawing one")
    func assemblyDoesNotScaleWithTheNumberOfDays() async throws {
        let audit = FetchAudit()
        let defaults = UserDefaults(suiteName: "today.tests.\(UUID().uuidString)") ?? .standard

        // Built before the provider closure, which is `@Sendable` and cannot reach back onto the
        // main actor to make them.
        let events = (0..<5).map { day in
            Self.event(
                "Review \(day)", id: "review-\(day)",
                from: Self.at(10, dayOffset: day), minutes: 60,
                attendees: [EventAttendee(name: "Maya Chen", emailAddress: "maya@northwind.example")]
            )
        }

        let services = AppServices.inMemory(
            dateProvider: Self.clock,
            populated: false,
            calendarProvider: { FixtureCalendarProvider(events: events, authorization: .authorized) },
            defaults: defaults,
            audit: audit
        )
        _ = await services.calendar.enable()

        _ = try services.persons.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )
        for index in 0..<20 {
            let task = try services.items.create(ItemDraft(kind: .task, title: "Task \(index)"))
            try services.reminderLifecycle.commit(task, to: Self.clock.startOfDay(daysFromToday: index % 5))
        }

        await services.dailyPlan.loadCalendar(
            from: Self.clock.startOfToday, through: Self.clock.startOfDay(daysFromToday: 4)
        )

        services.dailyPlan.invalidateCaches()
        let one = audit.measure { try? services.dailyPlan.window(from: Self.clock.startOfToday, count: 1) }

        services.dailyPlan.invalidateCaches()
        let five = audit.measure { try? services.dailyPlan.window(from: Self.clock.startOfToday, count: 5) }

        // The only thing that legitimately grows with the day count is the day's own note, which is
        // one indexed lookup per day. Four extra days may therefore cost four extra fetches and no
        // more; before this was fixed they cost roughly fifteen.
        let growth = five.tally.total - one.tally.total
        #expect(
            growth <= 4,
            "five days cost \(five.tally.description) against one day's \(one.tally.description)"
        )
    }

    /// The one somebody reported: click a filter off, click it back on, wait.
    ///
    /// Toggling a filter changes what is *drawn*. It cannot change what is in the library, so it has
    /// no business reading the library — and it was reading all of it, twice, plus the calendar,
    /// because the filters were part of the token that drove the load.
    ///
    /// A fetch count rather than a duration, for the usual reason: a stopwatch would pass on a fast
    /// machine with an empty library, which is exactly the condition under which this shipped.
    @Test("Toggling a filter reads nothing at all")
    func togglingAFilterDoesNotTouchTheStore() async throws {
        let audit = FetchAudit()
        let defaults = UserDefaults(suiteName: "today.tests.\(UUID().uuidString)") ?? .standard
        let events = [
            Self.event("Review", id: "review", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen", emailAddress: "maya@northwind.example")])
        ]
        let services = AppServices.inMemory(
            dateProvider: Self.clock,
            populated: false,
            calendarProvider: { FixtureCalendarProvider(events: events, authorization: .authorized) },
            defaults: defaults,
            audit: audit
        )
        _ = await services.calendar.enable()

        _ = try services.persons.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )
        for index in 0..<40 {
            let task = try services.items.create(ItemDraft(kind: .task, title: "Task \(index)"))
            try services.reminderLifecycle.commit(task, to: Self.clock.startOfDay(daysFromToday: index % 5))
        }

        let model = TodayModel(services: services)
        await model.reload()
        let afterFirstPaint = model.assemblyCount

        let toggling = audit.measure {
            services.todayPreferences.toggleMeetings()
            model.assemble()
            services.todayPreferences.toggleMeetings()
            model.assemble()
            services.todayPreferences.togglePeople()
            model.assemble()
        }

        #expect(
            toggling.tally.total == 0,
            "three toggles read the store: \(toggling.tally.description)"
        )
        #expect(model.assemblyCount == afterFirstPaint + 3, "each toggle is one rebuild, no more")
        #expect(services.calendar.revision >= 0)
    }

    @Test("An assembly that would produce the same answer does not run")
    func redundantAssembliesAreFree() async throws {
        // SwiftUI is entitled to re-run a `task(id:)` or an `onChange` more than once for what a
        // person experienced as one click.
        let services = await Self.fixture()
        let model = TodayModel(services: services)

        await model.reload()
        let after = model.assemblyCount

        for _ in 0..<20 { model.assemble() }
        #expect(model.assemblyCount == after)

        // Something genuinely changing still gets through.
        services.todayPreferences.toggleCompleted()
        model.assemble()
        #expect(model.assemblyCount == after + 1)
    }

    @Test("An edit to the library is never missed, however warm the caches are")
    func cachesNeverHideAnEdit() async throws {
        let services = await Self.fixture()
        let model = TodayModel(services: services)
        await model.reload()

        #expect(model.selectedPlan?.tasks.isEmpty == true)

        let task = try services.items.create(ItemDraft(kind: .task, title: "Something new"))
        try services.reminderLifecycle.commitToToday(task)
        services.noteChange(to: task)

        model.assemble()
        #expect(model.selectedPlan?.tasks.map(\.taskID) == [task.id])
    }

    @Test("Rebuilding the days never asks the calendar again")
    func assemblyDoesNotReachTheCalendar() async throws {
        // The other half of the loop. `assemble()` reads what is already in memory; if it ever
        // loaded, the page would be asking the calendar a question in response to the calendar
        // having answered one.
        let services = await Self.fixture(events: [
            Self.event("Review", id: "review", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")])
        ])

        await services.dailyPlan.loadCalendar(from: Self.clock.startOfToday, through: Self.clock.startOfToday)
        let settled = services.calendar.revision

        for _ in 0..<5 {
            services.dailyPlan.invalidateCaches()
            _ = try services.dailyPlan.window(from: Self.clock.startOfToday, count: 5)
        }

        #expect(services.calendar.revision == settled, "assembling asked the calendar something")
    }

    @Test("A window the calendar has answered for can be drawn without asking again")
    func answeredWindowsAssembleImmediately() async throws {
        let services = await Self.fixture(events: [
            Self.event("Standup", id: "standup", from: Self.at(9), minutes: 15)
        ])
        let today = Self.clock.startOfToday
        let last = Self.clock.startOfDay(daysFromToday: 4)

        // Before any load, the honest answer is no: assembling now would say the day is clear
        // before it has been read.
        #expect(!services.dailyPlan.canAnswerForCalendar(from: today, through: last))

        // The first visit loads the window. Every later visit finds it already answered — which is
        // what lets `TodayModel.reload()` assemble before the round trip instead of holding a
        // spinner through it.
        await services.dailyPlan.loadCalendar(from: today, through: last)
        #expect(services.dailyPlan.canAnswerForCalendar(from: today, through: last))
        #expect(services.dailyPlan.canAnswerForCalendar(from: today, through: today), "a narrower span too")

        // A span the load did not cover stays unanswered.
        let nextMonth = Self.clock.startOfDay(daysFromToday: 30)
        #expect(!services.dailyPlan.canAnswerForCalendar(from: today, through: nextMonth))

        // A fresh page over the answered window — the second click on Today — has its days before
        // any further round trip.
        let model = TodayModel(services: services)
        model.assemble()
        #expect(!model.isLoadingInitially)
        #expect(model.selectedPlan?.events.map(\.event.title) == ["Standup"])
    }

    @Test("A disabled calendar is never something to wait for")
    func disabledCalendarAlwaysAnswers() async throws {
        let defaults = UserDefaults(suiteName: "today.tests.\(UUID().uuidString)") ?? .standard
        let services = AppServices.inMemory(
            dateProvider: Self.clock,
            populated: false,
            defaults: defaults
        )
        #expect(
            services.dailyPlan.canAnswerForCalendar(
                from: Self.clock.startOfToday,
                through: Self.clock.startOfDay(daysFromToday: 4)
            ),
            "with the feature off there is no round trip to wait behind"
        )
    }

    // MARK: - Days other than today

    @Test("A future day carries no follow-up suggestions and no week of birthdays")
    func futureDaysStayAboutThatDay() async throws {
        let services = await Self.fixture()

        let rosa = try services.persons.createPerson(PersonDraft(fullName: "Rosa Iyer"))
        let parts = Self.clock.calendar.dateComponents([.month, .day], from: Self.clock.startOfToday)
        if let month = parts.month, let day = parts.day, let birthday = PartialDate(month: month, day: day) {
            try services.persons.addCelebration(to: rosa, kind: .birthday, title: nil, date: birthday)
        }

        #expect(try await plan(services).briefing.celebrations.contains { $0.daysAway == 0 })

        let nextWeek = try await plan(services, on: Self.clock.startOfDay(daysFromToday: 7))
        #expect(nextWeek.briefing.celebrations.isEmpty, "a birthday today is not a fact about next week")
    }

    @Test("Overdue work does not repeat on every day in the window")
    func overdueBelongsToTodayAlone() async throws {
        let services = await Self.fixture()

        let late = try services.items.create(ItemDraft(kind: .task, title: "The tax return"))
        try services.reminderLifecycle.setDeadline(Self.clock.startOfDay(daysFromToday: -4), on: late)

        #expect(try await plan(services).tasks.count == 1)
        #expect(try await plan(services, on: Self.clock.startOfTomorrow).tasks.isEmpty)
    }

    @Test("A day with nothing on it says so rather than looking broken")
    func emptyDaysAreRepresentable() async throws {
        let services = await Self.fixture()
        let day = try await plan(services, on: Self.clock.startOfDay(daysFromToday: 30))

        #expect(day.isEmpty)
        #expect(!day.hasContent)
        #expect(day.briefing.isClear)

        // The one thing a clear working day still has to say is how much of it there is — that is
        // the figure somebody uses to decide what to move into it. Anything else would be a count of
        // zero dressed up as news. On a non-working day there is no figure at all, which is why this
        // asserts the *set* rather than a fixed length.
        #expect(Set(day.briefing.figures.map(\.id)).isSubset(of: ["focus"]))
    }

    @Test("Several days are assembled in order, each about itself")
    func aWindowOfDaysIsInOrder() async throws {
        let services = await Self.fixture(events: [
            Self.event("Today's review", id: "a", from: Self.at(10), minutes: 60,
                       attendees: [EventAttendee(name: "Maya Chen")]),
            Self.event("Tomorrow's sync", id: "b", from: Self.at(10, dayOffset: 1), minutes: 30,
                       attendees: [EventAttendee(name: "Rosa Iyer")]),
        ])

        await services.dailyPlan.loadCalendar(
            from: Self.clock.startOfToday, through: Self.clock.startOfDay(daysFromToday: 2)
        )
        services.dailyPlan.invalidateCaches()
        let days = try services.dailyPlan.plans(from: Self.clock.startOfToday, count: 3)

        #expect(days.count == 3)
        #expect(days.map(\.isToday) == [true, false, false])
        #expect(days[0].events.map(\.event.title) == ["Today's review"])
        #expect(days[1].events.map(\.event.title) == ["Tomorrow's sync"])
        #expect(days[2].events.isEmpty)
    }
}
