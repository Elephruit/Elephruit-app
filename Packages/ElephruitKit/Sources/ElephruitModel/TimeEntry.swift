import ElephruitCore
import Foundation
import SwiftData

/// A tracked stretch of time.
///
/// ### Why this is not an `Item`
/// The rule everywhere else in this model is that everything the user thinks about is an `Item`, and
/// this is the first considered exception. A time entry has no title, no body, no children, cannot be
/// linked to, and cannot be filed. More decisively, you accumulate them by the hundred thousand: as
/// `Item`s they would flood the Inbox, the search index, every count in the sidebar, and every list
/// that does not explicitly exclude them — and each of those exclusions would be a place to forget.
///
/// So it is its own entity, and it *points at* an item rather than being one. Recorded in
/// `docs/09-v2-plan.md`, and the user's own constraint: time entries remain separate records.
///
/// ### The invariant
/// **At most one entry may have `endedAt == nil`.** Enforced by `TimeEntryRepository`, not by the
/// type, because it is a statement about the whole store rather than about one row.
@Model
public final class TimeEntry {
    /// One **compound** index over the pair that "is anything running?" filters on together, and one
    /// over the column every report's date range uses.
    ///
    /// ### The compound part is not a detail
    /// Declared as three separate single-column indexes — `[\.endedAt], [\.deletedAt], [\.startedAt]`
    /// — this made no difference at all: the query stayed a full scan, measured at **7.1 ms** over a
    /// 200,000-entry store and rising linearly with it. Declared as one index over
    /// `(endedAt, deletedAt)`, exactly the pair the predicate ANDs together, the same query costs
    /// **0.04 ms**. A hundred and seventy-five times faster for a one-line difference.
    ///
    /// The general rule, learned expensively: an index has to match the *shape of the predicate*,
    /// not the list of columns that appear in one. Three failed guesses preceded this — the single
    /// indexes, a dropped `ORDER BY`, and a fresh `ModelContext` — and what settled it was measuring
    /// the same query at two store sizes and seeing the cost scale with the store.
    ///
    /// Free to add: no store has ever contained a `TimeEntry`, so this is part of the entity's first
    /// shape rather than a change to one.
    #Index<TimeEntry>([\.endedAt, \.deletedAt], [\.startedAt])

    public var id: UUID = UUID()

    public var startedAt: Date = Date()

    /// `nil` while running.
    ///
    /// Indexed, because "is anything running?" is asked on every launch, every menu bar tick, and
    /// every attempt to start a timer.
    public var endedAt: Date?

    /// What this stretch of time was, in the user's words.
    ///
    /// Named `entryDescription` rather than `description` so it can never be confused with
    /// `CustomStringConvertible`, which every type has and which a debugger will print.
    public var entryDescription: String = ""

    public var isBillable: Bool = false

    /// Designed for, deliberately unused in v1.
    ///
    /// Present in the schema now because adding an attribute later is a migration, and these two are
    /// certain to be wanted the first time anyone invoices from this. Nothing reads them yet.
    public var rateMinorUnits: Int?
    public var currencyCode: String?

    /// ``TimeEntrySource`` raw value.
    public var sourceRaw: String = TimeEntrySource.timer.rawValue

    /// The last moment the app confirmed this timer was genuinely running.
    ///
    /// Written every thirty seconds while running, and once more when the machine is about to sleep.
    /// This is the entire basis on which a crashed timer can be offered an honest stopping point
    /// rather than a guess.
    public var lastHeartbeatAt: Date?

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Soft deletion, matching every other entity: nothing is destroyed by an undo-able action.
    public var deletedAt: Date?

    // MARK: Relationships

    /// What the time was spent on — a task, project, note, person, or meeting.
    ///
    /// Optional because time can be tracked before deciding what it belongs to, which is most of
    /// what makes a timer usable: the alternative is filing something before you are allowed to
    /// start, and that is the friction that stops people tracking at all.
    ///
    /// `.nullify` on delete: deleting an item must not silently destroy a record of hours worked.
    @Relationship(deleteRule: .nullify, inverse: \Item.timeEntries)
    public var item: Item?

    @Relationship(deleteRule: .nullify)
    public var tags: [Tag] = []

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        entryDescription: String = "",
        isBillable: Bool = false,
        source: TimeEntrySource = .timer,
        lastHeartbeatAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.entryDescription = entryDescription
        self.isBillable = isBillable
        self.sourceRaw = source.rawValue
        self.lastHeartbeatAt = lastHeartbeatAt
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - Derived

extension TimeEntry {
    public var source: TimeEntrySource {
        get { TimeEntrySource(rawValue: sourceRaw) ?? .timer }
        set { sourceRaw = newValue.rawValue }
    }

    public var isRunning: Bool { endedAt == nil && deletedAt == nil }

    public var isDeleted: Bool { deletedAt != nil }

    /// Duration, measured to `now` while still running.
    public func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public var tagSlugs: [String] {
        tags.map(\.slug).sorted()
    }

    /// The project a report should file this under.
    ///
    /// An entry against a task belongs to that task's project, which is what makes "time by project"
    /// answerable without asking the user to tag every entry twice.
    public func reportingProject() -> Item? {
        guard let item else { return nil }
        if item.kind == .project { return item }
        return item.enclosingProject()
    }

    public func snapshot(at now: Date = Date()) -> TimeEntrySnapshot {
        let project = reportingProject()
        return TimeEntrySnapshot(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            entryDescription: entryDescription,
            isBillable: isBillable,
            source: source,
            itemID: item?.id,
            itemTitle: item?.displayTitle,
            itemKind: item?.kind,
            projectID: project?.id,
            projectTitle: project?.displayTitle,
            tagSlugs: tagSlugs
        )
    }

    public func runningSnapshot() -> RunningTimer {
        RunningTimer(
            id: id,
            startedAt: startedAt,
            entryDescription: entryDescription,
            itemID: item?.id,
            itemTitle: item?.displayTitle,
            itemKind: item?.kind,
            tagSlugs: tagSlugs,
            isBillable: isBillable
        )
    }

    /// What the app can say about a timer it found still running at launch.
    ///
    /// Falls back to `startedAt` when there is no heartbeat: an entry that never got one is either
    /// seconds old or was written by an older version, and in both cases the start is the last
    /// moment anything is known about.
    public func recovery(at now: Date) -> TimerRecovery {
        let heartbeat = lastHeartbeatAt ?? startedAt
        return TimerRecovery(
            id: id,
            entryDescription: entryDescription,
            itemTitle: item?.displayTitle,
            startedAt: startedAt,
            lastHeartbeatAt: heartbeat,
            unaccountedFor: max(0, now.timeIntervalSince(heartbeat))
        )
    }
}
