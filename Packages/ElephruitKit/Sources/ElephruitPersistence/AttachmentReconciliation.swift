import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What a sweep of the attachment folder found.
///
/// A *report*, produced by a dry run, so the user is told before anything happens. The same shape
/// as ``MigrationReport`` and for the same reason: deciding to delete someone's files is not a
/// decision an app gets to make on launch.
public struct AttachmentReconciliationReport: Sendable, Hashable {
    /// Folders under `Attachments/` with no row pointing at them.
    ///
    /// The recoverable direction, and the one ADR 0003 deliberately chose to fail towards.
    public var orphanedFolders: [String] = []

    /// Rows whose managed bytes are not where they should be.
    ///
    /// Not deletable — a row is the only remaining record that the file existed, and its filename
    /// is what lets someone go and find it. Marked lost, never removed.
    public var missingFiles: [UUID] = []

    /// Deleted attachments still inside the grace period.
    public var pendingDeletion: [String] = []

    /// Grace-period folders old enough to go.
    public var expiredDeletions: [String] = []

    public var totalBytesRecoverable: Int = 0

    public var isEmpty: Bool {
        orphanedFolders.isEmpty && missingFiles.isEmpty && expiredDeletions.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !orphanedFolders.isEmpty {
            parts.append("\(orphanedFolders.count) file\(orphanedFolders.count == 1 ? "" : "s") no longer attached to anything")
        }
        if !missingFiles.isEmpty {
            parts.append("\(missingFiles.count) attachment\(missingFiles.count == 1 ? "" : "s") whose file is missing")
        }
        if !expiredDeletions.isEmpty {
            parts.append("\(expiredDeletions.count) removed file\(expiredDeletions.count == 1 ? "" : "s") ready to clear")
        }
        return parts.isEmpty ? "Nothing to tidy" : parts.joined(separator: ", ")
    }
}

/// Keeping the two stores agreeing with each other.
///
/// ### Why this exists
/// ADR 0003 put attachment bytes on disk and their metadata in the store, and named the consequence
/// plainly: two stores means two failure modes, a row with no file and a file with no row. It
/// specified "a startup integrity pass that reports orphans in both directions and offers recovery"
/// as the mitigation. That pass was never built, so for three phases the decision's own safety net
/// was a paragraph.
///
/// ### Why it reports rather than acts
/// Deleting files is not reversible and the app is often wrong about what a file is for. The dry run
/// is the product; applying it is a separate, explicit step. This mirrors ``ContainmentRepair``,
/// which is the pattern the repository already settled on for exactly this kind of decision.
@MainActor
public struct AttachmentReconciliation {
    /// How long removed bytes are kept before a sweep will clear them.
    ///
    /// Long enough to notice a mistake and to restore from a backup taken before it; short enough
    /// that the folder does not become an archive of everything ever deleted.
    public static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60

    /// The folder removed bytes wait in. A dot-prefix so it sorts away from real attachments and
    /// reads as machinery rather than as content.
    public static let deletionFolderName = ".removed"

    /// Encodes when something was removed into the folder that holds it: `<uuid>__<epoch>`.
    ///
    /// Deliberately not the filesystem's creation date. That is preserved across a move, is not
    /// what "removed at" means, and — the reason it was actually noticed — cannot be driven by an
    /// injected clock, so the sweep could only have been tested by waiting a week.
    public static func removalFolderName(id: UUID, at date: Date) -> String {
        "\(id.uuidString)__\(Int(date.timeIntervalSince1970))"
    }

    /// Reads back what ``removalFolderName(id:at:)`` wrote. `nil` for anything else in there.
    static func removalStamp(from name: String) -> (id: String, removedAt: Date)? {
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { return nil }
        return (parts[0], Date(timeIntervalSince1970: seconds))
    }

    private let context: ModelContext
    private let location: StoreLocation
    private let dateProvider: any DateProvider

    public init(context: ModelContext, location: StoreLocation, dateProvider: any DateProvider) {
        self.context = context
        self.location = location
        self.dateProvider = dateProvider
    }

