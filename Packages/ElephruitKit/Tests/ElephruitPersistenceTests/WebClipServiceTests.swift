import ElephruitCore
import ElephruitModel
@testable import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
@Suite("Web clip service", .serialized)
struct WebClipServiceTests {
    @MainActor
    private struct Fixture {
        let location: StoreLocation
        let context: ModelContext
        let items: SwiftDataItemRepository
        let attachments: AttachmentStore
        let service: WebClipService

        init() throws {
            location = .temporary()
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            context = ModelContext(stack.container)
            let clock = FixedDateProvider.reference
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
            attachments = AttachmentStore(context: context, location: location, dateProvider: clock)
            service = WebClipService(items: items, attachments: attachments)
        }

        func cleanUp() { location.removeForTesting() }
    }

    private func makeClip(mode: WebClipMode = .article) -> WebClip {
        WebClip(
            mode: mode,
            title: "  How local-first software lasts  ",
            sourceURL: URL(string: "https://example.com/story?utm_source=feed")!,
            canonicalURL: URL(string: "https://example.com/story"),
            siteName: "Example Journal",
            author: "Mara Chen",
            excerpt: "A fallback excerpt.",
            contentMarkdown: "## Keep the useful part\n\nThe durable copy lives here.",
            contentHTML: "<article><h2>Keep the useful part</h2><p>The durable copy lives here.</p></article>",
            comment: "Use this in the architecture review.",
            tagSlugs: ["#Research", " research ", "local-first"]
        )
    }


    @Test("An oversized article is excerpted inline and attached whole")
    func oversizedArticleIsExternalized() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let paragraph = "A sentence that repeats until the article outgrows a note. "
        let article = String(
            repeating: paragraph,
            count: WebClipService.maximumInlineBodyLength / paragraph.count + 50
        )
        var clip = makeClip()
        clip.contentMarkdown = article
        clip.contentHTML = nil

        let item = try fixture.service.save(clip)

        // The body holds an excerpt and says so; the record it syncs in stays bounded.
        #expect(item.body.count < WebClipService.maximumInlineBodyLength)
        #expect(item.body.contains("the whole text is attached"))

        // The whole article rides as a managed Markdown file, searchable by its extraction.
        let markdown = item.attachments.first { $0.typeIdentifier == "net.daringfireball.markdown" }
        let attached = try #require(markdown)
        #expect(attached.byteCount == article.utf8.count)
        #expect(attached.extractedText?.isEmpty == false)
        #expect((attached.extractedText?.count ?? 0) <= WebClipService.externalizedSearchLength)

        // The derived search column is bounded too — it is a stored field on the same record.
        #expect(item.searchText.count < WebClipService.maximumInlineBodyLength * 2)

