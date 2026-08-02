import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import Foundation
import Testing

/// A calendar the test controls, standing in for EventKit.
///
/// ### What it is for
/// Every call is recorded, so a test can assert that turning the feature *off* means the calendar is
/// not consulted at all — and, now that the module writes, that a write reaches the store exactly
/// once, with the scope the user chose and not a default one.
///
/// It behaves like EventKit in the ways that matter and not in the ways that do not: read-only
/// calendars refuse, an unknown identifier fails rather than silently creating a calendar, and
/// deleting a series with `.entireSeries` removes every occurrence rather than one. It does *not*
/// expand recurrence rules — a test that needs several occurrences hands them in.
actor FakeCalendarProvider: CalendarProviding {
    private var storedEvents: [CalendarEventSummary]
    private var storedCalendars: [CalendarInfo]
    private var status: IntegrationAuthorization
    private var grantOnRequest: IntegrationAuthorization

    /// Every call, in order. Reads and writes alike.
    private(set) var readLog: [String] = []

    /// Every write, with the scope it was given.
    private(set) var writeLog: [(operation: String, scope: EventEditScope?)] = []

    private var continuation: AsyncStream<Void>.Continuation?
    private var nextIdentifier = 1

    init(
        events: [CalendarEventSummary] = [],
        calendars: [CalendarInfo] = [
            CalendarInfo(id: "work", title: "Work", accountName: "iCloud", accountKind: .iCloud,
                         isDefaultForNewEvents: true),
            CalendarInfo(id: "personal", title: "Personal", accountName: "iCloud", accountKind: .iCloud),
            CalendarInfo(id: "holidays", title: "Holidays", accountName: "iCloud", accountKind: .subscribed),
        ],
        status: IntegrationAuthorization = .notRequested,
        grantOnRequest: IntegrationAuthorization = .authorized
    ) {
        self.storedEvents = events
        self.storedCalendars = calendars
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    var authorization: IntegrationAuthorization { status }

    func requestAccess() async -> IntegrationAuthorization {
        readLog.append("requestAccess")
        status = grantOnRequest
        return status
    }

    func calendars() -> [CalendarInfo] {
        readLog.append("calendars")
        guard status.canRead else { return [] }
        return storedCalendars
    }

    func defaultCalendarIdentifier() -> String? {
        guard status.canRead else { return nil }
        return storedCalendars.first { $0.isDefaultForNewEvents }?.id
    }

    func events(in range: Range<Date>, calendarIdentifiers: [String]?) -> [CalendarEventSummary] {
        readLog.append("events")
        guard status.canRead else { return [] }

        return storedEvents.filter { event in
            guard event.startAt < range.upperBound, event.endAt > range.lowerBound else { return false }
            guard let calendarIdentifiers else { return true }
            guard let identifier = event.calendarIdentifier else { return false }
            return calendarIdentifiers.contains(identifier)
        }
    }

    func event(matching identity: EventIdentity) -> CalendarEventSummary? {
        readLog.append("event")
        guard status.canRead else { return nil }

        if let exact = storedEvents.first(where: { $0.identity == identity }) { return exact }
        return storedEvents.first { $0.identity.externalIdentifier == identity.externalIdentifier }
    }

    // MARK: Writing

    func createEvent(_ draft: EventDraft) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        writeLog.append(("create", nil))
        guard status.canRead else { return .failure(.notAuthorized) }

        guard let calendar = storedCalendars.first(where: { $0.id == draft.calendarIdentifier }) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard calendar.allowsModification else {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        let identifier = "created-\(nextIdentifier)"
        nextIdentifier += 1

        let created = Self.summary(from: draft, identifier: identifier, calendar: calendar)
        storedEvents.append(created)
        return .success(created)
    }

    func updateEvent(
        matching identity: EventIdentity,
        with draft: EventDraft,
        scope: EventEditScope
    ) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        writeLog.append(("update", scope))
        guard status.canRead else { return .failure(.notAuthorized) }

        guard let index = storedEvents.firstIndex(where: { $0.identity == identity }) else {
            return .failure(.eventNotFound)
        }
        guard let calendar = storedCalendars.first(where: { $0.id == draft.calendarIdentifier }) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard calendar.allowsModification else {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        let updated = Self.summary(
            from: draft,
            identifier: identity.externalIdentifier,
            occurrence: identity.occurrenceDate,
            calendar: calendar,
            isRecurring: storedEvents[index].isRecurring,
            isDetached: scope == .thisEvent && storedEvents[index].isRecurring
        )
        storedEvents[index] = updated
        return .success(updated)
    }

    func deleteEvent(
        matching identity: EventIdentity,
        scope: EventEditScope
    ) -> Result<Void, CalendarWriteFailure> {
        writeLog.append(("delete", scope))
        guard status.canRead else { return .failure(.notAuthorized) }

        guard storedEvents.contains(where: { $0.identity == identity }) else {
            return .failure(.eventNotFound)
        }

        switch scope {
        case .thisEvent:
            storedEvents.removeAll { $0.identity == identity }
        case .entireSeries:
            storedEvents.removeAll { $0.identity.externalIdentifier == identity.externalIdentifier }
        case .thisAndFuture:
            let boundary = identity.occurrenceDate ?? .distantPast
            storedEvents.removeAll {
                $0.identity.externalIdentifier == identity.externalIdentifier
                    && ($0.identity.occurrenceDate ?? .distantPast) >= boundary
            }
        }

        return .success(())
    }

    private static func summary(
        from draft: EventDraft,
        identifier: String,
        occurrence: Date? = nil,
        calendar: CalendarInfo,
        isRecurring: Bool = false,
        isDetached: Bool = false
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: identifier, occurrenceDate: occurrence),
            title: draft.title,
            startAt: draft.startAt,
            endAt: draft.endAt,
            isAllDay: draft.isAllDay,
            calendarIdentifier: calendar.id,
            calendarName: calendar.title,
            calendarColorName: calendar.colorName,
            accountName: calendar.accountName,
            locationName: draft.location.isEmpty ? nil : draft.location,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            url: draft.url,
            availability: draft.availability,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            alarms: draft.alarms,
            isRecurring: isRecurring || draft.recurrence != nil,
            recurrence: draft.recurrence,
            isDetached: isDetached
        )
    }

    nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            Task { await self.store(continuation) }
        }
    }

    private func store(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    // MARK: Test control

    /// What EventKit does during a sync: posts `EKEventStoreChanged`, often in bursts.
    func emitChange() {
        continuation?.yield()
    }

    func replace(with events: [CalendarEventSummary]) {
        storedEvents = events
    }

    func replaceCalendars(with calendars: [CalendarInfo]) {
        storedCalendars = calendars
    }

    func revokeAccess() {
        status = .denied
    }

    func callCount(of name: String) -> Int {
        readLog.filter { $0 == name }.count
    }

    var storedEventCount: Int { storedEvents.count }

    func storedEvent(titled title: String) -> CalendarEventSummary? {
        storedEvents.first { $0.title == title }
    }

    var writes: [(operation: String, scope: EventEditScope?)] { writeLog }
}

