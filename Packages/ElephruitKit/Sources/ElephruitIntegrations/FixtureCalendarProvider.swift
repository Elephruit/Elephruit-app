import ElephruitCore
import Foundation

/// A calendar made of invented events.
///
/// ### Why this ships in the app rather than only in the tests
/// The same two reasons as ``FixtureContactsProvider``, and the second is again the important one.
///
/// A test must never write to the developer's real calendar, and a protocol with only a live
/// implementation invites exactly that.
///
/// But the reason it is reachable from the *app* is that a reviewer needs to see the module work —
/// the week grid, an overlapping morning, a multi-day trip, a recurring standup, a read-only
/// subscribed calendar refusing an edit, a declined meeting staying out of the way — without handing
/// it their own calendar to practise on. Every one of those states is here, deliberately, because
/// the awkward cases are the ones worth looking at and they are exactly the ones a real calendar
/// might not happen to contain on the day somebody reviews the work.
///
/// Every event here is invented and every calendar is fictional.
public actor FixtureCalendarProvider: CalendarProviding {
    private var events: [CalendarEventSummary]
    private var storedCalendars: [CalendarInfo]
    private var currentAuthorization: IntegrationAuthorization
    private let grantsAccess: Bool

    private var nextIdentifier = 1
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(
        events: [CalendarEventSummary]? = nil,
        calendars: [CalendarInfo] = CalendarFixtures.calendars,
        authorization: IntegrationAuthorization = .notRequested,
        grantsAccess: Bool = true
    ) {
        self.events = events ?? CalendarFixtures.week(around: Date())
        self.storedCalendars = calendars
        self.currentAuthorization = authorization
        self.grantsAccess = grantsAccess
    }

    // MARK: Authorisation

    public var authorization: IntegrationAuthorization { currentAuthorization }

    public func requestAccess() -> IntegrationAuthorization {
        currentAuthorization = grantsAccess ? .authorized : .denied
        return currentAuthorization
    }

    // MARK: Reading

    public func calendars() -> [CalendarInfo] {
        currentAuthorization.canRead ? storedCalendars : []
    }

    public func defaultCalendarIdentifier() -> String? {
        guard currentAuthorization.canRead else { return nil }
        return storedCalendars.first { $0.isDefaultForNewEvents }?.id
    }

    public func events(in range: Range<Date>, calendarIdentifiers: [String]?) -> [CalendarEventSummary] {
        guard currentAuthorization.canRead else { return [] }

        return events
            .filter { event in
                guard event.startAt < range.upperBound, event.endAt > range.lowerBound else { return false }
                guard let calendarIdentifiers else { return true }
                guard let identifier = event.calendarIdentifier else { return false }
                return calendarIdentifiers.contains(identifier)
            }
            .sorted { left, right in
                if left.isAllDay != right.isAllDay { return left.isAllDay }
                return left.startAt < right.startAt
            }
    }

    public func event(matching identity: EventIdentity) -> CalendarEventSummary? {
        guard currentAuthorization.canRead else { return nil }
        if let exact = events.first(where: { $0.identity == identity }) { return exact }
        return events.first { $0.identity.externalIdentifier == identity.externalIdentifier }
    }

    // MARK: Writing

    public func createEvent(_ draft: EventDraft) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard currentAuthorization.canRead else { return .failure(.notAuthorized) }
        guard let calendar = storedCalendars.first(where: { $0.id == draft.calendarIdentifier }) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard calendar.allowsModification else {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        let identifier = "fixture-\(nextIdentifier)"
        nextIdentifier += 1

        let created = Self.summary(from: draft, identifier: identifier, calendar: calendar)
        events.append(created)
        notifyChange()
        return .success(created)
    }

    public func updateEvent(
        matching identity: EventIdentity,
        with draft: EventDraft,
        scope: EventEditScope
    ) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard currentAuthorization.canRead else { return .failure(.notAuthorized) }
        guard let index = events.firstIndex(where: { $0.identity == identity }) else {
            return .failure(.eventNotFound)
        }
        guard let calendar = storedCalendars.first(where: { $0.id == draft.calendarIdentifier }) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard calendar.allowsModification else {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        let existing = events[index]
        let updated = Self.summary(
            from: draft,
            identifier: identity.externalIdentifier,
            occurrence: identity.occurrenceDate,
            calendar: calendar,
            isRecurring: existing.isRecurring,
            isDetached: scope == .thisEvent && existing.isRecurring
        )
        events[index] = updated

        // A scope reaching further than one occurrence moves the rest of the series by the same
        // amount, which is what a real store does and what makes the fixture worth demonstrating on.
        if scope != .thisEvent, existing.isRecurring {
            let shift = updated.startAt.timeIntervalSince(existing.startAt)
            let boundary = scope == .entireSeries ? Date.distantPast : (identity.occurrenceDate ?? .distantPast)

            for other in events.indices where
                events[other].identity.externalIdentifier == identity.externalIdentifier
                && events[other].identity != identity
                && (events[other].identity.occurrenceDate ?? .distantPast) >= boundary {
                events[other].startAt = events[other].startAt.addingTimeInterval(shift)
                events[other].endAt = events[other].endAt.addingTimeInterval(shift)
                events[other].title = updated.title
            }
        }

        notifyChange()
        return .success(updated)
    }

    public func deleteEvent(
        matching identity: EventIdentity,
        scope: EventEditScope
    ) -> Result<Void, CalendarWriteFailure> {
        guard currentAuthorization.canRead else { return .failure(.notAuthorized) }
        guard events.contains(where: { $0.identity == identity }) else { return .failure(.eventNotFound) }

        switch scope {
        case .thisEvent:
            events.removeAll { $0.identity == identity }
        case .entireSeries:
            events.removeAll { $0.identity.externalIdentifier == identity.externalIdentifier }
        case .thisAndFuture:
            let boundary = identity.occurrenceDate ?? .distantPast
            events.removeAll {
                $0.identity.externalIdentifier == identity.externalIdentifier
                    && ($0.identity.occurrenceDate ?? .distantPast) >= boundary
            }
        }

        notifyChange()
        return .success(())
    }

    // MARK: Changes

    public nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, for: id) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<Void>.Continuation, for id: UUID) {
        changeContinuations[id] = continuation
    }

    private func unregister(_ id: UUID) {
        changeContinuations[id] = nil
    }

    private func notifyChange() {
        for continuation in changeContinuations.values { continuation.yield() }
    }

    // MARK: Building

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
            status: .confirmed,
            availability: draft.availability,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            alarms: draft.alarms,
            isRecurring: isRecurring || draft.recurrence != nil,
            recurrence: draft.recurrence,
            isDetached: isDetached,
            isEditable: calendar.allowsModification,
            createdAt: Date(),
            lastModifiedAt: Date()
        )
    }
}

