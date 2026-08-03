import CryptoKit
import Foundation

/// One of the user's Reminders lists, as this app needs to see it.
///
/// A value type rather than an `EKCalendar`, so every rule about lists — which participate, which
/// refuse writes, which have gone away — is testable without EventKit and without the user's data.
public struct ReminderListSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String

    /// The account the list belongs to — "iCloud", "On My Mac", an Exchange account.
    ///
    /// Shown because two lists called "Shopping" in different accounts are two different lists, and
    /// picking the wrong one is the kind of mistake that only becomes visible on another device.
    public var accountName: String

    /// Reported by the system, never assumed. A subscribed or shared list can refuse writes, and
    /// finding that out by having a save fail is finding out too late.
    public var isReadOnly: Bool

    /// The list's own colour, so the app can echo the user's own organisation rather than
    /// renaming it.
    public var colorName: String?

    public init(
        id: String,
        title: String,
        accountName: String = "",
        isReadOnly: Bool = false,
        colorName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.accountName = accountName
        self.isReadOnly = isReadOnly
        self.colorName = colorName
    }
}

/// One reminder, as read from or written to the system store.
///
/// Deliberately narrow. It carries exactly the fields EventKit exposes and this app maps, and
/// nothing else — see ``ReminderFieldMapping/appOnlyFields`` for the list of things that stay here
/// and why encoding them into a title or a notes field would be vandalism.
public struct ReminderSnapshot: Sendable, Hashable, Identifiable {
    /// EventKit's `calendarItemIdentifier`.
    public var id: String

    /// The list this reminder lives in.
    public var listID: String

    public var title: String
    public var notes: String?

    /// EventKit models these as `DateComponents`, and the distinction between a date with a time and
    /// one without is carried by *which components are present*. Kept as components rather than
    /// flattened to a `Date` so an all-day reminder does not silently acquire midnight as its time.
    public var startComponents: DateComponents?
    public var dueComponents: DateComponents?

    public var isCompleted: Bool
    public var completionDate: Date?

    /// EventKit's 0–9 scale, where 0 means unset. Mapped rather than mirrored — see
    /// ``ReminderFieldMapping``.
    public var priority: Int

    /// Absolute alarm dates. EventKit also supports relative and location alarms; those are read and
    /// preserved on the record rather than being mapped onto a task's single reminder time.
    public var alarmDates: [Date]

    /// Whether the reminder carries a recurrence rule at all.
    ///
    /// The rule itself is mapped separately, and only when it is one this app can represent —
    /// see ``ReminderFieldMapping/recurrence(from:)``.
    public var hasRecurrence: Bool

    /// EventKit's last-modified stamp, when it has one.
    public var lastModified: Date?

    public var isReadOnly: Bool

    public init(
        id: String,
        listID: String,
        title: String = "",
        notes: String? = nil,
        startComponents: DateComponents? = nil,
        dueComponents: DateComponents? = nil,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        priority: Int = 0,
        alarmDates: [Date] = [],
        hasRecurrence: Bool = false,
        lastModified: Date? = nil,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.listID = listID
        self.title = title
        self.notes = notes
        self.startComponents = startComponents
        self.dueComponents = dueComponents
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
        self.alarmDates = alarmDates
        self.hasRecurrence = hasRecurrence
        self.lastModified = lastModified
        self.isReadOnly = isReadOnly
    }
}