@MainActor
private func makeService(
    provider: FakeCalendarProvider,
    clock: FixedDateProvider = .reference,
    enabled: Bool = false
) -> CalendarService {
    let defaults = UserDefaults(suiteName: "calendar-tests-\(UUID().uuidString)") ?? .standard
    defaults.set(enabled, forKey: "calendar.isEnabled")
    return CalendarService(dateProvider: clock, defaults: defaults) { provider }
}

private func event(
    _ title: String,
    identifier: String,
    occurrence: Date? = nil,
    start: Date,
    minutes: Int = 60,
    participation: EventParticipation = .unknown,
    status: EventStatus = .confirmed,
    isAllDay: Bool = false,
    isRecurring: Bool = false
) -> CalendarEventSummary {
    CalendarEventSummary(
        identity: EventIdentity(externalIdentifier: identifier, occurrenceDate: occurrence),
        title: title,
        startAt: start,
        endAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
        isAllDay: isAllDay,
        status: status,
        participation: participation,
        isRecurring: isRecurring
    )
}

@Suite("Event identity")
struct EventIdentityTests {
    @Test("A non-recurring event needs only its identifier")
    func plainIdentity() {
        let identity = EventIdentity(externalIdentifier: "abc")
        #expect(identity.storageKey == "abc")
        #expect(EventIdentity.fromStorageKey("abc") == identity)
    }