/// The invented calendar.
///
/// Chosen to contain the cases that are awkward rather than the ones that are typical: a morning
/// with three overlapping meetings, a trip spanning four days, a weekly standup, a declined
/// invitation, a cancelled meeting, an all-day holiday on a read-only feed, and an evening event
/// outside working hours. A calendar of tidy one-hour meetings demonstrates nothing.
public enum CalendarFixtures {
    public static let calendars: [CalendarInfo] = [
        CalendarInfo(
            id: "fixture.work", title: "Work", colorName: "indigo",
            accountName: "Acme", accountKind: .exchange, isDefaultForNewEvents: true
        ),
        CalendarInfo(
            id: "fixture.personal", title: "Personal", colorName: "teal",
            accountName: "iCloud", accountKind: .iCloud
        ),
        CalendarInfo(
            id: "fixture.family", title: "Family", colorName: "orange",
            accountName: "iCloud", accountKind: .iCloud
        ),
        CalendarInfo(
            id: "fixture.holidays", title: "UK Holidays", colorName: "graphite",
            accountName: "iCloud", accountKind: .subscribed
        ),
    ]

    /// A fortnight of events around a given day.
    public static func week(around date: Date, calendar: Calendar = .current) -> [CalendarEventSummary] {
        let day = calendar.startOfDay(for: date)

        func at(_ dayOffset: Int, _ hour: Double) -> Date {
            day.addingTimeInterval(Double(dayOffset) * 86_400 + hour * 3_600)
        }

        var events: [CalendarEventSummary] = []

        // A weekly standup, as a series with real occurrences.
        for week in -2...3 {
            for weekday in 0...4 {
                let start = at(week * 7 + weekday, 9.5)
                events.append(
                    make(
                        "Standup",
                        identifier: "fixture.standup",
                        occurrence: start,
                        start: start,
                        minutes: 15,
                        calendar: calendars[0],
                        recurring: true,
                        recurrence: EventRecurrence(
                            frequency: .weekly, daysOfWeek: (2...6).map { .init($0) }
                        )
                    )
                )
            }
        }

        // A morning where three things clash, which is the layout worth looking at.
        events.append(make("Design review", identifier: "fixture.design", start: at(0, 10),
                           minutes: 90, calendar: calendars[0], location: "Room 2",
                           attendees: ["Maya Chen", "Jordan Blake"]))
        events.append(make("Vendor call", identifier: "fixture.vendor", start: at(0, 10.5),
                           minutes: 30, calendar: calendars[0]))
        events.append(make("1:1 with Maya", identifier: "fixture.oneToOne", start: at(0, 11),
                           minutes: 30, calendar: calendars[0],
                           notes: "Career conversation — she raised this last month.",
                           attendees: ["Maya Chen"]))

        // A meeting somebody declined, which should stay out of the way without disappearing.
        events.append(make("All-hands", identifier: "fixture.allhands", start: at(1, 16),
                           minutes: 60, calendar: calendars[0], participation: .declined))

        // A cancelled meeting, which stays visible because somebody remembers it being there.
        events.append(make("Budget review", identifier: "fixture.budget", start: at(2, 14),
                           minutes: 60, calendar: calendars[0], status: .cancelled))

        // A trip across four days, starting yesterday, so today is the middle of something rather
        // than the start of it. That is the case the awareness band exists for: an entry reading
        // only "Berlin" on each of four mornings says nothing that was not already known on the
        // first, and "day 2 of 4" is the whole of what makes it worth a row.
        events.append(make("Berlin — client visit", identifier: "fixture.trip", start: at(-1, 0),
                           minutes: 4 * 24 * 60, calendar: calendars[0], allDay: true))

        // An all-day entry that is only today, so the one-day case is drawn too — it must not say
        // "day 1 of 1", which is a sentence nobody needs.
        events.append(make("Rosa's birthday", identifier: "fixture.birthday", start: at(0, 0),
                           minutes: 24 * 60, calendar: calendars[2], allDay: true))

        // Time claimed and left showing as free, which is what a defended block is — and which the
        // day's plan must not count as a meeting or as a clash with the review above it.
        events.append(make("Focus — pricing model", identifier: "fixture.focus", start: at(0, 14),
                           minutes: 120, calendar: calendars[0], availability: .free))

        // A video call, so Join has something to open. The link is in the URL field, which is where
        // an organiser's tooling puts it.
        events.append(make("Roadmap sync", identifier: "fixture.roadmap", start: at(0, 16),
                           minutes: 45, calendar: calendars[0],
                           attendees: ["Rosa Iyer", "Theo Brandt", "Ines Duarte"],
                           url: URL(string: "https://meet.google.com/fixture-roadmap")))

        // Leave, marked unavailable rather than busy — a different thing from a meeting, and the
        // reason the day's plan reads availability rather than guessing from the title.
        events.append(make("Out of office", identifier: "fixture.leave", start: at(6, 0),
                           minutes: 2 * 24 * 60, calendar: calendars[1], allDay: true,
                           availability: .unavailable))

        // Somewhere to actually go, late enough in the day that the "leave by" line is reviewable
        // in an afternoon as well as a morning. A named building with a street address is the case
        // that matters: a room number is a place you are already in, and a conferencing link in the
        // location field is not a place at all.
        events.append(make("Studio visit", identifier: "fixture.studio", start: at(0, 18),
                           minutes: 60, calendar: calendars[0],
                           location: "Northwind Studio, 40 Rivington Street"))

        // An evening event outside working hours.
        events.append(make("Dinner at Aba", identifier: "fixture.dinner", start: at(1, 19),
                           minutes: 120, calendar: calendars[1],
                           location: "Aba, 302 North Green Street"))

        // A read-only holiday, so a refusal is demonstrable.
        events.append(make("Summer Bank Holiday", identifier: "fixture.holiday", start: at(9, 0),
                           minutes: 24 * 60, calendar: calendars[3], allDay: true))

        // Something on the family calendar, for a Calendar Set to include or exclude.
        events.append(make("School concert", identifier: "fixture.concert", start: at(4, 18),
                           minutes: 90, calendar: calendars[2], location: "Assembly hall"))

        // A call in another zone, for the dual ruler and the warning.
        events.append(make("Call with Jordan", identifier: "fixture.jordan", start: at(2, 15),
                           minutes: 45, calendar: calendars[0],
                           attendees: ["Jordan Blake"], timeZone: "Europe/London"))

        return events
    }

