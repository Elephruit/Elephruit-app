import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

// `Tag` and `Attachment` are also names in the swift-testing module, so the model types are
// qualified in this file. App code never imports Testing and so never sees the ambiguity.

/// Verifies risk **R1** from `docs/08-risks.md`: that `SchemaV1` satisfies every constraint
/// CloudKit mirroring imposes, *before* there is data in the wild to migrate.
///
/// Sync ships in Phase 4. These tests exist now because retrofitting these constraints onto
/// a populated store is a data migration, and because the failures they prevent only appear
/// at container-open time against a real iCloud account — which is the worst possible place
/// to discover them.
@MainActor
@Suite("Schema: CloudKit mirroring compliance")
struct SchemaComplianceTests {
    @Test("Every entity can be created with no arguments")
    func everyEntityHasCompleteDefaults() throws {
        // CloudKit requires every attribute to be optional or to have a default value. If
        // an entity can be constructed with nothing supplied, that requirement is met.
        let fixture = try StoreFixture()
        let context = fixture.context

        context.insert(Item())
        context.insert(ElephruitModel.Tag(name: "untitled"))
        context.insert(ItemLink())
        context.insert(ElephruitModel.Attachment())
        context.insert(ItemCollection())
        context.insert(CollectionMembership())
        context.insert(SavedSearch())
        context.insert(PersonProfile())
        context.insert(EventReference())

        try context.save()

        // Reading each back proves the store accepted the defaults rather than silently
        // rejecting a row.
        let fresh = fixture.freshContext()
        #expect(try fresh.fetch(FetchDescriptor<Item>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<ElephruitModel.Tag>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<ItemLink>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<ElephruitModel.Attachment>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<ItemCollection>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<CollectionMembership>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<SavedSearch>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<PersonProfile>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<EventReference>()).count == 1)
    }

    @Test("The schema declares every entity")
    func schemaCoversEveryEntity() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })

        // An entity missing from the schema is invisible to migrations and to CloudKit, and
        // the failure mode is data that quietly does not sync.
        #expect(names == [
            "Item", "Tag", "ItemLink", "Attachment", "ItemCollection",
            "CollectionMembership", "SavedSearch", "PersonProfile", "EventReference",
        ])
    }

    @Test("Duplicate identifiers are rejected by the repository, not by the store")
    func duplicateIdentifiersAreRejected() throws {
        // CloudKit forbids `@Attribute(.unique)`, so `Item.id` uniqueness has to be enforced
        // in code. This is the test that keeps that promise honest.
        let fixture = try StoreFixture()
        let sharedID = UUID()

        _ = try fixture.items.create(ItemDraft(id: sharedID, kind: .note, title: "First"))

        #expect(throws: AppError.duplicateIdentifier(id: sharedID)) {
            try fixture.items.create(ItemDraft(id: sharedID, kind: .note, title: "Second"))
        }

        let all = try fixture.items.items(matching: .everything())
        #expect(all.count == 1)
        #expect(all.first?.title == "First")
    }

    /// Pinned to a literal rather than derived from `CurrentSchema`, so bumping the version is a
    /// deliberate act with a failing test attached rather than something that can happen quietly.
    /// The stamp beside the store is compared against this string, and the stamp is what decides
    /// whether a migrating launch takes a backup.
    @Test("Schema version is reported for archives and diagnostics")
    func schemaVersionIsReadable() {
        #expect(CurrentSchema.versionString == "0.0.7")
    }

    @Test("Every released schema stays in source, with a stage between each")
    func migrationPathIsComplete() {
        // A released version removed from `schemas` makes its migration path uncompilable and
        // untestable, and any store still on it unopenable. The rule in docs/05 is that they stay
        // forever; this is what enforces it.
        #expect(ElephruitMigrationPlan.stages.count == max(0, ElephruitMigrationPlan.schemas.count - 1))

        let versions = ElephruitMigrationPlan.schemas.map { $0.versionIdentifier }
        #expect(versions == versions.sorted(), "Versions must be declared in order")
        #expect(versions.last == CurrentSchema.versioned.versionIdentifier, "The last must be the current one")

        // Every declared version must have a *distinct* shape. Two that do not produce the same
        // Core Data checksum, and a plan holding both throws "Duplicate version checksums detected"
        // on any launch that needs migrating — which is precisely what shipped and crashed.
        let entitySets = ElephruitMigrationPlan.schemas.map { versioned in
            Set(Schema(versionedSchema: versioned).entities.map(\.name))
        }
        for (index, left) in entitySets.enumerated() {
            for right in entitySets[(index + 1)...] {
                #expect(left != right, "Two schema versions describe the same shape, which cannot migrate")
            }
        }
    }

    @Test("An unknown stored kind reads as reference without rewriting the row")
    func unknownKindDegradesGracefully() throws {
        // Forward compatibility: a store written by a newer build may contain kinds this
        // build has never heard of. It must display, and it must not be silently rewritten.
        let fixture = try StoreFixture()

        let item = Item()
        item.kindRaw = "habit"  // A kind from some hypothetical future version.
        fixture.context.insert(item)

        let refetched = try fixture.requireItem(id: item.id)
        #expect(refetched.kind == .reference, "Unknown kinds display as reference")
        #expect(refetched.kindRaw == "habit", "The original value must survive untouched")
    }
}

