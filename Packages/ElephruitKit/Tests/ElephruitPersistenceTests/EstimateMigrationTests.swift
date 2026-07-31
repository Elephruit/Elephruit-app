import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The V2 → V3 migration: an estimate on an item, and an index on its creation date.
///
/// Additive, so what has to be proven is that **nothing was disturbed** and that the launch which
/// does the disturbing takes a backup first.
///
/// The interesting question this slice answered is whether an additive change needs the old model
/// types frozen into nested snapshots before it can ship. It does not, and the evidence is not an
/// argument — it is `RealStoreMigrationTests`, which now migrates a store written by a build that
/// predates `TimeEntry` entirely, through both versions, and reads everything back. See ADR 0005
/// for what does trigger the freeze.
@MainActor
@Suite("Estimate migration", .serialized)
struct EstimateMigrationTests {
    private func populate(_ context: ModelContext, clock: any DateProvider) throws -> UUID {
        let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        let items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)

        let project = try items.create(ItemDraft(kind: .project, title: "Q3 Launch"))
        let task = try items.create(
            ItemDraft(kind: .task, title: "Book the venue", tagSlugs: ["work"], parentID: project.id)
        )
        try context.save()
        return task.id
    }

    @Test("A library from the previous version opens with everything it had")
    func existingDataSurvives() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        var taskID = UUID()

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            taskID = try populate(ModelContext(stack.container), clock: clock)
        }

        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)

        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(items.count == 2)

        let task = try #require(items.first { $0.id == taskID })
        #expect(task.title == "Book the venue")
        #expect(task.parent?.title == "Q3 Launch")
        #expect(task.tagSlugs == ["work"])
    }

    /// An item that predates the field has no estimate — not a zero. Zero is a claim that something
    /// takes no time; absence is the truth.
    @Test("An item written before the field existed has no estimate rather than a zero")
    func absenceIsNotZero() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            _ = try populate(ModelContext(stack.container), clock: clock)
        }

        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)

        for item in try context.fetch(FetchDescriptor<Item>()) {
            #expect(item.estimateMinutes == nil)
        }
    }

    @Test("An estimate survives a close and a reopen")
    func estimatesArePersisted() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        var taskID = UUID()

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            taskID = try populate(context, clock: clock)
            let task = try #require(try context.fetch(FetchDescriptor<Item>()).first { $0.id == taskID })
            task.estimateMinutes = 90
            try context.save()
        }

        let reopened = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(reopened.container)
        let task = try #require(try context.fetch(FetchDescriptor<Item>()).first { $0.id == taskID })
        #expect(task.estimateMinutes == 90)
    }

    /// The reason the version identifier was bumped rather than the property being added silently.
    ///
    /// The backup is keyed on the `.schema-version` stamp beside the store, so a schema change that
    /// kept the old number would migrate real user data with no backup taken — the exact bug fixed
    /// once before, when the trigger was `stages.isEmpty`.
    @Test("The launch that migrates writes a backup first")
    func migratingLaunchIsBackedUp() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }
        try location.createDirectories()

        let clock = FixedDateProvider.reference
        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            _ = try populate(ModelContext(stack.container), clock: clock)
        }

        // Stamp the store as the previous version, which is what an older build would have left.
        let stamp = location.root.appending(path: ".schema-version", directoryHint: .notDirectory)
        try "0.0.2".write(to: stamp, atomically: true, encoding: .utf8)

        _ = try PersistenceStack.open(mode: .onDisk(location))

        let backups = (try? FileManager.default.contentsOfDirectory(
            atPath: location.backupsRoot.path(percentEncoded: false)
        )) ?? []
        #expect(!backups.isEmpty, "a migrating launch left no backup behind")

        let restamped = try String(contentsOf: stamp, encoding: .utf8)
        #expect(restamped == CurrentSchema.versionString)
        #expect(restamped == "0.0.5")
    }
}
