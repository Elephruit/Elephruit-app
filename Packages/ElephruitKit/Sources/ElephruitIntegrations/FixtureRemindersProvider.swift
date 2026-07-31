import ElephruitCore
import Foundation

/// A Reminders store that exists entirely in memory.
///
/// ### Why this ships in the app rather than only in the tests
/// Two reasons, and the first is the important one.
///
/// **No automated test may touch the developer's real Reminders database.** A fake that lives in the
/// test target is a convention; one that lives here, behind the same protocol, and is the *only*
/// implementation the test targets can reach — because they never import EventKit — is a fact. The
/// EventKit adapter is constructed in exactly one place in the app, and nowhere in any test.
///
/// **And the whole integration can be reviewed without an Apple ID.** Launching with
/// `-ElephruitUseFixtureReminders` puts an invented, deliberately awkward store behind the feature:
/// a read-only shared list, a reminder that has been changed on "another device", one that has been
/// deleted, an all-day one and a timed one, a repeating one, and one whose priority came from
/// Apple's own scale. Every state the sync engine has to handle is reachable without risking
/// somebody's real data. The flag is ignored outside development mode.
public actor FixtureRemindersProvider: RemindersProviding {
    private var storedLists: [ReminderListSummary]
    private var storedReminders: [String: ReminderSnapshot]
    private var nextIdentifier = 1
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// What the app has been asked to change. Kept so a test can assert that a read-only pass wrote
    /// nothing at all, which is the claim that matters most here.
    public private(set) var appliedWrites: [ReminderWrite] = []

    /// The authorisation this fake reports. Settable, so the denied, restricted, and
    /// revoked-after-granting paths are all reachable.
    private var reportedAuthorization: IntegrationAuthorization

    public init(
        authorization: IntegrationAuthorization = .authorized,
        lists: [ReminderListSummary]? = nil,
        reminders: [ReminderSnapshot]? = nil
    ) {
        self.reportedAuthorization = authorization
        self.storedLists = lists ?? Self.defaultLists
        self.storedReminders = Dictionary(
            uniqueKeysWithValues: (reminders ?? Self.defaultReminders).map { ($0.id, $0) }
        )
    }

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization { reportedAuthorization }

    public func requestAccess() async -> IntegrationAuthorization {
        if reportedAuthorization == .notRequested { reportedAuthorization = .authorized }
        return reportedAuthorization
    }

    /// Simulates the user changing their mind in System Settings, which is a state the app must
    /// survive rather than a hypothetical.
    public func setAuthorization(_ authorization: IntegrationAuthorization) {
        reportedAuthorization = authorization
    }

    // MARK: - Reading

    public func lists() async -> [ReminderListSummary] {
        guard reportedAuthorization.canRead else { return [] }
        return storedLists
    }

    public func reminders(
        inLists listIDs: [String],
        includingCompleted: Bool = false
    ) async -> [ReminderSnapshot] {
        guard reportedAuthorization.canRead else { return [] }
        return storedReminders.values
            .filter { listIDs.isEmpty || listIDs.contains($0.listID) }
            .filter { includingCompleted || !$0.isCompleted }
            .sorted { $0.id < $1.id }
    }

    public func reminder(withIdentifier identifier: String) async -> ReminderSnapshot? {
        guard reportedAuthorization.canRead else { return nil }
        return storedReminders[identifier]
    }

    // MARK: - Writing

    public func apply(_ write: ReminderWrite) async -> ReminderWriteResult {
        guard reportedAuthorization.canRead else {
            return .failed("Reminders access has not been granted.")
        }
        appliedWrites.append(write)

        switch write {
        case .create(let snapshot):
            guard let list = storedLists.first(where: { $0.id == snapshot.listID }) else {
                return .missing
            }
            guard !list.isReadOnly else { return .readOnly }

            var stored = snapshot
            stored.id = "fixture-\(nextIdentifier)"
            nextIdentifier += 1
            storedReminders[stored.id] = stored
            notifyChange()
            return .saved(stored)

        case .update(let snapshot):
            guard let existing = storedReminders[snapshot.id] else { return .missing }
            guard !isReadOnly(listID: existing.listID) else { return .readOnly }

            var stored = snapshot
            // The real store keeps the identifier and the list unless asked to move it, and
            // normalises what it is given. Mirroring that is what makes the fingerprint the sync
            // engine records match what a real EventKit store would have produced.
            stored.id = existing.id
            stored.isReadOnly = existing.isReadOnly
            if !stored.isCompleted { stored.completionDate = nil }
            storedReminders[stored.id] = stored
            notifyChange()
            return .saved(stored)

        case .delete(let id):
            guard let existing = storedReminders[id] else { return .missing }
            guard !isReadOnly(listID: existing.listID) else { return .readOnly }

            storedReminders.removeValue(forKey: id)
            notifyChange()
            return .missing
        }
    }

    private func isReadOnly(listID: String) -> Bool {
        storedLists.first { $0.id == listID }?.isReadOnly ?? false
    }

    // MARK: - Simulating the world

    /// Changes a reminder the way another device would have — without going through ``apply(_:)``,
    /// so it does not count as something this app did.
    public func simulateExternalChange(
        to identifier: String,
        _ mutate: @Sendable (inout ReminderSnapshot) -> Void
    ) {
        guard var reminder = storedReminders[identifier] else { return }
        mutate(&reminder)
        storedReminders[identifier] = reminder
        notifyChange()
    }

    /// Removes a reminder the way another device would have.
    public func simulateExternalDeletion(of identifier: String) {
        storedReminders.removeValue(forKey: identifier)
        notifyChange()
    }

    public func simulateListRemoval(of listID: String) {
        storedLists.removeAll { $0.id == listID }
        for (id, reminder) in storedReminders where reminder.listID == listID {
            storedReminders.removeValue(forKey: id)
        }
        notifyChange()
    }

    // MARK: - Changes

    public nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<Void>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func notifyChange() {
        for continuation in continuations.values { continuation.yield() }
    }

    // MARK: - The invented store

    /// Two accounts and four lists, including one that refuses writes.
    ///
    /// Nothing here resembles anybody's real data: the names are generic and the account titles are
    /// the ones macOS itself uses.
    public static let defaultLists: [ReminderListSummary] = [
        ReminderListSummary(id: "list-personal", title: "Personal", accountName: "iCloud"),
        ReminderListSummary(id: "list-groceries", title: "Groceries", accountName: "iCloud"),
        ReminderListSummary(id: "list-work", title: "Work", accountName: "On My Mac"),
        ReminderListSummary(
            id: "list-shared",
            title: "House (shared)",
            accountName: "iCloud",
            isReadOnly: true
        ),
    ]

    /// A reminder of every shape the mapping has to handle.
    ///
    /// Dates are built from fixed components rather than from `Date()`, so a fixture is the same on
    /// every machine and in every time zone.
    public static let defaultReminders: [ReminderSnapshot] = [
        // All-day: day components only, which is how EventKit says "no time".
        ReminderSnapshot(
            id: "rem-milk",
            listID: "list-groceries",
            title: "Oat milk",
            dueComponents: DateComponents(year: 2026, month: 6, day: 16)
        ),
        // Timed, with a matching alarm — the case where the system owns the notification.
        ReminderSnapshot(
            id: "rem-call",
            listID: "list-personal",
            title: "Call the dentist",
            notes: "Ask about the referral",
            dueComponents: DateComponents(year: 2026, month: 6, day: 17, hour: 9, minute: 30),
            alarmDates: [FixtureRemindersProvider.fixedDate(year: 2026, month: 6, day: 17, hour: 9, minute: 30)]
        ),
        // Priority from Apple's own 0–9 scale, at a value this app maps to `.high` but does not
        // write back — the round trip keeps the level and not the number.
        ReminderSnapshot(
            id: "rem-invoice",
            listID: "list-work",
            title: "Send the invoice",
            startComponents: DateComponents(year: 2026, month: 6, day: 15),
            dueComponents: DateComponents(year: 2026, month: 6, day: 19),
            priority: 3
        ),
        // Repeating, so the "EventKit has a rule and the app may not be able to represent it" path
        // is reachable.
        ReminderSnapshot(
            id: "rem-bins",
            listID: "list-personal",
            title: "Put the bins out",
            dueComponents: DateComponents(year: 2026, month: 6, day: 18),
            hasRecurrence: true
        ),
        // Already completed, so the log and the "do not resurrect" path are reachable.
        ReminderSnapshot(
            id: "rem-post",
            listID: "list-personal",
            title: "Post the parcel",
            isCompleted: true,
            completionDate: FixtureRemindersProvider.fixedDate(year: 2026, month: 6, day: 14, hour: 11)
        ),
        // On the read-only list.
        ReminderSnapshot(
            id: "rem-boiler",
            listID: "list-shared",
            title: "Boiler service",
            dueComponents: DateComponents(year: 2026, month: 7, day: 1),
            isReadOnly: true
        ),
    ]

    private static func fixedDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        // A literal fallback keeps this non-optional without a force unwrap; it is only reached if a
        // future edit makes the components invalid.
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 1_781_514_000)
    }
}
