import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// What happens when a timer was running and the app was not.
///
/// ### How the crash is produced
/// By writing the state a crash leaves behind: a running entry whose heartbeat stopped, in an
/// on-disk store, read back through a fresh container. That is precisely what `kill -9` during a
/// timer leaves on disk — the process dies without stopping anything — so the recovery path is
/// exercised against real bytes rather than a mock.
///
/// **The limit, stated:** this does not spawn and kill a real process. What is proven is that the
/// on-disk state a crash produces is detected and recoverable; what is not proven is that no other
/// state can result from a kill at some unlucky instant. Autosave and the single-transaction writes
/// in `TimeEntryRepository` are what bound that, and they are tested separately.
@MainActor
@Suite("Timer recovery", .serialized)
struct TimerRecoveryTests {
    private struct CrashedStore {
        let location: StoreLocation
        let entryID: UUID
        let startedAt: Date
        let lastHeartbeatAt: Date
    }

    /// Leaves a running timer on disk with a heartbeat `silentFor` seconds old, then closes.
    private func crash(
        silentFor silence: TimeInterval,
        ranFor worked: TimeInterval = 1_800,
        clock: FixedDateProvider
    ) throws -> CrashedStore {
        let location = StoreLocation.temporary()
        try location.createDirectories()

        let now = clock.now
        let heartbeat = now.addingTimeInterval(-silence)
        let startedAt = heartbeat.addingTimeInterval(-worked)
        let entryID: UUID

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

            let task = try items.create(ItemDraft(kind: .task, title: "Drafting the brief"))

            let entry = TimeEntry(startedAt: startedAt, entryDescription: "", lastHeartbeatAt: heartbeat)
            entry.item = task
            context.insert(entry)
            try context.save()
            entryID = entry.id
        }

        return CrashedStore(
            location: location,
            entryID: entryID,
            startedAt: startedAt,
            lastHeartbeatAt: heartbeat
        )
    }

    private func reopen(_ crashed: CrashedStore, clock: FixedDateProvider)
        throws -> (service: TimerService, entries: SwiftDataTimeEntryRepository) {
        let stack = try PersistenceStack.open(mode: .onDisk(crashed.location))
        let context = ModelContext(stack.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let entries = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)
        return (TimerService(entries: entries, dateProvider: clock), entries)
    }

    // MARK: - Detection

    @Test("A timer running when the app died is offered for recovery")
    func crashOffersRecovery() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, ranFor: 1_800, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, _) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        let recovery = try #require(service.pendingRecovery)
        #expect(recovery.id == crashed.entryID)
        #expect(recovery.displayTitle == "Drafting the brief")
        #expect(recovery.confirmedDuration == 1_800, "The time up to the last heartbeat is vouched for")
        #expect(recovery.unaccountedFor == 3 * 3_600, "The silence is what the user has to decide about")
    }

    @Test("Nothing is decided on the user's behalf")
    func recoveryIsNeverAutomatic() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        // Opening the app resolved nothing: the entry is exactly as the crash left it.
        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.isRunning, "Launching must not stop a timer")
        #expect(entry.deletedAt == nil, "Launching must not discard one either")
        #expect(entry.lastHeartbeatAt == crashed.lastHeartbeatAt, "Nor quietly re-date it")
        #expect(service.pendingRecovery != nil, "It asks")
    }

    @Test("A timer that has been beating recently is not disturbed")
    func freshTimerIsNotOfferedForRecovery() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 20, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, _) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        #expect(service.pendingRecovery == nil, "Twenty seconds of silence is a busy machine, not a crash")
        #expect(service.isRunning, "…and the timer simply carries on")
    }

    @Test("All three choices are offered, and they are genuinely different")
    func threeDistinctChoices() {
        #expect(TimerRecoveryChoice.allCases.count == 3)
        #expect(Set(TimerRecoveryChoice.allCases.map(\.displayName)).count == 3)
    }

    // MARK: - Resolution

    @Test("Stopping at last activity keeps the time the app can vouch for")
    func stopAtLastActivity() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, ranFor: 1_800, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        service.resolveRecovery(.stopAtLastActivity)

        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.endedAt == crashed.lastHeartbeatAt)
        #expect(entry.duration() == 1_800, "The three silent hours are not billed")
        #expect(service.pendingRecovery == nil)
        #expect(!service.isRunning)
    }

    @Test("Keeping it running counts the gap and does not ask again")
    func keepRunning() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, ranFor: 1_800, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        service.resolveRecovery(.keepRunning)

        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.isRunning)
        #expect(entry.lastHeartbeatAt == clock.now, "The heartbeat moves, so the prompt does not loop")
        #expect(try entries.staleRunningEntry(tolerance: TimerService.stalenessTolerance, now: clock.now) == nil)
        #expect(service.isRunning)
    }

    @Test("Discarding is recoverable, because discard should not mean destroyed")
    func discardIsSoft() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        service.resolveRecovery(.discard)

        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.deletedAt != nil)
        #expect(try entries.runningEntry() == nil)
        #expect(!service.isRunning)

        // And it can come back.
        try entries.restore(entry)
        #expect(entry.deletedAt == nil)
        #expect(entry.endedAt != nil, "Restoring closes it rather than resurrecting a second timer")
    }

    @Test("Dismissing without deciding changes nothing and asks again next time")
    func deferringIsAllowed() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        service.deferRecovery()
        service.shutDown()

        #expect(service.pendingRecovery == nil, "The banner goes away")

        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.isRunning, "The timer does not")
        #expect(entry.lastHeartbeatAt == crashed.lastHeartbeatAt)

        // Next launch asks again, because the question was never answered.
        let (second, _) = try reopen(crashed, clock: clock)
        second.start()
        defer { second.shutDown() }
        #expect(second.pendingRecovery?.id == crashed.entryID)
    }

    @Test("An entry with no heartbeat at all falls back to its start")
    func missingHeartbeatDegradesGracefully() throws {
        let clock = FixedDateProvider.reference
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let startedAt = clock.now.addingTimeInterval(-7_200)
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            // No heartbeat: written by a build that predates them, or crashed within the first tick.
            context.insert(TimeEntry(startedAt: startedAt, entryDescription: "Old entry"))
            try context.save()
        }

        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let entries = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)
        let service = TimerService(entries: entries, dateProvider: clock)

        service.start()
        defer { service.shutDown() }

        let recovery = try #require(service.pendingRecovery)
        #expect(recovery.lastHeartbeatAt == startedAt)
        #expect(recovery.confirmedDuration == 0, "Nothing can be vouched for, and it says so")
        #expect(recovery.unaccountedFor == 7_200)
    }

    // MARK: - The invariant, on launch

    @Test("Two timers left running by two devices are reconciled at launch")
    func launchRepairsTheInvariant() throws {
        let clock = FixedDateProvider.reference
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let base = clock.now.addingTimeInterval(-7_200)
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            context.insert(TimeEntry(startedAt: base, entryDescription: "Laptop", lastHeartbeatAt: clock.now))
            context.insert(TimeEntry(
                startedAt: base.addingTimeInterval(3_600),
                entryDescription: "Desktop",
                lastHeartbeatAt: clock.now
            ))
            try context.save()
        }

        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let entries = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)
        let service = TimerService(entries: entries, dateProvider: clock)

        service.start()
        defer { service.shutDown() }

        #expect(service.reconciledTimerCount == 1, "The user is told, not silently corrected")
        #expect(service.running?.entryDescription == "Desktop")

        let all = try context.fetch(FetchDescriptor<TimeEntry>())
        #expect(all.count == 2, "Nothing was deleted to resolve it")
    }
}
