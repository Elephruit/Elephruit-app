import ElephruitCore
import EventKit
import Foundation

/// Reads and writes the user's Reminders through EventKit.
///
/// ### Every API here was checked against the macOS SDK headers, not recalled
/// - `requestFullAccessToReminders()` — `API_AVAILABLE(macos(14.0))`. There is **no** write-only or
///   read-only request for reminders; `requestWriteOnlyAccessToEvents()` is events-only. Full access
///   is the only tier, and the user has no way to grant less.
/// - `EKAuthorizationStatus.fullAccess` — `NS_ENUM_AVAILABLE(14_0)`.
/// - `fetchReminders(matching:completion:)` — callback-based, and still the only way to fetch
///   reminders; there is no synchronous equivalent and no async overload. It is bridged here rather
///   than at every call site.
/// - `EKCalendar.allowsContentModifications` — what says a list refuses writes. Reported by the
///   store, never assumed: a subscribed or shared list can refuse, and finding out by having a save
///   fail is finding out too late.
/// - `EKReminder.startDateComponents` / `dueDateComponents` — `DateComponents`, deliberately. The
///   presence of an hour component is the only thing that distinguishes an all-day reminder from a
///   timed one, which is why `ReminderSnapshot` carries components rather than dates.
/// - `EKEventStoreChanged` — since macOS 10.8.
///
/// ### Why an actor
/// `EKEventStore` is not `Sendable`, and the two usual escapes — `@unchecked Sendable` or a
/// `@preconcurrency` import — are banned by this project's source rules because they are how data
/// races reach a release. An actor needs neither: the store is isolated to it, and every `EKReminder`
/// is projected into a value *inside* the actor before anything crosses back.
///
/// ### On writing at all
/// This is the first adapter in the app that writes. The guarantee is not "it cannot" but "it does so
/// only through ``apply(_:)``, only with a ``ReminderWrite`` the caller could have shown the user
/// first, and never as a side effect of reading". `RemindersWriteSafetyTests` asserts the second half
/// by checking that no other method in this file names a mutating EventKit call.
public actor EventKitRemindersProvider: RemindersProviding {
    /// Owned privately and never handed out.
    private let store = EKEventStore()

    public init() {}

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization {
        Self.authorization(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    static func authorization(for status: EKAuthorizationStatus) -> IntegrationAuthorization {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly:
            // Not reachable for reminders — EventKit does not offer the tier — but representable.
            // Mapping it to denied is the honest reading: the app cannot see anything.
            .denied
        @unknown default:
            .denied
        }
    }

    public func requestAccess() async -> IntegrationAuthorization {
        let current = EKEventStore.authorizationStatus(for: .reminder)
        guard current == .notDetermined else {
            // macOS records the decision permanently; asking again shows nothing.
            return Self.authorization(for: current)
        }

        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            Diagnostics.integrations.error(
                "Reminders access request failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        return Self.authorization(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    // MARK: - Reading

    public func lists() -> [ReminderListSummary] {
        guard authorization.canRead else { return [] }
        return store.calendars(for: .reminder).map(Self.summary).sorted {
            $0.accountName == $1.accountName
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.accountName < $1.accountName
        }
    }

    public func reminders(
        inLists listIDs: [String],
        includingCompleted: Bool = false
    ) async -> [ReminderSnapshot] {
        guard authorization.canRead else { return [] }

        let calendars = store.calendars(for: .reminder)
            .filter { listIDs.isEmpty || listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = includingCompleted
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )

        return await fetch(matching: predicate)
    }

    public func reminder(withIdentifier identifier: String) -> ReminderSnapshot? {
        guard authorization.canRead else { return nil }
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return nil
        }
        return Self.snapshot(reminder)
    }

    /// Bridges the callback-based fetch, which has no async form in the SDK.
    ///
    /// Projected to values inside the actor, so no `EKReminder` crosses an isolation boundary.
    /// `fetchReminders` is documented as calling back on an arbitrary queue, which is precisely why
    /// the projection happens in the completion handler rather than after it.
    private func fetch(matching predicate: NSPredicate) async -> [ReminderSnapshot] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let projected = (reminders ?? []).map(Self.snapshot)
                continuation.resume(returning: projected)
            }
        }
    }

    // MARK: - Writing

    /// The one door. Nothing else in this type calls `save`, `remove`, or `commit`.
    public func apply(_ write: ReminderWrite) -> ReminderWriteResult {
        guard authorization.canRead else { return .failed("Reminders access has not been granted.") }

        switch write {
        case .create(let snapshot):
            guard let calendar = store.calendar(withIdentifier: snapshot.listID) else {
                return .missing
            }
            guard calendar.allowsContentModifications else { return .readOnly }

            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            Self.apply(snapshot, to: reminder)
            return save(reminder)

        case .update(let snapshot):
            guard let reminder = store.calendarItem(withIdentifier: snapshot.id) as? EKReminder else {
                return .missing
            }
            guard reminder.calendar?.allowsContentModifications == true else { return .readOnly }

            Self.apply(snapshot, to: reminder)
            return save(reminder)

        case .delete(let id):
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                // Already gone. Reporting it as missing rather than as a failure: the outcome the
                // caller wanted has been achieved by somebody else.
                return .missing
            }
            guard reminder.calendar?.allowsContentModifications == true else { return .readOnly }

            do {
                try store.remove(reminder, commit: true)
                return .missing
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ reminder: EKReminder) -> ReminderWriteResult {
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failed(error.localizedDescription)
        }

        // Refetched rather than assumed. The store normalises what it was given — components are
        // completed, a completion date is stamped — and recording a fingerprint of what was *sent*
        // rather than what was *stored* makes the very next sync pass see a change and push again.
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
        else {
            return .saved(Self.snapshot(reminder))
        }
        return .saved(Self.snapshot(saved))
    }

    // MARK: - Changes

    /// `nonisolated`, and observing any store, for the reason given on `EventKitCalendarProvider`:
    /// an observer token is not `Sendable`, and there is only one event store in this process.
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

    static func summary(_ calendar: EKCalendar) -> ReminderListSummary {
        ReminderListSummary(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            accountName: calendar.source?.title ?? "",
            isReadOnly: !calendar.allowsContentModifications,
            colorName: nil
        )
    }

    /// Turns an `EKReminder` into a value. The only place EventKit types cross into the app.
    static func snapshot(_ reminder: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            notes: reminder.notes,
            startComponents: reminder.startDateComponents,
            dueComponents: reminder.dueDateComponents,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: reminder.priority,
            alarmDates: (reminder.alarms ?? []).compactMap(\.absoluteDate),
            hasRecurrence: !(reminder.recurrenceRules ?? []).isEmpty,
            lastModified: reminder.lastModifiedDate,
            isReadOnly: !(reminder.calendar?.allowsContentModifications ?? true)
        )
    }

    /// Writes the mapped fields onto a reminder, and only those.
    ///
    /// ### What is deliberately not written
    /// The list is in ``ReminderFieldMapping/appOnlyFields``, and the reason it is enforced here is
    /// that the alternative has a name: apps that smuggle their own metadata into a reminder's notes
    /// or title so a round trip preserves it. That text appears in Apple's own app on every device
    /// the user owns, and in a shared list it appears to everybody it is shared with. A personal
    /// CRM's metadata is exactly the wrong thing to put there.
    ///
    /// Recurrence is likewise left alone rather than approximated. EventKit's rules are always
    /// anchored to the schedule, so an after-completion repeat written out as a calendar rule would
    /// become a different task that quietly drifts from what the user asked for.
    static func apply(_ snapshot: ReminderSnapshot, to reminder: EKReminder) {
        reminder.title = snapshot.title
        reminder.notes = snapshot.notes
        reminder.startDateComponents = snapshot.startComponents
        reminder.dueDateComponents = snapshot.dueComponents
        reminder.priority = snapshot.priority

        // Completion before the date: EventKit clears `completionDate` when `isCompleted` goes
        // false, and setting them the other way round loses the date.
        reminder.isCompleted = snapshot.isCompleted
        if snapshot.isCompleted { reminder.completionDate = snapshot.completionDate }

        applyAlarms(snapshot.alarmDates, to: reminder)
    }

    /// Replaces the absolute alarms, leaving relative and location alarms untouched.
    ///
    /// The app models one reminder time, and EventKit reminders can carry several alarms of three
    /// kinds. Clearing all of them to write one would delete a location alarm the user set in Apple's
    /// app — a feature this app cannot even create — so only the absolute ones are replaced.
    static func applyAlarms(_ dates: [Date], to reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil {
            reminder.removeAlarm(alarm)
        }
        for date in dates {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
    }
}