        // Saving the same clip again does not stack a second copy.
        _ = try fixture.service.save(clip)
        let copies = item.attachments.filter { $0.typeIdentifier == "net.daringfireball.markdown" }
        #expect(copies.count == 1)
    }

    @Test("The inline bound cuts at whitespace, never mid-word")
    func inlineBoundRespectsWords() {
        let word = "unbroken "
        let long = String(repeating: word, count: WebClipService.maximumInlineBodyLength / word.count + 20)
        let inline = WebClipService.inlineBody(for: long)
        #expect(inline.count < long.count)
        #expect(!inline.hasPrefix("unbrokenunbroken"))
        let short = "A short article."
        #expect(WebClipService.inlineBody(for: short) == short)
    }

    @Test("An article becomes a sourced, searchable note with a fidelity attachment")
    func savesArticle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let item = try fixture.service.save(makeClip())

        #expect(item.kind == .note)
        #expect(item.title == "How local-first software lasts")
        #expect(item.source.kind == .webClip)
        #expect(item.source.identifier == WebClipMode.article.rawValue)
        #expect(item.source.url?.absoluteString == "https://example.com/story")
        #expect(item.tagSlugs.sorted() == ["local-first", "research"])
        #expect(item.body.contains("Use this in the architecture review."))
        #expect(item.body.contains("[Open original](https://example.com/story)"))
        #expect(!item.body.contains("Keep the useful part"))
        #expect(item.searchText.contains("keep the useful part"))

        let attachment = try #require(item.attachments.first)
        #expect(attachment.typeIdentifier == "public.html")
        let htmlURL = try #require(fixture.attachments.resolve(attachment))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("<article>"))
        #expect(item.noteDocument.pieces.contains { piece in
            if case .object(.webClip(let attachmentID)) = piece { return attachmentID == attachment.id }
            return false
        })
    }

    @Test("A bookmark stays lightweight")
    func savesBookmark() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip(mode: .bookmark)
        clip.contentHTML = nil
        clip.contentMarkdown = ""
        clip.comment = ""
        let item = try fixture.service.save(clip)

        #expect(item.kind == .bookmark)
        #expect(item.body.contains("A fallback excerpt."))
        #expect(item.attachments.isEmpty)
    }

    @Test("A screenshot is stored as managed bytes")
    func savesScreenshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip(mode: .screenshot)
        clip.contentHTML = nil
        clip.screenshotData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let item = try fixture.service.save(clip)

        let attachment = try #require(item.attachments.first)
        #expect(attachment.typeIdentifier == "public.png")
        let url = try #require(fixture.attachments.resolve(attachment))
        #expect(try Data(contentsOf: url) == clip.screenshotData)
        #expect(item.noteDocument.pieces.contains { piece in
            if case .object(.image(let attachmentID, _)) = piece { return attachmentID == attachment.id }
            return false
        })
    }

    @Test("A full-page capture keeps extracted page text out of the editor")
    func keepsFullPageTextOutOfEditor() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip(mode: .fullPage)
        clip.contentMarkdown = "Page introduction.\n\n---\n\nPage footer."
        clip.screenshotData = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        let item = try fixture.service.save(clip)

        let imageIndex = try #require(item.noteDocument.pieces.firstIndex { piece in
            if case .object(.image) = piece { return true }
            return false
        })
        #expect(!item.body.contains("Page introduction"))
        #expect(!item.body.contains("A fallback excerpt"))
        let trailingText = item.noteDocument.pieces.dropFirst(imageIndex + 1)
            .compactMap(\.paragraph?.plainText)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trailingText.isEmpty)
        #expect(item.searchText.contains("page introduction"))
    }

    @Test("Full-page panels remain together before the copied page text")
    func placesFullPagePanelsFirst() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip(mode: .fullPage)
        clip.contentMarkdown = "Searchable page text."
        clip.images = (1...2).map { index in
            WebClipImage(
                altText: "Full-page capture \(index) of 2",
                filename: "full-page-0\(index).jpg",
                typeIdentifier: "public.jpeg",
                data: Data([0xFF, 0xD8, 0xFF, UInt8(index)])
            )
        }
        let item = try fixture.service.save(clip)

        let imageIndices = item.noteDocument.pieces.indices.filter { index in
            if case .object(.image) = item.noteDocument.pieces[index] { return true }
            return false
        }
        #expect(imageIndices.count == 2)
        #expect(imageIndices.allSatisfy { index in
            guard case .object(.image(_, let caption)) = item.noteDocument.pieces[index] else {
                return false
            }
            return caption.isEmpty
        })
        #expect(!item.body.contains("Searchable page text"))
        #expect(!item.body.contains("A fallback excerpt"))
        let trailingText = item.noteDocument.pieces.dropFirst(try #require(imageIndices.last) + 1)
            .compactMap(\.paragraph?.plainText)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trailingText.isEmpty)
        #expect(item.searchText.contains("searchable page text"))
    }

    @Test("Downloaded page images are local and inline in the note")
    func savesInlinePageImages() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        clip.images = [WebClipImage(
            sourceURL: URL(string: "https://example.com/hero.png"),
            altText: "A durable local-first diagram",
            filename: "hero.png",
            typeIdentifier: "public.png",
            data: bytes
        )]
        let imageID = try #require(clip.images.first?.id)
        clip.contentHTML = "<article><img src=\"elephruit-attachment://\(imageID.uuidString)\"><p>Local text.</p></article>"

        let item = try fixture.service.save(clip)
        let attachment = try #require(item.attachments.first(where: { $0.filename == "hero.png" }))
        let imageURL = try #require(fixture.attachments.resolve(attachment))
        let htmlAttachment = try #require(item.attachments.first(where: { $0.typeIdentifier == "public.html" }))
        let htmlURL = try #require(fixture.attachments.resolve(htmlAttachment))

        #expect(try Data(contentsOf: imageURL) == bytes)
        #expect(attachment.id == imageID)
        #expect(try String(contentsOf: htmlURL, encoding: .utf8).contains("elephruit-attachment://\(imageID.uuidString)"))
        #expect(item.noteDocument.pieces.contains { piece in
            guard case .object(.webClip(let attachmentID)) = piece else { return false }
            return attachmentID == htmlAttachment.id
        })
        #expect(!item.noteDocument.pieces.contains { piece in
            if case .object(.image) = piece { return true }
            return false
        })
    }

    @Test("Downloaded article images keep their position in the copied text")
    func placesArticleImagesInReadingOrder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip()
        let imageURL = URL(string: "https://example.com/diagram.png")!
        clip.contentMarkdown = "Before the diagram.\n\n![System diagram](\(imageURL.absoluteString))\n\nAfter the diagram."
        clip.images = [WebClipImage(
            sourceURL: imageURL,
            altText: "System diagram",
            filename: "diagram.png",
            typeIdentifier: "public.png",
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        )]
        let imageID = try #require(clip.images.first?.id)
        clip.contentHTML = "<article><p>Before the diagram.</p><img src=\"elephruit-attachment://\(imageID.uuidString)\"><p>After the diagram.</p></article>"

        let item = try fixture.service.save(clip)
        let htmlAttachment = try #require(item.attachments.first(where: { $0.typeIdentifier == "public.html" }))
        let htmlURL = try #require(fixture.attachments.resolve(htmlAttachment))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let beforeRange = try #require(html.range(of: "Before the diagram."))
        let imageRange = try #require(html.range(of: "elephruit-attachment://\(imageID.uuidString)"))
        let afterRange = try #require(html.range(of: "After the diagram."))

        #expect(beforeRange.lowerBound < imageRange.lowerBound)
        #expect(imageRange.lowerBound < afterRange.lowerBound)
        #expect(!item.body.contains("![System diagram]"))
    }

    @Test("Retrying an interrupted import completes attachments without duplicating the item")
    func resumesInterruptedImport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let clip = makeClip()
        let partial = try fixture.items.create(
            ItemDraft(
                id: clip.id,
                kind: .note,
                title: clip.title,
                source: ItemSource(kind: .webClip, url: clip.preferredSourceURL)
            )
        )

        let completed = try fixture.service.save(clip)
        let retried = try fixture.service.save(clip)

        #expect(completed === partial)
        #expect(retried === partial)
        #expect(partial.attachments.count == 1)
        #expect(try fixture.items.items(matching: .everything()).count == 1)
    }

    @Test("A project hint files the clip without making it a child")
    func filesUnderProject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let project = try fixture.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        var clip = makeClip(mode: .bookmark)
        clip.contentHTML = nil
        clip.projectHint = "Q3"
        let item = try fixture.service.save(clip)

        #expect(item.parent == nil)
        #expect(item.outgoingLinks.contains { $0.kind == .filedUnder && $0.target?.id == project.id })
    }

    @Test("Non-web sources are refused before writing")
    func refusesUnsafeSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        var clip = makeClip()
        clip.sourceURL = URL(string: "file:///Users/example/private.html")!

        #expect(throws: AppError.self) { try fixture.service.save(clip) }
        #expect(try fixture.items.items(matching: .everything()).isEmpty)
    }
}
