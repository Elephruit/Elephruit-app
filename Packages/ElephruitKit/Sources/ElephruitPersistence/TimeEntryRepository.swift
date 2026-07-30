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
    ///   ``switchTo(item:description:tagSlugs:)`` to stop the current one and start another in a
    ///   single step.
    @discardableResult
    func start(item: Item?, description: String, tagSlugs: [String]) throws(AppError) -> TimeEntry

    /// Stops the running timer, if any. Returns what it stopped.
    @discardableResult
    func stopRunning(at date: Date?) throws(AppError) -> TimeEntry?

    /// Stops whatever is running and starts a new timer, as one action.
    @discardableResult
    func switchTo(item: Item?, description: String, tagSlugs: [String]) throws(AppError) -> TimeEntry

    /// Records time that was never timed.
    @discardableResult
    func addManual(
        item: Item?,
        description: String,
        startedAt: Date,
        endedAt: Date,
        tagSlugs: [String]
    ) throws(AppError) -> TimeEntry

    /// Starts a new timer with the same subject as an existing entry.
    @discardableResult
    func resume(_ entry: TimeEntry) throws(AppError) -> TimeEntry

    func update(_ entry: TimeEntry, _ mutate: (TimeEntry) -> Void) throws(AppError)

    func delete(_ entry: TimeEntry) throws(AppError)

    func restore(_ entry: TimeEntry) throws(AppError)

    func entry(id: UUID) throws(AppError) -> TimeEntry?

    /// Entries overlapping a window, newest first.
    func entries(in range: Range<Date>, limit: Int?) throws(AppError) -> [TimeEntry]

    /// The most recently *finished* entries, for "continue previous".
    func recentEntries(limit: Int) throws(AppError) -> [TimeEntry]

    /// Writes the running timer's heartbeat.
    func recordHeartbeat(at date: Date) throws(AppError)

    /// A running entry whose heartbeat is older than `tolerance`, if there is one.
    func staleRunningEntry(tolerance: TimeInterval, now: Date) throws(AppError) -> TimeEntry?

    /// Applies the user's decision about a recovered timer.
    func resolveRecovery(_ choice: TimerRecoveryChoice, for entry: TimeEntry) throws(AppError)

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
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    @discardableResult
    public func start(item: Item?, description: String, tagSlugs: [String]) throws(AppError) -> TimeEntry {
        if let running = try runningEntry() {
            throw .timerAlreadyRunning(description: running.item?.displayTitle ?? running.entryDescription)
        }
        return try insertEntry(
            item: item,
            description: description,
            startedAt: dateProvider.now,
            endedAt: nil,
            tagSlugs: tagSlugs,
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
    public func switchTo(item: Item?, description: String, tagSlugs: [String]) throws(AppError) -> TimeEntry {
        // One save, so a crash between the two cannot leave nothing running *and* nothing stopped.
        let now = dateProvider.now

        if let running = try runningEntry() {
            running.endedAt = max(running.startedAt, now)
            running.updatedAt = now
            running.lastHeartbeatAt = nil
        }

        return try insertEntry(
            item: item,
            description: description,
            startedAt: now,
            endedAt: nil,
            tagSlugs: tagSlugs,
            source: .timer
        )
    }

    // MARK: Manual and resume

    @discardableResult
    public func addManual(
        item: Item?,
        description: String,
        startedAt: Date,
        endedAt: Date,
        tagSlugs: [String]
    ) throws(AppError) -> TimeEntry {
        guard endedAt > startedAt else {
            throw .invalidQuery(reason: "A time entry has to end after it starts.")
        }
        return try insertEntry(
            item: item,
            description: description,
            startedAt: startedAt,
            endedAt: endedAt,
            tagSlugs: tagSlugs,
            source: .manual
        )
    }

    @discardableResult
    public func resume(_ entry: TimeEntry) throws(AppError) -> TimeEntry {
        // Switch rather than start: continuing something is a thing you do *instead* of what you
        // were doing, and refusing because a timer is running would be pedantry.
        try switchTo(item: entry.item, description: entry.entryDescription, tagSlugs: entry.tagSlugs)
    }

    private func insertEntry(
        item: Item?,
        description: String,
        startedAt: Date,
        endedAt: Date?,
        tagSlugs: [String],
        source: TimeEntrySource
    ) throws(AppError) -> TimeEntry {
        let now = dateProvider.now
        let entry = TimeEntry(
            startedAt: startedAt,
            endedAt: endedAt,
            entryDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            lastHeartbeatAt: endedAt == nil ? now : nil,
            createdAt: now
        )
        entry.item = item
        entry.tags = try tags.ensureTags(named: tagSlugs)

        context.insert(entry)
        try save()
        return entry
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
