import CryptoKit
import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Attaching files to items.
///
/// ### Two kinds, one decision
/// A file is either **copied in** — Elephruit owns the bytes and they live under the container, so
/// they export cleanly and survive the original being moved — or **referenced** by a security-scoped
/// bookmark, where the user keeps the file and Elephruit keeps a pointer.
///
/// Copying is the default. A reference is right for a 2 GB video or a document someone actively edits
/// elsewhere, and wrong for a screenshot dragged in from Downloads that will be tidied away next
/// week. The choice is offered rather than guessed at, and the consequence of each is stated where
/// it is offered.
///
/// ### Nothing here throws for a missing file
/// A referenced file that has moved is a **state**, not an error: `referenceLostAt` is set, the row
/// keeps its filename and size, and the user is offered "Locate…". A crash or a silent disappearance
/// would both be worse than a row that says what it used to point at.
@MainActor
public final class AttachmentStore {
    private let context: ModelContext
    private let location: StoreLocation?
    private let dateProvider: any DateProvider

    public init(context: ModelContext, location: StoreLocation?, dateProvider: any DateProvider) {
        self.context = context
        self.location = location
        self.dateProvider = dateProvider
    }

    // MARK: - Attaching

    /// Copies a file into the library.
    ///
    /// The bytes land at `Attachments/<attachment-uuid>/<filename>`, so two files with the same name
    /// cannot collide and removing one attachment is removing one directory.
    @discardableResult
    public func attachCopy(of url: URL, to item: Item) throws(AppError) -> Attachment {
        // A file chosen through an Open panel arrives with a scoped grant that has to be opened
        // before the bytes can be read, and balanced afterwards or the grant leaks.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .fileAccessDenied(path: url.path(percentEncoded: false))
        }

