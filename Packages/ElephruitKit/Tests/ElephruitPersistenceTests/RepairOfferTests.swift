import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The repair is *offered*, never performed on the user's behalf.
///
/// This is the standing constraint — suggestions and recovery states never decide anything on their
/// own — applied to the one operation that cannot be undone by hand. Opening a library must change
/// nothing; a dry run says what *would* change; and only an explicit action changes it.
@MainActor
@Suite("Containment repair is offered, not imposed", .serialized)
struct RepairOfferTests {
    /// A store in the pre-restriction shape, written directly because the repository would now refuse
    /// these relationships.
    private func makeLegacyStore(_ location: StoreLocation, noteCount: Int = 3) throws {
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        let project = Item(kind: .project, title: "Q3 Launch")
        project.refreshSearchText()
        context.insert(project)

        for index in 1...noteCount {
            let note = Item(kind: .note, title: "Note \(index)", body: "Body \(index)")
            note.refreshSearchText()
            note.parent = project
            context.insert(note)
        }
        try context.save()
    }

    @Test("Opening a legacy library changes nothing")
    func openingIsNonDestructive() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeLegacyStore(location)

        // Reopen, exactly as the app does at launch.
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let items = try context.fetch(FetchDescriptor<Item>())

        let stillContained = items.filter { $0.kind == .note && $0.parent != nil }
        #expect(stillContained.count == 3, "Launching must not migrate anything")
        #expect(items.allSatisfy { $0.filedUnderContainers().isEmpty }, "No filings were invented")
    }

    @Test("A dry run reports what would change, and changes nothing")
    func planIsAPreview() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeLegacyStore(location)
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        let report = try ContainmentRepair.plan(in: context)
        #expect(report.isDryRun)
        #expect(report.conversions.count == 3)

        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(items.count { $0.parent != nil } == 3, "The preview wrote nothing")
    }

    @Test("The offer appears only when there is something to do")
    func offerIsConditional() throws {
        // A library created after the change has nothing to convert and should never see the banner.
        let modern = try StoreFixture()
        let project = try modern.makeProject(title: "Q3 Launch")
        let note = try modern.makeNote(title: "Positioning")
        try modern.items.fileItem(note, under: project)

        let report = try ContainmentRepair.plan(in: modern.context)
        #expect(report.hasWork == false)
        #expect(report.unresolved.isEmpty)
    }

    @Test("Applying it converts, and the library keeps working")
    func applyingWorks() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeLegacyStore(location)
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)

        let report = try ContainmentRepair.apply(in: context)
        #expect(report.conversions.count == 3)
        #expect(report.isDryRun == false)

        let items = try context.fetch(FetchDescriptor<Item>())
        let notes = items.filter { $0.kind == .note }

        #expect(notes.allSatisfy { $0.parent == nil })
        #expect(notes.allSatisfy { $0.filedUnderContainers().count == 1 })

        // Every note is still valid and therefore still editable — an illegal parent would have
        // failed validation on the next save and left it stuck.
        #expect(notes.allSatisfy { ItemValidator.isValid($0) })

        let project = try #require(items.first { $0.kind == .project })
        #expect(project.filedItems().count == 3)
    }

    @Test("It survives a close and reopen")
    func conversionPersists() throws {
        let location = StoreLocation.temporary()
        defer { location.removeForTesting() }

        try makeLegacyStore(location)

        do {
            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let context = ModelContext(stack.container)
            try ContainmentRepair.apply(in: context)
        }

        // A genuinely new container over the same file.
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let context = ModelContext(stack.container)
        let items = try context.fetch(FetchDescriptor<Item>())
        let project = try #require(items.first { $0.kind == .project })

        #expect(project.filedItems().count == 3)
        #expect(items.filter { $0.kind == .note }.allSatisfy { $0.parent == nil })
    }

    /// **A2-3.**
    @Test("Inbox holds no containers, and no headings")
    func inboxExcludesStructure() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "An unfiled thought")
        _ = try fixture.makeTask(title: "An unfiled task")
        _ = try fixture.makeProject(title: "A top-level project")
        _ = try fixture.makeArea(title: "A top-level area")
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "A loose heading"))

        let inbox = try fixture.items.items(matching: .inbox())

        #expect(inbox.count == 2)
        #expect(!inbox.contains { $0.kind == .project })
        #expect(!inbox.contains { $0.kind == .area })
        #expect(!inbox.contains { $0.kind == .heading })
    }

    @Test("A converted note leaves the Inbox, because a filing is a home")
    func filedNotesLeaveTheInbox() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")
        let note = try fixture.makeNote(title: "Unfiled for now")

        #expect(try fixture.items.items(matching: .inbox()).contains { $0.id == note.id })

        try fixture.items.fileItem(note, under: project)

        // Filing is what "processed" means — the same as acquiring a tag or a parent used to be.
        let inbox = try fixture.items.items(matching: .inbox())
        #expect(!inbox.contains { $0.id == note.id })
    }
}

/// The badge and the list must always agree. A count of 3 over a list of 2 reads as a bug in the app
/// rather than in the query, and it destroys trust in every other number the sidebar shows.
@MainActor
@Suite("Inbox count agrees with the Inbox list", .serialized)
struct InboxAgreementTests {
    private func assertAgreement(_ fixture: StoreFixture) async throws {
        let counts = CountsService(container: fixture.stack.container, dateProvider: fixture.dateProvider)
        await counts.refreshAndWait()

        let listed = try fixture.items.items(matching: .inbox()).count
        #expect(counts.counts.inbox == listed, "badge \(counts.counts.inbox) vs list \(listed)")
    }

    @Test("They agree on an empty library")
    func emptyLibrary() async throws {
        try await assertAgreement(StoreFixture())
    }

    @Test("They agree with unfiled captures")
    func unfiledCaptures() async throws {
        let fixture = try StoreFixture()
        for index in 1...4 {
            _ = try fixture.makeNote(title: "Capture \(index)")
        }
        try await assertAgreement(fixture)
    }

    @Test("They agree once things acquire a home")
    func mixedHomes() async throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeNote(title: "Unfiled")
        _ = try fixture.makeNote(title: "Tagged", tags: ["work"])

        let filed = try fixture.makeNote(title: "Filed")
        try fixture.items.fileItem(filed, under: project)

        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Contained", parentID: project.id))
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "A heading", parentID: project.id))

        try await assertAgreement(fixture)
    }

    @Test("They agree after trashing and archiving")
    func lifecycleStates() async throws {
        let fixture = try StoreFixture()

        let trashed = try fixture.makeNote(title: "Trashed")
        let archived = try fixture.makeNote(title: "Archived")
        _ = try fixture.makeNote(title: "Live")

        try fixture.items.moveToTrash(trashed)
        try fixture.items.setArchived(archived, true)

        try await assertAgreement(fixture)
    }

    @Test("They agree after a containment repair")
    func afterRepair() async throws {
        let fixture = try StoreFixture()

        // Pre-restriction shape, written directly.
        let project = Item(kind: .project, title: "Legacy")
        project.refreshSearchText()
        fixture.context.insert(project)
        for index in 1...3 {
            let note = Item(kind: .note, title: "Legacy note \(index)")
            note.refreshSearchText()
            note.parent = project
            fixture.context.insert(note)
        }
        try fixture.context.save()

        try await assertAgreement(fixture)

        try ContainmentRepair.apply(in: fixture.context)
        try await assertAgreement(fixture)
    }
}
