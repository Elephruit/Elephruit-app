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
        guard let location else {
            throw .writeFailed(path: url.lastPathComponent, reason: "This library has no file storage.")
        }

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

        let attachment = Attachment(
            filename: url.lastPathComponent,
            typeIdentifier: Self.typeIdentifier(for: url),
            byteCount: data.count
        )
        attachment.storageKind = .managedCopy
        attachment.contentHash = Self.hash(data)
        attachment.createdAt = dateProvider.now

        let directory = location.attachmentDirectory(id: attachment.id)
        let destination = directory.appending(path: url.lastPathComponent, directoryHint: .notDirectory)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw .writeFailed(
                path: destination.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }

        attachment.relativePath = "\(attachment.id.uuidString)/\(url.lastPathComponent)"
        attachment.owner = item
        context.insert(attachment)
        try save()

        return attachment
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
                options: .withSecurityScope,
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
            options: .withSecurityScope,
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
                options: .withSecurityScope,
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
            options: .withSecurityScope,
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
    public func remove(_ attachment: Attachment) throws(AppError) {
        if attachment.storageKind == .managedCopy, let location {
            let directory = location.attachmentDirectory(id: attachment.id)
            try? FileManager.default.removeItem(at: directory)
        }

        context.delete(attachment)
        try save()
    }

    // MARK: - Helpers

    static func typeIdentifier(for url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.identifier
        }
        return UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
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
