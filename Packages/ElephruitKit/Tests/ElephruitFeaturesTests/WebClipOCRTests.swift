import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitPersistence
import Foundation
import Testing

@MainActor
@Suite("Web clip OCR", .serialized)
struct WebClipOCRTests {
    private struct FixtureRecognizer: TextRecognizing {
        func recognizeText(in imageData: Data) async throws -> [RecognizedLine] {
            [
                RecognizedLine(
                    text: "Bottom line",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)
                ),
                RecognizedLine(
                    text: "Top right",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05)
                ),
                RecognizedLine(
                    text: "Top left",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)
                ),
            ]
        }
    }

    @Test("Captured images are OCR indexed without adding a transcription to the note")
    func indexesCaptureTextOutsideEditor() async throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let defaults = UserDefaults(suiteName: "web-clip-ocr-\(UUID().uuidString)") ?? .standard
        let services = AppServices(
            stack: stack,
            dateProvider: FixedDateProvider.reference,
            textRecognizer: FixtureRecognizer(),
            defaults: defaults
        )
        let image = WebClipImage(
            filename: "full-page-01.jpg",
            typeIdentifier: "public.jpeg",
            data: Data([0xFF, 0xD8, 0xFF, 0x01])
        )
        let clip = WebClip(
            mode: .fullPage,
            title: "OCR fixture",
            sourceURL: URL(string: "https://example.com/ocr")!,
            excerpt: "This must not appear below the capture.",
            contentMarkdown: "DOM-only searchable text.",
            contentHTML: "<main>DOM-only searchable text.</main>",
            images: [image]
        )

        let item = try await services.saveWebClip(clip)
        let attachment = try #require(item.attachments.first { $0.filename == image.filename })

        #expect(attachment.extractedText == "Top left\nTop right\nBottom line")
        #expect(item.searchText.contains("top left"))
        #expect(item.searchText.contains("dom-only searchable text"))
        #expect(!item.body.contains("Top left"))
        #expect(!item.body.contains("This must not appear"))
        #expect(!item.body.contains("DOM-only searchable text"))
    }
}
