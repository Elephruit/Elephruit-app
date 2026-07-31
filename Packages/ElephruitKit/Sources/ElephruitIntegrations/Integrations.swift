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

// `ContactLabelledValue` and `ContactAccount` moved to `ElephruitCore` when `SystemContact` came to
// need them. They are pure value types with no framework dependency, and Core is where the domain
// vocabulary lives; leaving them here would have made Core depend on Integrations, which is the wrong
// way round the dependency graph.

/// A contact, as the app understands it. Contacts remains authoritative for what it holds; this is a
/// read-only projection used to offer links.
public struct ContactSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var givenName: String
    public var familyName: String
    public var nickname: String?
    public var organizationName: String?
    public var jobTitle: String?
    public var emailAddresses: [ContactLabelledValue]
    public var phoneNumbers: [ContactLabelledValue]
    public var postalAddresses: [ContactLabelledValue]
    public var urlAddresses: [ContactLabelledValue]

    /// Day and month, and the year only when Contacts actually holds one.
    public var birthdayMonth: Int?
    public var birthdayDay: Int?
    public var birthdayYear: Int?

    /// Which account holds this record.
    public var accountName: String?

    /// Whether the app may write back to it. Reported, never assumed.
    public var isReadOnly: Bool

    public init(
        id: String,
        givenName: String,
        familyName: String,
        nickname: String? = nil,
        organizationName: String? = nil,
        jobTitle: String? = nil,
        emailAddresses: [ContactLabelledValue] = [],
        phoneNumbers: [ContactLabelledValue] = [],
        postalAddresses: [ContactLabelledValue] = [],
        urlAddresses: [ContactLabelledValue] = [],
        birthdayMonth: Int? = nil,
        birthdayDay: Int? = nil,
        birthdayYear: Int? = nil,
        accountName: String? = nil,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organizationName = organizationName
        self.jobTitle = jobTitle
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.birthdayMonth = birthdayMonth
        self.birthdayDay = birthdayDay
        self.birthdayYear = birthdayYear
        self.accountName = accountName
        self.isReadOnly = isReadOnly
    }

    public var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Reading the system Contacts store.
///
/// ### Read-only by construction, on the same terms as the calendar
/// There is **no write method here**, and no way to reach a `CNContactStore` through it. Creating or
/// updating a system contact from Elephruit is a compile error rather than a rule somebody could
/// forget — and the requirement that system contacts change "only with explicit user intent" is
/// satisfied by the strongest available means, which is not offering the capability at all.
///
/// A user who wants Elephruit's richer profile in their address book exports a vCard, which is an
/// act they perform in a save panel. See `docs/19-permissions-matrix.md`.
public protocol ContactsProviding: Sendable {
    var authorization: IntegrationAuthorization { get async }
    func requestAccess() async -> IntegrationAuthorization

    /// The accounts the system has configured.
    func accounts() async -> [ContactAccount]

    /// Contacts matching a name fragment. Empty when access has not been granted, which is a
    /// legitimate state with nothing in it rather than an error.
    func contacts(matching query: String) async -> [ContactSummary]

    /// One contact, for refreshing a stored link. `nil` means the record is gone.
    func contact(withIdentifier identifier: String) async -> ContactSummary?

    // MARK: Import

    /// Every contact available, as **unified** records.
    ///
    /// Unified is the whole point: macOS already knows that the iCloud Maya and the Google Maya are
    /// one person, and asking for the unified view means the CRM inherits that rather than
    /// re-deriving it and disagreeing. Passing container identifiers narrows the scan; passing none
    /// takes everything.
    ///
    /// Streamed in batches through `onBatch` rather than returned whole, so a library of several
    /// thousand never exists twice in memory and the interface can show progress. Returns the total
    /// seen.
    func enumerateContacts(
        inContainers containerIdentifiers: [String],
        onBatch: @Sendable ([SystemContact]) async -> Void
    ) async -> Int

    /// One unified contact, in full. `nil` means the record no longer resolves.
    func systemContact(withIdentifier identifier: String) async -> SystemContact?

    /// The contact whose signature matches, for re-finding a record whose identifier changed.
    ///
    /// Deliberately narrow: it matches on email and phone, never on name alone.
    func systemContact(matching signature: ContactIdentitySignature) async -> SystemContact?

    /// A thumbnail for one contact, fetched only when a person is actually on screen.
    ///
    /// Separate from the snapshot because image data is by far the largest thing Contacts holds, and
    /// fetching it for a whole library to draw a list is how an import becomes a beachball.
    func thumbnail(forIdentifier identifier: String) async -> Data?

    // MARK: Change tracking

    /// An opaque token marking the current state of the store, for incremental refreshes later.
    ///
    /// `nil` when the platform cannot supply one, which is a supported state: the sync layer falls
    /// back to full reconciliation rather than failing.
    func currentHistoryToken() async -> Data?

    /// What changed since `token`.
    ///
    /// Returns `nil` when the token is missing, expired, or unreadable — the caller's cue to
    /// reconcile fully. That is a normal outcome after a long gap, not an error.
    func changes(since token: Data) async -> ContactChangeSet?

    /// Fires when the Contacts database changes.
    ///
    /// An `AsyncStream` rather than a notification name, so a consumer neither imports Contacts nor
    /// has to remember to remove an observer — the same arrangement `CalendarProviding` uses.
    var changes: AsyncStream<Void> { get }

    // MARK: Writing