    @Test("An occurrence round-trips through storage")
    func occurrenceRoundTrips() {
        let occurrence = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let identity = EventIdentity(externalIdentifier: "abc", occurrenceDate: occurrence)

        let restored = EventIdentity.fromStorageKey(identity.storageKey)
        #expect(restored == identity, "A link that cannot be read back is not a link")
    }

    @Test("An identifier containing a hash is not truncated")
    func identifiersMayContainSeparators() {
        // EventKit identifiers are opaque, and assuming a character never appears in one is how
        // links silently break for a subset of users.
        let identity = EventIdentity(externalIdentifier: "abc#def")
        #expect(EventIdentity.fromStorageKey(identity.storageKey)?.externalIdentifier == "abc#def")
    }

    @Test("Two occurrences of one series are different links")
    func occurrencesAreDistinct() {
        let tuesday = EventIdentity(externalIdentifier: "standup", occurrenceDate: Date(timeIntervalSinceReferenceDate: 0))
        let wednesday = EventIdentity(externalIdentifier: "standup", occurrenceDate: Date(timeIntervalSinceReferenceDate: 86_400))

        #expect(tuesday != wednesday)
        #expect(tuesday.storageKey != wednesday.storageKey)
        #expect(tuesday.externalIdentifier == wednesday.externalIdentifier, "…but the same series")
    }

    @Test("An empty key is not an identity")
    func emptyKeyIsNil() {
        #expect(EventIdentity.fromStorageKey("") == nil)
    }
}

@Suite("Calendar is off until asked for")
@MainActor
struct CalendarOptInTests {
    @Test("A fresh install never touches the calendar")
    func nothingHappensUntilEnabled() async {
        let provider = FakeCalendarProvider(events: [
            event("Standup", identifier: "a", start: FixedDateProvider.reference.startOfToday),
        ])
        let service = makeService(provider: provider)

        await service.start()
        await service.load(range: FixedDateProvider.reference.today)

        #expect(!service.isEnabled)
        #expect(service.events.isEmpty)
        #expect(await provider.readLog.isEmpty,
                "The calendar must not be read, and no prompt shown, before the user asks for it")
    }

    @Test("Enabling asks once and then reads")
    func enablingRequestsAccess() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(events: [event("Standup", identifier: "a", start: clock.startOfToday)])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        let authorization = await service.enable()

        #expect(authorization == .authorized)
        #expect(service.isEnabled)
        #expect(await provider.callCount(of: "requestAccess") == 1)
        #expect(service.events.count == 1)
    }

    @Test("A refusal is a state, not a crash or an empty day")
    func refusalIsExplained() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(
            events: [event("Standup", identifier: "a", start: clock.startOfToday)],
            grantOnRequest: .denied
        )
        let service = makeService(provider: provider, clock: clock)

        let authorization = await service.enable()

        #expect(authorization == .denied)
        #expect(service.events.isEmpty)
        #expect(authorization.explanation?.isEmpty == false, "A refusal has to say what to do about it")
        #expect(!authorization.isWorthAsking, "…and must not offer a button that shows no prompt")
    }

    @Test("Turning it off forgets what was read")
    func disablingClearsEvents() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(events: [event("Standup", identifier: "a", start: clock.startOfToday)])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()
        #expect(!service.events.isEmpty)

        service.disable()

        #expect(!service.isEnabled)
        #expect(service.events.isEmpty, "A stale copy of a calendar the user removed is the wrong answer")
    }

    @Test("Access revoked in System Settings degrades to an explained state")
    func revocationWhileRunning() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(events: [event("Standup", identifier: "a", start: clock.startOfToday)])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()
        #expect(service.events.count == 1)

        // What System Settings does while the app is open.
        await provider.revokeAccess()
        await service.refreshAuthorization()

        #expect(service.authorization == .denied)
        #expect(service.events.isEmpty, "Not a silently empty day — an explained one")
        #expect(service.authorization.explanation?.isEmpty == false)
    }
}

