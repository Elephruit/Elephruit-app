import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// ADR 0003's own unbuilt consequences, finally built.
///
/// The decision to put bytes on disk and metadata in the store named two failure modes — a row with
/// no file, and a file with no row — and specified "a startup integrity pass that reports orphans in
/// both directions and offers recovery" as the mitigation. For three phases that mitigation was a
/// paragraph. These tests are what makes it a fact.
///
/// Real store, real filesystem. In-memory would prove nothing about files that go missing.
@MainActor
@Suite("Attachment reconciliation", .serialized)
struct AttachmentReconciliationTests {
    @MainActor
    private struct Fixture {
        let location: StoreLocation
        let context: ModelContext
        let items: SwiftDataItemRepository
        let attachments: AttachmentStore
        let reconciliation: AttachmentReconciliation
        let clock: FixedDateProvider
        let scratch: URL

        init(clock: FixedDateProvider = .reference) throws {
            self.clock = clock
            location = StoreLocation.temporary()
            try location.createDirectories()

            let stack = try PersistenceStack.open(mode: .onDisk(location))
            context = ModelContext(stack.container)
            let tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
            attachments = AttachmentStore(context: context, location: location, dateProvider: clock)
            reconciliation = AttachmentReconciliation(
                context: context, location: location, dateProvider: clock
            )

            scratch = location.root.deletingLastPathComponent()
                .appending(path: "Scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        }

        func makeFile(_ name: String, contents: String = "bytes") throws -> URL {
            let url = scratch.appending(path: name, directoryHint: .notDirectory)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        var removedRoot: URL {
            location.attachmentsRoot.appending(
                path: AttachmentReconciliation.deletionFolderName, directoryHint: .isDirectory
            )
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        func cleanUp() { location.removeForTesting() }
    }

    // MARK: - A clean library

    @Test("A library with nothing wrong reports nothing to do")
    func cleanLibraryIsQuiet() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        _ = try fixture.attachments.attachCopy(of: try fixture.makeFile("report.txt"), to: note)

        let report = try fixture.reconciliation.plan()
        #expect(report.isEmpty)
        #expect(report.summary == "Nothing to tidy")
    }

    // MARK: - Orphans

    @Test("A folder no attachment claims is found")
    func orphanedFoldersAreFound() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let stray = fixture.location.attachmentDirectory(id: UUID())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "left behind".write(
            to: stray.appending(path: "ghost.txt", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        let report = try fixture.reconciliation.plan()
        #expect(report.orphanedFolders == [stray.lastPathComponent])
        #expect(report.totalBytesRecoverable > 0)
    }

    /// A file the app cannot account for is exactly the file it should be least confident about
    /// destroying.
    @Test("Applying moves an orphan aside rather than deleting it")
    func orphansAreMovedNotDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let id = UUID()
        let stray = fixture.location.attachmentDirectory(id: id)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "left behind".write(
            to: stray.appending(path: "ghost.txt", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        try fixture.reconciliation.apply(try fixture.reconciliation.plan())

        #expect(fixture.exists(stray) == false)
        let moved = fixture.removedRoot
            .appending(path: AttachmentReconciliation.removalFolderName(id: id, at: fixture.clock.now), directoryHint: .isDirectory)
            .appending(path: "ghost.txt", directoryHint: .notDirectory)
        #expect(fixture.exists(moved), "the bytes were destroyed rather than set aside")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "left behind")
    }

    @Test("A dry run writes nothing")
    func planningIsReadOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let stray = fixture.location.attachmentDirectory(id: UUID())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        _ = try fixture.reconciliation.plan()
        #expect(fixture.exists(stray), "a dry run moved something")
    }

    @Test("Running twice finds nothing the second time")
    func applyingIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let stray = fixture.location.attachmentDirectory(id: UUID())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        try fixture.reconciliation.apply(try fixture.reconciliation.plan())
        let second = try fixture.reconciliation.plan()
        #expect(second.orphanedFolders.isEmpty)
    }

    // MARK: - Missing files

    @Test("A row whose bytes have gone is marked, never deleted")
    func missingFilesAreMarkedNotRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let attachment = try fixture.attachments.attachCopy(of: try fixture.makeFile("report.txt"), to: note)

        // Something outside Elephruit removed the bytes.
        try FileManager.default.removeItem(at: fixture.location.attachmentDirectory(id: attachment.id))

        let report = try fixture.reconciliation.plan()
        #expect(report.missingFiles == [attachment.id])

        try fixture.reconciliation.apply(report)

        // The row is the last record that the file ever existed, and its name is what lets someone
        // go and look for it.
        #expect(try fixture.context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).count == 1)
        #expect(attachment.isReferenceLost)
        #expect(attachment.filename == "report.txt")
    }

    @Test("A referenced file living elsewhere is not reported as missing")
    func referencesAreNotOrphans() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a reference"))
        _ = try fixture.attachments.attachReference(to: try fixture.makeFile("elsewhere.txt"), from: note)

        let report = try fixture.reconciliation.plan()
        #expect(report.missingFiles.isEmpty, "a reference has no managed bytes to be missing")
        #expect(report.orphanedFolders.isEmpty)
    }

