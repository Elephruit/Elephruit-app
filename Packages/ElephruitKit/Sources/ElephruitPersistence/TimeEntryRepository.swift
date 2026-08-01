import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Reading and writing tracked time.
///
/// ### The one invariant
/// **At most one entry may be running.** It lives here rather than on the type because it is a
/// statement about the whole store, and every path that could break it goes through this object:
/// starting, switching, recovering after a crash, and reconciling two devices.
///
/// Everything that could produce a second running timer either refuses or resolves it explicitly.
/// Nothing silently stops a timer the user did not ask to stop.
@MainActor
public protocol TimeEntryRepository: AnyObject {
    /// The running entry, if there is one.
    func runningEntry() throws(AppError) -> TimeEntry?

    /// Starts a timer.
    ///
    /// - Throws: ``AppError/timerAlreadyRunning(description:)`` if one is already running. Use
    ///   ``switchTo(item:description:tagSlugs:isBillable:)`` to stop the current one and start
    ///   another in a single step.
    @discardableResult
    func start(
        item: Item?,
        project: Item?,
        people: [Item],
        description: String,
        tagSlugs: [String],
        isBillable: Bool
    ) throws(AppError) -> TimeEntry

    /// Stops the running timer, if any. Returns what it stopped.
    @discardableResult
    func stopRunning(at date: Date?) throws(AppError) -> TimeEntry?

    /// Throws away the running timer without recording it.
    ///
    /// Distinct from stopping, and the distinction is the point: stopping keeps the time, and this
    /// says the timer should never have been running at all. Soft, like every other deletion here,
    /// so "discard" does not mean "unrecoverable".
    @discardableResult
    func discardRunning() throws(AppError) -> TimeEntry?

    /// Stops whatever is running and starts a new timer, as one action.
    @discardableResult
    func switchTo(
        item: Item?,
        project: Item?,
        people: [Item],
        description: String,
        tagSlugs: [String],
        isBillable: Bool
    ) throws(AppError) -> TimeEntry

    /// Records time that was never timed.
    @discardableResult
    func addManual(
        item: Item?,
        project: Item?,
        people: [Item],
        description: String,
        startedAt: Date,
        endedAt: Date,
        tagSlugs: [String],
        isBillable: Bool
    ) throws(AppError) -> TimeEntry

    /// Starts a new timer with the same subject as an existing entry.
    @discardableResult
    func resume(_ entry: TimeEntry) throws(AppError) -> TimeEntry

    /// Copies an entry, in place, over the same stretch of the clock.
    @discardableResult
    func duplicate(_ entry: TimeEntry) throws(AppError) -> TimeEntry

    func update(_ entry: TimeEntry, _ mutate: (TimeEntry) -> Void) throws(AppError)

    /// Replaces an entry's tags, creating any that do not exist yet.
    ///
    /// Here rather than in a ``update(_:_:)`` closure because turning slugs into `Tag`s needs the
    /// tag repository, which this object already holds and a view has no business reaching for.
    func setTags(_ slugs: [String], on entry: TimeEntry) throws(AppError)

    /// Replaces who was there.
    ///
    /// Anything that is not a person is dropped rather than refused. The call sites are pickers that
    /// search every kind, and a search that can offer a project has to be allowed to be wrong about
    /// one without failing the edit that carried it.
    func setPeople(_ people: [Item], on entry: TimeEntry) throws(AppError)

    /// Sets the project an entry is billed to, overriding the one derived from its subject.
    ///
    /// Passing `nil` returns it to the derived answer rather than to no project at all — see
    /// ``ElephruitModel/TimeEntry/reportingProject()``.
    func setProject(_ project: Item?, on entry: TimeEntry) throws(AppError)

    /// Records that one more focus block was finished on this entry.
    ///
    /// Called when a pomodoro's focus phase runs to its end, never when one is cut short: the count
    /// has to mean *blocks you finished*, or a streak becomes something the app awards for leaving a
    /// timer on.
    func noteFocusRound(on entry: TimeEntry) throws(AppError)

    /// Remembers, or forgets, the calendar event written for this entry.
    func setMirror(
        eventIdentifier: String?,
        calendarIdentifier: String?,
        on entry: TimeEntry
    ) throws(AppError)

    /// Finished entries in a window, oldest first, for the mirror to work through.
    ///
    /// Oldest first because it writes a calendar, and a calendar written backwards is one whose
    /// progress nobody can see. Excludes anything still running, which by definition has no end to
    /// write.
    func finishedEntries(in range: Range<Date>) throws(AppError) -> [TimeEntry]