    /// Writes an edit back into the system address book.
    ///
    /// ### The one write in the app, and what it is fenced with
    /// This is the only method on any provider that changes a system contact, and it exists because
    /// the alternative was worse: a linked person's details could not be corrected anywhere, since
    /// editing them locally meant the next refresh discarding the correction without saying so. The
    /// requirement that system contacts change "only with explicit user intent" is now met by intent
    /// rather than by incapacity, and the fences are:
    ///
    /// - Only emails, numbers, sites, the job title, and the organisation are writable. Names,
    ///   birthdays, relations, photographs, and every other field are not expressible in a
    ///   ``ContactWrite`` and so cannot be touched.
    /// - **Postal addresses are not writable, on purpose.** Contacts stores them structured — street,
    ///   city, postcode, country — and this app reads them through `CNPostalAddressFormatter` into a
    ///   single display line. That projection does not invert: parsing "12 Rosewood Lane, Austin"
    ///   back into fields is guesswork, and guessing wrong writes a mangled address into somebody's
    ///   address book. They stay editable on the Elephruit record, where the single line is the whole
    ///   truth, and the sheet says so rather than quietly dropping the change.
    /// - The caller must already hold a confirmation from the user — see `ContactWriteBackSheet`,
    ///   which shows the before and after of every changed line and is the only caller.
    /// - A read-only account refuses rather than failing silently, because "saved" about a change the
    ///   address book discarded is the one outcome worse than an error.
    ///
    /// Returns what happened, rather than throwing: every outcome here is something the user needs
    /// telling about in ordinary words, and none of them is exceptional.
    func write(_ change: ContactWrite) async -> ContactWriteOutcome
}

/// An edit destined for a system contact.
///
/// Deliberately not a `SystemContact`: a write must be unable to express a change to a field this
/// app has no business setting, and the way to guarantee that is for the type not to have one. What
/// is absent here is as much the design as what is present.
public struct ContactWrite: Sendable, Hashable {
    /// The record to change. A write never creates a contact.
    public var identifier: String

    public var jobTitle: String
    public var organizationName: String

    public var emailAddresses: [ContactLabelledValue]
    public var phoneNumbers: [ContactLabelledValue]
    public var urlAddresses: [ContactLabelledValue]

    public init(
        identifier: String,
        jobTitle: String = "",
        organizationName: String = "",
        emailAddresses: [ContactLabelledValue] = [],
        phoneNumbers: [ContactLabelledValue] = [],
        urlAddresses: [ContactLabelledValue] = []
    ) {
        self.identifier = identifier
        self.jobTitle = jobTitle
        self.organizationName = organizationName
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
        self.urlAddresses = urlAddresses
    }
}

/// What became of a write.
public enum ContactWriteOutcome: Sendable, Hashable {
    case written

    /// Contacts access has not been granted. Nothing was attempted.
    case notPermitted

    /// The record no longer resolves — deleted, or merged away since it was linked.
    case recordMissing

    /// The account holding the contact does not accept changes, such as a subscribed directory.
    case accountIsReadOnly

    /// Contacts refused the save, with whatever it said about why.
    case failed(String)

    /// What to tell the user. Written as a sentence because every one of these reaches a person.
    public var explanation: String? {
        switch self {
        case .written: nil
        case .notPermitted: "Elephruit does not have access to your contacts."
        case .recordMissing: "That contact is no longer in your address book. The link has been cleared."
        case .accountIsReadOnly: "That contact lives in an account that does not accept changes."
        case .failed(let reason): "Your address book refused the change: \(reason)"
        }
    }
}

/// What changed in the Contacts store since a token was taken.
public struct ContactChangeSet: Sendable, Hashable {
    /// Identifiers of contacts added or updated.
    public var changedIdentifiers: Set<String>

    /// Identifiers of contacts deleted.
    public var deletedIdentifiers: Set<String>

    /// The token to store for next time.
    public var newToken: Data?

    public init(
        changedIdentifiers: Set<String> = [],
        deletedIdentifiers: Set<String> = [],
        newToken: Data? = nil
    ) {
        self.changedIdentifiers = changedIdentifiers
        self.deletedIdentifiers = deletedIdentifiers
        self.newToken = newToken
    }

    public var isEmpty: Bool {
        changedIdentifiers.isEmpty && deletedIdentifiers.isEmpty
    }
}

/// The default, and what the app uses until the user turns Contacts on.
///
/// Reports ``IntegrationAuthorization/notRequested`` and returns nothing, so every path through the
/// interface runs against a real implementation from the first launch rather than a `nil` branch
/// that only executes for users who grant permission.
public struct NoContactsProvider: ContactsProviding {
    public init() {}

    public var authorization: IntegrationAuthorization { .notRequested }

    public func requestAccess() async -> IntegrationAuthorization {
        Diagnostics.integrations.debug("Contacts access requested but no provider is configured")
        return .unavailable
    }

    public func accounts() async -> [ContactAccount] { [] }
    public func contacts(matching query: String) async -> [ContactSummary] { [] }
    public func contact(withIdentifier identifier: String) async -> ContactSummary? { nil }

    public func enumerateContacts(
        inContainers containerIdentifiers: [String],
        onBatch: @Sendable ([SystemContact]) async -> Void
    ) async -> Int { 0 }

    public func systemContact(withIdentifier identifier: String) async -> SystemContact? { nil }
    public func systemContact(matching signature: ContactIdentitySignature) async -> SystemContact? { nil }
    public func thumbnail(forIdentifier identifier: String) async -> Data? { nil }
    public func currentHistoryToken() async -> Data? { nil }
    public func changes(since token: Data) async -> ContactChangeSet? { nil }

    /// A stream that never yields and never finishes — the honest shape when nothing will change.
    public var changes: AsyncStream<Void> { AsyncStream { _ in } }

    /// Nothing is configured, so nothing was written. Reported as the refusal it is rather than as a
    /// success, because a caller told "written" would stop showing the user their unsaved change.
    public func write(_ change: ContactWrite) async -> ContactWriteOutcome { .notPermitted }
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
