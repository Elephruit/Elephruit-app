import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// What happens when a timer was running while the app was closed.
///
/// A timer is an explicit user decision and closing the app is not a stop command. These tests
/// recreate the on-disk state left by a quit or crash, reopen it in a fresh container, and prove the
/// same entry continues from its original start date without a recovery question.
@MainActor
@Suite("Timer continuity", .serialized)
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

    @Test("A timer keeps running for the entire time the app is closed")
    func timerContinuesAcrossLaunches() throws {
        let clock = FixedDateProvider.reference
        let crashed = try crash(silentFor: 3 * 3_600, ranFor: 1_800, clock: clock)
        defer { crashed.location.removeForTesting() }

        let (service, entries) = try reopen(crashed, clock: clock)
        service.start()
        defer { service.shutDown() }

        let entry = try #require(try entries.entry(id: crashed.entryID))
        #expect(entry.isRunning)
        #expect(entry.startedAt == crashed.startedAt, "Reopening must not move the start date")
        #expect(service.isRunning)
        #expect(service.running?.id == crashed.entryID)
        #expect(service.elapsed == 3 * 3_600 + 1_800, "The closed-app interval counts as elapsed time")
        #expect(service.pendingRecovery == nil, "Continuing a timer does not require a recovery choice")
    }

    @Test("A timer from an older build without a heartbeat also keeps running")
    func missingHeartbeatStillContinues() throws {
        let clock = FixedDateProvider.reference
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let startedAt = clock.now.addingTimeInterval(-7_200)
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            // No heartbeat: written by a build that predates them, or closed within the first tick.
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

        #expect(service.isRunning)
        #expect(service.elapsed == 7_200)
        #expect(service.pendingRecovery == nil)
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
