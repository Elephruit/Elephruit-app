import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import Foundation
import SwiftData
import Testing

/// A store populated with every entity type and every relationship, plus a second empty store to
/// import into. The point is to make "export is lossless" a test result rather than a claim —
/// risk **R11** in `docs/08-risks.md`.
@MainActor
struct TransferFixture {
    let stack: PersistenceStack
    let context: ModelContext
    let items: SwiftDataItemRepository
    let tags: SwiftDataTagRepository
    let exporter: Exporter
    let importer: Importer
    let clock = FixedDateProvider.reference

    init() throws {
        stack = try PersistenceStack.inMemory()
        context = ModelContext(stack.container)
        tags = SwiftDataTagRepository(context: context, dateProvider: clock)
        items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
        exporter = Exporter(items: items, context: context, dateProvider: clock)
        importer = Importer(items: items, tags: tags, context: context, dateProvider: clock)
    }

    /// Builds a library exercising every feature the archive is supposed to preserve.
    @discardableResult
    func populate() throws -> PopulatedGraph {
        let area = try items.create(ItemDraft(kind: .area, title: "Work"))

        let project = try items.create(
            ItemDraft(
                kind: .project,
                title: "Q3 Launch",
                body: "The brief for the launch.",
                tagSlugs: ["work/clients/acme"],
                parentID: area.id
            )
        )
        try items.update(project) { $0.colorName = "blue" }

        let openTask = try items.create(
            ItemDraft(
                kind: .task,
                title: "Draft the announcement",
                body: "Reference [[Q3 Launch]] and the positioning note.",
                tagSlugs: ["urgent"],
                parentID: project.id,
                dueAt: clock.startOfDay(daysFromToday: 3),
                priority: .high
            )
        )

        let doneTask = try items.create(
            ItemDraft(kind: .task, title: "Book the venue", parentID: project.id)
        )
        try items.toggleCompletion(doneTask)

        let recurringTask = try items.create(
            ItemDraft(kind: .task, title: "Weekly review", dueAt: clock.startOfDay(daysFromToday: 1))
        )
        try items.update(recurringTask) { subject in
            subject.recurrence = RecurrenceRule(frequency: .weekly, weekdays: [2], anchor: .schedule)
        }

        let note = try items.create(
            ItemDraft(
                kind: .note,
                title: "Positioning",
                body: "Links to [[Q3 Launch]] and to [[Something Unwritten]].",
                tagSlugs: ["work"]
            )
        )
        try items.update(note) { subject in
            subject.isFavorite = true
            subject.isPinned = true
            subject.userMetadata = ["client": .text("Acme"), "confidence": .number(0.8), "reviewed": .flag(true)]
        }

        let bookmark = try items.create(
            ItemDraft(
                kind: .bookmark,
                title: "Reference article",
                tagSlugs: ["reading"],
                source: ItemSource(kind: .quickCapture, url: URL(string: "https://example.com/article")),
                url: URL(string: "https://example.com/article")
            )
        )

        let archived = try items.create(ItemDraft(kind: .note, title: "Old note"))
        try items.setArchived(archived, true)

        let trashed = try items.create(ItemDraft(kind: .note, title: "Trashed note"))
        try items.moveToTrash(trashed)

        // A deliberate, non-text link.
        context.insert(ItemLink(kind: .related, source: note, target: bookmark, createdAt: clock.now))

        // An ordered collection — the thing a tag cannot be.
        let collection = ItemCollection(name: "Launch reading", summary: "In order.", symbolName: "book", createdAt: clock.now)
        context.insert(collection)
        context.insert(CollectionMembership(collection: collection, item: bookmark, position: 0, note: "Read first", addedAt: clock.now))
        context.insert(CollectionMembership(collection: collection, item: note, position: 1024, addedAt: clock.now))

        let savedSearch = SavedSearch(
            name: "Urgent work",
            queryString: "tag:urgent is:open type:task",
            symbolName: "flame",
            createdAt: clock.now
        )
        context.insert(savedSearch)

        try context.save()

        return PopulatedGraph(
            areaID: area.id,
            projectID: project.id,
            openTaskID: openTask.id,
            doneTaskID: doneTask.id,
            recurringTaskID: recurringTask.id,
            noteID: note.id,
            bookmarkID: bookmark.id,
            archivedID: archived.id,
            trashedID: trashed.id,
            collectionID: collection.id,
            savedSearchID: savedSearch.id
        )
    }

