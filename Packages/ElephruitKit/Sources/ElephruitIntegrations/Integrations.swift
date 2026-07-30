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

/// Reading the user's calendar.
///
/// ### Read-only by construction, not by promise
/// There is **no write method on this protocol**, and no way to reach the underlying `EKEventStore`
/// through it. Writing to a calendar from Elephruit is therefore a compile error rather than a rule
/// someone might forget — which matters more than usual here, because of what EventKit makes us ask
/// for.
///
/// ### The permission is broader than the use, and that is Apple's model, not a choice
/// EventKit offers exactly two requests: `requestFullAccessToEvents()` and
/// `requestWriteOnlyAccessToEvents()`. **There is no read-only tier.** Write-only is for apps that
/// only add events, so an app that merely *reads* has to ask for full access — verified against the
/// macOS SDK headers, where `requestAccessToEntityType:` is deprecated as of macOS 14.
///
/// So the app asks for more than it uses, and cannot avoid it. What it can do is make the unused
/// half unreachable, which is what this protocol does, and prove it, which is what
/// `CalendarWriteSafetyTests` does.
public protocol CalendarProviding: Sendable, AnyObject {
    /// The current authorisation, read without prompting.
    var authorization: IntegrationAuthorization { get async }

    /// Prompts, if and only if the user has never been asked.
    ///
    /// Returns the resulting authorisation. Calling this when a decision already exists is harmless
    /// and shows nothing — macOS records the answer permanently, which is why
    /// ``IntegrationAuthorization/isWorthAsking`` exists.
    func requestAccess() async -> IntegrationAuthorization

    /// Events overlapping `range`, in start order.
    ///
    /// Returns an empty array rather than failing when access has not been granted: an unauthorised
    /// calendar is a legitimate state with nothing in it, not an error to be handled at every call
    /// site.
    func events(in range: Range<Date>) async -> [CalendarEventSummary]

    /// One occurrence, if it still exists.
    ///
    /// Used to refresh a stored link. `nil` means the occurrence is gone — deleted, or the calendar
    /// was removed — which is a state the app records rather than an error.
    func event(matching identity: EventIdentity) async -> CalendarEventSummary?

    /// Fires when the calendar database changes, so views can re-read.
    ///
    /// An `AsyncStream` rather than a notification name, so a consumer neither imports EventKit nor
    /// has to remember to remove an observer.
    var changes: AsyncStream<Void> { get }
}

/// The default, and what the app uses until calendar access is deliberately enabled.
///
/// Reports ``IntegrationAuthorization/notRequested`` and returns nothing. Every path through the
/// interface therefore runs against a real implementation from the first launch, rather than a `nil`
/// branch that only executes for users who grant permission.
public final class NoCalendarProvider: CalendarProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Calendar access requested but no provider is configured")
        return .unavailable
    }

    public func events(in range: Range<Date>) async -> [CalendarEventSummary] { [] }

    public func event(matching identity: EventIdentity) async -> CalendarEventSummary? { nil }

    /// A stream that never yields and never finishes, which is the honest shape: nothing will change,
    /// and a finished stream would make a consumer think it should stop listening.
    public var changes: AsyncStream<Void> {
        AsyncStream { _ in }
    }
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
