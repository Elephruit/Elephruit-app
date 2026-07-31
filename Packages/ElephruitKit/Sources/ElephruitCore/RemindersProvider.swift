import Foundation

// MARK: - Reading and writing the system store
//
// The protocol below lives in this module, beside the value types it speaks in, rather than in
// `ElephruitIntegrations` where `CalendarProviding` and `ContactsProviding` sit. The reason is the
// dependency graph: the reconciliation engine that consumes it is a persistence-layer type — it
// reads and writes stored tasks — and `ElephruitCore` is the only module both it and the EventKit
// adapter can see. Putting it in Integrations would mean either Persistence depending on EventKit
// or one algorithm split across two modules.
//
// The concrete adapters stay where the others are: `EventKitRemindersProvider` and
// `FixtureRemindersProvider` are both in `ElephruitIntegrations`.

/// A change the app wants made to the user's Reminders store.
///
/// ### Why writes are described rather than performed by the caller
/// This is the first integration in the app that writes anywhere. Every other one — Calendar,
/// Contacts — is read-only *by construction*, with no write method to call. That is not available
/// here: a task manager linked to Reminders that cannot tick a reminder off is not linked to
/// anything.
///
/// So the guarantee changes shape. Instead of "there is no write method", it becomes "every write is
/// a value the app can show you before it happens". A ``ReminderWrite`` can be previewed, logged, and
/// asserted about in a test, and ``RemindersProviding/apply(_:)`` is the single narrow door it goes
/// through.
public enum ReminderWrite: Sendable, Hashable {
    /// Create a reminder in a list.
    case create(ReminderSnapshot)

    /// Update the mapped fields of an existing reminder.
    case update(ReminderSnapshot)

    /// Delete a reminder. **Only** ever produced from an explicit user choice — see
    /// ``LinkedDeletionChoice``.
    case delete(id: String)

    /// The reminder this write is about, for a preview.
    public var reminderID: String? {
        switch self {
        case .create: nil
        case .update(let snapshot): snapshot.id
        case .delete(let id): id
        }
    }

    /// A sentence describing what will happen in Apple's own app.
    public var summary: String {
        switch self {
        case .create(let snapshot): "Add “\(snapshot.title)” to Reminders"
        case .update(let snapshot): "Update “\(snapshot.title)” in Reminders"
        case .delete: "Delete a reminder"
        }
    }

    /// Whether this write destroys something in the user's store.
    public var isDestructive: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// What happened to one write.
public enum ReminderWriteResult: Sendable, Hashable {
    /// Succeeded. Carries the reminder as it is *after* the write, refetched rather than assumed —
    /// which is what lets the sync engine record a fingerprint that matches what is actually there.
    case saved(ReminderSnapshot)

    /// The list refuses writes.
    case readOnly

    /// The reminder is no longer in the store.
    case missing

    /// The store refused, with its own message.
    case failed(String)
}

/// Reading and writing the user's Reminders.
///
/// ### Why this is a protocol with a fake
/// Every automated test in this repository must be incapable of touching the developer's real
/// Reminders database. A protocol with a deterministic fake is what makes that true by construction
/// rather than by convention: `FixtureRemindersProvider` has no `EKEventStore` in it, and the test
/// targets never construct the EventKit one.
public protocol RemindersProviding: Sendable, AnyObject {
    /// The current authorisation, read without prompting.
    var authorization: IntegrationAuthorization { get async }

    /// Prompts, if and only if the user has never been asked.
    ///
    /// EventKit offers only `requestFullAccessToReminders()` for this entity type — there is no
    /// read-only tier — so this asks for full access. Unlike the calendar, the app genuinely uses
    /// the write half, and only ever from an explicit action.
    func requestAccess() async -> IntegrationAuthorization

    /// The user's reminder lists, with the account each belongs to and whether it accepts writes.
    func lists() async -> [ReminderListSummary]

    /// Reminders in the named lists. Passing none means every list.
    ///
    /// - Parameter includingCompleted: Completed reminders are excluded by default; a store with
    ///   years of ticked shopping items in it is otherwise most of what comes back.
    func reminders(inLists listIDs: [String], includingCompleted: Bool) async -> [ReminderSnapshot]

    /// One reminder. `nil` means it is no longer in the store — which is a state, not an error.
    func reminder(withIdentifier identifier: String) async -> ReminderSnapshot?

    /// Performs one write.
    ///
    /// The only method on this protocol that changes anything, so "what can this app do to somebody's
    /// Reminders?" has a one-line answer.
    func apply(_ write: ReminderWrite) async -> ReminderWriteResult

    /// Fires when the Reminders database changes.
    var changes: AsyncStream<Void> { get }
}

/// The default, and what the app holds until the user turns the integration on.
///
/// Reports ``IntegrationAuthorization/notRequested`` and does nothing, so every path through the
/// interface runs against a real implementation from the first launch rather than a `nil` branch
/// that only executes for people who granted permission.
public final class NoRemindersProvider: RemindersProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Reminders access requested but no provider is configured")
        return .unavailable
    }

    public func lists() async -> [ReminderListSummary] { [] }

    public func reminders(inLists listIDs: [String], includingCompleted: Bool) async -> [ReminderSnapshot] { [] }

    public func reminder(withIdentifier identifier: String) async -> ReminderSnapshot? { nil }

    /// Refuses rather than pretending to succeed. A caller that believed a write landed would record
    /// a link to a reminder that does not exist.
    public func apply(_ write: ReminderWrite) async -> ReminderWriteResult {
        Diagnostics.integrations.debug("Reminder write attempted with no provider configured")
        return .failed("Reminders is not connected.")
    }

    /// A stream that never yields and never finishes — the honest shape when nothing will change.
    public var changes: AsyncStream<Void> { AsyncStream { _ in } }
}