    struct PopulatedGraph {
        let areaID: UUID
        let projectID: UUID
        let openTaskID: UUID
        let doneTaskID: UUID
        let recurringTaskID: UUID
        let noteID: UUID
        let bookmarkID: UUID
        let archivedID: UUID
        let trashedID: UUID
        let collectionID: UUID
        let savedSearchID: UUID
    }

    func item(id: UUID) throws -> Item {
        guard let item = try items.item(id: id) else { throw AppError.itemNotFound(id: id) }
        return item
    }
}

@MainActor
@Suite("Archive round trip")
struct ArchiveRoundTripTests {
    @Test("Every item survives export and import into an empty store")
    func itemsSurvive() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        let report = try destination.importer.apply(archive)

        #expect(report.itemsCreated == archive.items.count)
        #expect(report.itemsSkipped == 0)
        #expect(report.warnings.isEmpty, "A clean archive should import without warnings: \(report.warnings)")

        // Identifiers are preserved, which is what makes the round trip a round trip rather than
        // a copy.
        for record in archive.items {
            let imported = try destination.item(id: record.id)
            #expect(imported.title == record.title)
        }

        #expect(try destination.item(id: graph.noteID).title == "Positioning")
    }

    @Test("Scalar fields and flags come back exactly")
    func scalarFidelity() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let originalNote = try source.item(id: graph.noteID)
        let importedNote = try destination.item(id: graph.noteID)

        #expect(importedNote.title == originalNote.title)
        #expect(importedNote.body == originalNote.body)
        #expect(importedNote.isFavorite == originalNote.isFavorite)
        #expect(importedNote.isPinned == originalNote.isPinned)
        #expect(importedNote.createdAt == originalNote.createdAt)
        #expect(importedNote.userMetadata == originalNote.userMetadata)

        let originalTask = try source.item(id: graph.openTaskID)
        let importedTask = try destination.item(id: graph.openTaskID)

        #expect(importedTask.dueAt == originalTask.dueAt)
        #expect(importedTask.priority == .high)
        #expect(importedTask.status == .open)

        let importedDone = try destination.item(id: graph.doneTaskID)
        #expect(importedDone.status == .completed)
        #expect(importedDone.completedAt != nil, "The completion invariant must survive import")
    }

    @Test("Containment hierarchy is rebuilt")
    func hierarchySurvives() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let project = try destination.item(id: graph.projectID)
        let task = try destination.item(id: graph.openTaskID)

        #expect(project.parent?.id == graph.areaID)
        #expect(task.parent?.id == graph.projectID)
    }

    @Test("Tags, including hierarchy, are preserved and not duplicated")
    func tagsSurvive() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let sourceSlugs = Set(try source.tags.allTags().map(\.slug))
        let destinationSlugs = Set(try destination.tags.allTags().map(\.slug))
        #expect(destinationSlugs == sourceSlugs)

        let project = try destination.item(id: graph.projectID)
        #expect((project.tags ?? []).map(\.slug) == ["work/clients/acme"])
    }

    @Test("Links survive, both resolved and unresolved")
    func linksSurvive() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let note = try destination.item(id: graph.noteID)

        // A wiki link to a real note, a wiki link to a title that does not exist, and a
        // deliberate `related` link.
        let kinds = Set((note.outgoingLinks ?? []).map(\.kind))
        #expect(kinds.contains(.wiki))
        #expect(kinds.contains(.related))

        let unresolved = (note.outgoingLinks ?? []).filter { !$0.isResolved }
        #expect(unresolved.count == 1)
        #expect(unresolved.first?.unresolvedTitle == "Something Unwritten")

        let resolvedWiki = (note.outgoingLinks ?? []).filter { $0.kind == .wiki && $0.isResolved }
        #expect(resolvedWiki.first?.target?.id == graph.projectID)
    }

    @Test("Collection order is preserved")
    func collectionOrderSurvives() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let collections = try destination.context.fetch(FetchDescriptor<ItemCollection>())
        let collection = try #require(collections.first { $0.id == graph.collectionID })

        #expect(collection.name == "Launch reading")
        #expect(collection.orderedItems().map(\.id) == [graph.bookmarkID, graph.noteID])
        #expect((collection.memberships ?? []).first { $0.item?.id == graph.bookmarkID }?.note == "Read first")
    }

    @Test("Saved searches survive as text")
    func savedSearchesSurvive() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let searches = try destination.context.fetch(FetchDescriptor<SavedSearch>())
        let search = try #require(searches.first { $0.id == graph.savedSearchID })
        #expect(search.queryString == "tag:urgent is:open type:task")
    }

    @Test("Archived and trashed states survive, because an export is a backup")
    func lifecycleStatesSurvive() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        #expect(try destination.item(id: graph.archivedID).archivedAt != nil)
        #expect(try destination.item(id: graph.trashedID).deletedAt != nil)
        #expect(try destination.items.items(matching: .trash()).count == 1)
    }

    @Test("Recurrence rules survive")
    func recurrenceSurvives() throws {
        let source = try TransferFixture()
        let graph = try source.populate()
        let archive = try source.exporter.buildArchive()

        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let rule = try #require(try destination.item(id: graph.recurringTaskID).recurrence)
        #expect(rule.frequency == .weekly)
        #expect(rule.weekdays == [2])
        #expect(rule.anchor == .schedule)
    }

    @Test("The archive survives its own JSON encoding")
    func jsonEncodingIsStable() throws {
        let source = try TransferFixture()
        try source.populate()

        let archive = try source.exporter.buildArchive()
        let data = try archive.encoded()
        let decoded = try ArchiveDocument.decoded(from: data)

        #expect(decoded == archive, "Encoding and decoding must be exact inverses")

        // And it is human-readable, which is a stated promise of the format.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"formatVersion\""))
        #expect(text.contains("\n"), "Pretty-printed so it can be diffed")
    }

    @Test("A newer archive format is refused with an explanation, not partially read")
    func futureFormatIsRefused() throws {
        var archive = ArchiveDocument(schemaVersion: "1.0.0", exportedAt: Date())
        archive.formatVersion = ArchiveDocument.currentFormatVersion + 1

        let data = try archive.encoded()

        #expect(throws: AppError.self) {
            try ArchiveDocument.decoded(from: data)
        }
    }

    @Test("Re-importing into the same store changes nothing by default")
    func reimportIsIdempotent() throws {
        let fixture = try TransferFixture()
        try fixture.populate()

        let countBefore = try fixture.items.items(matching: .everything()).count
        let archive = try fixture.exporter.buildArchive()

        let report = try fixture.importer.apply(archive, policy: .skip)

        #expect(report.itemsCreated == 0)
        #expect(report.itemsSkipped == countBefore)
        #expect(try fixture.items.items(matching: .everything()).count == countBefore)
    }

    @Test("Keep-both duplicates rather than overwriting")
    func keepBothDuplicates() throws {
        let fixture = try TransferFixture()
        try fixture.populate()

        let countBefore = try fixture.items.items(matching: .everything()).count
        let archive = try fixture.exporter.buildArchive()

        let report = try fixture.importer.apply(archive, policy: .keepBoth)

        #expect(report.itemsCreated == countBefore)
        #expect(try fixture.items.items(matching: .everything()).count == countBefore * 2)
    }

    @Test("An unknown item kind survives a round trip rather than being flattened")
    func unknownKindSurvives() throws {
        let source = try TransferFixture()
        let item = Item()
        item.kindRaw = "habit"
        item.title = "From a newer version"
        source.context.insert(item)
        try source.context.save()

        let archive = try source.exporter.buildArchive()
        let destination = try TransferFixture()
        _ = try destination.importer.apply(archive)

        let imported = try destination.item(id: item.id)
        #expect(imported.kindRaw == "habit", "Forward compatibility means not rewriting what we do not understand")
        #expect(imported.kind == .reference, "…while still displaying it")
    }
}