    // MARK: - The grace period

    @Test("Removing an attachment sets its bytes aside rather than destroying them")
    func removalIsGraceful() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let attachment = try fixture.attachments.attachCopy(
            of: try fixture.makeFile("report.txt", contents: "the numbers"),
            to: note
        )
        let id = attachment.id

        try fixture.attachments.remove(attachment)

        // Gone from where it was — the existing guarantee.
        #expect(fixture.exists(fixture.location.attachmentDirectory(id: id)) == false)
        #expect(try fixture.context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).isEmpty)

        // But recoverable.
        let held = fixture.removedRoot
            .appending(path: AttachmentReconciliation.removalFolderName(id: id, at: fixture.clock.now), directoryHint: .isDirectory)
            .appending(path: "report.txt", directoryHint: .notDirectory)
        #expect(try String(contentsOf: held, encoding: .utf8) == "the numbers")
    }

    @Test("Bytes inside the grace period are held, not swept")
    func recentDeletionsAreHeld() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let attachment = try fixture.attachments.attachCopy(of: try fixture.makeFile("report.txt"), to: note)
        let id = attachment.id
        try fixture.attachments.remove(attachment)

        let report = try fixture.reconciliation.plan()
        #expect(report.pendingDeletion.count == 1)
        #expect(report.pendingDeletion.first?.hasPrefix(id.uuidString) == true)
        #expect(report.expiredDeletions.isEmpty)

        try fixture.reconciliation.apply(report)
        #expect(fixture.exists(fixture.removedRoot.appending(path: AttachmentReconciliation.removalFolderName(id: id, at: fixture.clock.now), directoryHint: .isDirectory)))
    }

    /// The clock moves, not the files — so the sweep is tested rather than waited for.
    @Test("Bytes past the grace period are swept")
    func expiredDeletionsAreSwept() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let attachment = try fixture.attachments.attachCopy(of: try fixture.makeFile("report.txt"), to: note)
        let id = attachment.id
        try fixture.attachments.remove(attachment)

        let later = FixedDateProvider(
            now: fixture.clock.now.addingTimeInterval(AttachmentReconciliation.gracePeriod + 60),
            calendar: fixture.clock.calendar
        )
        let future = AttachmentReconciliation(
            context: fixture.context, location: fixture.location, dateProvider: later
        )

        let report = try future.plan()
        #expect(report.expiredDeletions.count == 1)
        #expect(report.expiredDeletions.first?.hasPrefix(id.uuidString) == true)

        try future.apply(report)
        #expect(fixture.exists(fixture.removedRoot.appending(path: AttachmentReconciliation.removalFolderName(id: id, at: fixture.clock.now), directoryHint: .isDirectory)) == false)
    }

    @Test("The grace folder is not itself reported as an orphan")
    func theGraceFolderIsNotAnOrphan() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let note = try fixture.items.create(ItemDraft(kind: .note, title: "With a file"))
        let attachment = try fixture.attachments.attachCopy(of: try fixture.makeFile("report.txt"), to: note)
        try fixture.attachments.remove(attachment)

        let report = try fixture.reconciliation.plan()
        #expect(report.orphanedFolders.isEmpty)
    }
}