    /// Looks, and writes nothing.
    public func plan() throws(AppError) -> AttachmentReconciliationReport {
        var report = AttachmentReconciliationReport()
        let fileManager = FileManager.default

        let attachments: [Attachment]
        do {
            attachments = try context.fetch(FetchDescriptor<Attachment>())
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }

        // Rows pointing at bytes that are not there.
        var knownFolders = Set<String>()
        for attachment in attachments where attachment.storageKind == .managedCopy {
            knownFolders.insert(attachment.id.uuidString)
            guard let relativePath = attachment.relativePath else {
                report.missingFiles.append(attachment.id)
                continue
            }
            let url = location.attachmentsRoot.appending(path: relativePath, directoryHint: .notDirectory)
            if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                report.missingFiles.append(attachment.id)
            }
        }

        // Folders no row claims.
        let contents = (try? fileManager.contentsOfDirectory(
            atPath: location.attachmentsRoot.path(percentEncoded: false)
        )) ?? []

        for name in contents where name != Self.deletionFolderName {
            guard !knownFolders.contains(name) else { continue }
            report.orphanedFolders.append(name)
            report.totalBytesRecoverable += Self.byteCount(
                of: location.attachmentsRoot.appending(path: name, directoryHint: .isDirectory)
            )
        }

        // Grace-period contents, split by whether their time is up.
        let removedRoot = location.attachmentsRoot.appending(
            path: Self.deletionFolderName, directoryHint: .isDirectory
        )
        let removed = (try? fileManager.contentsOfDirectory(atPath: removedRoot.path(percentEncoded: false))) ?? []
        let cutoff = dateProvider.now.addingTimeInterval(-Self.gracePeriod)

        for name in removed {
            let url = removedRoot.appending(path: name, directoryHint: .isDirectory)
            // Anything without a stamp predates the naming scheme, or was put there by hand. Treated
            // as expired, because it has already been sitting in a folder called ".removed".
            guard let stamp = Self.removalStamp(from: name) else {
                report.expiredDeletions.append(name)
                report.totalBytesRecoverable += Self.byteCount(of: url)
                continue
            }

            if stamp.removedAt < cutoff {
                report.expiredDeletions.append(name)
                report.totalBytesRecoverable += Self.byteCount(of: url)
            } else {
                report.pendingDeletion.append(name)
            }
        }

        report.orphanedFolders.sort()
        report.expiredDeletions.sort()
        report.pendingDeletion.sort()
        return report
    }

    /// Performs what a plan described.
    ///
    /// Orphaned folders are **moved into the grace area**, not deleted — a file the app cannot
    /// account for is exactly the file it should be least confident about destroying. Only bytes
    /// that have already served their grace period are actually removed.
    ///
    /// Idempotent: running it twice finds nothing the second time.
    @discardableResult
    public func apply(_ report: AttachmentReconciliationReport) throws(AppError) -> AttachmentReconciliationReport {
        let fileManager = FileManager.default
        let removedRoot = location.attachmentsRoot.appending(
            path: Self.deletionFolderName, directoryHint: .isDirectory
        )
        try? fileManager.createDirectory(at: removedRoot, withIntermediateDirectories: true)

        for name in report.orphanedFolders {
            let source = location.attachmentsRoot.appending(path: name, directoryHint: .isDirectory)
            let stamped = UUID(uuidString: name).map {
                Self.removalFolderName(id: $0, at: dateProvider.now)
            } ?? name
            let destination = removedRoot.appending(path: stamped, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: source, to: destination)
        }

        for name in report.expiredDeletions {
            try? fileManager.removeItem(at: removedRoot.appending(path: name, directoryHint: .isDirectory))
        }

        // A row whose bytes are gone is *marked*, never deleted. The row is the last record that
        // the file existed at all, and its filename is what lets someone go and look for it.
        if !report.missingFiles.isEmpty {
            let ids = Set(report.missingFiles)
            let attachments = (try? context.fetch(FetchDescriptor<Attachment>())) ?? []
            for attachment in attachments where ids.contains(attachment.id) && attachment.referenceLostAt == nil {
                attachment.referenceLostAt = dateProvider.now
            }
            do {
                try context.save()
            } catch {
                throw .writeFailed(path: "store", reason: error.localizedDescription)
            }
        }

        return report
    }

    private static func byteCount(of directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