@Suite("Markdown front-matter")
struct MarkdownFrontMatterTests {
    @Test("Front-matter and body are separated")
    func parsesFrontMatter() {
        let text = """
        ---
        id: 6E1B2C3D-0000-0000-0000-000000000000
        kind: note
        title: A Title
        tags: [work, urgent]
        ---

        The body text.
        Second line.
        """

        let (fields, body) = MarkdownFrontMatter.parse(text)

        #expect(fields["kind"] == "note")
        #expect(fields["title"] == "A Title")
        #expect(MarkdownFrontMatter.parseList(fields["tags"] ?? "") == ["work", "urgent"])
        #expect(body == "The body text.\nSecond line.")
    }

    @Test("A file with no front-matter is entirely body")
    func handlesPlainMarkdown() {
        let text = "# Just a heading\n\nSome prose."
        let (fields, body) = MarkdownFrontMatter.parse(text)

        #expect(fields.isEmpty)
        #expect(body == text)
    }

    @Test("An unterminated fence is treated as body, not as broken front-matter")
    func handlesUnterminatedFence() {
        let text = "---\nid: something\nno closing fence"
        let (fields, body) = MarkdownFrontMatter.parse(text)

        #expect(fields.isEmpty)
        #expect(body == text)
    }

    @Test("Values needing quotes are quoted, and unquote is the inverse")
    func quotingRoundTrips() {
        let awkward = "Title: with a colon, and a comma"
        let quoted = MarkdownFrontMatter.yamlScalar(awkward)

        #expect(quoted.hasPrefix("\""))
        #expect(MarkdownFrontMatter.unquote(quoted) == awkward)

        // Ordinary values stay unquoted, which is what keeps the files pleasant to read.
        #expect(MarkdownFrontMatter.yamlScalar("Simple title") == "Simple title")
    }