extension ReminderSnapshot {
    /// A fingerprint of every field this app maps.
    ///
    /// ### Why a fingerprint rather than a timestamp
    /// EventKit's `lastModified` is not reliable for this: it moves for changes the app does not map,
    /// it does not always move for ones it does, and on a store synchronised through iCloud it can
    /// arrive later than the change itself. Comparing a hash of exactly the mapped fields answers the
    /// only question that matters — *has anything I care about changed since I last looked* — and
    /// gives the same answer on every machine.
    /// ### Why this is not `Hasher`
    /// It was, and the value is **persisted** — `ReminderLinkState.lastSyncedFingerprint` is stored
    /// on the task and compared against a freshly computed one on the next pass, possibly weeks and
    /// several launches later.
    ///
    /// Swift seeds `Hasher` randomly per process. The same reminder therefore fingerprinted
    /// differently on every launch, so after every restart *every* linked task looked as though it
    /// had been changed in Reminders. Paired with a local edit that is what produces a conflict, and
    /// on its own it silently re-adopts the remote over local state. The comment that used to sit
    /// here claimed the hash "gives the same answer on every machine", which is the one thing
    /// `Hasher` guarantees it does not.
    ///
    /// SHA-256 over a canonical string gives the same answer in every process, on every machine, and
    /// after every upgrade. CryptoKit is a system framework, so this adds no dependency.
    ///
    /// The `v2:` prefix marks a fingerprint as one of these. Anything without it was written by the
    /// old scheme and cannot be compared against anything — see `ReminderReconciliation.decide`,
    /// which treats those as a baseline to be re-established rather than as evidence of a change.
    public var fingerprint: String {
        let alarms: String = alarmDates
            .map(\.timeIntervalSinceReferenceDate)
            .sorted()
            .map { String($0) }
            .joined(separator: ",")

        let canonical: String = [
            title,
            notes ?? "",
            startComponents?.description ?? "",
            dueComponents?.description ?? "",
            String(isCompleted),
            String(completionDate?.timeIntervalSinceReferenceDate ?? -1),
            String(priority),
            alarms,
            String(hasRecurrence),
            listID,
        ].joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return Self.fingerprintPrefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Marks a fingerprint as one this build knows how to compare.
    public static let fingerprintPrefix = "v2:"

    /// Whether a stored fingerprint can be compared against a freshly computed one.
    ///
    /// A value written by the pre-`v2` scheme cannot: it was a randomly seeded hash and means
    /// nothing outside the process that produced it.
    public static func isComparable(_ storedFingerprint: String) -> Bool {
        storedFingerprint.hasPrefix(fingerprintPrefix)
    }
}

/// What the app has recorded about a link to one system reminder.
public struct ReminderLinkState: Sendable, Hashable {
    public var externalID: String
    public var listID: String

    /// The fingerprint at the last successful reconciliation.
    public var lastSyncedFingerprint: String

    /// When that reconciliation happened.
    public var lastSyncedAt: Date

    /// The task's `updatedAt` at that moment, so a later local edit is detectable.
    public var lastSyncedLocalStamp: Date

    public init(
        externalID: String,
        listID: String,
        lastSyncedFingerprint: String,
        lastSyncedAt: Date,
        lastSyncedLocalStamp: Date
    ) {
        self.externalID = externalID
        self.listID = listID
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncedLocalStamp = lastSyncedLocalStamp
    }
}

// MARK: - Field mapping

/// Which fields cross the boundary to Apple Reminders, and which never do.
///
/// ### The rule the whole integration hangs on
/// Anything EventKit models, this app maps. Anything it does not, this app **keeps** — locally,
/// unencoded, and unmentioned in the reminder. There is a well-trodden alternative where an app
/// smuggles its own metadata into a reminder's notes or title so that round-tripping preserves it,
/// and it is unacceptable here for two reasons: the user sees that text in Apple's own app on every
/// device, and a personal CRM's metadata is exactly the kind of thing that must not be written into
/// a record synchronised through somebody's iCloud account and shared with whoever the list is
/// shared with.
///
/// So the trade is stated rather than hidden: link a task and the shared half stays in step; the
/// private half stays here and is shown as such.
public enum ReminderFieldMapping {
    /// Fields with a faithful equivalent on both sides.
    public static let mappedFields: [String] = [
        "Title",
        "Notes",
        "Start date",
        "Deadline",
        "Reminder alarm",
        "Completion and completion date",
        "Priority",
        "Repeat",
        "List",
    ]

    /// Fields that stay in this app, with the reason each one cannot cross.
    ///
    /// Surfaced in the interface verbatim, because the honest version of "some things will not
    /// sync" is a list the user can read before deciding.
    public static let appOnlyFields: [(field: String, reason: String)] = [
        ("Areas", "Reminders has no layer above a list."),
        ("Projects", "A project is not a list: it finishes, and it has an outcome."),
        ("Sections", "Reminders has no headings inside a list that EventKit exposes."),
        ("Today and Later Today", "A commitment to today is this app's idea, not the system's."),
        ("Today's manual order", "EventKit exposes no ordering this app can write."),
        ("Someday", "Apple Reminders has no parked state; a parked reminder would read as merely undated."),
        ("Waiting for", "There is no field for who you are waiting on."),
        ("Linked people, notes, and meetings", "Private relationship data, which must not travel in a shared list."),
        ("Provenance", "Where a reminder came from is a fact about this library."),
        ("Attachments", "EventKit does not expose reminder attachments to third-party apps."),
        ("Smart-list rules", "Rules are evaluated here, over fields the system does not have."),
        ("Work history", "Completion history beyond the single completion date has nowhere to go."),
    ]

