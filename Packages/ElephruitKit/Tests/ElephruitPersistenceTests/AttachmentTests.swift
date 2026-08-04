import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Attachments, against a real store on a real filesystem.
///
/// In-memory would prove nothing here: the whole feature is about bytes on disk, files that move,
/// and bookmarks that go stale.
@MainActor
@Suite("Attachments", .serialized)
struct AttachmentTests {
    @MainActor
    private struct Fixture {
        let location: StoreLocation
        let context: ModelContext
        let items: SwiftDataItemRepository
        let attachments: AttachmentStore
        let scratch: URL
        let clock = FixedDateProvider.reference

        init() throws {
            location = StoreLocation.temporary()
            try location.createDirectories()

            let stack = try PersistenceStack.open(mode: .onDisk(location))
            context = ModelContext(stack.container)
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
            attachments = AttachmentStore(context: context, location: location, dateProvider: clock)

            scratch = location.root.deletingLastPathComponent()
                .appending(path: "Scratch", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        }

        func makeFile(_ name: String, contents: String = "hello") throws -> URL {
            let url = scratch.appending(path: name, directoryHint: .notDirectory)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func cleanUp() {
            location.removeForTesting()
        }
    }

    // MARK: - Copying

    @Test("A copied file survives the original being deleted")
    func copiesAreIndependent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let source = try fixture.makeFile("report.txt", contents: "the numbers")

        let attachment = try fixture.attachments.attachCopy(of: source, to: note)

        // The user tidies their Downloads folder, as they do.
        try FileManager.default.removeItem(at: source)

        let resolved = try #require(fixture.attachments.resolve(attachment))
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "the numbers",
                "A copy that depends on the original still existing is not a copy")
        #expect(attachment.referenceLostAt == nil)
    }

    @Test("Two files with the same name do not collide")
    func sameNameDifferentAttachments() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Two files"))

        let first = try fixture.makeFile("notes.txt", contents: "first")
        let firstAttachment = try fixture.attachments.attachCopy(of: first, to: note)

        let second = try fixture.makeFile("notes.txt", contents: "second")
        let secondAttachment = try fixture.attachments.attachCopy(of: second, to: note)

        let firstURL = try #require(fixture.attachments.resolve(firstAttachment))
        let secondURL = try #require(fixture.attachments.resolve(secondAttachment))

        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "first")
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "second")
    }

    @Test("In-memory bytes become an ordinary managed attachment")
    func dataAttachment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Clipped page"))
        let bytes = Data("<article>Saved</article>".utf8)
        let attachment = try fixture.attachments.attach(
            data: bytes,
            filename: "../unsafe:name.html",
            typeIdentifier: "public.html",
            to: note
        )

        #expect(attachment.filename == "unsafe-name.html")
        let stored = try #require(fixture.attachments.resolve(attachment))
        #expect(try Data(contentsOf: stored) == bytes)
    }

    @Test("The same bytes hash the same, so a duplicate is noticeable")
    func contentHashing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let first = try fixture.makeFile("a.txt", contents: "identical")
        let second = try fixture.makeFile("b.txt", contents: "identical")

        let one = try fixture.attachments.attachCopy(of: first, to: note)
        let two = try fixture.attachments.attachCopy(of: second, to: note)

        #expect(one.contentHash == two.contentHash)
        #expect(one.contentHash?.count == 64, "SHA-256, hex-encoded")
    }

    @Test("Removing a copied attachment deletes its bytes")
    func removingCopyDeletesBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("temp.txt")
        let attachment = try fixture.attachments.attachCopy(of: source, to: note)

        let stored = try #require(fixture.attachments.resolve(attachment))
        #expect(FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))

        try fixture.attachments.remove(attachment)
        #expect(!FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))
    }

    // MARK: - References

    @Test("Removing a referenced attachment leaves the user's file alone")
    func removingReferenceKeepsTheFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("important.txt", contents: "do not delete me")
        let attachment = try fixture.attachments.attachReference(to: source, from: note)

        try fixture.attachments.remove(attachment)

        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)),
                "Detaching must never delete a document Elephruit does not own")
        #expect(try String(contentsOf: source, encoding: .utf8) == "do not delete me")
    }

    @Test("A missing referenced file is a state, not an error")
    func missingReferenceIsRecorded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("gone.txt")
        let attachment = try fixture.attachments.attachReference(to: source, from: note)

        try FileManager.default.removeItem(at: source)

        // Does not throw, does not crash.
        let resolved = fixture.attachments.resolve(attachment)

        #expect(resolved == nil)
        #expect(attachment.referenceLostAt != nil, "The loss is recorded so the row can say so")
        #expect(attachment.filename == "gone.txt", "…while keeping what it used to point at")
        #expect(attachment.lastKnownPath?.hasSuffix("gone.txt") == true)
    }

    @Test("A lost reference can be pointed at the file again")
    func relocating() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("moved.txt", contents: "still here")
        let attachment = try fixture.attachments.attachReference(to: source, from: note)

        try FileManager.default.removeItem(at: source)
        _ = fixture.attachments.resolve(attachment)
        #expect(attachment.referenceLostAt != nil)

        // The user finds it somewhere else.
        let moved = try fixture.makeFile("moved-elsewhere.txt", contents: "still here")
        try fixture.attachments.relocate(attachment, to: moved)

        #expect(attachment.referenceLostAt == nil)
        let resolved = try #require(fixture.attachments.resolve(attachment))
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "still here")
    }

    // MARK: - Item lifecycle

    @Test("Attachments survive a relaunch")
    func attachmentsAreDurable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("durable.txt", contents: "persisted")
        _ = try fixture.attachments.attachCopy(of: source, to: note)
        let noteID = note.id

        // A fresh container over the same store, as the next launch produces.
        let stack = try PersistenceStack.open(mode: .onDisk(fixture.location))
        let context = ModelContext(stack.container)
        let store = AttachmentStore(context: context, location: fixture.location, dateProvider: fixture.clock)

        var descriptor = FetchDescriptor<Item>(predicate: #Predicate<Item> { $0.id == noteID })
        descriptor.fetchLimit = 1
        let reopened = try #require(try context.fetch(descriptor).first)

        #expect(reopened.attachments.count == 1)
        let attachment = try #require(reopened.attachments.first)
        let resolved = try #require(store.resolve(attachment))
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "persisted")
    }

    @Test("The file type is recorded, so a preview knows what it is looking at")
    func typeIdentifierIsRecorded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "Note"))
        let source = try fixture.makeFile("readme.txt")
        let attachment = try fixture.attachments.attachCopy(of: source, to: note)

        #expect(attachment.typeIdentifier.contains("text") || attachment.typeIdentifier == "public.plain-text")
        #expect(attachment.byteCount > 0)
    }
}