    @Test("Rendering then parsing recovers the fields")
    func renderParseRoundTrip() {
        let record = ArchiveItem(
            id: UUID(),
            kind: ItemKind.task.rawValue,
            title: "Draft: the brief, urgently",
            body: "Body text here.",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_500),
            dueAt: Date(timeIntervalSince1970: 1_781_000_000),
            status: ItemStatus.open.rawValue,
            priority: Priority.high.rawValue,
            isFavorite: true,
            sourceKind: SourceKind.manual.rawValue
        )

        let rendered = MarkdownFrontMatter.render(record, tagSlugs: ["work", "urgent"])
        let (fields, body) = MarkdownFrontMatter.parse(rendered)

        #expect(fields["id"] == record.id.uuidString)
        #expect(fields["kind"] == "task")
        #expect(fields["title"] == record.title)
        #expect(fields["priority"] == "high")
        #expect(fields["favorite"] == "true")
        #expect(body == record.body)
        #expect(MarkdownFrontMatter.parseList(fields["tags"] ?? "") == ["work", "urgent"])

        let due = fields["due"].flatMap(MarkdownFrontMatter.date(from:))
        #expect(due?.timeIntervalSince1970 == record.dueAt?.timeIntervalSince1970)
    }

    @Test("Filenames are filesystem-safe and collision-resistant")
    func filenamesAreSafe() {
        let record = ArchiveItem(
            id: UUID(),
            kind: ItemKind.note.rawValue,
            title: "Work/Clients: Acme — Q3!",
            body: "",
            createdAt: Date(),
            updatedAt: Date(),
            status: ItemStatus.none.rawValue,
            priority: Priority.normal.rawValue,
            sourceKind: SourceKind.manual.rawValue
        )

        let filename = MarkdownFrontMatter.filename(for: record)

        #expect(!filename.contains("/"))
        #expect(!filename.contains(":"))
        #expect(filename.hasSuffix(".md"))
        // The identifier prefix is what stops two same-titled notes colliding.
        #expect(filename.contains(record.id.uuidString.prefix(8)))
    }

    @Test("An untitled item still gets a filename")
    func untitledGetsFilename() {
        let record = ArchiveItem(
            id: UUID(),
            kind: ItemKind.note.rawValue,
            title: "",
            body: "",
            createdAt: Date(),
            updatedAt: Date(),
            status: ItemStatus.none.rawValue,
            priority: Priority.normal.rawValue,
            sourceKind: SourceKind.manual.rawValue
        )

        #expect(MarkdownFrontMatter.filename(for: record).hasPrefix("untitled-"))
    }
}

