import CloudKit
import ElephruitPersistence
import Foundation
import Testing

/// The sync status machine, driven without CloudKit, an account, or a network —
/// which is the point of ``SyncMonitor/ingest(_:)`` being a plain function of a value.
@MainActor
@Suite("Sync monitor")
struct SyncMonitorTests {
    @Test("Disabled stays disabled, whatever arrives")
    func disabledIsInert() {
        let monitor = SyncMonitor(enabled: false)
        #expect(monitor.status == .disabled)

        monitor.ingest(.init(kind: .importRecords, ended: nil, succeeded: false))
        monitor.ingest(.init(kind: .importRecords, ended: .now, succeeded: true))
        #expect(monitor.status == .disabled)
    }

    @Test("A started event reads as syncing; a finished one as synced, with its time")
    func happyPath() {
        let monitor = SyncMonitor(enabled: true)
        #expect(monitor.status == .idle(lastSyncedAt: nil))

        monitor.ingest(.init(kind: .exportRecords, ended: nil, succeeded: false))
        #expect(monitor.status == .syncing)

        let finished = Date(timeIntervalSinceReferenceDate: 800_000_000)
        monitor.ingest(.init(kind: .exportRecords, ended: finished, succeeded: true))
        #expect(monitor.status == .idle(lastSyncedAt: finished))
    }

    @Test("A completed import announces itself — that is the refresh pass's cue")
    func importAnnounces() {
        let monitor = SyncMonitor(enabled: true)
        var announcements = 0
        monitor.onImportCompleted = { announcements += 1 }

        monitor.ingest(.init(kind: .exportRecords, ended: .now, succeeded: true))
        #expect(announcements == 0, "An export changes nothing local")

        monitor.ingest(.init(kind: .importRecords, ended: .now, succeeded: true))
        #expect(announcements == 1)
    }

    @Test("Network trouble is a state, not a problem")
    func networkReadsAsOffline() {
        let monitor = SyncMonitor(enabled: true)
        monitor.ingest(
            .init(
                kind: .exportRecords,
                ended: .now,
                succeeded: false,
                cloudKitErrorCode: CKError.networkUnavailable.rawValue,
                failureDescription: "The Internet connection appears to be offline."
            )
        )
        #expect(monitor.status == .offline)

        // Recovery: the next success clears it.
        let finished = Date.now
        monitor.ingest(.init(kind: .exportRecords, ended: finished, succeeded: true))
        #expect(monitor.status == .idle(lastSyncedAt: finished))
    }

    @Test("Anything else failed is a failure, in CloudKit's own words")
    func realFailuresRead() {
        let monitor = SyncMonitor(enabled: true)
        monitor.ingest(
            .init(
                kind: .setup,
                ended: .now,
                succeeded: false,
                cloudKitErrorCode: CKError.notAuthenticated.rawValue,
                failureDescription: "Not signed in to iCloud."
            )
        )
        #expect(monitor.status == .failed(reason: "Not signed in to iCloud."))
        #expect(monitor.status.isActionable)
    }

    @Test("A temporary store never syncs, no matter what the caller asked for")
    func ephemeralStoresRefuseSync() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        let stack = try PersistenceStack.open(mode: .onDisk(location), syncEnabled: true)
        #expect(stack.isSyncEnabled == false, "Fixtures mirrored into a real library would be unrecoverable")
        #expect(location.isEphemeral)

        let memory = try PersistenceStack.inMemory()
        #expect(memory.isSyncEnabled == false)
    }
}