@Suite("Calendar reading")
@MainActor
struct CalendarReadingTests {
    @Test("Declined events are hidden; cancelled ones are not")
    func declinedHiddenCancelledShown() async {
        let clock = FixedDateProvider.reference
        let start = clock.startOfToday.addingTimeInterval(9 * 3_600)

        let provider = FakeCalendarProvider(events: [
            event("Accepted", identifier: "a", start: start, participation: .accepted),
            event("Declined", identifier: "b", start: start, participation: .declined),
            event("Cancelled", identifier: "c", start: start, participation: .accepted, status: .cancelled),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()

        let today = service.events(on: clock.startOfToday)
        let titles = today.map { $0.displayTitle }

        #expect(!titles.contains("Declined"), "A meeting you said no to is not part of your day")
        #expect(titles.contains("Cancelled"),
                "A meeting cancelled an hour beforehand is information, not noise")
        #expect(titles.contains("Accepted"))
    }

    @Test("An event is on every day it touches")
    func multiDayEvents() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(events: [
            event("Conference", identifier: "a", start: clock.startOfToday.addingTimeInterval(-3_600), minutes: 60 * 30),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.startOfDay(daysFromToday: -1)..<clock.startOfDay(daysFromToday: 2))
        await service.enable()

        #expect(!service.events(on: clock.startOfDay(daysFromToday: -1)).isEmpty)
        #expect(!service.events(on: clock.startOfToday).isEmpty)
    }

    @Test("Only what overlaps the window is returned")
    func windowIsRespected() async {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(events: [
            event("Today", identifier: "a", start: clock.startOfToday.addingTimeInterval(3_600)),
            event("Next month", identifier: "b", start: clock.startOfDay(daysFromToday: 40)),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()

        #expect(service.events.map { $0.displayTitle } == ["Today"])
    }
}

@Suite("Recurring events")
@MainActor
struct RecurringEventTests {
    /// The Phase D acceptance criterion: a link to one occurrence survives a series edit.
    @Test("A link to one occurrence survives an edit to the whole series")
    func occurrenceLinkSurvivesSeriesEdit() async {
        let clock = FixedDateProvider.reference
        let tuesday = clock.startOfToday.addingTimeInterval(9 * 3_600)
        let wednesday = clock.startOfDay(daysFromToday: 1).addingTimeInterval(9 * 3_600)

        // A weekly standup. The note was written about Tuesday's.
        let tuesdayIdentity = EventIdentity(externalIdentifier: "standup", occurrenceDate: tuesday)

        let provider = FakeCalendarProvider(events: [
            event("Standup", identifier: "standup", occurrence: tuesday, start: tuesday, isRecurring: true),
            event("Standup", identifier: "standup", occurrence: wednesday, start: wednesday, isRecurring: true),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()

        let before = await service.event(matching: tuesdayIdentity)
        #expect(before?.startAt == tuesday)

        // Someone renames the series and moves it an hour later — "all future events". The
        // occurrence *dates* are unchanged, which is exactly why they are the key.
        await provider.replace(with: [
            event("Daily Standup", identifier: "standup", occurrence: tuesday,
                  start: tuesday.addingTimeInterval(3_600), isRecurring: true),
            event("Daily Standup", identifier: "standup", occurrence: wednesday,
                  start: wednesday.addingTimeInterval(3_600), isRecurring: true),
        ])

        let after = await service.event(matching: tuesdayIdentity)

        #expect(after != nil, "The link must still resolve after the series is edited")
        #expect(after?.identity == tuesdayIdentity, "…and to the same occurrence, not a different one")
        #expect(after?.title == "Daily Standup", "…showing the edit rather than a stale title")
        #expect(after?.startAt == tuesday.addingTimeInterval(3_600), "…and its new time")
    }

    @Test("A deleted occurrence falls back to its series rather than vanishing")
    func deletedOccurrenceFallsBack() async {
        let clock = FixedDateProvider.reference
        let tuesday = clock.startOfToday.addingTimeInterval(9 * 3_600)
        let wednesday = clock.startOfDay(daysFromToday: 1).addingTimeInterval(9 * 3_600)

        let provider = FakeCalendarProvider(events: [
            event("Standup", identifier: "standup", occurrence: wednesday, start: wednesday, isRecurring: true),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.today)
        await service.enable()

        let found = await service.event(matching: EventIdentity(externalIdentifier: "standup", occurrenceDate: tuesday))
        #expect(found?.identity.externalIdentifier == "standup",
                "A note about a cancelled instance should still point at the meeting it was about")
    }

    @Test("Two occurrences of the same series are separately linkable")
    func occurrencesResolveIndependently() async {
        let clock = FixedDateProvider.reference
        let tuesday = clock.startOfToday.addingTimeInterval(9 * 3_600)
        let wednesday = clock.startOfDay(daysFromToday: 1).addingTimeInterval(9 * 3_600)

        let provider = FakeCalendarProvider(events: [
            event("Standup", identifier: "s", occurrence: tuesday, start: tuesday, isRecurring: true),
            event("Standup", identifier: "s", occurrence: wednesday, start: wednesday, isRecurring: true),
        ])
        let service = makeService(provider: provider, clock: clock)

        await service.load(range: clock.startOfToday..<clock.startOfDay(daysFromToday: 3))
        await service.enable()

        let first = await service.event(matching: EventIdentity(externalIdentifier: "s", occurrenceDate: tuesday))
        let second = await service.event(matching: EventIdentity(externalIdentifier: "s", occurrenceDate: wednesday))

        #expect(first?.startAt == tuesday)
        #expect(second?.startAt == wednesday)
        #expect(first?.id != second?.id, "Two notes about two standups must not collapse into one link")
    }
}

/// A background sync posts `EKEventStoreChanged` in bursts, and a burst must cost one refresh.
@MainActor
@Suite("Change notifications coalesce")
struct CalendarChangeCoalescingTests {
    @Test("A burst of store-change notifications produces one re-read, not one each")
    func burstCoalesces() async throws {
        let clock = FixedDateProvider.reference
        let provider = FakeCalendarProvider(
            events: [event("Standup", identifier: "a", start: clock.startOfToday)]
        )
        let service = makeService(provider: provider, clock: clock)

        await service.enable()
        await service.load(range: clock.today)
        let readsBeforeBurst = await provider.callCount(of: "events")

        // What a sync delivers: many notifications in quick succession.
        for _ in 0..<12 {
            await provider.emitChange()
        }

        // Wait for the coalescing window to close and the refresh to land, then a beat longer to
        // catch any queued extras the old code would have run.
        var refreshed = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            refreshed = (await provider.callCount(of: "events")) - readsBeforeBurst
            if refreshed > 0 { break }
        }
        try await Task.sleep(for: .milliseconds(400))
        refreshed = (await provider.callCount(of: "events")) - readsBeforeBurst

        #expect(refreshed > 0, "a store change must still cause a re-read")
        // On a loaded machine the twelve emissions can straddle a few coalescing windows, so the
        // bound is a tolerance rather than an exact count. The defect this guards — one re-read
        // per buffered notification — produces all twelve, every time.
        #expect(refreshed <= 4,
                "twelve notifications became \(refreshed) re-reads — the burst is not being coalesced")
    }
}