@MainActor
@Suite("Markdown import")
struct MarkdownImportTests {
    @Test("Plain Markdown becomes a note titled by its first heading")
    func plainMarkdownImport() throws {
        let fixture = try TransferFixture()

        let report = try fixture.importer.importMarkdownFiles([
            (filename: "some-file.md", contents: "# The Real Title\n\nSome prose."),
        ])

        #expect(report.itemsCreated == 1)

        let created = try #require(try fixture.items.items(matching: .kind(.note)).first)
        #expect(created.title == "The Real Title")
        #expect(created.body.contains("Some prose."))
        #expect(created.source.kind == .markdownImport)
        #expect(created.source.identifier == "some-file.md")
    }

    @Test("A file with no heading is titled by its filename")
    func filenameFallback() throws {
        let fixture = try TransferFixture()

        _ = try fixture.importer.importMarkdownFiles([
            (filename: "meeting-notes.md", contents: "Just prose, no heading."),
        ])

        let created = try #require(try fixture.items.items(matching: .kind(.note)).first)
        #expect(created.title == "meeting-notes")
    }

    @Test("Front-matter is honoured, including tags and state")
    func frontMatterIsHonoured() throws {
        let fixture = try TransferFixture()
        let identifier = UUID()

        let contents = """
        ---
        id: \(identifier.uuidString)
        kind: task
        title: Imported Task
        status: completed
        priority: high
        due: \(MarkdownFrontMatter.iso(Date(timeIntervalSince1970: 1_781_000_000)))
        favorite: true
        tags: [work, urgent]
        ---

        Task detail.
        """

        let report = try fixture.importer.importMarkdownFiles([(filename: "task.md", contents: contents)])
        #expect(report.itemsCreated == 1)

        let created = try fixture.item(id: identifier)
        #expect(created.kind == .reminder)
        #expect(created.title == "Imported Task")
        #expect(created.status == .completed)
        #expect(created.completedAt != nil, "The completion invariant holds even on import")
        #expect(created.priority == .high)
        #expect(created.isFavorite)
        #expect(Set((created.tags ?? []).map(\.slug)) == ["work", "urgent"])
    }

    @Test("Importing the same file twice skips by default")
    func duplicateSkipping() throws {
        let fixture = try TransferFixture()
        let identifier = UUID()
        let contents = "---\nid: \(identifier.uuidString)\nkind: note\ntitle: Once\n---\n\nBody."

        _ = try fixture.importer.importMarkdownFiles([(filename: "a.md", contents: contents)])
        let second = try fixture.importer.importMarkdownFiles([(filename: "a.md", contents: contents)])

        #expect(second.itemsSkipped == 1)
        #expect(second.itemsCreated == 0)
        #expect(try fixture.items.items(matching: .everything()).count == 1)
    }

    @Test("Replace updates the existing item in place")
    func replacePolicy() throws {
        let fixture = try TransferFixture()
        let identifier = UUID()

        _ = try fixture.importer.importMarkdownFiles([
            (filename: "a.md", contents: "---\nid: \(identifier.uuidString)\nkind: note\ntitle: Original\n---\n\nOld body."),
        ])

        let report = try fixture.importer.importMarkdownFiles(
            [(filename: "a.md", contents: "---\nid: \(identifier.uuidString)\nkind: note\ntitle: Updated\n---\n\nNew body.")],
            policy: .replace
        )

        #expect(report.itemsUpdated == 1)

        let item = try fixture.item(id: identifier)
        #expect(item.title == "Updated")
        #expect(item.body == "New body.")
        #expect(try fixture.items.items(matching: .everything()).count == 1)
    }

