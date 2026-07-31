import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Migrates a **real store written by an earlier build**, if one has been placed where this can find
/// it.
///
/// ### Why a synthetic fixture was not enough
/// Every other migration test builds its store with today's model types, because the versioned
/// schemas reference live types rather than frozen copies. That means a "V1" store in a test already
/// has the shape V1 never had, so opening it needs no migration and the migration path is never
/// executed — it looked covered and was not.
///
/// The failure that made this necessary: `SchemaV2` was declared with `models` identical to
/// `SchemaV1`, which gives both the same Core Data version checksum. With one stage nothing
/// noticed. Adding a second stage made `NSLightweightMigrationStage` throw *"Duplicate version
/// checksums detected"*, and **every launch that needed migrating crashed** — while the entire test
/// suite stayed green.
///
/// Only bytes written by an older build reproduce that, so this test reads them. Set
/// `ELEPHRUIT_LEGACY_STORE` to a copy of such a store to run it; it skips otherwise, so an ordinary
/// checkout is unaffected.
@MainActor
@Suite("Real store migration", .serialized)
struct RealStoreMigrationTests {
    /// `nonisolated` so the `.enabled(if:)` condition — which runs in a `Sendable` closure before
    /// the suite is isolated — can read it.
    nonisolated static var legacyStorePath: String? {
        ProcessInfo.processInfo.environment["ELEPHRUIT_LEGACY_STORE"]
    }

    nonisolated static var isAvailable: Bool {
        guard let path = legacyStorePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    @Test("A store from an earlier build opens, migrates, and keeps everything",
          .enabled(if: RealStoreMigrationTests.isAvailable))
    func legacyStoreMigrates() throws {
        let sourcePath = try #require(Self.legacyStorePath)
        let source = URL(filePath: sourcePath)

        // Worked on a copy. A test that migrates the original would be a test that can destroy the
        // thing it is checking.
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: source.path(percentEncoded: false) + suffix)
            guard fileManager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            let to = URL(filePath: location.storeURL.path(percentEncoded: false) + suffix)
            try fileManager.copyItem(at: from, to: to)
        }

        // The launch path, unmodified. This is the line that used to throw.
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(!items.isEmpty, "A migrated library still has its items")

        // Every relationship the migration could have disturbed, read rather than assumed.
        for item in items {
            _ = item.tagSlugs
            _ = item.outgoingLinks.count
            _ = item.incomingLinks.count
            _ = item.timeEntries.count
        }

        #expect(try context.fetchCount(FetchDescriptor<TimeEntry>()) == 0,
                "Time tracking arrives empty rather than inventing something")

        // And the new entity works against the migrated data.
        let tags = SwiftDataTagRepository(context: context, dateProvider: FixedDateProvider.reference)
        let entries = SwiftDataTimeEntryRepository(
            context: context,
            dateProvider: FixedDateProvider.reference,
            tags: tags
        )
        let started = try entries.start(item: items.first, description: "After migrating", tagSlugs: [])
        #expect(started.isRunning)
        _ = try entries.stopRunning(at: nil)

        print("  [migration] \(items.count) items migrated and readable")
    }
}
