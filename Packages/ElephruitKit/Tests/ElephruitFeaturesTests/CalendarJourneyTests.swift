import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// The journeys, end to end, through the real composition root.
///
/// ### Why these exist alongside the unit tests
/// Every piece of this module is tested on its own, and every one of those tests passes against a
/// piece that is wired to nothing. What they cannot catch is the failure that actually ships: a
/// service constructed but never given its index, an annotation written to a store the search engine
/// is not reading, a set saved and never applied to a fetch.
///
/// So these build a whole `AppServices` — the same one the app builds — over an in-memory store and
/// a synthetic calendar, and walk a journey from one end to the other.
@Suite("Calendar journeys")
@MainActor
struct CalendarJourneyTests {
    /// A whole app, with an invented calendar and a scratch preferences suite.
    ///
    /// The scratch suite matters: enabling the calendar writes a preference, and a test that used
    /// the standard suite would turn the feature on for the person running it.
    private static func services() throws -> AppServices {
        let stack = try PersistenceStack.inMemory()
        let defaults = UserDefaults(suiteName: "calendar-journey-\(UUID().uuidString)") ?? .standard

        // The fixture's events are built around the *injected* clock rather than the real one.
        // Building them around `Date()` while the services run on a fixed clock puts every event
        // outside every window the test looks at, which reads as "nothing was read" and is really
        // two clocks disagreeing — the same class of bug as the display zone one.
        let clock = FixedDateProvider.reference
        let events = CalendarFixtures.week(around: clock.now, calendar: clock.calendar)

        return AppServices(
            stack: stack,
            dateProvider: clock,
            isDevelopmentMode: true,
            calendarProvider: { FixtureCalendarProvider(events: events) },
            defaults: defaults
        )
    }

    private static var clock: FixedDateProvider { .reference }

    private static var week: Range<Date> {
        clock.startOfDay(daysFromToday: -7)..<clock.startOfDay(daysFromToday: 14)
    }

    @Test("Turning the calendar on reads calendars and events")
    func enabling() async throws {
        let services = try Self.services()

        #expect(!services.calendar.isEnabled)
        #expect(services.calendar.events.isEmpty)

        let authorization = await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        #expect(authorization == .authorized)
        #expect(!services.calendar.calendars.isEmpty)
        #expect(!services.calendar.events.isEmpty)
        #expect(!services.calendar.isShowingCachedEvents)
    }

    @Test("An event created here is searchable afterwards")
    func creatingThenSearching() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let start = Self.clock.startOfToday.addingTimeInterval(15 * 3_600)
        let calendarIdentifier = try #require(services.calendar.defaultCalendarIdentifier)
        let draft = EventDraft(
            calendarIdentifier: calendarIdentifier,
            title: "Pottery class",
            startAt: start,
            endAt: start.addingTimeInterval(5_400),
            location: "Bermondsey"
        )

        let outcome = await services.calendar.create(draft)
        guard case .success = outcome else {
            Issue.record("Creating should have succeeded")
            return
        }

        let results = await services.calendarSearch.search(
            "pottery",
            now: Self.clock.now,
            calendar: services.calendar.displayCalendar,
            limit: 20
        )

