import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// **M4, M5, M7** — the backup is real, complete, and can actually put things back.
///
/// A backup that has never been opened is a hope, not a backup. These tests write one from a real
/// on-disk store, open it as a store, and read the contents out; then destroy the live store and
/// prove the backup restores it.
@MainActor
@Suite("Backup and restore", .serialized)
struct BackupRestoreTests {
    /// A real file-backed store with known contents.
    private func makeStore(_ location: StoreLocation, titles: [String]) throws {
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        for title in titles {
            let item = Item(kind: .note, title: title, body: "Body of \(title)")
            item.refreshSearchText()
            context.insert(item)
        }
        try context.save()
    }

    private func titles(in location: StoreLocation) throws -> Set<String> {
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        return Set(try context.fetch(FetchDescriptor<Item>()).map(\.title))
    }

    // MARK: - M5: every component

    @Test("A backup contains every SQLite component, not just the main file")
    func backupIsComplete() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeStore(location, titles: ["Alpha", "Beta", "Gamma"])
        let backup = try #require(PersistenceStack.backupStore(at: location, label: "complete"))

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: backup.path(percentEncoded: false)
        )

        // Copying only `.store` either fails to open or silently loses whatever was still in the
        // write-ahead log — on a real library, the most recent work.
        #expect(contents.contains("Elephruit.store"))

        let liveComponents = PersistenceStack.storeComponentSuffixes.filter { suffix in
            FileManager.default.fileExists(
                atPath: location.storeURL.path(percentEncoded: false) + suffix
            )
        }
        for suffix in liveComponents {
            let name = "Elephruit.store" + suffix
            #expect(contents.contains(name), "\(name) is part of the store and must be in the backup")
        }
    }

    // MARK: - M4: it opens

    @Test("A backup can be opened as a store and read")
    func backupOpensAndReads() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        let expected: Set<String> = ["Alpha", "Beta", "Gamma"]
        try makeStore(location, titles: Array(expected))

        let backup = try #require(PersistenceStack.backupStore(at: location, label: "readable"))

        // Open the *backup* as a store in its own right. Writing bytes proves nothing; reading them
        // back through SwiftData is what makes it a backup.
        let restoredLocation = StoreLocation(root: backup, cachesRoot: backup)
        #expect(try titles(in: restoredLocation) == expected)
    }

    @Test("A backup taken with unflushed work still contains it")
    func backupCapturesUncommittedWork() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeStore(location, titles: ["Committed"])

        // Write more without letting anything checkpoint, so the newest rows are still in the WAL —
        // exactly the state a real library is in most of the time.
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        for title in ["In the log", "Also in the log"] {
            let item = Item(kind: .note, title: title)
            item.refreshSearchText()
            context.insert(item)
        }
        try context.save()

        let backup = try #require(PersistenceStack.backupStore(at: location, label: "with-wal"))
        let restoredLocation = StoreLocation(root: backup, cachesRoot: backup)

        #expect(try titles(in: restoredLocation) == ["Committed", "In the log", "Also in the log"])
    }

    // MARK: - M7: it puts things back

    @Test("Restoring after a destroyed store recovers exactly what was there")
    func restoreRecoversTheOriginal() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        let expected: Set<String> = ["First", "Second", "Third"]
        try makeStore(location, titles: Array(expected))

        let backup = try #require(PersistenceStack.backupStore(at: location, label: "pre-fault"))

        // Inject the fault: destroy the live store the way a half-finished migration would.
        try Data("not a database".utf8).write(to: location.storeURL)

        let restored = PersistenceStack.restoreStore(at: location, from: backup)
        #expect(restored)

        // The original opens, with its contents, as if nothing had happened.
        #expect(try titles(in: location) == expected)
    }

    @Test("Restoring clears a stale write-ahead log rather than replaying it over the restore")
    func restoreRemovesStaleComponents() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeStore(location, titles: ["Original"])
        let backup = try #require(PersistenceStack.backupStore(at: location, label: "clean"))

        // A leftover WAL from the failed attempt. If restore copied the .store back but left this in
        // place, SQLite could replay it and quietly undo the restore.
        let stalePath = location.storeURL.path(percentEncoded: false) + "-wal"
        try Data(repeating: 0xFF, count: 4_096).write(to: URL(filePath: stalePath))

        #expect(PersistenceStack.restoreStore(at: location, from: backup))
        #expect(try titles(in: location) == ["Original"])
    }

    // MARK: - Housekeeping

    @Test("Backups are pruned, so they cannot fill the container over a year of use")
    func backupsArePruned() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeStore(location, titles: ["Item"])

        for index in 1...6 {
            _ = PersistenceStack.backupStore(at: location, label: "backup-\(index)")
            // Distinct creation times, so "most recent" is well defined.
            Thread.sleep(forTimeInterval: 0.02)
        }

        PersistenceStack.pruneBackups(at: location, keeping: 3)

        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: location.backupsRoot.path(percentEncoded: false)
        )
        #expect(remaining.count == 3)
        #expect(remaining.contains("backup-6"), "The newest must survive")
    }

    @Test("Backing up a store that does not exist is not an error")
    func missingStoreIsHandled() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        #expect(PersistenceStack.backupStore(at: location, label: "nothing") == nil)
    }
}