/// The invariants from `docs/04-domain-model.md`, each asserted directly.
@MainActor
@Suite("Item invariants")
struct ItemValidationTests {
    @Test("A note cannot hold a due date")
    func noteRejectsDueDate() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "Just a note")

        #expect(throws: AppError.self) {
            try fixture.items.update(note) { $0.dueAt = Date() }
        }
    }

    @Test("Marking completed without a completion date is refused")
    func completedWithoutDateIsRefused() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Do the thing")

        #expect(throws: AppError.self) {
            try fixture.items.update(task) { $0.status = .completed }
        }
    }

    @Test("A completion date without the matching status is refused")
    func completionDateWithoutStatusIsRefused() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Do the thing")

        #expect(throws: AppError.self) {
            try fixture.items.update(task) { $0.completedAt = Date() }
        }
    }

    @Test("An item is still usable after a rejected edit")
    func itemRecoversAfterRejectedEdit() throws {
        // A validation failure rolls the context back. The user's next action must work — an
        // error dialogue that leaves the object in a broken state is worse than the error.
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Original")

        #expect(throws: AppError.self) {
            try fixture.items.update(task) { $0.status = .completed }
        }

        // The rejected change left nothing behind.
        #expect(task.status == .open)
        #expect(task.completedAt == nil)

        // And a valid edit still lands.
        try fixture.items.update(task) { $0.title = "Renamed after recovery" }
        #expect(try fixture.requireItem(id: task.id).title == "Renamed after recovery")
    }

    @Test("Toggling completion sets both halves together")
    func toggleCompletionKeepsInvariant() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Do the thing")

        try fixture.items.toggleCompletion(task)
        #expect(task.status == .completed)
        #expect(task.completedAt != nil)

        try fixture.items.toggleCompletion(task)
        #expect(task.status == .open)
        #expect(task.completedAt == nil)
    }

    @Test("A note cannot be completed at all")
    func notesCannotBeCompleted() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "A note")

        #expect(throws: AppError.self) {
            try fixture.items.toggleCompletion(note)
        }
    }

    @Test("Containment follows the declared hierarchy")
    func containmentRespectsKindRules() throws {
        let fixture = try StoreFixture()

        let area = try fixture.makeArea(title: "Work")
        let project = try fixture.makeProject(title: "Q3 Launch")
        let task = try fixture.makeTask(title: "Draft the brief")

        // Area ▸ Project ▸ Task is legal.
        try fixture.items.setParent(project, to: area)
        try fixture.items.setParent(task, to: project)
        #expect(task.parent?.id == project.id)
        #expect(project.parent?.id == area.id)

        // A task cannot contain a project.
        #expect(throws: AppError.self) {
            try fixture.items.setParent(project, to: task)
        }

        // An area cannot sit inside anything.
        #expect(throws: AppError.self) {
            try fixture.items.setParent(area, to: project)
        }
    }

    @Test("Cycles are refused, directly and transitively")
    func cyclesAreRefused() throws {
        let fixture = try StoreFixture()

        let outer = try fixture.makeTask(title: "Outer")
        let middle = try fixture.makeTask(title: "Middle")
        let inner = try fixture.makeTask(title: "Inner")

        try fixture.items.setParent(middle, to: outer)
        try fixture.items.setParent(inner, to: middle)

        #expect(throws: AppError.self) {
            try fixture.items.setParent(outer, to: outer)  // self
        }
        #expect(throws: AppError.self) {
            try fixture.items.setParent(outer, to: inner)  // transitive
        }

        // The graph is unchanged by the refusals.
        #expect(outer.parent == nil)
        #expect(inner.parent?.id == middle.id)
    }

    @Test("A start date after its due date is refused")
    func inverseDateRangeIsRefused() throws {
        let fixture = try StoreFixture()
        let task = try fixture.makeTask(title: "Task", dueAt: Date())

        #expect(throws: AppError.self) {
            try fixture.items.update(task) { subject in
                subject.startAt = Date().addingTimeInterval(86_400 * 7)
            }
        }
    }

    @Test("Changing kind clears what the new kind cannot hold, and says what it cleared")
    func changingKindConformsFields() throws {
        let fixture = try StoreFixture()

        let task = try fixture.makeTask(title: "Was a task", dueAt: Date(), priority: .high)
        try fixture.items.toggleCompletion(task)

        let cleared = try fixture.items.setKind(task, to: .note)

        #expect(task.kind == .note)
        #expect(task.dueAt == nil)
        #expect(task.priority == .normal)
        #expect(task.status == .none)
        #expect(task.completedAt == nil)
        #expect(cleared.contains("due date"))
        #expect(cleared.contains("priority"))
        #expect(cleared.contains("completion"))
    }

    @Test("Search text is refreshed on every mutation path")
    func searchTextStaysCurrent() throws {
        let fixture = try StoreFixture()

        let note = try fixture.makeNote(title: "Original Title", body: "Original body", tags: ["work"])
        var stored = try fixture.requireItem(id: note.id)
        #expect(stored.searchText.contains("original title"))
        #expect(stored.searchText.contains("work"))

        try fixture.items.update(note) { $0.title = "Renamed Entirely" }
        stored = try fixture.requireItem(id: note.id)
        #expect(stored.searchText.contains("renamed entirely"))
        #expect(!stored.searchText.contains("original title"))
    }

    @Test("Every kind's supported fields are declared")
    func everyKindDeclaresItsFields() {
        // Guards against the wide-row failure mode in R2: a kind with no declaration would
        // silently permit every field.
        for kind in ItemKind.allCases where kind.participatesInContentViews {
            #expect(
                kind.supportedFields.contains(.body),
                "\(kind.rawValue) is content, so it should declare a body"
            )
            #expect(
                kind.supportedFields.contains(.tags),
                "\(kind.rawValue) is content, so it should be taggable"
            )
        }

        // A structural kind carries nothing but its title, its order, and what it contains.
        for kind in ItemKind.allCases where !kind.participatesInContentViews {
            #expect(kind.supportedFields == [.children], "\(kind.rawValue) should carry nothing else")
            #expect(kind.appearsInInbox == false)
            #expect(kind.countsAsWork == false)
        }

        // Status-bearing kinds and the status field must agree.
        for kind in ItemKind.allCases {
            #expect(kind.supportsStatus == kind.supportedFields.contains(.status))
        }
    }
}
