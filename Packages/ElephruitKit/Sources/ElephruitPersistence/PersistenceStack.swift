import ElephruitCore
import ElephruitModel
import Foundation
import SQLite3
import SwiftData

/// How the store is configured.
public enum StoreMode: Sendable, Hashable {
    /// A file-backed store at the given location. Production.
    case onDisk(StoreLocation)

    /// An in-memory store. Previews and tests — isolated, fast, and discarded.
    case inMemory
}

/// Whether iCloud sync is running, and how it is getting on.
///
/// Defined in milestone 1 and reporting ``SyncStatus/disabled`` so that the sidebar's
/// status line does not change shape when sync arrives in Phase 4.
public enum SyncStatus: Sendable, Hashable {
    case disabled
    case idle(lastSyncedAt: Date?)
    case syncing
    case offline
    case failed(reason: String)

    /// One quiet line for the sidebar. Never a spinner in the toolbar, never a modal.
    public var summary: String {
        switch self {
        case .disabled: "Stored on this Mac"
        case .idle(let date):
            if let date { "Synced \(date.formatted(.relative(presentation: .named)))" } else { "Synced" }
        case .syncing: "Syncing…"
        case .offline: "Offline — changes will sync later"
        case .failed: "Sync problem"
        }
    }

    /// Only a failure is worth interrupting the user to explain.
    public var isActionable: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Builds and owns the `ModelContainer`.
///
/// Bootstrap is deliberately *fallible and recoverable*: if the store cannot be opened
/// the app shows a failure state offering retry, reveal-in-Finder, and quit — it does not
/// call `fatalError`, and it does not delete anything. See
/// `docs/05-cloudkit-and-migrations.md` for the sequence.
public struct PersistenceStack: Sendable {
    public let container: ModelContainer
    public let mode: StoreMode

    /// Where files live, when the store is on disk.
    public var location: StoreLocation? {
        if case .onDisk(let location) = mode { return location }
        return nil
    }

    private init(container: ModelContainer, mode: StoreMode) {
        self.container = container
        self.mode = mode
    }

    /// Opens the store.
    ///
    /// - Throws: ``AppError/storeUnavailable(underlying:)`` or
    ///   ``AppError/migrationFailed(fromVersion:toVersion:backupPath:)``. Both are
    ///   recoverable states the shell can render; neither is fatal.
    public static func open(mode: StoreMode) throws(AppError) -> PersistenceStack {
        let configuration: ModelConfiguration

        switch mode {
        case .onDisk(let location):
            try location.createDirectories()
            configuration = ModelConfiguration(
                schema: CurrentSchema.schema,
                url: location.storeURL,
                // Phase 4 flips this to `.private(containerIdentifier)`. Everything the
                // schema needs to make that a one-line change is already in place.
                cloudKitDatabase: .none
            )

        case .inMemory:
            configuration = ModelConfiguration(
                schema: CurrentSchema.schema,
                isStoredInMemoryOnly: true
            )
        }

        // A migration plan with stages means this open may rewrite the store. Back it up first, so
        // a failure has something to restore from — requirement M4. Skipped when there is nothing to
        // protect: no stages, no store file, or an in-memory store.
        var backup: URL?
        if case .onDisk(let location) = mode,
           !ElephruitMigrationPlan.stages.isEmpty,
           FileManager.default.fileExists(atPath: location.storeURL.path(percentEncoded: false)) {
            backup = backupStore(at: location, label: "pre-v\(CurrentSchema.versionString)-\(UUID().uuidString.prefix(8))")
            pruneBackups(at: location, keeping: 3)
        }

        do {
            let container = try ModelContainer(
                for: CurrentSchema.schema,
                migrationPlan: ElephruitMigrationPlan.self,
                configurations: configuration
            )

            Diagnostics.persistence.info(
                "Opened store, schema \(CurrentSchema.versionString, privacy: .public), mode \(String(describing: mode), privacy: .public)"
            )

            return PersistenceStack(container: container, mode: mode)
        } catch {
            Diagnostics.persistence.error("Store open failed: \(error.localizedDescription, privacy: .public)")

            // Requirement M7: a failed migration leaves the original store untouched. SwiftData may
            // have partially rewritten it before failing, so "untouched" is achieved by putting the
            // backup back rather than by hoping nothing was written.
            if case .onDisk(let location) = mode, let backup {
                let restored = restoreStore(at: location, from: backup)
                Diagnostics.persistence.error(
                    "Restored pre-migration store: \(restored, privacy: .public)"
                )
            }

            if ElephruitMigrationPlan.stages.isEmpty {
                throw .storeUnavailable(underlying: error.localizedDescription)
            } else {
                throw .migrationFailed(
                    fromVersion: "unknown",
                    toVersion: CurrentSchema.versionString,
                    backupPath: backup?.path(percentEncoded: false) ?? backupPath(for: mode)
                )
            }
        }
    }

