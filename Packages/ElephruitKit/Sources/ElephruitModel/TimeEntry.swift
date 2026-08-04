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

    /// How many finished focus blocks this stretch contains.
    ///
    /// Zero unless the entry was run as pomodoros. Counted rather than inferred from the duration,
    /// because a block that was cut short is not a block: the number has to mean *blocks you
    /// finished*, or a streak is something the app awards for leaving a timer on.
    public var focusRounds: Int = 0

    /// The calendar event written for this entry, if the mirror is on.
    ///
    /// Two identifiers rather than one, because an event is only findable given the calendar it is
    /// in — and because the calendar can be changed in settings, at which point an event written to
    /// the old one has to be recognisable as belonging somewhere else.
    ///
    /// Never read as a source of truth about anything but *which event this app wrote*. See
    /// ``ElephruitCore/TimeMirroring``.
    public var mirroredEventIdentifier: String?
    public var mirroredCalendarIdentifier: String?

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

    /// The project this is billed to when the subject's own parent chain is not the answer.
    ///
    /// Usually `nil`, and usually right to be: ``reportingProject()`` walks up from the subject,
    /// which is what makes *time by project* answerable without filing anything twice. This is the
    /// override for what that walk cannot reach — an hour on a note, a meeting, or nothing at all,
    /// that nonetheless belongs to a project. When set it **wins**, because an explicit answer from
    /// the user beats a derived one every time.
    @Relationship(deleteRule: .nullify, inverse: \Item.billedTimeEntries)
    public var project: Item?

    /// Who was there.
    ///
    /// People, always — the relationship is to `Item` because a person *is* one, and nothing else
    /// belongs here. Whether a non-person can be added is a question for the repository rather than
    /// the type, on the same terms as every other kind rule in this model.
    @Relationship(deleteRule: .nullify, inverse: \Item.attendedTimeEntries)
    public var people: [Item] = []

    // The inverse CloudKit mirroring requires, named here to match ``Item/tags``'s side
    // of the same convention. Nullify preserves what deletion already meant.
    @Relationship(deleteRule: .nullify, inverse: \Tag.timeEntries)
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

    /// Who was there, as values a view can hold.
    ///
    /// Sorted by name so two entries with the same people in a different order group together in the
    /// log rather than reading as two different afternoons.
    public var participants: [TimeParticipant] {
        people
            .map { TimeParticipant(id: $0.id, name: $0.displayTitle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The project a report should file this under.
    ///
    /// An entry against a task belongs to that task's project, which is what makes "time by project"
    /// answerable without asking the user to tag every entry twice. An explicit ``project`` beats
    /// that walk: the user said so, and a derivation cannot outrank an answer.
    public func reportingProject() -> Item? {
        if let project { return project }
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
            isProjectExplicit: self.project != nil,
            tagSlugs: tagSlugs,
            people: participants,
            focusRounds: focusRounds
        )
    }

    public func runningSnapshot() -> RunningTimer {
        let project = reportingProject()
        return RunningTimer(
            id: id,
            startedAt: startedAt,
            entryDescription: entryDescription,
            itemID: item?.id,
            itemTitle: item?.displayTitle,
            itemKind: item?.kind,
            projectID: project?.id,
            projectTitle: project?.displayTitle,
            people: participants,
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