        return try attach(
            data: data,
            filename: url.lastPathComponent,
            typeIdentifier: Self.typeIdentifier(for: url),
            to: item
        )
    }

    /// Stores bytes that were produced in memory, without making the caller stage a temporary file.
    ///
    /// Web clips are the first caller: Safari supplies a PNG and a cleaned HTML snapshot as message
    /// data. Treating those like every other managed attachment keeps export, reconciliation, and
    /// deletion behavior identical to a file dragged in from Finder.
    @discardableResult
    public func attach(
        data: Data,
        id: UUID = UUID(),
        filename: String,
        typeIdentifier: String,
        to item: Item
    ) throws(AppError) -> Attachment {
        guard let location else {
            throw .writeFailed(path: filename, reason: "This library has no file storage.")
        }

        let safeFilename = Self.safeFilename(filename)
        let attachment = Attachment(
            id: id,
            filename: safeFilename,
            typeIdentifier: typeIdentifier,
            byteCount: data.count
        )
        attachment.storageKind = .managedCopy
        attachment.contentHash = Self.hash(data)
        attachment.createdAt = dateProvider.now

        let directory = location.attachmentDirectory(id: attachment.id)
        let destination = directory.appending(path: safeFilename, directoryHint: .notDirectory)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw .writeFailed(
                path: destination.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }

        attachment.relativePath = "\(attachment.id.uuidString)/\(safeFilename)"
        attachment.owner = item
        context.insert(attachment)

        // Bytes first, then the row — ADR 0003's ordering, because an orphan file is recoverable
        // and a row pointing at nothing is not. But a *failed* save used to leave that orphan
        // behind with nothing to clean it up, so the write is undone here. Nothing else references
        // these bytes yet, which is what makes removing them safe rather than presumptuous.
        do {
            try save()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        return attachment
    }

    /// The bookmark flavour each platform issues.
    ///
    /// macOS wants `.withSecurityScope` said explicitly; iOS has no such option because every
    /// bookmark made from a document-picker URL is implicitly security-scoped. Same capability,
    /// two spellings — resolved here once so the four call sites stay identical.
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
            .withSecurityScope
        #else
            []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
            .withSecurityScope
        #else
            []
        #endif
    }

    /// Records a pointer to a file the user keeps elsewhere.
    ///
    /// The bookmark is *not* a secret — it is an OS-issued capability for a file the user already
    /// chose — so the store is its correct home. Secrets go in the Keychain, and none of these are.
    @discardableResult
    public func attachReference(to url: URL, from item: Item) throws(AppError) -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw .fileAccessDenied(path: url.path(percentEncoded: false))
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let attachment = Attachment(
            filename: url.lastPathComponent,
            typeIdentifier: Self.typeIdentifier(for: url),
            byteCount: size
        )
        attachment.storageKind = .externalBookmark
        attachment.bookmarkData = bookmark
        attachment.lastKnownPath = url.path(percentEncoded: false)
        attachment.createdAt = dateProvider.now
        attachment.owner = item

        context.insert(attachment)
        try save()
        return attachment
    }

    // MARK: - Resolving

    /// Where an attachment's bytes are, if they can still be found.
    ///
    /// Returns `nil` and records the loss rather than throwing. The caller renders a row either way;
    /// only what the row *says* changes.
    public func resolve(_ attachment: Attachment) -> URL? {
        switch attachment.storageKind {
        case .managedCopy:
            guard let location, let relativePath = attachment.relativePath else { return nil }
            let url = location.attachmentsRoot.appending(path: relativePath, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                markLost(attachment)
                return nil
            }
            return url

        case .externalBookmark:
            return resolveBookmark(attachment)
        }
    }

    /// Resolves a bookmark, refreshing it when the file has merely moved.
    ///
    /// A stale bookmark that still resolves is rewritten, because otherwise the same slow resolution
    /// happens on every open until the user happens to relocate the file by hand.
    private func resolveBookmark(_ attachment: Attachment) -> URL? {
        guard let data = attachment.bookmarkData else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            markLost(attachment)
            return nil
        }

        if isStale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            if let refreshed = try? url.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                attachment.bookmarkData = refreshed
                attachment.lastKnownPath = url.path(percentEncoded: false)
                try? context.save()
            }
        }

        attachment.referenceLostAt = nil
        return url
    }

    private func markLost(_ attachment: Attachment) {
        guard attachment.referenceLostAt == nil else { return }
        attachment.referenceLostAt = dateProvider.now
        try? context.save()
    }

    /// Points a lost reference at a file the user has found.
    public func relocate(_ attachment: Attachment, to url: URL) throws(AppError) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            throw .fileAccessDenied(path: url.path(percentEncoded: false))
        }

        attachment.bookmarkData = bookmark
        attachment.lastKnownPath = url.path(percentEncoded: false)
        attachment.referenceLostAt = nil
        attachment.storageKind = .externalBookmark
        try save()
    }

    // MARK: - Removing

    /// Detaches, and deletes managed bytes.
    ///
    /// A referenced file is **never** deleted — Elephruit does not own it, and removing an attachment
    /// must not remove someone's document from their Desktop.
    ///
    /// ### Why the row goes first
    /// ADR 0003 chose the ordering deliberately: of the two ways two stores can disagree, "a crash
    /// leaves an orphan file, which is recoverable, rather than a row pointing at nothing, which is
    /// not." Deletion is that rule read backwards — bytes go only **after** the transaction commits,
    /// so a failed save leaves a row whose file is still there rather than a row pointing at nothing.
    ///
    /// This used to run the other way round, which inverted the ADR's own consequence 3 and made the
    /// one unrecoverable direction the likely one.
    ///
    /// The directory is resolved *before* the delete, because the identifier it is keyed on belongs
    /// to an object that is about to leave the context.
    public func remove(_ attachment: Attachment) throws(AppError) {
        let removedID = attachment.id
        let managedBytes: URL? = if attachment.storageKind == .managedCopy, let location {
            location.attachmentDirectory(id: attachment.id)
        } else {
            nil
        }

        context.delete(attachment)
        try save()

        // Past the commit. A failure here leaves an orphan directory, which the reconciliation pass
        // can find and the user can be offered; it cannot leave a live row with no bytes.
        //
        // The bytes are *moved aside*, not destroyed. Detaching a file is easy to do by accident and
        // impossible to undo, and a week of grace costs disk the user can see and get back. The
        // sweep in ``AttachmentReconciliation`` is what eventually clears it.
        if let managedBytes, let location {
            let removedRoot = location.attachmentsRoot.appending(
                path: AttachmentReconciliation.deletionFolderName,
                directoryHint: .isDirectory
            )
            let destination = removedRoot.appending(
                path: AttachmentReconciliation.removalFolderName(id: removedID, at: dateProvider.now),
                directoryHint: .isDirectory
            )

            try? FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.moveItem(at: managedBytes, to: destination)) == nil {
                // If it cannot be moved aside, removing it is still better than leaving bytes for a
                // row that no longer exists.
                try? FileManager.default.removeItem(at: managedBytes)
            }
        }
    }

    // MARK: - Helpers

    static func typeIdentifier(for url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.identifier
        }
        return UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
    }

    private static func safeFilename(_ proposed: String) -> String {
        let lastComponent = URL(fileURLWithPath: proposed).lastPathComponent
        let stripped = lastComponent.replacingOccurrences(of: ":", with: "-")
        return stripped.isEmpty || stripped == "." ? "Attachment" : String(stripped.prefix(180))
    }

    /// SHA-256, hex-encoded. Used to notice the same file being attached twice.
    ///
    /// Hex built by hand rather than with `String(format:)`, matching `DayKey`: that call takes
    /// `CVarArg`, which the strict-memory-safety checks flag, and this is arithmetic anyway.
    static func hash(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)

        for byte in SHA256.hash(data: data) {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
