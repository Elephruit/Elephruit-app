import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What one reconciliation pass did.
///
/// Counts rather than a Boolean, because the interesting failures here are quiet ones: a pass that
/// pushed forty times when it should have pushed once, or that created a duplicate every time the
/// store-change notification fired. Both are visible in these numbers and in nothing else.
public struct ReminderSyncReport: Sendable, Hashable {
    public var examined = 0
    public var adopted = 0
    public var pushed = 0
    public var conflicted = 0
    public var missing = 0
    public var readOnly = 0
    public var imported = 0
    public var failures: [String] = []

    public init() {}

    public var changedAnything: Bool {
        adopted > 0 || pushed > 0 || imported > 0 || conflicted > 0 || missing > 0
    }

    public var summary: String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) brought in") }
        if adopted > 0 { parts.append("\(adopted) updated from Reminders") }
        if pushed > 0 { parts.append("\(pushed) sent to Reminders") }
        if conflicted > 0 { parts.append("\(conflicted) need a decision") }
        if missing > 0 { parts.append("\(missing) no longer in Reminders") }
        if readOnly > 0 { parts.append("\(readOnly) on a read-only list") }
        return parts.isEmpty ? "Everything is in step." : parts.joined(separator: ", ")
    }
}

/// Keeps linked tasks and system reminders in step, and says so when it cannot.
///
/// ### The three rules this type exists to keep
/// 1. **Nothing in the user's Reminders changes without their intent.** Every write goes through
///    ``RemindersProviding/apply(_:)`` as a describable value, and the only decision that produces
///    one is ``ReminderMergeDecision/pushLocal`` — which follows from a local edit the user made.
///    Deletions are produced only from an explicit ``LinkedDeletionChoice``.
/// 2. **Repeating a pass changes nothing the second time.** The fingerprint recorded after a write
///    is taken from the reminder as it came *back* from the store, not from what was sent, because
///    the store normalises what it is given and a mismatch there makes every pass a push.
/// 3. **App-only data is never destroyed by a remote change.** Adopting a remote reminder writes the
///    mapped fields and nothing else; the notes, links, area, project, waiting state, and history all
///    survive.
@MainActor
public final class ReminderSyncEngine {
    private let items: any ItemRepository
    private let tasks: TaskService
    private let context: ModelContext
    private let dateProvider: any DateProvider

    /// The adapter, resolved **per use** rather than captured once.
    ///
    /// ### Why this is a closure and not a value
    /// It was a value, and that was the bug that made linking Reminders appear to do nothing.
    ///
    /// `RemindersService` does not hold one adapter for its lifetime. It starts with an inert
    /// `NoRemindersProvider` — so that an app which never links a reminder never constructs an
    /// `EKEventStore` and never prompts — and swaps in the real `EventKitRemindersProvider` inside
    /// `enable()`, when the user turns the integration on. `AppServices` builds this engine during
    /// its own initialisation, which is *before* any of that can have happened.
    ///
    /// So on the launch in which somebody links Reminders, the engine was left holding the inert
    /// adapter for the rest of the session. `reconcile()` asked it whether it could read, was told
    /// no, and returned an empty report — no reminders, no error, no explanation. The list picker
    /// filled in correctly the whole time, because `RemindersService` asks *itself*, so the
    /// integration looked connected while importing nothing.
    ///
    /// Resolving through the service on every call means the engine can never be older than the
    /// adapter it is meant to be driving.
    private let resolveProvider: @MainActor () -> any RemindersProviding

    private var provider: any RemindersProviding { resolveProvider() }

    public init(
        items: any ItemRepository,
        tasks: TaskService,
        context: ModelContext,
        dateProvider: any DateProvider,
        provider: @escaping @MainActor () -> any RemindersProviding
    ) {
        self.items = items
        self.tasks = tasks
        self.context = context
        self.dateProvider = dateProvider
        self.resolveProvider = provider
    }

    /// For a caller whose adapter genuinely never changes — the fixtures, and the tests over them.
    public convenience init(
        items: any ItemRepository,
        tasks: TaskService,
        context: ModelContext,
        dateProvider: any DateProvider,
        provider: any RemindersProviding
    ) {
        self.init(
            items: items,
            tasks: tasks,
            context: context,
            dateProvider: dateProvider,
            provider: { provider }
        )
    }

    private var calendar: Calendar { dateProvider.calendar }

    // MARK: - Mapping

