import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The V2 → V3 migration: adding time tracking.
///
/// The change is additive — one new entity and one relationship to it — so what has to be proven is
/// not that data was *transformed* correctly but that **nothing was disturbed**: a real library
/// opens under the new schema with everything it had, and time tracking works afterwards.
///
/// The limit on this, stated plainly here as well as on `SchemaV3`: the versioned schemas reference
/// the live model types rather than frozen copies, so the "V2" store below is built with V3's
/// `Item`. What these tests genuinely verify is that a populated store survives a close, a reopen
/// through the migration plan, and a second reopen. What they do not verify is a byte-level shape
/// migration from a store written by a build that predates `TimeEntry`. That is affordable only
/// because the change adds and never rewrites, and a backup is written before any migrating open
/// regardless.
@MainActor
@Suite("Time tracking migration", .serialized)
struct TimeMigrationTests {
    /// A library with something of every shape in it, so a migration that quietly dropped one
    /// relationship would be caught rather than assumed away.
    private func populate(_ context: ModelContext, clock: any DateProvider) throws -> [String: UUID] {
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let project = try items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        let heading = try items.create(ItemDraft(kind: .heading, title: "Before launch", parentID: project.id))
        let task = try items.create(
            ItemDraft(kind: .task, title: "Book the venue", tagSlugs: ["work"], parentID: heading.id)
        )
        let note = try items.create(ItemDraft(kind: .note, title: "Venue options", body: "Three candidates."))
        let person = try items.create(ItemDraft(kind: .person, title: "Ana Ferreira"))

        try items.fileItem(note, under: project)
        context.insert(ItemLink(kind: .mentions, source: note, target: person, createdAt: clock.now))

        let collection = ItemCollection(name: "Reading")
        context.insert(collection)
        context.insert(SavedSearch(name: "Open work", queryString: "is:open tag:work"))

        try context.save()

        return [
            "project": project.id, "heading": heading.id, "task": task.id,
            "note": note.id, "person": person.id,
        ]
    }

    // A synthetic "previous version" test used to live here and has been removed, because it could
    // not do what its name claimed. The versioned schemas share live model types, and SwiftData
    // resolves each one's full entity graph — so a store built from `SchemaV1` already contains
    // `TimeEntry`, pulled in through `Item.timeEntries`. It needed no migration, so it exercised
    // none, while reading as coverage.
    //
    // `RealStoreMigrationTests` replaces it. That one migrates bytes written by an earlier build,
    // which is the only thing that reproduces the failure this suite missed.

    @Test("A populated library opens under the new schema with everything intact")
    func existingDataSurvives() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        var ids: [String: UUID] = [:]

        // Written, then fully closed.
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            ids = try populate(context, clock: clock)
        }

        // Reopened through the migration plan, exactly as a launch does.
        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)

        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(items.count == 5, "Every item survives")

        let taskID = try #require(ids["task"])
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate<Item> { $0.id == taskID })
        descriptor.fetchLimit = 1
        let task = try #require(try context.fetch(descriptor).first)

        #expect(task.parent?.kind == .heading, "Containment survives")
        #expect(task.tagSlugs == ["work"], "Tags survive")

        let noteID = try #require(ids["note"])
        var noteDescriptor = FetchDescriptor<Item>(predicate: #Predicate<Item> { $0.id == noteID })
        noteDescriptor.fetchLimit = 1
        let note = try #require(try context.fetch(noteDescriptor).first)

        #expect(note.filedUnderContainers().count == 1, "Filing links survive")
        #expect(note.outgoingLinks.contains { $0.kind == .mentions }, "Mentions survive")

        #expect(try context.fetchCount(FetchDescriptor<SavedSearch>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ItemCollection>()) == 1)
    }

    @Test("Time tracking works on a library that predates it")
    func timeTrackingWorksAfterMigrating() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        var ids: [String: UUID] = [:]

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            ids = try populate(context, clock: clock)
        }

        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let time = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)

        #expect(try context.fetchCount(FetchDescriptor<TimeEntry>()) == 0,
                "A migrated library starts with no tracked time, not with something invented")

        let taskID = try #require(ids["task"])
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate<Item> { $0.id == taskID })
        descriptor.fetchLimit = 1
        let task = try #require(try context.fetch(descriptor).first)

        let entry = try time.start(item: task, description: "First session", tagSlugs: [])
        #expect(entry.isRunning)
        #expect(try time.runningEntry()?.id == entry.id)

        _ = try time.stopRunning(at: clock.now.addingTimeInterval(1_800))
        #expect(entry.duration() == 1_800)
        #expect(task.timeEntries.count == 1, "The inverse relationship is wired both ways")
    }

    @Test("Tracked time survives a relaunch")
    func trackedTimeIsDurable() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        let entryID: UUID

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            let time = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)

            let entry = try time.addManual(
                item: nil,
                description: "Deep work",
                startedAt: clock.now.addingTimeInterval(-3_600),
                endedAt: clock.now,
                tagSlugs: ["focus"]
            )
            entryID = entry.id
        }

        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let time = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)

        let entry = try #require(try time.entry(id: entryID))
        #expect(entry.duration() == 3_600)
        #expect(entry.entryDescription == "Deep work")
        #expect(entry.tagSlugs == ["focus"])
        #expect(entry.source == .manual)
    }

    @Test("A backup is written when the schema version has changed, and not otherwise")
    func migrationIsBackedUp() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            _ = try populate(ModelContext(stack.container), clock: clock)
        }

        // Reopening an already-current store must *not* churn out a backup on every launch.
        _ = try PersistenceStack.open(mode: .onDisk(location))
        let afterOrdinaryOpen = (try? FileManager.default.contentsOfDirectory(
            at: location.backupsRoot, includingPropertiesForKeys: nil
        )) ?? []
        #expect(afterOrdinaryOpen.isEmpty, "An open that migrates nothing has nothing to protect")

        // Now make the store look like one written by a different version, which is exactly what a
        // real upgrade is, and open it again.
        let stamp = location.root.appending(path: ".schema-version", directoryHint: .notDirectory)
        try "0.9.0".write(to: stamp, atomically: true, encoding: .utf8)

        _ = try PersistenceStack.open(mode: .onDisk(location))

        let backups = try FileManager.default.contentsOfDirectory(
            at: location.backupsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(backups.count == 1, "A migrating open with no backup has no way back")

        // And the backup is a store that opens, not just bytes on disk.
        let backup = try #require(backups.first)
        let restored = StoreLocation(
            root: backup,
            cachesRoot: location.cachesRoot.appending(path: "check", directoryHint: .isDirectory)
        )
        let stack = try PersistenceStack.open(mode: .onDisk(restored))
        #expect(try ModelContext(stack.container).fetchCount(FetchDescriptor<Item>()) == 5,
                "A backup nobody has opened is a hope, not a backup")
    }

    @Test("The stamp is only written after a successful open")
    func stampFollowsSuccess() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        #expect(PersistenceStack.lastOpenedSchemaVersion(at: location) == nil,
                "An untouched location claims nothing")

        _ = try PersistenceStack.open(mode: .onDisk(location))
        #expect(PersistenceStack.lastOpenedSchemaVersion(at: location) == CurrentSchema.versionString)
    }
}
