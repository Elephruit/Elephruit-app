import ElephruitCore
import Foundation

/// Optional system integrations, each behind a protocol with an inert default.
///
/// Milestone 1 ships **no** integrations: the app has no calendar, contacts, or notification
/// entitlement, and adding one happens in the same commit as the feature that needs it — see
/// `docs/06-privacy-and-entitlements.md`.
///
/// These protocols and their no-op implementations exist now so that the features which will use
/// them can be written, injected, and tested without waiting for a permission dialogue, and so that
/// a user who never grants access exercises a real code path rather than an untested `nil` branch.

// MARK: - Calendar

/// A calendar event, as the app understands it.
///
/// A value type rather than an `EKEvent`, so nothing outside this module depends on EventKit and the
/// no-op provider needs no framework at all.
public struct CalendarEventSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var calendarName: String?
    public var locationName: String?

    public init(
        id: String,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        locationName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.locationName = locationName
    }
}

/// Whether an integration may be used.
///
/// `notRequested` is distinct from `denied` so the interface can offer to ask rather than reporting a
/// refusal the user never made.
public enum IntegrationAuthorization: Sendable, Hashable {
    case notRequested
    case authorized
    case denied
    case unavailable

    public var canRead: Bool { self == .authorized }
}

/// Reading the user's calendar. **Read-only by design** — Elephruit never writes to EventKit, so it
/// cannot corrupt a calendar it does not own.
public protocol CalendarProviding: Sendable {
    var authorization: IntegrationAuthorization { get async }
    func requestAccess() async -> IntegrationAuthorization
    func events(in range: Range<Date>) async -> [CalendarEventSummary]
}

/// The default. Reports ``IntegrationAuthorization/notRequested`` and returns nothing.
public struct NoCalendarProvider: CalendarProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Calendar access requested but no provider is configured")
        return .unavailable
    }

    public func events(in range: Range<Date>) async -> [CalendarEventSummary] { [] }
}

// MARK: - Contacts

/// A contact, as the app understands it. Contacts remains authoritative for what it holds; this is a
/// read-only projection used to offer links.
public struct ContactSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var givenName: String
    public var familyName: String
    public var organizationName: String?
    public var emailAddresses: [String]

    public init(
        id: String,
        givenName: String,
        familyName: String,
        organizationName: String? = nil,
        emailAddresses: [String] = []
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.organizationName = organizationName
        self.emailAddresses = emailAddresses
    }

    public var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public protocol ContactsProviding: Sendable {
    var authorization: IntegrationAuthorization { get async }
    func requestAccess() async -> IntegrationAuthorization
    func contacts(matching query: String) async -> [ContactSummary]
}

public struct NoContactsProvider: ContactsProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Contacts access requested but no provider is configured")
        return .unavailable
    }

    public func contacts(matching query: String) async -> [ContactSummary] { [] }
}

// MARK: - Notifications

/// A reminder the app would like the system to deliver.
public struct ScheduledReminder: Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var body: String
    public var fireAt: Date

    public init(id: UUID, title: String, body: String, fireAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.fireAt = fireAt
    }
}

public protocol NotificationScheduling: Sendable {
    var authorization: IntegrationAuthorization { get async }
    func requestAccess() async -> IntegrationAuthorization
    func schedule(_ reminder: ScheduledReminder) async
    func cancel(id: UUID) async
    func cancelAll() async
}

/// The default. Milestone 1 schedules nothing, and the app requests no notification permission.
public struct NoNotificationScheduler: NotificationScheduling {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Notification access requested but no scheduler is configured")
        return .unavailable
    }

    public func schedule(_ reminder: ScheduledReminder) async {}
    public func cancel(id: UUID) async {}
    public func cancelAll() async {}
}