    /// The reminder a task should become, for a given list.
    ///
    /// Only the mapped fields. See ``ReminderFieldMapping/appOnlyFields`` for what stays here and
    /// why writing it into a title or a note would be wrong.
    public func snapshot(for task: Item, listID: String, existingID: String? = nil) -> ReminderSnapshot {
        var snapshot = ReminderSnapshot(id: existingID ?? "", listID: listID)
        snapshot.title = task.title
        snapshot.notes = task.body.isEmpty ? nil : task.body

        if let startAt = task.availableFrom {
            snapshot.startComponents = ReminderFieldMapping.components(
                from: startAt, hasTime: false, calendar: calendar
            )
        }
        if let deadline = task.dueAt {
            snapshot.dueComponents = ReminderFieldMapping.components(
                from: deadline, hasTime: false, calendar: calendar
            )
        }
        if let reminderAt = task.reminderAt {
            snapshot.alarmDates = [reminderAt]
            // A reminder time with no due date has nowhere to live in EventKit's model, which shows
            // alarms against the due date. Writing the due date too would fabricate a deadline, so
            // the alarm goes out on its own and the interface says the reminder is app-owned.
        }

        snapshot.isCompleted = task.status == .completed
        snapshot.completionDate = task.completedAt
        snapshot.priority = ReminderFieldMapping.eventKitPriority(
            from: task.priority == .normal ? nil : task.priority
        )
        snapshot.hasRecurrence = task.recurrence.map(ReminderFieldMapping.isRepresentableInEventKit) ?? false

        return snapshot
    }

    /// Writes a reminder's mapped fields onto a task, leaving everything else exactly as it was.
    public func adopt(_ snapshot: ReminderSnapshot, into task: Item) throws(AppError) {
        try tasks.mutate(task) { subject in
            subject.title = snapshot.title
            if let notes = snapshot.notes { subject.body = notes }

            subject.startAt = ReminderFieldMapping
                .date(from: snapshot.startComponents, calendar: self.calendar)?.date
            subject.dueAt = ReminderFieldMapping
                .date(from: snapshot.dueComponents, calendar: self.calendar)?.date

            if let alarm = snapshot.alarmDates.min() {
                subject.reminderAt = alarm
                subject.reminderIsTimed = true
                // The system already holds this alarm. Scheduling a second one here is how a person
                // ends up being told twice about the same task.
                subject.reminderOwner = .system
            } else {
                subject.reminderAt = nil
                subject.reminderOwner = .none
            }

            if let priority = ReminderFieldMapping.priority(fromEventKit: snapshot.priority) {
                subject.priority = priority
            }

            if snapshot.isCompleted {
                subject.status = .completed
                subject.completedAt = snapshot.completionDate ?? self.dateProvider.now
            } else if subject.status == .completed {
                subject.status = .open
                subject.completedAt = nil
            }
        }
    }

    // MARK: - Linking

    /// Brings a system reminder in as a task, linked to it.
    ///
    /// The task is created with no parent, no tags and no filing, because there is nothing honest to
    /// put it under: the user filed it in Reminders, and inventing a project here would be the app
    /// making a decision on their behalf. What that *used* to mean is that it matched the Inbox's
    /// definition — active, unparented, untagged, unfiled — the instant it existed, so a connected
    /// account with four hundred reminders in it produced four hundred rows of triage the user had
    /// already done somewhere else. See ``ElephruitModel/Item/hasHome``, which now counts the list it
    /// came from as the home it is.
    @discardableResult
    public func importReminder(
        _ snapshot: ReminderSnapshot,
        into container: Item? = nil
    ) throws(AppError) -> Item {
        let task = try items.create(
            ItemDraft(
                kind: .reminder,
                title: snapshot.title,
                parentID: container?.id,
                // The reminder's own identifier, kept whatever happens to the link afterwards. It is
                // what stops a second pass importing this reminder again — see
                // ``knownReminderIdentifiers()`` — and it is what the row cites when it says where
                // this task came from.
                source: ItemSource(kind: .systemStore, identifier: snapshot.id)
            )
        )

        try adopt(snapshot, into: task)
        try record(snapshot, on: task, localStampFrom: task)
        return task
    }

