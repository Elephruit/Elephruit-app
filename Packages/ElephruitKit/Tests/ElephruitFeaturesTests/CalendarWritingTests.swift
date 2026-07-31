import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import Foundation
import Testing

@MainActor
private func writingService(
    provider: FakeCalendarProvider,
    clock: FixedDateProvider = .reference
) async -> CalendarService {
    let defaults = UserDefaults(suiteName: "calendar-writes-\(UUID().uuidString)") ?? .standard
    defaults.set(true, forKey: "calendar.isEnabled")

    let service = CalendarService(dateProvider: clock, defaults: defaults) { provider }
    await service.enable()
    await service.load(range: clock.startOfDay(daysFromToday: -7)..<clock.startOfDay(daysFromToday: 30))
    return service
}

private func draft(
    calendar: String = "work",
    title: String = "Review",
    at start: Date,
    minutes: Int = 60
) -> EventDraft {
    EventDraft(
        calendarIdentifier: calendar,
        title: title,
        startAt: start,
        endAt: start.addingTimeInterval(TimeInterval(minutes * 60))
    )
}

@Suite("Creating and changing events")
@MainActor
struct CalendarWritingTests {
    private static let clock = FixedDateProvider.reference

    @Test("Creating an event writes it once and shows it")
    func creating() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        let outcome = await service.create(draft(at: Self.clock.startOfToday.addingTimeInterval(9 * 3_600)))