    @Test("A due date on a note is dropped rather than failing the import")
    func invalidFieldsAreDroppedNotFatal() throws {
        let fixture = try TransferFixture()

        // A note cannot hold a due date. The file should still import.
        let report = try fixture.importer.importMarkdownFiles([
            (filename: "note.md", contents: "---\nkind: note\ntitle: A Note\ndue: 2026-08-14T00:00:00Z\n---\n\nBody."),
        ])

        #expect(report.itemsCreated == 1)
        let created = try #require(try fixture.items.items(matching: .kind(.note)).first)
        #expect(created.dueAt == nil)
    }

    @Test("One unreadable file does not abandon the rest of the batch")
    func batchContinuesAfterOneFailure() throws {
        let fixture = try TransferFixture()

        let report = try fixture.importer.importMarkdownFiles([
            (filename: "good-1.md", contents: "# First\n\nBody."),
            (filename: "good-2.md", contents: "# Second\n\nBody."),
        ])

        #expect(report.itemsCreated == 2)
        #expect(report.warnings.isEmpty)
    }
}

@MainActor
@Suite("Bundle writing")
struct BundleWritingTests {
    @Test("A JSON archive is written and reads back")
    func writesJSONArchive() throws {
        let fixture = try TransferFixture()
        try fixture.populate()

        let directory = URL.temporaryDirectory.appending(path: "ElephruitExportTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "library.json", directoryHint: .notDirectory)
        let report = try fixture.exporter.write(format: .jsonArchive, to: destination)

        #expect(report.fileCount == 1)
        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))

        let data = try Data(contentsOf: destination)
        let decoded = try ArchiveDocument.decoded(from: data)
        #expect(decoded.items.count == report.itemCount)
    }

    @Test("A Markdown bundle has the documented layout, archive, and README")
    func writesMarkdownBundle() throws {
        let fixture = try TransferFixture()
        try fixture.populate()

        let directory = URL.temporaryDirectory.appending(path: "ElephruitExportTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = try fixture.exporter.write(format: .markdownBundle, to: directory)
        let fileManager = FileManager.default

        // The lossless companion and the explanation are both promises of the format.
        #expect(fileManager.fileExists(atPath: directory.appending(path: "elephruit-archive.json").path(percentEncoded: false)))
        #expect(fileManager.fileExists(atPath: directory.appending(path: "README.md").path(percentEncoded: false)))

        // Grouped by kind, so the bundle is navigable.
        #expect(fileManager.fileExists(atPath: directory.appending(path: "Notes").path(percentEncoded: false)))
        #expect(fileManager.fileExists(atPath: directory.appending(path: "Reminders").path(percentEncoded: false)))

        #expect(report.fileCount == report.itemCount + 2)

        // And the archive inside the bundle re-imports completely.
        let archiveData = try Data(contentsOf: directory.appending(path: "elephruit-archive.json"))
        let destination = try TransferFixture()
        let importReport = try destination.importer.importArchive(archiveData)
        #expect(importReport.itemsCreated == report.itemCount)
    }

    @Test("CSV is written with a BOM and RFC 4180 quoting")
    func writesCSV() throws {
        let fixture = try TransferFixture()
        try fixture.populate()

        let directory = URL.temporaryDirectory.appending(path: "ElephruitExportTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try fixture.exporter.write(format: .csv, to: directory)

        let data = try Data(contentsOf: directory.appending(path: "items.csv"))
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]), "Spreadsheets need the BOM to read UTF-8")

        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        #expect(text.hasPrefix("id,kind,title,"))
        #expect(text.contains("Q3 Launch"))
    }

    @Test("Fields containing commas or quotes are escaped")
    func csvEscaping() {
        #expect(CSVWriter.escape("plain") == "plain")
        #expect(CSVWriter.escape("has,comma") == "\"has,comma\"")
        #expect(CSVWriter.escape("has\"quote") == "\"has\"\"quote\"")
        #expect(CSVWriter.escape("has\nnewline") == "\"has\nnewline\"")
    }
}
