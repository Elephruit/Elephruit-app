import ElephruitCore
import Foundation
import Testing

@Suite("Web clip payload")
struct WebClipTests {
    @Test("Payloads round-trip through the shared-inbox JSON format")
    func codableRoundTrip() throws {
        let source = URL(string: "https://example.com/story?ref=home")!
        let canonical = URL(string: "https://example.com/story")
        let clip = WebClip(
            id: UUID(uuidString: "A15D9283-624C-4C82-BF36-89169F4F5061")!,
            mode: .article,
            title: "A useful story",
            sourceURL: source,
            canonicalURL: canonical,
            siteName: "Example",
            author: "Rina Shah",
            excerpt: "A short summary.",
            contentMarkdown: "## First idea\n\nKeep this.",
            contentHTML: "<article><h2>First idea</h2><p>Keep this.</p></article>",
            comment: "Read before Friday.",
            tagSlugs: ["research"],
            projectHint: "Launch",
            screenshotData: Data([0x89, 0x50, 0x4E, 0x47]),
            clippedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder().decode(WebClip.self, from: JSONEncoder().encode(clip))

        #expect(decoded == clip)
        #expect(decoded.preferredSourceURL == canonical)
    }

    @Test("Only web URLs are eligible clip sources")
    func webURLValidation() {
        #expect(URL(string: "https://example.com")!.isWebURL)
        #expect(URL(string: "http://localhost:8080/page")!.isWebURL)
        #expect(!URL(string: "file:///private/secret")!.isWebURL)
        #expect(!URL(string: "javascript:alert(1)")!.isWebURL)
    }
}