    /// The work address the sample library gives these people, so an invitation resolves to a record.
    ///
    /// Everybody on a fixture invitation is either somebody `PeopleSampleData` created — in which
    /// case the address matches and they resolve — or somebody it did not, in which case they stay
    /// an unlinked attendee. Both cases are worth being able to see.
    private static func address(for name: String) -> String? {
        let known = [
            "Maya Chen": "maya@northwind.example",
            "Nisha Raman": "nisha@northwind.example",
            "Rosa Iyer": "rosa@northwind.example",
            "Theo Brandt": "theo@northwind.example",
            "Ines Duarte": "ines@northwind.example",
        ]
        // Jordan Blake and anybody else deliberately has none: an address on an invitation that the
        // library has never heard of is the ordinary case, and the page has to draw it honestly.
        return known[name]
    }

    private static func make(
        _ title: String,
        identifier: String,
        occurrence: Date? = nil,
        start: Date,
        minutes: Int,
        calendar: CalendarInfo,
        location: String? = nil,
        notes: String? = nil,
        attendees: [String] = [],
        allDay: Bool = false,
        recurring: Bool = false,
        recurrence: EventRecurrence? = nil,
        participation: EventParticipation = .accepted,
        status: EventStatus = .confirmed,
        availability: EventAvailability = .busy,
        url: URL? = nil,
        timeZone: String? = nil
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: identifier, occurrenceDate: occurrence),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: allDay,
            calendarIdentifier: calendar.id,
            calendarName: calendar.title,
            calendarColorName: calendar.colorName,
            accountName: calendar.accountName,
            locationName: location,
            notes: notes,
            url: url,
            status: status,
            participation: attendees.isEmpty ? .unknown : participation,
            availability: availability,
            timeZoneIdentifier: timeZone,
            alarms: attendees.isEmpty ? [] : [.minutesBefore(10)],
            // Addresses, not just names. A real invitation carries them, and they are what lets an
            // attendee resolve to somebody in the library by *identity* rather than by their name
            // folding to the same string as somebody else's — see `DailyPlanService.participants`.
            attendees: attendees.map {
                EventAttendee(name: $0, emailAddress: address(for: $0), participation: .accepted)
            },
            isRecurring: recurring,
            recurrence: recurrence,
            isEditable: calendar.allowsModification,
            createdAt: start.addingTimeInterval(-7 * 86_400),
            lastModifiedAt: start.addingTimeInterval(-86_400)
        )
    }
}