    /// Brings a reminder in and immediately breaks the link, leaving a private local task.
    ///
    /// Offered as its own action because "I want this in my task manager" and "I want this kept in
    /// step with my phone" are different wishes, and defaulting to the second means the app starts
    /// writing to somebody's iCloud account on the strength of an import.
    @discardableResult
    public func importAsLocalOnly(
        _ snapshot: ReminderSnapshot,
        into container: Item? = nil
    ) throws(AppError) -> Item {
        let task = try importReminder(snapshot, into: container)
        try unlink(task)
        return task
    }

    /// Sends an existing local task out to a list, and links the two.
    public func export(_ task: Item, toList listID: String) async -> ReminderWriteResult {
        let outgoing = snapshot(for: task, listID: listID)
        let result = await provider.apply(.create(outgoing))

        if case .saved(let saved) = result {
            try? record(saved, on: task, localStampFrom: task)
        }
        return result
    }

    /// Points an existing local task at an existing reminder, adopting the reminder's values.
    ///
    /// The remote wins on the mapped fields, because the user has just said "this task *is* that
    /// reminder" and the reminder is the copy their other devices already agree about.
    public func link(_ task: Item, to snapshot: ReminderSnapshot) throws(AppError) {
        try adopt(snapshot, into: task)
        try record(snapshot, on: task, localStampFrom: task)
    }

    /// Breaks a link without touching the reminder.
    public func unlink(_ task: Item) throws(AppError) {
        try items.update(task) { subject in
            subject.setReminderLink(nil)
            subject.syncState = .local
            if subject.reminderOwner == .system {
                // The alarm belonged to the reminder. Leaving the owner set would mean nothing ever
                // delivers it; taking it means this app now does.
                subject.reminderOwner = subject.reminderAt == nil ? .none : .app
            }
        }
    }

    /// Records a successful reconciliation.
    ///
    /// The local stamp is taken from the task **after** the write that just happened, so the next
    /// pass does not read that write as a fresh local edit — which would make every pass a push and
    /// every push a conflict. This is the bug the idempotence test in `ReminderBridgeTests` exists
    /// to prevent, seen from the other side.
    private func record(
        _ snapshot: ReminderSnapshot,
        on task: Item,
        localStampFrom stampSource: Item
    ) throws(AppError) {
        let stamp = stampSource.updatedAt
        // Through `recordSyncMetadata`, not `update`: this is bookkeeping about a sync, not an edit
        // the user made, and stamping `updatedAt` here is what made every pass believe there was a
        // local change to push. See `ItemRepository.recordSyncMetadata(on:_:)`.
        try items.recordSyncMetadata(on: task) { subject in
            subject.setReminderLink(
                ReminderLinkState(
                    externalID: snapshot.id,
                    listID: snapshot.listID,
                    lastSyncedFingerprint: snapshot.fingerprint,
                    lastSyncedAt: self.dateProvider.now,
                    lastSyncedLocalStamp: max(stamp, subject.updatedAt)
                )
            )
            subject.syncState = snapshot.isReadOnly ? .externalReadOnly : .linked
        }
    }

    // MARK: - The pass

