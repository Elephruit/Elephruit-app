import ElephruitCore
import Foundation
import Testing

@Suite("Web clip inbox", .serialized)
struct WebClipInboxTests {
    private func makeClip(_ id: UUID, seconds: TimeInterval) -> WebClip {
        WebClip(
            id: id,
            mode: .article,
            title: "Queued article",
            sourceURL: URL(string: "https://example.com/article")!,
            contentMarkdown: "The complete article.",
            clippedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Clips stay durable and ordered until acknowledged")
    func durableOrderedHandoff() throws {
        let root = URL.temporaryDirectory.appending(path: "WebClipInboxTests/\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WebClipInbox(root: root)
        let later = makeClip(UUID(), seconds: 200)
        let earlier = makeClip(UUID(), seconds: 100)

        _ = try inbox.enqueue(later)
        _ = try inbox.enqueue(earlier)

        var pending = try inbox.pending()
        #expect(pending.map(\.id) == [earlier.id, later.id])

        try inbox.acknowledge(pending.removeFirst())
        #expect(try inbox.pending().map(\.id) == [later.id])

        try inbox.acknowledge(try #require(inbox.pending().first))
        #expect(try inbox.pending().isEmpty)
    }

    @Test("Acknowledgement refuses paths outside its own inbox")
    func scopedAcknowledgement() throws {
        let root = URL.temporaryDirectory.appending(path: "WebClipInboxTests/\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WebClipInbox(root: root)
        let clip = makeClip(UUID(), seconds: 100)
        let outside = PendingWebClip(
            clip: clip,
            fileURL: root.appending(path: "do-not-delete.json", directoryHint: .notDirectory)
        )

        #expect(throws: AppError.self) { try inbox.acknowledge(outside) }
    }
}