    /// EventKit's priority scale, mapped to the app's three levels.
    ///
    /// EventKit uses RFC 5545's 0–9, where 0 is unspecified, 1–4 is high, 5 is medium and 6–9 is
    /// low. Three levels map onto that cleanly in one direction and lossily in the other, which is
    /// why the round trip is asserted rather than assumed: a reminder set to priority 3 in Apple's
    /// app comes back as `.high`, and writing `.high` back writes 1, not 3. The *level* survives;
    /// the exact number does not, and no user-visible meaning is lost.
    public static func priority(fromEventKit value: Int) -> Priority? {
        switch value {
        case 1...4: .high
        case 5: .normal
        case 6...9: .low
        default: nil  // 0 — unspecified. Not the same as "normal".
        }
    }

    public static func eventKitPriority(from priority: Priority?) -> Int {
        switch priority {
        case .high: 1
        case .normal: 5
        case .low: 9
        case nil: 0
        }
    }

    /// Turns EventKit's date components into a date and a flag saying whether a time was given.
    ///
    /// The presence of an hour component is the *only* signal EventKit gives, and it is a real one:
    /// a reminder set for "today" has year, month and day; one set for "today at 9" has an hour too.
    public static func date(
        from components: DateComponents?,
        calendar: Calendar
    ) -> (date: Date, hasTime: Bool)? {
        guard let components, let date = calendar.date(from: components) else { return nil }
        return (date, components.hour != nil)
    }

    /// The components to write for a date, honouring whether it names a time.
    public static func components(
        from date: Date,
        hasTime: Bool,
        calendar: Calendar
    ) -> DateComponents {
        let fields: Set<Calendar.Component> = hasTime
            ? [.year, .month, .day, .hour, .minute]
            : [.year, .month, .day]
        return calendar.dateComponents(fields, from: date)
    }

    /// Whether a recurrence rule is one EventKit can hold without distortion.
    ///
    /// ``RecurrenceRule/Anchor/completion`` is the case that cannot cross: EventKit's recurrence is
    /// always anchored to the schedule, so "every 3 days after I last did it" written out as a
    /// calendar rule would become "every 3 days from a fixed date" — a different task that quietly
    /// drifts from what the user asked for. Rather than writing something wrong, the rule stays here
    /// and the interface says the repeat is local.
    public static func isRepresentableInEventKit(_ rule: RecurrenceRule) -> Bool {
        rule.anchor == .schedule
    }
}

// MARK: - Reconciliation

/// What to do about one linked task after looking at both sides.
public enum ReminderMergeDecision: Sendable, Hashable {
    /// Neither side moved.
    case unchanged

    /// Only the reminder changed. Take its values, keeping every app-only field.
    case adoptRemote

    /// Only the task changed. Write the mapped fields out.
    case pushLocal

    /// Both changed. Surfaced for the user to resolve; nothing is overwritten.
    case conflict

    /// The reminder is gone from the system store.
    ///
    /// **Never** a deletion. The task keeps its notes, its links, and its history, and the user is
    /// offered the choice — because a reminder deleted on a phone is not consent to delete the
    /// project context somebody built around it here.
    case remoteMissing

    /// The list refuses writes, so local changes cannot be sent.
    case remoteReadOnly