    /// Every entry this app has written a calendar event for, whether or not it is deleted.
    ///
    /// What *Remove mirrored events* works through. Includes soft-deleted entries deliberately: an
    /// entry thrown away after being mirrored still has an event out there, and leaving it behind is
    /// how somebody ends up deleting two hundred events by hand.
    func mirroredEntries() throws(AppError) -> [TimeEntry]

    /// Makes an entry exactly this long.
    ///
    /// Which end moves depends on whether the entry is finished — see the implementation.
    func setDuration(_ duration: TimeInterval, for entry: TimeEntry) throws(AppError)

    func delete(_ entry: TimeEntry) throws(AppError)

    func restore(_ entry: TimeEntry) throws(AppError)

    func entry(id: UUID) throws(AppError) -> TimeEntry?

    /// Entries overlapping a window, newest first.
    func entries(in range: Range<Date>, limit: Int?) throws(AppError) -> [TimeEntry]

    /// Entries overlapping a window, projected into `Sendable` values ready to report on.
    func snapshots(in range: Range<Date>, limit: Int?) throws(AppError) -> [TimeEntrySnapshot]

    /// The most recently *finished* entries, for "continue previous".
    func recentEntries(limit: Int) throws(AppError) -> [TimeEntry]

    /// Writes the running timer's heartbeat.
    func recordHeartbeat(at date: Date) throws(AppError)

    /// A running entry whose heartbeat is older than `tolerance`, if there is one.
    func staleRunningEntry(tolerance: TimeInterval, now: Date) throws(AppError) -> TimeEntry?

    /// Applies the user's decision about a recovered timer.
    func resolveRecovery(_ choice: TimerRecoveryChoice, for entry: TimeEntry) throws(AppError)

    /// Applies the user's decision about a stretch nobody was at the machine for.
    func resolveIdle(_ choice: IdleChoice, for observation: IdleObservation) throws(AppError)

    /// Repairs the invariant if more than one entry is somehow running.
    @discardableResult
    func reconcileConcurrentTimers() throws(AppError) -> Int
}

// MARK: - Implementation

@MainActor
public final class SwiftDataTimeEntryRepository: TimeEntryRepository {
    private let context: ModelContext
    private let dateProvider: any DateProvider
    private let tags: any TagRepository
    private let audit: FetchAudit?

    public init(
        context: ModelContext,
        dateProvider: any DateProvider,
        tags: any TagRepository,
        audit: FetchAudit? = nil
    ) {
        self.context = context
        self.dateProvider = dateProvider
        self.tags = tags
        self.audit = audit
    }

    // MARK: Running