    /// Reconciles every linked task.
    ///
    /// Reads first, decides second, writes last — so a pass that finds nothing to do performs no
    /// writes at all, which is what makes "reminders are never changed without intent" testable.
    @discardableResult
    /// - Parameter listIDs: The lists the user has chosen to take part. Reminders in them that are
    ///   not linked to anything here yet are brought in. Empty means import nothing — never "all",
    ///   which would be the app deciding to copy somebody's whole Reminders database.
    public func reconcile(importingFrom listIDs: [String] = []) async -> ReminderSyncReport {
        var report = ReminderSyncReport()

        guard await provider.authorization.canRead else { return report }

        // ### Why the import comes first, and why it exists at all
        // It did not. `reconcile()` walked the tasks that were *already* linked and reconciled each
        // against its reminder, which is the right thing to do second and useless on its own: with
        // nothing linked yet there was nothing to walk, so a freshly connected account reported
        // "Everything is in step" and imported not one reminder. `unlinkedReminders(inLists:)` and
        // `importReminder(_:)` were both written and neither was called from anywhere but a test.
        //
        // First, because a reminder imported now should then be reconciled by the same pass rather
        // than waiting for the next one — that is what makes connecting an account a single step.
        for snapshot in await unlinkedReminders(inLists: listIDs) {
            do {
                _ = try importReminder(snapshot)
                report.imported += 1
            } catch {
                // Named by list rather than by title: a failure message is a diagnostic, and the
                // titles of somebody's reminders are not diagnostics.
                report.failures.append("Could not import a reminder from list \(snapshot.listID).")
            }
        }

        let linked = (try? linkedTasks()) ?? []
        report.examined = linked.count

        for task in linked {
            guard let state = task.reminderLink else { continue }

            let remote = await provider.reminder(withIdentifier: state.externalID)
            let decision = ReminderReconciliation.decide(
                link: state,
                remote: remote,
                localUpdatedAt: task.updatedAt
            )

            switch decision {
            case .unchanged:
                continue

            case .establishBaseline:
                // The stored fingerprint was written by the pre-`v2` scheme and cannot be compared.
                // Record today's, and *keep the existing local stamp* so an edit the user is waiting
                // to push is still waiting after this pass rather than being swallowed by it.
                guard let remote else { continue }
                try? items.recordSyncMetadata(on: task) { subject in
                    subject.setReminderLink(
                        ReminderLinkState(
                            externalID: state.externalID,
                            listID: state.listID,
                            lastSyncedFingerprint: remote.fingerprint,
                            lastSyncedAt: self.dateProvider.now,
                            lastSyncedLocalStamp: state.lastSyncedLocalStamp
                        )
                    )
                }

            case .adoptRemote:
                guard let remote else { continue }
                do {
                    try adopt(remote, into: task)
                    try record(remote, on: task, localStampFrom: task)
                    report.adopted += 1
                } catch {
                    report.failures.append("\(task.displayTitle): \(error.localizedDescription)")
                }

            case .pushLocal:
                let outgoing = snapshot(for: task, listID: state.listID, existingID: state.externalID)
                switch await provider.apply(.update(outgoing)) {
                case .saved(let saved):
                    try? record(saved, on: task, localStampFrom: task)
                    report.pushed += 1
                case .readOnly:
                    try? mark(task, as: .externalReadOnly)
                    report.readOnly += 1
                case .missing:
                    try? mark(task, as: .externalMissing)
                    report.missing += 1
                case .failed(let reason):
                    report.failures.append("\(task.displayTitle): \(reason)")
                }

            case .conflict:
                try? mark(task, as: .conflicted)
                report.conflicted += 1

            case .remoteMissing:
                // The task keeps everything. The user is asked what to do about the link, and until
                // they answer nothing is deleted anywhere.
                try? mark(task, as: .externalMissing)
                report.missing += 1

            case .remoteReadOnly:
                try? mark(task, as: .externalReadOnly)
                report.readOnly += 1
            }
        }

        return report
    }

    private func mark(_ task: Item, as state: TaskSyncState) throws(AppError) {
        guard task.syncState != state else { return }
        try items.update(task) { $0.syncState = state }
    }