    /// The stored fingerprint predates the comparable scheme, so the two sides cannot be compared.
    ///
    /// Record today's fingerprint and change nothing else. Not `unchanged`, because that would also
    /// re-stamp the local side and swallow an edit the user is waiting to push; not `adoptRemote` or
    /// `conflict`, because neither is a claim the evidence supports — a pre-`v2` fingerprint was a
    /// randomly seeded hash and never meant anything outside the process that wrote it.
    ///
    /// Nothing is lost by this. A remote change made before the upgrade was already invisible, and
    /// every change after it is caught normally from the next pass onwards.
    case establishBaseline
}

/// Decides what a sync pass should do, without doing any of it.
///
/// Pure and total: every combination of "did the remote move", "did the local move", "does the
/// remote still exist" and "can it be written" has an answer here, and each has a test. The engine
/// that performs the decision holds no policy at all.
public enum ReminderReconciliation {
    /// - Parameters:
    ///   - link: What was recorded at the last successful pass.
    ///   - remote: The reminder as it is now, or `nil` if it is no longer in the store.
    ///   - localUpdatedAt: The task's current modification stamp.
    public static func decide(
        link: ReminderLinkState,
        remote: ReminderSnapshot?,
        localUpdatedAt: Date
    ) -> ReminderMergeDecision {
        guard let remote else { return .remoteMissing }

        // A fingerprint from the old scheme cannot be compared against a new one. Saying so is the
        // only honest answer; guessing produces either a false conflict on every linked task after
        // the upgrade, or a silent re-adopt over local state.
        guard ReminderSnapshot.isComparable(link.lastSyncedFingerprint) else { return .establishBaseline }

        let remoteMoved = remote.fingerprint != link.lastSyncedFingerprint
        // Strictly greater: a task written *by* the last sync has exactly that stamp and must not be
        // read as a local edit, which would make every pass push and every pass therefore conflict.
        let localMoved = localUpdatedAt > link.lastSyncedLocalStamp

        switch (remoteMoved, localMoved) {
        case (false, false):
            return .unchanged
        case (true, false):
            return .adoptRemote
        case (false, true):
            return remote.isReadOnly ? .remoteReadOnly : .pushLocal
        case (true, true):
            return .conflict
        }
    }

    /// The sync state a decision leaves the task in.
    public static func state(after decision: ReminderMergeDecision) -> TaskSyncState {
        switch decision {
        case .unchanged, .adoptRemote, .pushLocal, .establishBaseline: .linked
        case .conflict: .conflicted
        case .remoteMissing: .externalMissing
        case .remoteReadOnly: .externalReadOnly
        }
    }

    /// Whether a decision requires writing to the user's store.
    ///
    /// The one place this is decided, so a pass that merely *reads* can be asserted to write
    /// nothing — which is what makes "external reminders are never changed without user intent"
    /// checkable rather than promised.
    public static func writesToSystemStore(_ decision: ReminderMergeDecision) -> Bool {
        decision == .pushLocal
    }
}

/// How a conflict was resolved, once the user has said.
public enum ConflictResolution: String, Sendable, Hashable, CaseIterable, Codable {
    /// Take this app's version and write it out.
    case keepLocal

    /// Take the reminder's version, keeping every app-only field.
    case keepRemote

    /// Keep both: the reminder stays as it is, and the local edits are split into a new local-only
    /// task linked to the original.
    case keepBoth

    public var displayName: String {
        switch self {
        case .keepLocal: "Keep this app's version"
        case .keepRemote: "Keep the Reminders version"
        case .keepBoth: "Keep both"
        }
    }

    public var explanation: String {
        switch self {
        case .keepLocal: "The reminder is updated to match. Notes and links here are untouched."
        case .keepRemote: "The shared fields are taken from Reminders. Everything private stays."
        case .keepBoth: "The reminder is left alone, and your edits become a separate local reminder."
        }
    }
}

/// What happens to the system reminder when a linked task is deleted here.
///
/// Asked every time, and never defaulted to deletion. Deleting somebody's reminder out of their
/// iCloud account — where it may be shared with other people — because they tidied up in a different
/// app is not a recoverable mistake.
public enum LinkedDeletionChoice: String, Sendable, Hashable, CaseIterable, Codable {
    /// Remove it here; leave the reminder where it is.
    case removeLocally

    /// Remove both.
    case deleteBoth

    public var displayName: String {
        switch self {
        case .removeLocally: "Remove from Elephruit only"
        case .deleteBoth: "Also delete the reminder"
        }
    }
}

/// What happens to a task whose linked reminder has vanished.
public enum MissingReminderChoice: String, Sendable, Hashable, CaseIterable, Codable {
    /// Keep the task, drop the link. The default offered, because it loses nothing.
    case keepAsLocal

    /// Delete the task here too.
    case deleteLocally

    /// Point the link at a different reminder.
    case relink

    public var displayName: String {
        switch self {
        case .keepAsLocal: "Keep it here as a local reminder"
        case .deleteLocally: "Delete it here as well"
        case .relink: "Link it to a different reminder"
        }
    }
}