    public func runningEntry() throws(AppError) -> TimeEntry? {
        audit?.record(.other)

        // `endedAt == nil` is the definition of running; `deletedAt == nil` excludes an entry the
        // user has thrown away without stopping, which would otherwise haunt every start.
        //
        // **Deliberately unsorted.** A sort by `startedAt` reads harmlessly but costs everything: the
        // database can use one index per query, and given an `ORDER BY` it picks the one that serves
        // the sort, then walks the whole history applying the predicate. Measured over 200,000
        // entries that was a 7 ms scan, for a question asked on every launch, every menu bar tick,
        // and every attempt to start a timer.
        //
        // Dropping it is safe because the invariant makes it meaningless: there is at most one
        // running entry, and `reconcileConcurrentTimers()` runs at launch to guarantee it.
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    @discardableResult
    public func start(
        item: Item?,
        project: Item? = nil,
        people: [Item] = [],
        description: String,
        tagSlugs: [String],
        isBillable: Bool = false
    ) throws(AppError) -> TimeEntry {
        if let running = try runningEntry() {
            throw .timerAlreadyRunning(description: running.item?.displayTitle ?? running.entryDescription)
        }
        return try insertEntry(
            item: item,
            project: project,
            people: people,
            description: description,
            startedAt: dateProvider.now,
            endedAt: nil,
            tagSlugs: tagSlugs,
            isBillable: isBillable,
            source: .timer
        )
    }

    @discardableResult
    public func stopRunning(at date: Date? = nil) throws(AppError) -> TimeEntry? {
        guard let running = try runningEntry() else { return nil }

        let now = dateProvider.now
        // A stop cannot land before the start — a clock change or a supplied date could otherwise
        // produce a negative duration, which every report would then have to defend against.
        let stopAt = max(running.startedAt, date ?? now)

        running.endedAt = stopAt
        running.updatedAt = now
        running.lastHeartbeatAt = nil
        try save()
        return running
    }

    @discardableResult
    public func discardRunning() throws(AppError) -> TimeEntry? {
        guard let running = try runningEntry() else { return nil }

        let now = dateProvider.now
        // Closed as well as deleted. A soft-deleted entry with no end is still `endedAt == nil`, and
        // restoring it from the trash would resurrect a second running timer — the same trap
        // `restore(_:)` guards, closed here at source instead.
        running.endedAt = max(running.startedAt, now)
        running.lastHeartbeatAt = nil
        running.deletedAt = now
        running.updatedAt = now
        try save()
        return running
    }

    @discardableResult
    public func switchTo(
        item: Item?,
        project: Item? = nil,
        people: [Item] = [],
        description: String,
        tagSlugs: [String],
        isBillable: Bool = false
    ) throws(AppError) -> TimeEntry {
        // One save, so a crash between the two cannot leave nothing running *and* nothing stopped.
        let now = dateProvider.now

        if let running = try runningEntry() {
            running.endedAt = max(running.startedAt, now)
            running.updatedAt = now
            running.lastHeartbeatAt = nil
        }

        return try insertEntry(
            item: item,
            project: project,
            people: people,
            description: description,
            startedAt: now,
            endedAt: nil,
            tagSlugs: tagSlugs,
            isBillable: isBillable,
            source: .timer
        )
    }

    // MARK: Manual and resume

    @discardableResult
    public func addManual(
        item: Item?,
        project: Item? = nil,
        people: [Item] = [],
        description: String,
        startedAt: Date,
        endedAt: Date,
        tagSlugs: [String],
        isBillable: Bool = false
    ) throws(AppError) -> TimeEntry {
        guard endedAt > startedAt else {
            throw .invalidQuery(reason: "A time entry has to end after it starts.")
        }
        return try insertEntry(
            item: item,
            project: project,
            people: people,
            description: description,
            startedAt: startedAt,
            endedAt: endedAt,
            tagSlugs: tagSlugs,
            isBillable: isBillable,
            source: .manual
        )
    }

    @discardableResult
    public func resume(_ entry: TimeEntry) throws(AppError) -> TimeEntry {
        // Switch rather than start: continuing something is a thing you do *instead* of what you
        // were doing, and refusing because a timer is running would be pedantry.
        //
        // Billability comes along. Whether work is billable is a fact about the work, not about the
        // stretch of clock, so continuing something billable and getting an unbillable entry is a
        // silent revenue leak nobody notices until the invoice.
        //
        // So do the people and the project. Continuing the pairing session you broke off ten minutes
        // ago and getting an entry that has forgotten who you were pairing with is a correction
        // nobody remembers to make.
        try switchTo(
            item: entry.item,
            project: entry.project,
            people: entry.people,
            description: entry.entryDescription,
            tagSlugs: entry.tagSlugs,
            isBillable: entry.isBillable
        )
    }

    @discardableResult
    public func duplicate(_ entry: TimeEntry) throws(AppError) -> TimeEntry {
        // A copy over the same clock, not a new timer: this is for the second identical meeting you
        // forgot to track, and it lands where the original did so the correction is one edit away.
        // Marked `.manual`, because the copy was typed into existence and nothing watched it happen
        // — which is also what stops crash recovery from ever offering it.
        guard let endedAt = entry.endedAt else {
            throw .invalidQuery(reason: "A running timer cannot be duplicated. Stop it first.")
        }

        return try insertEntry(
            item: entry.item,
            project: entry.project,
            people: entry.people,
            description: entry.entryDescription,
            startedAt: entry.startedAt,
            endedAt: endedAt,
            tagSlugs: entry.tagSlugs,
            isBillable: entry.isBillable,
            source: .manual
        )
    }

    @discardableResult
    private func insertEntry(
        item: Item?,
        project: Item?,
        people: [Item],
        description: String,
        startedAt: Date,
        endedAt: Date?,
        tagSlugs: [String],
        isBillable: Bool,
        source: TimeEntrySource
    ) throws(AppError) -> TimeEntry {
        let now = dateProvider.now
        let entry = TimeEntry(
            startedAt: startedAt,
            endedAt: endedAt,
            entryDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
            isBillable: isBillable,
            source: source,
            lastHeartbeatAt: endedAt == nil ? now : nil,
            createdAt: now
        )
        entry.item = item
        entry.project = Self.projectOrNil(project)
        entry.people = Self.peopleOnly(people)
        entry.tags = try tags.ensureTags(named: tagSlugs)

        context.insert(entry)
        try save()
        return entry
    }

    /// Keeps only the people out of whatever a picker handed over.
    ///
    /// Dropped rather than refused, and deduplicated, because these arrive from a search field that
    /// can offer every kind: a picker allowed to be wrong about one row must not be allowed to fail
    /// the whole edit that carried it.
    private static func peopleOnly(_ items: [Item]) -> [Item] {
        var seen = Set<UUID>()
        return items.filter { item in
            guard item.kind == .person, !seen.contains(item.id) else { return false }
            seen.insert(item.id)
            return true
        }
    }

    /// Only a project may be billed to.
    ///
    /// An area or a goal contains projects rather than being one, and filing time directly against
    /// either would make a project report that silently skips those hours.
    private static func projectOrNil(_ item: Item?) -> Item? {
        guard let item, item.kind == .project else { return nil }
        return item
    }

    // MARK: Editing

    public func update(_ entry: TimeEntry, _ mutate: (TimeEntry) -> Void) throws(AppError) {
        mutate(entry)

        // Guard the one thing an edit can break that a report cannot recover from.
        if let endedAt = entry.endedAt, endedAt < entry.startedAt {
            entry.endedAt = entry.startedAt
        }

        entry.updatedAt = dateProvider.now
        try save()
    }

    public func setTags(_ slugs: [String], on entry: TimeEntry) throws(AppError) {
        entry.tags = try tags.ensureTags(named: slugs)
        entry.updatedAt = dateProvider.now
        try save()
    }

    public func setPeople(_ people: [Item], on entry: TimeEntry) throws(AppError) {
        entry.people = Self.peopleOnly(people)
        entry.updatedAt = dateProvider.now
        try save()
    }

    public func setProject(_ project: Item?, on entry: TimeEntry) throws(AppError) {
        entry.project = Self.projectOrNil(project)
        entry.updatedAt = dateProvider.now
        try save()
    }

    public func noteFocusRound(on entry: TimeEntry) throws(AppError) {
        entry.focusRounds += 1
        // Deliberately not touching `updatedAt`, on the same terms as a heartbeat: a finished focus
        // block is the app counting, not the user editing, and letting it bump the modification date
        // would make every tracked pomodoro look like a correction.
        try save()
    }

    public func setMirror(
        eventIdentifier: String?,
        calendarIdentifier: String?,
        on entry: TimeEntry
    ) throws(AppError) {
        entry.mirroredEventIdentifier = eventIdentifier
        entry.mirroredCalendarIdentifier = eventIdentifier == nil ? nil : calendarIdentifier
        // Also not an edit. The mirror is bookkeeping about a copy, and an entry that looks modified
        // every time a calendar write succeeds is one whose real edit history is unreadable.
        try save()
    }

    /// Makes an entry exactly `duration` long.
    ///
    /// ### Which end moves
    /// A finished entry keeps its start and moves its end. That is what somebody typing `1:30` into
    /// a row of yesterday's log means: the work began when it began, and the guess about when it
    /// stopped is the part being corrected.
    ///
    /// A **running** entry moves its *start* instead, because it has no end to move — its end is
    /// the present moment and will still be the present moment a second later. Typing `1:30` into a
    /// running timer therefore back-dates it to have begun ninety minutes ago, which is exactly the
    /// "I started this at two" correction the field exists for.
    ///
    /// A negative duration is refused rather than clamped: `DurationParser` cannot produce one, so
    /// anything that gets here with one is a caller bug and should say so.
    public func setDuration(_ duration: TimeInterval, for entry: TimeEntry) throws(AppError) {
        guard duration >= 0 else {
            throw .invalidQuery(reason: "A time entry cannot be a negative length.")
        }

        if entry.endedAt == nil {
            entry.startedAt = dateProvider.now.addingTimeInterval(-duration)
        } else {
            entry.endedAt = entry.startedAt.addingTimeInterval(duration)
        }

        entry.updatedAt = dateProvider.now
        try save()
    }

    public func delete(_ entry: TimeEntry) throws(AppError) {
        entry.deletedAt = dateProvider.now
        entry.updatedAt = entry.deletedAt ?? dateProvider.now
        try save()
    }

    public func restore(_ entry: TimeEntry) throws(AppError) {
        // Restoring a still-running entry would resurrect a second timer. Close it at the moment it
        // was discarded instead: the user gets their time back without the invariant breaking.
        if entry.endedAt == nil, let discardedAt = entry.deletedAt {
            entry.endedAt = max(entry.startedAt, discardedAt)
        }
        entry.deletedAt = nil
        entry.updatedAt = dateProvider.now
        try save()
    }

    public func entry(id: UUID) throws(AppError) -> TimeEntry? {
        var descriptor = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    // MARK: Reading

    public func entries(in range: Range<Date>, limit: Int? = nil) throws(AppError) -> [TimeEntry] {
        audit?.record(.other)

        let lower = range.lowerBound
        let upper = range.upperBound

        // Overlap, not containment: an entry that began yesterday evening and ended this morning is
        // part of both days, and a report that dropped it would simply lose the hours.
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && $0.startedAt < upper
                    && ($0.endedAt == nil || ($0.endedAt ?? upper) > lower)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }

        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    /// Entries as report-ready values, resolving each item's project only once.
    ///
    /// ### Why this is not `entries(in:).map { $0.snapshot() }`
    /// Deciding which project an entry rolls up to means walking its item's parent chain. Done per
    /// entry, a year of history asks that question tens of thousands of times to get a few hundred
    /// distinct answers — measured at **1.9 seconds** over a 200,000-entry store. Memoising by item
    /// takes it to one walk per item.
    ///
    /// The memo is local to the call, so it cannot go stale: it lives exactly as long as the one
    /// report being built.
    public func snapshots(in range: Range<Date>, limit: Int? = nil) throws(AppError) -> [TimeEntrySnapshot] {
        let entries = try entries(in: range, limit: limit)

        var projectByItem: [UUID: (id: UUID, title: String)?] = [:]

        return entries.map { entry in
            var projectID: UUID?
            var projectTitle: String?

            // An entry that names its project needs no walk at all, and must not take one: the memo
            // is keyed by *item*, so two entries against the same note billed to two different
            // projects would otherwise be given whichever answer was cached first.
            if let explicit = entry.project {
                projectID = explicit.id
                projectTitle = explicit.displayTitle
            } else if let item = entry.item {
                let resolved: (id: UUID, title: String)?
                if let cached = projectByItem[item.id] {
                    resolved = cached
                } else {
                    resolved = entry.reportingProject().map { ($0.id, $0.displayTitle) }
                    projectByItem[item.id] = resolved
                }
                projectID = resolved?.id
                projectTitle = resolved?.title
            }

            return TimeEntrySnapshot(
                id: entry.id,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                entryDescription: entry.entryDescription,
                isBillable: entry.isBillable,
                source: entry.source,
                itemID: entry.item?.id,
                itemTitle: entry.item?.displayTitle,
                itemKind: entry.item?.kind,
                projectID: projectID,
                projectTitle: projectTitle,
                tagSlugs: entry.tagSlugs,
                people: entry.participants,
                focusRounds: entry.focusRounds
            )
        }
    }

    public func finishedEntries(in range: Range<Date>) throws(AppError) -> [TimeEntry] {
        audit?.record(.other)

        let lower = range.lowerBound
        let upper = range.upperBound

        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && $0.endedAt != nil
                    && $0.startedAt < upper
                    && ($0.endedAt ?? upper) > lower
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        descriptor.fetchLimit = nil

        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    public func mirroredEntries() throws(AppError) -> [TimeEntry] {
        audit?.record(.other)

        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.mirroredEventIdentifier != nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    public func recentEntries(limit: Int) throws(AppError) -> [TimeEntry] {
        audit?.record(.other)

        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    // MARK: Heartbeat and recovery

    public func recordHeartbeat(at date: Date) throws(AppError) {
        guard let running = try runningEntry() else { return }
        running.lastHeartbeatAt = date
        // Deliberately *not* touching `updatedAt`. A heartbeat is the app noticing time passing, not
        // the user changing anything, and letting it bump the modification date would make every
        // running timer look permanently edited.
        try save()
    }

    public func staleRunningEntry(tolerance: TimeInterval, now: Date) throws(AppError) -> TimeEntry? {
        guard let running = try runningEntry() else { return nil }
        let heartbeat = running.lastHeartbeatAt ?? running.startedAt
        guard now.timeIntervalSince(heartbeat) > tolerance else { return nil }
        return running
    }

    public func resolveRecovery(_ choice: TimerRecoveryChoice, for entry: TimeEntry) throws(AppError) {
        let now = dateProvider.now

        switch choice {
        case .stopAtLastActivity:
            let heartbeat = entry.lastHeartbeatAt ?? entry.startedAt
            entry.endedAt = max(entry.startedAt, heartbeat)
            entry.lastHeartbeatAt = nil

        case .keepRunning:
            // The gap counts as worked. Heartbeat moves to now so it is not offered again in a loop.
            entry.lastHeartbeatAt = now

        case .discard:
            // Soft, like every other deletion here. "Discard" should not mean "unrecoverable".
            entry.deletedAt = now
        }

        entry.updatedAt = now
        try save()
    }

    /// Applies the user's decision about an idle stretch.
    ///
    /// ### Why three of the four choices end the entry at `idleSince`
    /// Because that is the last moment anything is known to have happened. Everything after it is
    /// the disputed part, and the three answers differ only in what becomes of the dispute: thrown
    /// away, thrown away and resumed, or kept as its own row. Only `.keep` says the gap was work,
    /// and only `.keep` leaves the entry alone.
    ///
    /// The split-out entry from `.keepAsSeparateEntry` is deliberately **not** billable and is
    /// deliberately described differently from the work around it. Not billable, because defaulting
    /// to charging for time the machine saw nobody for is the one direction of this that cannot be
    /// undone by noticing later. Described differently, because the log collapses matching rows, and
    /// an idle stretch that matched would fold straight back into the work it was just split out of.
    public func resolveIdle(_ choice: IdleChoice, for observation: IdleObservation) throws(AppError) {
        guard let entry = try entry(id: observation.id) else { return }
        guard choice != .keep else { return }

        let now = dateProvider.now
        let stopAt = max(entry.startedAt, observation.idleSince)

        entry.endedAt = stopAt
        entry.lastHeartbeatAt = nil
        entry.updatedAt = now
        try save()

        switch choice {
        case .keep, .discard:
            break

        case .discardAndContinue:
            try insertEntry(
                item: entry.item,
                project: entry.project,
                people: entry.people,
                description: entry.entryDescription,
                startedAt: now,
                endedAt: nil,
                tagSlugs: entry.tagSlugs,
                isBillable: entry.isBillable,
                source: .timer
            )

        case .keepAsSeparateEntry:
            let awayEnd = max(stopAt, observation.idleUntil)
            if awayEnd > stopAt {
                // The people are deliberately dropped along with the billability. Nobody was there —
                // that is the definition of the stretch being split out — and a row saying an hour
                // was spent with somebody who had gone home is worse than no row at all.
                try insertEntry(
                    item: entry.item,
                    project: entry.project,
                    people: [],
                    description: idleEntryDescription,
                    startedAt: stopAt,
                    endedAt: awayEnd,
                    tagSlugs: entry.tagSlugs,
                    isBillable: false,
                    source: .manual
                )
            }

            // The work carries on from where the gap ended, so the user is left timing the same
            // thing they were timing before they walked away.
            try insertEntry(
                item: entry.item,
                project: entry.project,
                people: entry.people,
                description: entry.entryDescription,
                startedAt: max(awayEnd, now),
                endedAt: nil,
                tagSlugs: entry.tagSlugs,
                isBillable: entry.isBillable,
                source: .timer
            )
        }
    }

    // MARK: Invariant repair

    @discardableResult
    public func reconcileConcurrentTimers() throws(AppError) -> Int {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )

        let running: [TimeEntry]
        do {
            running = try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }

        guard running.count > 1 else { return 0 }

        // Two devices each started a timer. Last-writer-wins would destroy one, so instead each
        // earlier entry is closed at the moment the next one began — nothing is deleted, and the
        // result is a plausible reading of what happened rather than a guess about which device
        // mattered more.
        var closed = 0
        for (index, entry) in running.enumerated() where index < running.count - 1 {
            let next = running[index + 1]
            entry.endedAt = max(entry.startedAt, next.startedAt)
            entry.lastHeartbeatAt = nil
            entry.updatedAt = dateProvider.now
            closed += 1
        }

        try save()
        Diagnostics.persistence.info("Reconciled \(closed, privacy: .public) concurrent timers")
        return closed
    }

    // MARK: Saving

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
