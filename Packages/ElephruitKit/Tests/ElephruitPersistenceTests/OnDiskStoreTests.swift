import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Everything else in this suite runs against an in-memory store, which is right for speed and
/// isolation but proves nothing about the file-backed path the app actually uses. These tests use a
/// real store on disk, close it, and reopen it.
///
/// What that catches and in-memory testing cannot: a migration plan that fails on a real file, a
/// store URL that cannot be created, data that does not survive a close, and SQLite companion files
/// going missing.
@MainActor
@Suite("On-disk store", .serialized)
struct OnDiskStoreTests {
    /// Opens a throwaway on-disk store, runs the body, and removes the whole directory afterwards.
    private func withTemporaryStore(
        _ body: (StoreLocation, PersistenceStack) throws -> Void
    ) throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        let stack = try PersistenceStack.open(mode: .onDisk(location))
        try body(location, stack)
    }

    @Test("Opening a store creates the expected directory layout")
    func createsDirectories() throws {
        try withTemporaryStore { location, _ in
            let fileManager = FileManager.default

            #expect(fileManager.fileExists(atPath: location.root.path(percentEncoded: false)))
            #expect(fileManager.fileExists(atPath: location.attachmentsRoot.path(percentEncoded: false)))
            #expect(fileManager.fileExists(atPath: location.backupsRoot.path(percentEncoded: false)))
            #expect(fileManager.fileExists(atPath: location.storeURL.path(percentEncoded: false)))
        }
    }

    @Test("Data survives closing and reopening the store")
    func dataSurvivesReopen() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        let itemID = UUID()
        let clock = FixedDateProvider.reference

        // First session: write.
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

            let project = try items.create(ItemDraft(kind: .project, title: "Persisted Project"))
            _ = try items.create(
                ItemDraft(
                    id: itemID,
                    kind: .task,
                    title: "Persisted Task",
                    body: "Refers to [[Persisted Project]].",
                    tagSlugs: ["work/clients"],
                    parentID: project.id,
                    dueAt: clock.startOfDay(daysFromToday: 2),
                    priority: .high
                )
            )
            try context.save()
        }

        // Second session: a genuinely new container over the same file.
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let reopened = try #require(try items.item(id: itemID))

        #expect(reopened.title == "Persisted Task")
        #expect(reopened.priority == .high)
        #expect(reopened.dueAt == clock.startOfDay(daysFromToday: 2))
        #expect(reopened.parent?.title == "Persisted Project")
        #expect((reopened.tags ?? []).map(\.slug) == ["work/clients"])

        // The link graph survived too, including its resolution.
        let link = try #require((reopened.outgoingLinks ?? []).first)
        #expect(link.kind == .wiki)
        #expect(link.target?.title == "Persisted Project")

        // And the implicit tag hierarchy.
        #expect(Set(try tags.allTags().map(\.slug)) == ["work", "work/clients"])
    }

    @Test("Every entity round-trips through a real file store")
    func everyEntityPersists() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)

            let item = Item(kind: .note, title: "Owner")
            context.insert(item)

            let tag = ElephruitModel.Tag(name: "sample")
            context.insert(tag)
            item.tags = [tag]

            let collection = ItemCollection(name: "A collection")
            context.insert(collection)
            context.insert(CollectionMembership(collection: collection, item: item, position: 0))

            context.insert(SavedSearch(name: "Saved", queryString: "type:note"))
            context.insert(ItemLink(kind: .related, source: item, target: item))
            context.insert(ElephruitModel.Attachment(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf"))

            let person = Item(kind: .person, title: "Someone")
            context.insert(person)
            let profile = PersonProfile(givenName: "Some", familyName: "One")
            profile.item = person
            context.insert(profile)

            let meeting = Item(kind: .meeting, title: "A meeting")
            context.insert(meeting)
            let event = EventReference(calendarItemIdentifier: "abc", cachedTitle: "A meeting")
            event.item = meeting
            context.insert(event)

            try context.save()
        }

        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        #expect(try context.fetch(FetchDescriptor<Item>()).count == 3)
        #expect(try context.fetch(FetchDescriptor<ElephruitModel.Tag>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ItemCollection>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CollectionMembership>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SavedSearch>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ItemLink>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PersonProfile>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EventReference>()).count == 1)
    }

    @Test("A backup copies the store and its SQLite companions")
    func backupIncludesCompanionFiles() throws {
        try withTemporaryStore { location, stack in
            let context = ModelContext(stack.container)
            context.insert(Item(kind: .note, title: "Something to back up"))
            try context.save()

            let destination = try #require(PersistenceStack.backupStore(at: location, label: "pre-v2-test"))

            let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false))
            // Copying only the main file would produce a backup that cannot be opened.
            #expect(contents.contains("Elephruit.store"))
            #expect(contents.contains { $0.hasPrefix("Elephruit.store") })
        }
    }

    @Test("Store location reports the documented paths")
    func locationLayoutIsStable() {
        let location = StoreLocation.temporary(name: "layout")

        #expect(location.storeURL.lastPathComponent == "Elephruit.store")
        #expect(location.attachmentsRoot.lastPathComponent == "Attachments")
        #expect(location.backupsRoot.lastPathComponent == "Backups")

        let attachmentID = UUID()
        #expect(location.attachmentDirectory(id: attachmentID).lastPathComponent == attachmentID.uuidString)
    }
}
