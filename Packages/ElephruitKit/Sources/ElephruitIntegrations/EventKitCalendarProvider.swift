import AppKit
import ElephruitCore
import EventKit
import Foundation

/// Reads and writes the user's calendar through EventKit.
///
/// ### Every API here was checked against the macOS SDK headers, not recalled
/// - `requestFullAccessToEvents()` — `API_AVAILABLE(macos(14.0))`
/// - `requestAccessToEntityType:completion:` — **deprecated** `macos(10.0, 14.0)`, and therefore not
///   used
/// - `EKAuthorizationStatus.fullAccess` — `NS_ENUM_AVAILABLE(14_0)`; `.authorized` is the deprecated
///   spelling and is treated as equivalent for older stores
/// - `EKEventStoreChanged` — available since macOS 10.8
/// - `calendarItemExternalIdentifier` and `occurrenceDate` — both since macOS 10.8, which is what
///   makes occurrence-stable linking possible at all
/// - `calendarItems(withExternalIdentifier:)` — since macOS 10.8, and the only supported way to
///   reach a series' master event without scanning backwards through time
/// - `EKSpan` — exactly two values, `.thisEvent` and `.futureEvents`. There is no "entire series"
///   span; see ``entireSeriesEvent(for:)`` for how the third scope is honoured anyway.
///
/// ### What it deliberately cannot do
/// The `EKEventStore` is `private` and never escapes, and every `EKEvent` is projected into a value
/// *inside* the actor before it crosses back — which is what removes the need for any `Sendable`
/// escape hatch and keeps this an actor rather than a class with a lock.
///
/// Mutating calls appear in exactly three methods — ``createEvent(_:)``, ``updateEvent(matching:with:scope:)``
/// and ``deleteEvent(matching:scope:)`` — and `CalendarWriteSafetyTests` fails if one appears
/// anywhere else, including inside a method whose name says it reads.
public actor EventKitCalendarProvider: CalendarProviding {
    /// Owned privately and never handed out.
    private let store = EKEventStore()

    public init() {}

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization {
        Self.authorization(for: EKEventStore.authorizationStatus(for: .event))
    }

    /// Maps EventKit's status onto the app's, treating write-only as no access at all.
    ///
    /// Write-only is a status this app never asks for, but it is representable — an earlier build
    /// could have been granted it. Mapping it to `.denied` is the honest reading: a calendar the app
    /// cannot see is one it must not offer to edit either.
    static func authorization(for status: EKAuthorizationStatus) -> IntegrationAuthorization {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .denied
        @unknown default:
            // A status this build has never heard of is not assumed to grant anything.
            .denied
        }
    }

    public func requestAccess() async -> IntegrationAuthorization {
        let current = EKEventStore.authorizationStatus(for: .event)
        guard current == .notDetermined else {
            // macOS records the decision permanently; asking again shows nothing. Returning the
            // existing answer keeps the caller from waiting on a prompt that will never appear.
            return Self.authorization(for: current)
        }

        do {
            // Full access, because EventKit offers no read-only request. See `CalendarProviding`.
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Diagnostics.integrations.error(
                "Calendar access request failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        return Self.authorization(for: EKEventStore.authorizationStatus(for: .event))
    }

    // MARK: - Discovery

    public func calendars() -> [CalendarInfo] {
        guard authorization.canRead else { return [] }

        let defaultIdentifier = store.defaultCalendarForNewEvents?.calendarIdentifier

        return store.calendars(for: .event)
            .map { Self.info(for: $0, defaultIdentifier: defaultIdentifier) }
            .sorted { left, right in
                // Grouped by account, then alphabetical — the order Calendar.app's own sidebar uses,
                // and the one a user's muscle memory already has.
                if left.accountName != right.accountName { return left.accountName < right.accountName }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    public func defaultCalendarIdentifier() -> String? {
        guard authorization.canRead else { return nil }
        return store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    // MARK: - Reading

    public func events(in range: Range<Date>, calendarIdentifiers: [String]?) -> [CalendarEventSummary] {
        guard authorization.canRead else { return [] }
        guard range.lowerBound < range.upperBound else { return [] }

        // An empty selection is not "everything". A Calendar Set with nothing switched on must cost
        // nothing, rather than quietly reading the whole store and filtering afterwards.
        let selected: [EKCalendar]?
        if let calendarIdentifiers {
            guard !calendarIdentifiers.isEmpty else { return [] }
            let wanted = Set(calendarIdentifiers)
            selected = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
            if selected?.isEmpty == true { return [] }
        } else {
            selected = nil
        }

        let predicate = store.predicateForEvents(
            withStart: range.lowerBound,
            end: range.upperBound,
            calendars: selected
        )

        // Projected to values here, inside the actor, so no `EKEvent` ever crosses an isolation
        // boundary.
        return store.events(matching: predicate)
            .map(Self.summary)
            .sorted(by: Self.displayOrder)
    }

    public func event(matching identity: EventIdentity) -> CalendarEventSummary? {
        guard authorization.canRead else { return nil }
        return ekEvent(matching: identity).map(Self.summary)
    }

    /// All-day events first within a day, then by start, then by title.
    ///
    /// An all-day event is context for the whole day rather than something happening at midnight, so
    /// sorting it by its start time would put it below the 8 a.m. meeting it frames.
    static func displayOrder(_ left: CalendarEventSummary, _ right: CalendarEventSummary) -> Bool {
        if left.isAllDay != right.isAllDay { return left.isAllDay }
        if left.startAt != right.startAt { return left.startAt < right.startAt }
        return left.displayTitle < right.displayTitle
    }

    // MARK: - Writing

    public func createEvent(_ draft: EventDraft) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard authorization.canRead else { return .failure(.notAuthorized) }

        guard let calendar = store.calendar(withIdentifier: draft.calendarIdentifier) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard calendar.allowsContentModifications else {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(draft, to: event)

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure(.saveRejected(reason: error.localizedDescription))
        }

        return .success(Self.summary(event))
    }

    public func updateEvent(
        matching identity: EventIdentity,
        with draft: EventDraft,
        scope: EventEditScope
    ) -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard authorization.canRead else { return .failure(.notAuthorized) }

        guard let target = event(for: identity, scope: scope) else { return .failure(.eventNotFound) }
        guard let destination = store.calendar(withIdentifier: draft.calendarIdentifier) else {
            return .failure(.calendarNotFound(identifier: draft.calendarIdentifier))
        }
        guard destination.allowsContentModifications else {
            return .failure(.calendarReadOnly(title: destination.title))
        }
        if let origin = target.calendar, !origin.allowsContentModifications {
            return .failure(.calendarReadOnly(title: origin.title))
        }

        // EventKit refuses to move a recurring event between calendars, and the refusal arrives as an
        // opaque save error. Saying so plainly beats letting the framework's message reach a user.
        if target.hasRecurrenceRules, target.calendar?.calendarIdentifier != destination.calendarIdentifier {
            return .failure(.saveRejected(
                reason: "A repeating event cannot be moved to another calendar. Delete it and create it again."
            ))
        }

        target.calendar = destination
        apply(draft, to: target)

        do {
            try store.save(target, span: Self.span(for: scope), commit: true)
        } catch {
            return .failure(.saveRejected(reason: error.localizedDescription))
        }

        return .success(Self.summary(target))
    }

    public func deleteEvent(
        matching identity: EventIdentity,
        scope: EventEditScope
    ) -> Result<Void, CalendarWriteFailure> {
        guard authorization.canRead else { return .failure(.notAuthorized) }

        guard let target = event(for: identity, scope: scope) else { return .failure(.eventNotFound) }
        if let calendar = target.calendar, !calendar.allowsContentModifications {
            return .failure(.calendarReadOnly(title: calendar.title))
        }

        do {
            try store.remove(target, span: Self.span(for: scope), commit: true)
        } catch {
            return .failure(.deleteRejected(reason: error.localizedDescription))
        }

        return .success(())
    }

    /// EventKit's two spans, from the app's three scopes.
    ///
    /// `.entireSeries` maps to `.futureEvents` *applied to the master event*, which is the whole
    /// series by definition — see ``event(for:scope:)``. There is no third span to map it to.
    static func span(for scope: EventEditScope) -> EKSpan {
        switch scope {
        case .thisEvent: .thisEvent
        case .thisAndFuture, .entireSeries: .futureEvents
        }
    }

    /// The `EKEvent` a scoped edit should be applied to.
    ///
    /// For `.entireSeries`, that is the series' **first** occurrence rather than the one the user
    /// clicked: `.futureEvents` from the master covers every occurrence, and there is no span that
    /// reaches backwards from the middle. For the other two scopes it is the occurrence itself.
    private func event(for identity: EventIdentity, scope: EventEditScope) -> EKEvent? {
        switch scope {
        case .thisEvent, .thisAndFuture:
            return ekEvent(matching: identity)
        case .entireSeries:
            return entireSeriesEvent(for: identity) ?? ekEvent(matching: identity)
        }
    }

    /// The master event of a series.
    ///
    /// `calendarItems(withExternalIdentifier:)` returns the underlying items rather than expanded
    /// occurrences, so this reaches the first one without scanning a window backwards through time —
    /// which would have to guess how far back to look and would be wrong for anything older.
    private func entireSeriesEvent(for identity: EventIdentity) -> EKEvent? {
        store.calendarItems(withExternalIdentifier: identity.externalIdentifier)
            .compactMap { $0 as? EKEvent }
            .min { left, right in
                (left.startDate ?? .distantFuture) < (right.startDate ?? .distantFuture)
            }
    }

    /// Copies a draft onto an event. The only place a user's decision becomes EventKit state.
    ///
    /// Nothing Elephruit knows that the user did not type is written here. There is no branch that
    /// consults a linked person, a note, or a project — ``EventDraft`` cannot carry one.
    private func apply(_ draft: EventDraft, to event: EKEvent) {
        event.title = draft.title
        event.startDate = draft.startAt
        event.endDate = draft.endAt
        event.isAllDay = draft.isAllDay
        event.timeZone = draft.timeZone
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.url = draft.url

        // Offered only where the calendar supports it. An Exchange calendar that does not do
        // "tentative" would otherwise reject the whole save over one field nobody chose deliberately.
        if let availability = Self.availability(from: draft.availability),
           let supported = event.calendar?.supportedEventAvailabilities,
           supported.contains(Self.availabilityMask(for: draft.availability)) {
            event.availability = availability
        }

        // Replaced wholesale rather than merged: the editor shows every alarm the event has, so what
        // it hands back *is* the complete set, and merging would resurrect one the user removed.
        for existing in event.alarms ?? [] { event.removeAlarm(existing) }
        for alarm in draft.alarms { event.addAlarm(Self.ekAlarm(from: alarm)) }

        if let recurrence = draft.recurrence {
            event.recurrenceRules = [Self.ekRule(from: recurrence)]
        } else {
            event.recurrenceRules = nil
        }
    }

    /// The occurrence a stored identity points at.
    private func ekEvent(matching identity: EventIdentity) -> EKEvent? {
        guard let occurrence = identity.occurrenceDate else {
            // A non-recurring event resolves directly, without a date window at all.
            if let direct = store.calendarItems(withExternalIdentifier: identity.externalIdentifier)
                .compactMap({ $0 as? EKEvent })
                .first {
                return direct
            }
            return firstEvent(matching: identity, near: Date(), window: 366 * 86_400)
        }
        return firstEvent(matching: identity, near: occurrence, window: 2 * 86_400)
    }

    private func firstEvent(
        matching identity: EventIdentity,
        near date: Date,
        window: TimeInterval
    ) -> EKEvent? {
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil
        )
        let candidates = store.events(matching: predicate)

        // Exact occurrence first.
        if let exact = candidates.first(where: { Self.identity(of: $0) == identity }) { return exact }

        // Then the same series, which is what a link should fall back to when an occurrence has been
        // deleted from a series that still exists — the user's note is about *that meeting*, and
        // pointing at the series is more useful than reporting nothing.
        return candidates.first { $0.calendarItemExternalIdentifier == identity.externalIdentifier }
    }

    // MARK: - Changes

    /// `nonisolated`, and observing *any* store rather than this one.
    ///
    /// Both follow from the same constraint: an observer token is not `Sendable`, so it cannot be
    /// captured for later removal, and `store` is actor-isolated so it cannot be named from a
    /// `nonisolated` context. `NotificationCenter.notifications` sidesteps the token entirely — the
    /// `Task` owns the subscription and cancelling it unsubscribes — and there is only ever one event
    /// store in this process, so filtering by object would exclude nothing.
    public nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Projection

    static func identity(of event: EKEvent) -> EventIdentity {
        EventIdentity(
            externalIdentifier: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "",
            occurrenceDate: event.hasRecurrenceRules ? event.occurrenceDate : nil
        )
    }

    /// Turns an `EKEvent` into a value. The only place EventKit types cross into the app.
    static func summary(_ event: EKEvent) -> CalendarEventSummary {
        let calendar = event.calendar

        return CalendarEventSummary(
            identity: identity(of: event),
            title: event.title ?? "",
            startAt: event.startDate ?? Date(),
            endAt: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            calendarIdentifier: calendar?.calendarIdentifier,
            calendarName: calendar?.title,
            calendarColorName: calendar.map(paletteName(for:)),
            accountName: calendar?.source?.title,
            locationName: event.location,
            notes: event.notes,
            url: event.url,
            status: status(for: event.status),
            participation: participation(for: event),
            availability: availability(for: event.availability),
            timeZoneIdentifier: event.timeZone?.identifier,
            alarms: (event.alarms ?? []).map(alarm(for:)),
            attendees: attendees(for: event),
            organizerName: event.organizer?.name,
            isRecurring: event.hasRecurrenceRules,
            recurrence: event.recurrenceRules?.first.map(recurrence(for:)),
            isDetached: event.isDetached,
            isEditable: calendar?.allowsContentModifications ?? false,
            createdAt: event.creationDate,
            lastModifiedAt: event.lastModifiedDate
        )
    }

    static func status(for status: EKEventStatus) -> EventStatus {
        switch status {
        case .none: .none
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .cancelled
        @unknown default: .none
        }
    }

    static func availability(for availability: EKEventAvailability) -> EventAvailability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .notSupported
        @unknown default: .busy
        }
    }

    /// The same value as a mask, which is the shape `supportedEventAvailabilities` reports in.
    static func availabilityMask(for availability: EventAvailability) -> EKCalendarEventAvailabilityMask {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: []
        }
    }

    static func availability(from availability: EventAvailability) -> EKEventAvailability? {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: nil
        }
    }

    /// What *this user* said about attending, from the attendee record representing them.
    ///
    /// `EKParticipant.isCurrentUser` is the only reliable way to find yourself among the attendees;
    /// matching by email would miss an alias. An event with no attendees is your own, so there is
    /// nothing to have replied to.
    static func participation(for event: EKEvent) -> EventParticipation {
        guard let attendees = event.attendees, !attendees.isEmpty else { return .unknown }
        guard let me = attendees.first(where: \.isCurrentUser) else { return .unknown }
        return participation(for: me.participantStatus)
    }

    static func participation(for status: EKParticipantStatus) -> EventParticipation {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
    }

    static func attendees(for event: EKEvent) -> [EventAttendee] {
        let organizerIdentifier = event.organizer.flatMap(emailAddress(of:))

        return (event.attendees ?? []).map { participant in
            let email = emailAddress(of: participant)
            return EventAttendee(
                name: participant.name ?? email ?? "",
                emailAddress: email,
                participation: participation(for: participant.participantStatus),
                role: role(for: participant.participantRole),
                isOrganizer: email != nil && email == organizerIdentifier,
                isCurrentUser: participant.isCurrentUser
            )
        }
    }

    /// The address behind a participant, which EventKit exposes only as a `mailto:` URL.
    static func emailAddress(of participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        // `mailto:someone@example.com` — everything after the scheme, percent-decoded.
        let address = url.absoluteString.dropFirst("mailto:".count)
        let decoded = address.removingPercentEncoding ?? String(address)
        return decoded.isEmpty ? nil : decoded
    }

    static func role(for role: EKParticipantRole) -> EventAttendeeRole {
        switch role {
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        default: .unknown
        }
    }

    // MARK: Alarms

    static func alarm(for alarm: EKAlarm) -> EventAlarm {
        // `relativeOffset` is not optional and reads as zero when the alarm is absolute, so the
        // absolute date is what decides which kind this is.
        if let absolute = alarm.absoluteDate {
            return EventAlarm(absoluteDate: absolute)
        }
        return EventAlarm(relativeOffset: alarm.relativeOffset)
    }

    static func ekAlarm(from alarm: EventAlarm) -> EKAlarm {
        if let absolute = alarm.absoluteDate { return EKAlarm(absoluteDate: absolute) }
        return EKAlarm(relativeOffset: alarm.relativeOffset ?? 0)
    }

    // MARK: Recurrence

    static func recurrence(for rule: EKRecurrenceRule) -> EventRecurrence {
        let end: EventRecurrence.End
        if let recurrenceEnd = rule.recurrenceEnd {
            if let date = recurrenceEnd.endDate {
                end = .onDate(date)
            } else if recurrenceEnd.occurrenceCount > 0 {
                end = .afterOccurrences(recurrenceEnd.occurrenceCount)
            } else {
                end = .never
            }
        } else {
            end = .never
        }

        return EventRecurrence(
            frequency: frequency(for: rule.frequency),
            interval: rule.interval,
            daysOfWeek: (rule.daysOfTheWeek ?? []).map {
                EventRecurrence.DayOfWeek($0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
            },
            daysOfMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            end: end
        )
    }

    static func ekRule(from recurrence: EventRecurrence) -> EKRecurrenceRule {
        let end: EKRecurrenceEnd?
        switch recurrence.end {
        case .never: end = nil
        case .onDate(let date): end = EKRecurrenceEnd(end: date)
        case .afterOccurrences(let count): end = EKRecurrenceEnd(occurrenceCount: max(1, count))
        }

        let days = recurrence.daysOfWeek.compactMap { entry -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: entry.weekday) else { return nil }
            return EKRecurrenceDayOfWeek(weekday, weekNumber: entry.weekNumber)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency(from: recurrence.frequency),
            interval: max(1, recurrence.interval),
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: recurrence.daysOfMonth.isEmpty ? nil : recurrence.daysOfMonth.map(NSNumber.init),
            monthsOfTheYear: recurrence.monthsOfYear.isEmpty ? nil : recurrence.monthsOfYear.map(NSNumber.init),
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    static func frequency(for frequency: EKRecurrenceFrequency) -> EventRecurrence.Frequency {
        switch frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        @unknown default: .weekly
        }
    }

    static func frequency(from frequency: EventRecurrence.Frequency) -> EKRecurrenceFrequency {
        switch frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
    }

    // MARK: Calendars

    static func info(for calendar: EKCalendar, defaultIdentifier: String?) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            colorName: paletteName(for: calendar),
            accountName: calendar.source?.title ?? "",
            accountKind: accountKind(for: calendar),
            allowsModification: calendar.allowsContentModifications,
            isDefaultForNewEvents: calendar.calendarIdentifier == defaultIdentifier
        )
    }

    /// A calendar's colour, reduced to a palette name.
    ///
    /// Converted through `NSColor` rather than by reading `CGColor.components` directly, because the
    /// components of a colour in a device or pattern space are not red, green, and blue — and
    /// treating them as though they were is how a grey calendar comes out pink.
    static func paletteName(for calendar: EKCalendar) -> String {
        guard let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) else {
            return "blue"
        }
        return CalendarPalette.name(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }

    static func accountKind(for calendar: EKCalendar) -> CalendarAccountKind {
        // The calendar's own type is checked first: a subscribed feed can sit inside any account, and
        // the fact that it cannot be edited is a property of the calendar rather than the source.
        switch calendar.type {
        case .subscription: return .subscribed
        case .birthday: return .birthdays
        default: break
        }

        guard let source = calendar.source else { return .other }

        switch source.sourceType {
        case .local: return .local
        case .exchange: return .exchange
        case .subscribed: return .subscribed
        case .birthdays: return .birthdays
        case .mobileMe: return .iCloud
        case .calDAV:
            // iCloud is a CalDAV source whose title EventKit sets to "iCloud"; Google is CalDAV too,
            // and there is no type that distinguishes them. The title is the only signal available,
            // and getting it wrong costs a glyph rather than a behaviour.
            let title = source.title.lowercased()
            if title.contains("icloud") { return .iCloud }
            if title.contains("google") || title.contains("gmail") { return .google }
            return .other
        @unknown default:
            return .other
        }
    }
}