    private func linkedTasks() throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.kinds = [.reminder]
        query.scope = .all
        let all = try items.items(matching: query)
        return all.filter { $0.externalIdentifier != nil && $0.deletedAt == nil }
    }

    // MARK: - Resolving

    /// Applies the user's answer to a conflict.
    public func resolve(_ task: Item, as resolution: ConflictResolution) async -> ReminderWriteResult? {
        guard let state = task.reminderLink else { return nil }

        switch resolution {
        case .keepLocal:
            let outgoing = snapshot(for: task, listID: state.listID, existingID: state.externalID)
            let result = await provider.apply(.update(outgoing))
            if case .saved(let saved) = result {
                try? record(saved, on: task, localStampFrom: task)
            }
            return result

        case .keepRemote:
            guard let remote = await provider.reminder(withIdentifier: state.externalID) else {
                try? mark(task, as: .externalMissing)
                return nil
            }
            try? adopt(remote, into: task)
            try? record(remote, on: task, localStampFrom: task)
            return .saved(remote)

        case .keepBoth:
            // The reminder is left exactly as it is. The local edits become their own task, linked
            // to the original so neither version is orphaned.
            guard let remote = await provider.reminder(withIdentifier: state.externalID) else {
                return nil
            }
            try? splitLocalCopy(of: task)
            try? adopt(remote, into: task)
            try? record(remote, on: task, localStampFrom: task)
            return .saved(remote)
        }
    }

    /// Preserves the local version of a conflicted task as a separate, local-only task.
    private func splitLocalCopy(of task: Item) throws(AppError) {
        let copy = try items.create(
            ItemDraft(
                kind: .reminder,
                title: task.title,
                body: task.body,
                tagSlugs: task.tags.map(\.slug),
                parentID: task.parent?.id,
                dueAt: task.dueAt,
                startAt: task.availableFrom,
                priority: task.priority,
                source: ItemSource(kind: .generated, identifier: "conflict-copy")
            )
        )
        try items.link(copy, to: task, kind: .conflictCopy)
    }

    /// Applies the user's answer about a reminder that has vanished.
    public func resolveMissing(_ task: Item, as choice: MissingReminderChoice) throws(AppError) {
        switch choice {
        case .keepAsLocal:
            try unlink(task)
        case .deleteLocally:
            try items.moveToTrash(task)
        case .relink:
            // The picker does the relinking; this only clears the stale pointer so the picker has
            // somewhere to write.
            try unlink(task)
        }
    }

    /// Deletes a linked task, asking nothing of the system store unless told to.
    ///
    /// The default is ``LinkedDeletionChoice/removeLocally``, and there is no code path that deletes
    /// a reminder without one of these values being passed in. Deleting somebody's reminder out of
    /// an iCloud account — where it may be shared with other people — because they tidied up in a
    /// different app is not a recoverable mistake.
    public func delete(_ task: Item, choice: LinkedDeletionChoice) async -> ReminderWriteResult? {
        var result: ReminderWriteResult?

        if choice == .deleteBoth, let identifier = task.externalIdentifier {
            result = await provider.apply(.delete(id: identifier))
        }

        try? items.moveToTrash(task)
        return result
    }

    // MARK: - Discovery

    /// Reminders in the chosen lists that this library has never seen.
    ///
    /// ### An empty list of lists means none
    /// `RemindersProviding.reminders(inLists:)` reads an empty array as *every* list — a reasonable
    /// convention for a fetch primitive, and the exact opposite of what it means one layer up, where
    /// `RemindersService.participatingListIDs` starts empty and is documented as "empty means none,
    /// never all, which would be the app deciding".
    ///
    /// Those two readings met here. Connecting an account and ticking nothing would have imported
    /// the user's entire Reminders database on the first pass — every list, including the ones they
    /// had deliberately left out. The guard is what keeps the promise the settings screen makes.
    ///
    /// ### Never seen, not currently linked
    /// This asked ``knownReminderIdentifiers()`` for *linked* tasks, which is a narrower set than the
    /// one that matters and produced duplicates two ways.
    ///
    /// A task whose link the user deliberately broke — `importAsLocalOnly(_:into:)`, or answering
    /// *Keep as a local task* to a reminder that vanished and came back — carries no
    /// `externalIdentifier` at all. It fell out of the set, the reminder read as new, and the next
    /// pass imported a second copy beside the one already on screen. And a task in the Trash was
    /// filtered out by `linkedTasks()`, so tidying up an imported reminder here brought it straight
    /// back, and restoring the original later left two.
    ///
    /// The honest question is not "am I keeping this in step" but "have I ever taken this reminder
    /// in", and the app already records the answer: ``ElephruitModel/Item/sourceIdentifier`` holds
    /// the reminder's identifier from the moment it is imported and survives both unlinking and the
    /// Trash. Deleting the local task for good is what forgets a reminder — which is the only place
    /// where re-importing it is the right answer.
    public func unlinkedReminders(inLists listIDs: [String]) async -> [ReminderSnapshot] {
        guard !listIDs.isEmpty else { return [] }

        let remote = await provider.reminders(inLists: listIDs, includingCompleted: false)
        let known = knownReminderIdentifiers()
        return remote.filter { !known.contains($0.id) }
    }

    /// Every reminder identifier this library has a record of, however that record is filed now.
    ///
    /// Live links, broken links, and items in the Trash alike. See ``unlinkedReminders(inLists:)``.
    func knownReminderIdentifiers() -> Set<String> {
        var query = ItemQuery()
        query.kinds = [.reminder]
        query.scope = .all
        // Everything, including what has been archived or thrown away: a reminder the user deleted
        // here is one they have already decided about, and re-importing it would be the app arguing.
        let all = (try? items.items(matching: query)) ?? []

        var known: Set<String> = []
        for task in all {
            if let identifier = task.externalIdentifier { known.insert(identifier) }
            if task.source.kind == .systemStore, let identifier = task.sourceIdentifier {
                known.insert(identifier)
            }
        }
        return known
    }

    public func lists() async -> [ReminderListSummary] {
        await provider.lists()
    }
}
