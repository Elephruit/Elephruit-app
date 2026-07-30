import EverythingCore
import EverythingModel
import Foundation
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

        do {
            let container = try ModelContainer(
                for: CurrentSchema.schema,
                migrationPlan: EverythingMigrationPlan.self,
                configurations: configuration
            )

            Diagnostics.persistence.info(
                "Opened store, schema \(CurrentSchema.versionString, privacy: .public), mode \(String(describing: mode), privacy: .public)"
            )

            return PersistenceStack(container: container, mode: mode)
        } catch {
            Diagnostics.persistence.error("Store open failed: \(error.localizedDescription, privacy: .public)")

            // A failure while a migration plan is in play is reported as a migration
            // failure, because that is the recovery the user needs — the backup path.
            if EverythingMigrationPlan.stages.isEmpty {
                throw .storeUnavailable(underlying: error.localizedDescription)
            } else {
                throw .migrationFailed(
                    fromVersion: "unknown",
                    toVersion: CurrentSchema.versionString,
                    backupPath: backupPath(for: mode)
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
    @discardableResult
    public static func backupStore(at location: StoreLocation, label: String) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: location.storeURL.path(percentEncoded: false)) else { return nil }

        let destination = location.backupsRoot.appending(path: label, directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            // SQLite keeps companions; copying only the main file would produce a backup
            // that cannot be opened.
            for suffix in ["", "-wal", "-shm"] {
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
}