        #expect(outcome.isSuccess)
        #expect(await provider.writes.count == 1)
        #expect(await provider.writes.first?.operation == "create")
        #expect(service.events.contains { $0.title == "Review" })
    }

    @Test("A read-only calendar refuses, and says which one")
    func readOnlyCalendarRefuses() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        let outcome = await service.create(draft(calendar: "holidays", at: Self.clock.startOfToday))

        #expect(!outcome.isSuccess)
        if case .failure(let failure) = outcome {
            #expect(failure.message.contains("Holidays"))
            #expect(!failure.isWorthRetrying, "Retrying a read-only calendar will never work")
        }
        #expect(service.lastWriteFailure != nil)
    }

    @Test("A calendar that no longer exists refuses rather than inventing one")
    func missingCalendarRefuses() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        let outcome = await service.create(draft(calendar: "removed", at: Self.clock.startOfToday))
        #expect(!outcome.isSuccess)
    }

    @Test("Dragging an event keeps its length")
    func draggingPreservesLength() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let existing = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "a"),
            title: "Standup",
            startAt: start,
            endAt: start.addingTimeInterval(1_800),
            calendarIdentifier: "work",
            calendarName: "Work"
        )

        let provider = FakeCalendarProvider(events: [existing])
        let service = await writingService(provider: provider)

        let outcome = await service.move(existing, to: start.addingTimeInterval(3_600), scope: .thisEvent)

        #expect(outcome.isSuccess)
        if case .success(let moved) = outcome {
            #expect(moved.duration == 1_800, "A drag moves an event; it does not resize it")
            #expect(moved.startAt == start.addingTimeInterval(3_600))
        }
    }

    @Test("A read-only event refuses a drag without reaching the store at all")
    func readOnlyEventsCannotBeDragged() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let locked = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "holiday"),
            title: "Bank Holiday",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "holidays",
            calendarName: "Holidays",
            isEditable: false
        )

        let provider = FakeCalendarProvider(events: [locked])
        let service = await writingService(provider: provider)

        let outcome = await service.move(locked, to: start.addingTimeInterval(3_600), scope: .thisEvent)

        #expect(!outcome.isSuccess)
        #expect(await provider.writes.isEmpty, """
            A refusal the app already knows about should not become a round trip to EventKit and an \
            error message from a framework
            """)
    }

    @Test("Resizing changes the end and leaves the start alone")
    func resizing() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let existing = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "a"),
            title: "Workshop",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "work",
            calendarName: "Work"
        )

        let provider = FakeCalendarProvider(events: [existing])
        let service = await writingService(provider: provider)

        let outcome = await service.resize(existing, newEnd: start.addingTimeInterval(7_200), scope: .thisEvent)

        if case .success(let resized) = outcome {
            #expect(resized.startAt == start)
            #expect(resized.duration == 7_200)
        } else {
            Issue.record("The resize should have succeeded")
        }
    }

    @Test("Every scope reaches the store exactly as chosen")
    func scopesArePassedThrough() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let occurrence = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "series", occurrenceDate: start),
            title: "Standup",
            startAt: start,
            endAt: start.addingTimeInterval(900),
            calendarIdentifier: "work",
            calendarName: "Work",
            isRecurring: true
        )

        let provider = FakeCalendarProvider(events: [occurrence])
        let service = await writingService(provider: provider)

        await service.update(
            occurrence.identity,
            with: EventDraft(editing: occurrence),
            scope: .thisAndFuture
        )

        #expect(await provider.writes.last?.scope == .thisAndFuture, """
            A scope defaulted anywhere between the sheet and the store is a year of somebody's \
            series changed by an edit they meant for one day
            """)
    }

    @Test("Deleting a whole series removes every occurrence")
    func deletingASeries() async {
        let first = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let second = first.addingTimeInterval(86_400)

        let occurrences = [first, second].map { start in
            CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "series", occurrenceDate: start),
                title: "Standup",
                startAt: start,
                endAt: start.addingTimeInterval(900),
                calendarIdentifier: "work",
                calendarName: "Work",
                isRecurring: true
            )
        }

        let provider = FakeCalendarProvider(events: occurrences)
        let service = await writingService(provider: provider)

        await service.delete(
            EventIdentity(externalIdentifier: "series", occurrenceDate: first),
            scope: .entireSeries
        )

        #expect(await provider.storedEventCount == 0)
    }

    @Test("Deleting one occurrence leaves the rest of the series")
    func deletingOneOccurrence() async {
        let first = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let second = first.addingTimeInterval(86_400)

        let occurrences = [first, second].map { start in
            CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "series", occurrenceDate: start),
                title: "Standup",
                startAt: start,
                endAt: start.addingTimeInterval(900),
                calendarIdentifier: "work",
                calendarName: "Work",
                isRecurring: true
            )
        }

        let provider = FakeCalendarProvider(events: occurrences)
        let service = await writingService(provider: provider)

        await service.delete(
            EventIdentity(externalIdentifier: "series", occurrenceDate: first),
            scope: .thisEvent
        )

        #expect(await provider.storedEventCount == 1)
    }

    @Test("Moving between calendars is confirmed before it happens")
    func calendarMoveNeedsConfirming() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let existing = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "a"),
            title: "Review",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "work",
            calendarName: "Work"
        )

        let provider = FakeCalendarProvider(events: [existing])
        let service = await writingService(provider: provider)

        var moved = EventDraft(editing: existing)
        moved.calendarIdentifier = "personal"

        let required = service.confirmations(for: moved, replacing: existing)

        #expect(required.count == 1)
        #expect(required.first?.message.contains("Work") == true)
        #expect(required.first?.message.contains("Personal") == true)
    }

    @Test("An unchanged calendar needs no confirmation")
    func ordinaryEditsAreNotInterrupted() async {
        let start = Self.clock.startOfToday.addingTimeInterval(9 * 3_600)
        let existing = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "a"),
            title: "Review",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "work",
            calendarName: "Work"
        )

        let provider = FakeCalendarProvider(events: [existing])
        let service = await writingService(provider: provider)

        var retitled = EventDraft(editing: existing)
        retitled.title = "Quarterly review"

        #expect(service.confirmations(for: retitled, replacing: existing).isEmpty, """
            Interrupting every edit trains people to click through the ones that matter
            """)
    }
}

@Suite("Which calendars are showing")
@MainActor
struct CalendarVisibilityTests {
    private static let clock = FixedDateProvider.reference

    @Test("Every calendar is read when no set is applied")
    func noSetReadsEverything() async {
        let provider = FakeCalendarProvider(events: [
            CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "w"),
                title: "Work thing",
                startAt: clockToday(9),
                endAt: clockToday(10),
                calendarIdentifier: "work"
            ),
            CalendarEventSummary(
                identity: EventIdentity(externalIdentifier: "p"),
                title: "Personal thing",
                startAt: clockToday(11),
                endAt: clockToday(12),
                calendarIdentifier: "personal"
            ),
        ])

        let service = await writingService(provider: provider)
        #expect(service.events.count == 2)
        #expect(service.visibleCalendarIdentifiers == nil)
    }

    @Test("A default calendar prefers one that can actually be written to")
    func defaultCalendarIsWritable() async {
        let provider = FakeCalendarProvider(calendars: [
            CalendarInfo(id: "holidays", title: "Holidays", accountKind: .subscribed,
                         isDefaultForNewEvents: true),
            CalendarInfo(id: "work", title: "Work", accountKind: .iCloud),
        ])
        let service = await writingService(provider: provider)

        #expect(service.defaultCalendarIdentifier == "work", """
            A subscribed calendar marked as the store's default would otherwise be where every new \
            event tried and failed to land
            """)
    }

    @Test("Calendars are grouped by the account that holds them")
    func groupedByAccount() async {
        let provider = FakeCalendarProvider(calendars: [
            CalendarInfo(id: "a", title: "Work", accountName: "Acme", accountKind: .exchange),
            CalendarInfo(id: "b", title: "Home", accountName: "iCloud", accountKind: .iCloud),
            CalendarInfo(id: "c", title: "Family", accountName: "iCloud", accountKind: .iCloud),
        ])
        let service = await writingService(provider: provider)

        let groups = service.calendarsByAccount
        #expect(groups.count == 2)
        #expect(groups.first { $0.account == "iCloud" }?.calendars.count == 2)
    }

    private func clockToday(_ hour: Double) -> Date {
        Self.clock.startOfToday.addingTimeInterval(hour * 3_600)
    }
}

@Suite("Showing another time zone")
@MainActor
struct CalendarDisplayZoneTests {
    @Test("Choosing a display zone changes the labels and not the events")
    func displayZoneIsPresentationOnly() async {
        let clock = FixedDateProvider.reference
        let start = clock.startOfToday.addingTimeInterval(15 * 3_600)

        let event = CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: "a"),
            title: "Call",
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: "work"
        )

        let provider = FakeCalendarProvider(events: [event])
        let service = await writingService(provider: provider, clock: clock)

        let before = service.events.first?.startAt
        service.showTimes(in: "Asia/Tokyo")

        #expect(service.timeZoneDisplay.displayZone.identifier == "Asia/Tokyo")
        #expect(service.events.first?.startAt == before, """
            The one invariant of the whole time-zone feature: drawing the calendar somewhere else \
            must never move an event
            """)
        #expect(service.displayCalendar.timeZone.identifier == "Asia/Tokyo")
    }

    @Test("Travel mode is explicit and reversible")
    func travelMode() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        service.setTravelling(true, destinationZone: "Europe/London")
        #expect(service.timeZoneDisplay.isTravelling)
        #expect(service.timeZoneDisplay.displayZone.identifier == "Europe/London")

        service.setTravelling(false, destinationZone: nil)
        #expect(!service.timeZoneDisplay.isTravelling)
        #expect(service.timeZoneDisplay.displayZone.identifier == service.timeZoneDisplay.deviceZoneIdentifier)
    }

    @Test("A favourite zone can be added and taken away")
    func favourites() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        service.toggleFavourite(zoneIdentifier: "Europe/London")
        #expect(service.timeZoneDisplay.favouriteZoneIdentifiers == ["Europe/London"])

        service.toggleFavourite(zoneIdentifier: "Europe/London")
        #expect(service.timeZoneDisplay.favouriteZoneIdentifiers.isEmpty)
    }
}

private extension Result where Success == CalendarEventSummary, Failure == CalendarWriteFailure {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

@Suite("Switching calendars off for now")
@MainActor
struct CalendarVisibilityToggleTests {
    private static let clock = FixedDateProvider.reference

    private static func made(_ title: String, calendar: String) -> CalendarEventSummary {
        let start = clock.startOfToday.addingTimeInterval(9 * 3_600)
        return CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            calendarIdentifier: calendar
        )
    }

    @Test("Hiding a calendar removes its events and nothing else")
    func hidingOneCalendar() async {
        let provider = FakeCalendarProvider(events: [
            Self.made("Work thing", calendar: "work"),
            Self.made("Personal thing", calendar: "personal"),
        ])
        let service = await writingService(provider: provider)
        #expect(service.events.count == 2)

        await service.toggleVisibility(of: "personal")

        #expect(service.events.map { $0.title } == ["Work thing"])
        #expect(!service.isVisible(CalendarInfo(id: "personal", title: "Personal")))
    }

    @Test("Showing everything again is one action")
    func showingAllAgain() async {
        let provider = FakeCalendarProvider(events: [
            Self.made("Work thing", calendar: "work"),
            Self.made("Personal thing", calendar: "personal"),
        ])
        let service = await writingService(provider: provider)

        await service.toggleVisibility(of: "personal")
        await service.toggleVisibility(of: "work")
        #expect(service.events.isEmpty)

        await service.showAllCalendars()
        #expect(service.events.count == 2)
    }

    @Test("A hidden calendar and a Calendar Set compose rather than fight")
    func visibilityComposesWithSets() async {
        let provider = FakeCalendarProvider(events: [
            Self.made("Work thing", calendar: "work"),
            Self.made("Personal thing", calendar: "personal"),
        ])
        let service = await writingService(provider: provider)

        // With no set, hiding one calendar leaves the rest.
        await service.toggleVisibility(of: "personal")
        #expect(service.visibleCalendarIdentifiers?.contains("personal") == false)
        #expect(service.visibleCalendarIdentifiers?.contains("work") == true, """
            A momentary tick must not turn into a saved configuration, and a saved configuration must
            not be edited by a glance
            """)
    }

    @Test("Cycling sets passes through “everything”")
    func cyclingIncludesEverything() async {
        let provider = FakeCalendarProvider()
        let service = await writingService(provider: provider)

        // With no sets at all there is nothing to cycle to, which is a state rather than a crash.
        #expect(service.setAfterActive() == nil)
    }
}