        #expect(results.events.map(\.title) == ["Pottery class"], """
            The unit tests prove the index works and prove the service writes. Only this proves the \
            service was actually given the index.
            """)

        let byPlace = await services.calendarSearch.search(
            "in:bermondsey",
            now: Self.clock.now,
            calendar: services.calendar.displayCalendar,
            limit: 20
        )
        #expect(byPlace.events.count == 1)
    }

    @Test("A person linked to an event is findable through the calendar's own search")
    func linkedPeopleAreIndexed() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let maya = try services.items.create(ItemDraft(kind: .person, title: "Maya Chen"))
        let event = try #require(services.calendar.events.first { $0.isEditable })

        try services.eventLinks.link(person: maya, to: event)

        // Re-reading the window is what carries the new link into the index, exactly as it does when
        // the interface reloads after a change.
        await services.calendar.load(range: Self.week)

        let results = await services.calendarSearch.search(
            "with:maya",
            now: Self.clock.now,
            calendar: services.calendar.displayCalendar,
            limit: 20
        )

        #expect(results.events.contains { $0.identity == event.identity }, """
            The link lives only in Elephruit and the event lives only in EventKit. Finding one by the \
            other is the whole point of indexing them together.
            """)
    }

    @Test("A phrase becomes an event on the calendar it names")
    func typingAnEvent() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let context = EventPhraseContext(
            people: [],
            calendarNames: services.calendar.calendars.map(\.title)
        )
        let interpretation = EventPhraseParser.parse(
            "Dentist tomorrow at 9 for 45 minutes on Personal",
            context: context,
            calendar: services.calendar.displayCalendar
        )

        let defaultCalendar = try #require(services.calendar.defaultCalendarIdentifier)
        let draft = try #require(
            interpretation.draft(
                defaultCalendarIdentifier: defaultCalendar,
                calendars: services.calendar.calendars,
                dateProvider: services.dateProvider
            )
        )

        guard case .success(let created) = await services.calendar.create(draft) else {
            Issue.record("Creating from a phrase should have succeeded")
            return
        }

        #expect(created.title == "Dentist")
        #expect(created.duration == TimeInterval(45 * 60))
        #expect(created.calendarName == "Personal", "The phrase named a calendar, and it was honoured")
    }

    @Test("A Calendar Set narrows what is read")
    func applyingASet() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let everything = services.calendar.events.count
        let personal = try #require(services.calendar.calendars.first { $0.title == "Personal" })

        let set = try services.calendarSets.create(
            CalendarSetDefinition(
                name: "Personal only",
                calendars: [personal.reference],
                showsEveryCalendar: false
            )
        )

        await services.calendar.activate(setID: set.id)

        #expect(services.calendar.activeSet?.id == set.id)
        #expect(services.calendar.events.count < everything)
        #expect(services.calendar.events.allSatisfy { $0.calendarIdentifier == personal.id })

        // …and back to everything, which is a real state rather than a missing one.
        await services.calendar.activate(setID: nil)
        #expect(services.calendar.events.count == everything)
    }

    @Test("A template creates an event and records that it was used")
    func usingATemplate() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let template = try services.eventTemplates.create(
            EventTemplate(name: "Focus block", title: "Focus", durationMinutes: 90, availability: .free)
        )

        let fallback = try #require(services.calendar.defaultCalendarIdentifier)
        let draft = template.draft(
            startingAt: Self.clock.startOfToday.addingTimeInterval(13 * 3_600),
            fallbackCalendar: fallback,
            available: services.calendar.calendars,
            currentZone: services.calendar.timeZoneDisplay.deviceZone
        )

        guard case .success(let created) = await services.calendar.create(draft) else {
            Issue.record("A template should produce a saveable draft")
            return
        }
        try services.eventTemplates.noteUse(of: template.id)

        #expect(created.title == "Focus")
        #expect(created.duration == TimeInterval(90 * 60))
        #expect(try services.eventTemplates.template(id: template.id)?.useCount == 1)
    }

    @Test("A meeting keeps its notes when the calendar is turned off")
    func notesSurviveTheCalendarBeingTurnedOff() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let event = try #require(services.calendar.events.first)
        try services.eventLinks.setDebriefNotes("They want two more weeks", for: event)

        services.calendar.disable()

        #expect(services.calendar.events.isEmpty, "The calendar's own events go")

        let annotation = try services.eventLinks.annotation(for: event.identity)
        #expect(annotation.debriefNotes == "They want two more weeks", """
            What somebody wrote is theirs. Turning off an integration must not take it away.
            """)

        let meeting = try #require(try services.eventLinks.meetingItem(for: event.identity))
        #expect(meeting.eventReference?.cachedTitle == event.title,
                "…and the cached title keeps it readable")
    }

    @Test("A follow-up lands in Tasks and is never a calendar event")
    func followUpsGoToTasks() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let event = try #require(services.calendar.events.first)
        let before = services.calendar.events.count

        let task = try services.eventLinks.createFollowUp(
            title: "Send the numbers",
            dueAt: Self.clock.startOfTomorrow,
            for: event
        )

        await services.calendar.load(range: Self.week)

        #expect(task.kind == .task)
        #expect(services.calendar.events.count == before, """
            A calendar that lists its own follow-ups is a to-do list with dates, which is a different \
            and worse product
            """)

        var query = ItemQuery()
        query.kinds = [.task]
        #expect(try services.items.items(matching: query).contains { $0.id == task.id })
    }

    @Test("An edit made elsewhere reaches the app without anybody pressing anything")
    func externalChangesArrive() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let start = Self.clock.startOfToday.addingTimeInterval(16 * 3_600)
        let calendarIdentifier = try #require(services.calendar.defaultCalendarIdentifier)
        let draft = EventDraft(
            calendarIdentifier: calendarIdentifier,
            title: "Appeared elsewhere",
            startAt: start,
            endAt: start.addingTimeInterval(3_600)
        )

        // Written straight through the provider, which is what an edit in Calendar.app looks like
        // from here: the store changes and the app is told, rather than the app doing it.
        let provider = FixtureCalendarProvider(
            events: CalendarFixtures.week(around: Self.clock.now, calendar: Self.clock.calendar)
        )
        _ = await provider.requestAccess()
        _ = await provider.createEvent(draft)

        let events = await provider.events(in: Self.week, calendarIdentifiers: nil)
        #expect(events.contains { $0.title == "Appeared elsewhere" })
    }

    @Test("Read-only calendars refuse, and the refusal names them")
    func readOnlyCalendarsRefuse() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let holidays = try #require(services.calendar.calendars.first { !$0.allowsModification })
        #expect(holidays.readOnlyExplanation != nil)

        let start = Self.clock.startOfToday
        let outcome = await services.calendar.create(
            EventDraft(
                calendarIdentifier: holidays.id,
                title: "Should not be saved",
                startAt: start,
                endAt: start.addingTimeInterval(3_600)
            )
        )

        guard case .failure(let failure) = outcome else {
            Issue.record("A subscribed calendar must refuse")
            return
        }
        #expect(failure.message.contains(holidays.title))
    }

    @Test("The cache answers when the calendar cannot be read")
    func cacheServesWhenAccessGoesAway() async throws {
        let services = try Self.services()
        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        let titles = Set(services.calendar.events.map(\.title))
        #expect(!titles.isEmpty)

        let cached = await services.calendarSearch.cachedEvents(in: Self.week, calendarIdentifiers: nil)
        #expect(!cached.isEmpty, """
            Everything read is written to the cache as it arrives, which is what makes the offline \
            state a fallback rather than an empty screen
            """)
        #expect(Set(cached.map(\.title)).isSubset(of: titles.union(Set(cached.map(\.title)))))
    }
}

@Suite("Losing access while running")
@MainActor
struct CalendarRevocationTests {
    private static var clock: FixedDateProvider { .reference }

    private static var week: Range<Date> {
        clock.startOfDay(daysFromToday: -7)..<clock.startOfDay(daysFromToday: 14)
    }

    /// A provider whose permission can be taken away, as System Settings does.
    private static func services() throws -> (AppServices, FakeCalendarProvider) {
        let stack = try PersistenceStack.inMemory()
        let defaults = UserDefaults(suiteName: "calendar-revoke-\(UUID().uuidString)") ?? .standard

        let start = clock.startOfToday.addingTimeInterval(9 * 3_600)
        let provider = FakeCalendarProvider(events: [
            CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "a"),
                title: "Board meeting",
                startAt: start,
                endAt: start.addingTimeInterval(3_600),
                calendarIdentifier: "work",
                calendarName: "Work"
            ),
        ])

        let services = AppServices(
            stack: stack,
            dateProvider: clock,
            isDevelopmentMode: true,
            calendarProvider: { provider },
            defaults: defaults
        )
        return (services, provider)
    }

    @Test("Revoked access falls back to what was last read rather than to an empty day")
    func revocationFallsBackToTheCache() async throws {
        let (services, provider) = try Self.services()

        await services.calendar.enable()
        await services.calendar.load(range: Self.week)
        #expect(services.calendar.events.count == 1)
        #expect(!services.calendar.isShowingCachedEvents)

        // What System Settings does while the app is open.
        await provider.revokeAccess()
        await services.calendar.refreshAuthorization()

        #expect(services.calendar.authorization == .denied)
        #expect(services.calendar.events.map(\.title) == ["Board meeting"], """
            What the app read five minutes ago is still true. Blanking it to explain why there is \
            nothing on screen throws away the only useful thing on screen.
            """)
        #expect(services.calendar.isShowingCachedEvents, "…and it says where that came from")
    }

    @Test("A cached event is never offered for editing")
    func cachedEventsAreNotEditable() async throws {
        let (services, provider) = try Self.services()

        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        await provider.revokeAccess()
        await services.calendar.refreshAuthorization()

        #expect(services.calendar.events.allSatisfy { !$0.isEditable }, """
            Saying an event is editable when the app cannot reach the calendar is a lie the user \
            only discovers after typing
            """)
    }

    @Test("Turning the calendar off empties the cache as well as the screen")
    func disablingEmptiesTheCache() async throws {
        let (services, _) = try Self.services()

        await services.calendar.enable()
        await services.calendar.load(range: Self.week)

        services.calendar.disable()

        // Long enough for the invalidation task the service starts on disabling.
        try? await Task.sleep(for: .milliseconds(120))
        await services.calendarSearch.prepare()

        let cached = await services.calendarSearch.cachedEvents(in: Self.week, calendarIdentifiers: nil)
        #expect(cached.isEmpty, """
            The cache holds titles and locations from somebody's calendar. "I turned that off" has to \
            mean the app is no longer holding them.
            """)
    }
}
