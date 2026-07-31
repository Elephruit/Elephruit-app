import ElephruitCore
import Foundation

/// Where Elephruit keeps its files.
///
/// Every path in the app is resolved here, so that introducing an App Group — which a
/// widget or share extension will require — is a change to one function rather than to
/// every call site.
public struct StoreLocation: Sendable, Hashable {
    /// The container root: `…/Application Support/Elephruit/`.
    public let root: URL

    /// The SwiftData store file.
    public var storeURL: URL { root.appending(path: "Elephruit.store", directoryHint: .notDirectory) }

    /// Managed attachment bytes, one directory per attachment.
    public var attachmentsRoot: URL { root.appending(path: "Attachments", directoryHint: .isDirectory) }

    /// Pre-migration store backups, one directory per attempt.
    public var backupsRoot: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }

    /// Purgeable derived data. Under Caches, so the OS may reclaim it — which is exactly
    /// right for a rebuildable index. See `docs/03-storage-matrix.md`.
    public let cachesRoot: URL

    /// The full-text search index.
    ///
    /// Derived, and safe to delete: everything in it is a projection of the store, and the app
    /// rebuilds it in the background if it is missing.
    ///
    /// **Beside the store rather than under Caches**, which is a deliberate departure from the
    /// storage matrix. On a large library the index runs to hundreds of megabytes, so it is exactly
    /// the kind of file the system reclaims first under pressure — and losing it costs a rebuild
    /// during which search is degraded. Search is a primary way of using this app, not a
    /// convenience, so it does not get to disappear when the disk fills. The recovery it would have
    /// bought is available deliberately instead, from Settings.
    public var searchIndexURL: URL {
        root.appending(path: "SearchIndex.sqlite", directoryHint: .notDirectory)
    }

    /// The calendar cache and its index.
    ///
    /// A second file rather than more tables in the first, because the two are invalidated by
    /// entirely different things: the search index is rebuilt when the *library* changes shape, and
    /// this one when EventKit does. Sharing a file would mean either rebuild throwing away the
    /// other's work, and a calendar refresh is not a reason to reindex fifty thousand notes.
    ///
    /// Derived on the same terms and beside the store for the same reason. Deleting it costs a
    /// refresh: EventKit is authoritative for every row in it.
    public var calendarIndexURL: URL {
        root.appending(path: "CalendarIndex.sqlite", directoryHint: .notDirectory)
    }

    public init(root: URL, cachesRoot: URL) {
        self.root = root
        self.cachesRoot = cachesRoot
    }

    /// The production location, inside the sandbox container.
    ///
    /// - Throws: ``AppError/storeUnavailable(underlying:)`` if the system cannot supply
    ///   an Application Support directory. There is no sensible fallback — writing a
    ///   user's library to a temporary directory would be worse than failing visibly.
    public static func application() throws(AppError) -> StoreLocation {
        let fileManager = FileManager.default

        let supportDirectory: URL
        let cachesDirectory: URL
        do {
            supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            cachesDirectory = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }

        return StoreLocation(
            root: supportDirectory.appending(path: "Elephruit", directoryHint: .isDirectory),
            cachesRoot: cachesDirectory.appending(path: "Elephruit", directoryHint: .isDirectory)
        )
    }

    /// A throwaway location under the system temporary directory, for tests that need a
    /// real file-backed store rather than an in-memory one.
    public static func temporary(name: String = UUID().uuidString) -> StoreLocation {
        let base = URL.temporaryDirectory.appending(path: "ElephruitTests/\(name)", directoryHint: .isDirectory)
        return StoreLocation(
            root: base.appending(path: "Library", directoryHint: .isDirectory),
            cachesRoot: base.appending(path: "Caches", directoryHint: .isDirectory)
        )
    }

    /// Creates the directories the app expects to exist.
    ///
    /// Idempotent. Called during bootstrap before the store is opened.
    public func createDirectories() throws(AppError) {
        for directory in [root, attachmentsRoot, backupsRoot, cachesRoot] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw .writeFailed(path: directory.path(percentEncoded: false), reason: error.localizedDescription)
            }
        }
    }

    /// Where a managed attachment's bytes live.
    public func attachmentDirectory(id: UUID) -> URL {
        attachmentsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Removes the whole location. Only for tests — the app never deletes a user's
    /// library.
    public func removeForTesting() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
