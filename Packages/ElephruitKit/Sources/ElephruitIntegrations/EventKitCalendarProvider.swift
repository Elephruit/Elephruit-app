import ElephruitCore
import EventKit
import Foundation

/// Reads the user's calendar through EventKit.
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
///
/// ### What it deliberately cannot do
/// The `EKEventStore` is `private` and never escapes. `CalendarProviding` has no write method. No
/// method on this type calls `save`, `remove`, or `commit`. That last one is asserted by a source
/// check rather than left to review, because "I did not call the write API" is exactly the sort of
/// claim that stops being true during a later edit.
/// ### Why an actor rather than a class with a lock
/// `EKEventStore` is not `Sendable`, and the two usual escapes — `@unchecked Sendable` on the wrapper
/// or `@preconcurrency` on the import — are both banned by this project's own source rules, because
/// they are how data races reach a release. An actor needs neither: the store is isolated to it, and
/// nothing non-`Sendable` ever leaves, because every `EKEvent` is projected into a value *inside* the
/// actor before it crosses back.
public actor EventKitCalendarProvider: CalendarProviding {
    /// Owned privately and never handed out. The whole read-only guarantee rests on this reference
    /// not escaping.
    private let store = EKEventStore()

    public init() {}

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization {
        Self.authorization(for: EKEventStore.authorizationStatus(for: .event))
    }

    /// Maps EventKit's status onto the app's, treating write-only as no read access at all.
    ///
    /// Write-only is a status this app can never usefully be in — it asks for full access — but it is
    /// representable, and mapping it to `.denied` is the honest reading: the app cannot see anything.
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

    // MARK: - Reading

    public func events(in range: Range<Date>) -> [CalendarEventSummary] {
        guard authorization.canRead else { return [] }

        let predicate = store.predicateForEvents(
            withStart: range.lowerBound,
            end: range.upperBound,
            calendars: nil
        )

        // Projected to values here, inside the actor, so no `EKEvent` ever crosses an isolation
        // boundary — which is what removes the need for any `Sendable` escape hatch.
        return store.events(matching: predicate)
            .map(Self.summary)
            .sorted { left, right in
                // All-day events first within a day, then by start. An all-day event is context for
                // the whole day rather than something happening at midnight.
                if left.isAllDay != right.isAllDay { return left.isAllDay }
                if left.startAt != right.startAt { return left.startAt < right.startAt }
                return left.displayTitle < right.displayTitle
            }
    }

    public func event(matching identity: EventIdentity) -> CalendarEventSummary? {
        guard authorization.canRead else { return nil }

        // Searched by date window rather than by identifier, because an occurrence of a recurring
        // event cannot be fetched directly — `event(withIdentifier:)` returns the series. A day
        // either side covers a timezone shift or an occurrence nudged by an edit.
        guard let occurrence = identity.occurrenceDate else {
            return firstEvent(matching: identity, near: Date(), window: 366 * 86_400)
        }
        return firstEvent(matching: identity, near: occurrence, window: 2 * 86_400)
    }

    private func firstEvent(
        matching identity: EventIdentity,
        near date: Date,
        window: TimeInterval
    ) -> CalendarEventSummary? {
        let range = date.addingTimeInterval(-window)..<date.addingTimeInterval(window)
        let candidates = events(in: range)

        // Exact occurrence first.
        if let exact = candidates.first(where: { $0.identity == identity }) {
            return exact
        }

        // Then the same series, which is what a link should fall back to when an occurrence has been
        // deleted from a series that still exists — the user's note is about *that meeting*, and
        // pointing at the series is more useful than reporting nothing.
        return candidates.first { $0.identity.externalIdentifier == identity.externalIdentifier }
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

    /// Turns an `EKEvent` into a value. The only place EventKit types cross into the app.
    static func summary(_ event: EKEvent) -> CalendarEventSummary {
        let identity = EventIdentity(
            externalIdentifier: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "",
            occurrenceDate: event.hasRecurrenceRules ? event.occurrenceDate : nil
        )

        return CalendarEventSummary(
            identity: identity,
            title: event.title ?? "",
            startAt: event.startDate ?? Date(),
            endAt: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            calendarName: event.calendar?.title,
            calendarColorName: nil,
            locationName: event.location,
            notes: event.notes,
            status: status(for: event.status),
            participation: participation(for: event),
            isRecurring: event.hasRecurrenceRules,
            isDetached: event.isDetached,
            attendeeNames: attendeeNames(for: event)
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

    /// What *this user* said about attending, from the attendee record representing them.
    ///
    /// `EKParticipant.isCurrentUser` is the only reliable way to find yourself among the attendees;
    /// matching by email would miss an alias. An event with no attendees is your own, so there is
    /// nothing to have replied to.
    static func participation(for event: EKEvent) -> EventParticipation {
        guard let attendees = event.attendees, !attendees.isEmpty else { return .unknown }
        guard let me = attendees.first(where: \.isCurrentUser) else { return .unknown }

        switch me.participantStatus {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .pending
        default: return .unknown
        }
    }

    static func attendeeNames(for event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }
        return attendees
            .filter { !$0.isCurrentUser }
            .compactMap { $0.name }
            .filter { !$0.isEmpty }
    }
}
