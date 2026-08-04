import ElephruitCore
import ElephruitModel
import ElephruitPersistence
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
        #expect(item.body.contains("Keep the useful part"))

        let attachment = try #require(item.attachments.first)
        #expect(attachment.typeIdentifier == "public.html")
        let htmlURL = try #require(fixture.attachments.resolve(attachment))
        #expect(try String(contentsOf: htmlURL, encoding: .utf8).contains("<article>"))
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