    /// An isolated in-memory stack. The default for tests and previews.
    public static func inMemory() throws(AppError) -> PersistenceStack {
        try open(mode: .inMemory)
    }

    private static func backupPath(for mode: StoreMode) -> String? {
        guard case .onDisk(let location) = mode else { return nil }
        return location.backupsRoot.path(percentEncoded: false)
    }

    /// Copies the store aside before a migration that is not lightweight.
    ///
    /// Best-effort by design: a failed backup must not prevent the app from starting, but
    /// it is logged so the reason is discoverable. Returns the backup directory when one
    /// was written.
    /// Copies the store aside before a migration.
    ///
    /// All three SQLite components are copied together — requirement **M5**. Copying only
    /// `.store` produces a file that either fails to open or silently loses whatever was still in
    /// the write-ahead log, which on a real library is the most recent work.
    ///
    /// The WAL is checkpointed first, so the copy is a consistent snapshot rather than three files
    /// caught mid-transaction.
    @discardableResult
    public static func backupStore(at location: StoreLocation, label: String) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: location.storeURL.path(percentEncoded: false)) else { return nil }

        checkpointWriteAheadLog(at: location.storeURL)

        let destination = location.backupsRoot.appending(path: label, directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            for suffix in storeComponentSuffixes {
                let source = URL(filePath: location.storeURL.path(percentEncoded: false) + suffix)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: destination.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
                )
            }

            Diagnostics.persistence.info("Wrote pre-migration backup \(label, privacy: .public)")
            return destination
        } catch {
            Diagnostics.persistence.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Every file that is part of the store. A backup missing one is not a backup.
    public static let storeComponentSuffixes = ["", "-wal", "-shm"]

    /// Puts a backup back over the live store — requirement **M7**.
    ///
    /// Removes the current components first, so a leftover `-wal` from the failed attempt cannot be
    /// replayed over the restored `.store` and undo the restore.
    @discardableResult
    public static func restoreStore(at location: StoreLocation, from backup: URL) -> Bool {
        let fileManager = FileManager.default

        do {
            for suffix in storeComponentSuffixes {
                let live = URL(filePath: location.storeURL.path(percentEncoded: false) + suffix)
                if fileManager.fileExists(atPath: live.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: live)
                }
            }

            for suffix in storeComponentSuffixes {
                let name = location.storeURL.lastPathComponent + suffix
                let source = backup.appending(path: name, directoryHint: .notDirectory)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: URL(filePath: location.storeURL.path(percentEncoded: false) + suffix)
                )
            }
            return true
        } catch {
            Diagnostics.persistence.fault("Restore failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Folds the write-ahead log into the main file, so a copy is self-contained.
    ///
    /// Best-effort: if the checkpoint cannot run, all three components are still copied together and
    /// the backup remains valid — it is simply three files rather than one.
    private static func checkpointWriteAheadLog(at storeURL: URL) {
        var handle: OpaquePointer?
        let path = storeURL.path(percentEncoded: false)

        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if handle != nil { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(handle) }

        sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    /// Keeps the most recent backups and removes the rest.
    ///
    /// Bounded on purpose: a backup per launch would fill the container over a year of use. Three is
    /// enough to recover from a bad migration and from the attempt that followed it.
    public static func pruneBackups(at location: StoreLocation, keeping count: Int) {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: location.backupsRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = entries.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return leftDate > rightDate
        }

        for stale in sorted.dropFirst(count) {
            try? fileManager.removeItem(at: stale)
        }
    }
}
