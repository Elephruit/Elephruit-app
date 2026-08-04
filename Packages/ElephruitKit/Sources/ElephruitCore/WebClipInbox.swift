import Foundation

/// One clip waiting in the app-group handoff directory.
public struct PendingWebClip: Sendable, Hashable, Identifiable {
    public var clip: WebClip
    public var fileURL: URL
    public var id: UUID { clip.id }

    public init(clip: WebClip, fileURL: URL) {
        self.clip = clip
        self.fileURL = fileURL
    }
}

/// The atomic file queue shared by the Safari extension and Elephruit.
///
/// Safari never opens the SwiftData store. It writes one immutable JSON envelope here and asks
/// macOS to open Elephruit; the app imports and removes that envelope. If either process exits at
/// any point, an atomic write is either absent or complete and an unacknowledged clip remains for
/// the next launch.
public struct WebClipInbox: Sendable {
    public static let applicationGroupIdentifier = "group.com.elephruit.Elephruit"

    private let directory: URL

    public init(root: URL) {
        directory = root.appending(path: "WebClips/Incoming", directoryHint: .isDirectory)
    }

    public static func applicationGroup(
        identifier: String = applicationGroupIdentifier
    ) throws(AppError) -> WebClipInbox {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw .storeUnavailable(underlying: "The Safari clipper app-group container is unavailable.")
        }
        return WebClipInbox(root: root)
    }

    /// Makes a clip durable before the native extension reports success.
    @discardableResult
    public func enqueue(_ clip: WebClip) throws(AppError) -> PendingWebClip {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let milliseconds = Int64(clip.clippedAt.timeIntervalSince1970 * 1_000)
            let destination = directory.appending(
                path: "\(milliseconds)-\(clip.id.uuidString.lowercased()).json",
                directoryHint: .notDirectory
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(clip).write(to: destination, options: [.atomic, .completeFileProtection])
            return PendingWebClip(clip: clip, fileURL: destination)
        } catch {
            throw .writeFailed(path: directory.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }

    /// Reads complete envelopes in capture order. It does not remove them; persistence must commit
    /// before ``acknowledge(_:)`` makes the handoff disappear.
    public func pending() throws(AppError) -> [PendingWebClip] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let decoder = JSONDecoder()
            return try urls
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    PendingWebClip(clip: try decoder.decode(WebClip.self, from: Data(contentsOf: url)), fileURL: url)
                }
        } catch {
            throw .importFailed(format: "web clip", reason: error.localizedDescription)
        }
    }

    /// Removes exactly the envelope that was successfully committed to Elephruit.
    public func acknowledge(_ pending: PendingWebClip) throws(AppError) {
        let proposedParent = pending.fileURL.deletingLastPathComponent().standardizedFileURL.path
        let inboxPath = directory.standardizedFileURL.path
        guard proposedParent == inboxPath else {
            throw .writeFailed(path: pending.fileURL.path(percentEncoded: false), reason: "The clip is outside the inbox.")
        }
        do {
            try FileManager.default.removeItem(at: pending.fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Idempotent: another window may already have acknowledged it.
        } catch {
            throw .writeFailed(path: pending.fileURL.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }
}
