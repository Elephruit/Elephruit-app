import CryptoKit
import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import Foundation
import SwiftData
import Testing

/// What an archive has to contain before it is a backup — ADR 0009.
///
/// Two things were silently missing. Every archive named a `bundlePath` for each attachment and no
/// code ever wrote a file at it, so an export lost every attached file while claiming otherwise.
/// And `TimeEntry` appeared nowhere in the transfer layer at all, so a round trip destroyed every
/// interval the user had tracked.
///
/// The attachment half runs against a real store on a real filesystem, because the feature is bytes
/// moving between folders and in-memory would prove nothing.
@MainActor
@Suite("Archive completeness", .serialized)
struct ArchiveCompletenessTests {
    @MainActor
    private struct Library {
        let location: StoreLocation
        let context: ModelContext
        let items: SwiftDataItemRepository
        let tags: SwiftDataTagRepository
        let attachments: AttachmentStore
        let entries: SwiftDataTimeEntryRepository
        let exporter: Exporter
        let importer: Importer
        let clock = FixedDateProvider.reference

        init() throws {
            location = StoreLocation.temporary()
            try location.createDirectories()

            let stack = try PersistenceStack.open(mode: .onDisk(location))
            context = ModelContext(stack.container)
            tags = SwiftDataTagRepository(context: context, dateProvider: clock)
            items = SwiftDataItemRepository(context: context, dateProvider: clock, tags: tags)
            attachments = AttachmentStore(context: context, location: location, dateProvider: clock)
            entries = SwiftDataTimeEntryRepository(context: context, dateProvider: clock, tags: tags)
            exporter = Exporter(items: items, context: context, dateProvider: clock, location: location)
            importer = Importer(items: items, tags: tags, context: context, dateProvider: clock, location: location)
        }

        func scratchFile(_ name: String, contents: String) throws -> URL {
            let directory = location.root.deletingLastPathComponent()
                .appending(path: "Scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func cleanUp() { location.removeForTesting() }
    }

    private static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func exportDestination() -> URL {
        URL.temporaryDirectory.appending(path: "ElephruitExport-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: - Attachments

    @Test("A copied-in file round-trips with its bytes, and the hash matches")
    func attachmentBytesRoundTrip() throws {
        let source = try Library()
        defer { source.cleanUp() }

        let note = try source.items.create(ItemDraft(kind: .note, title: "With a diagram"))
        let file = try source.scratchFile("diagram.txt", contents: "the shape of the thing")
        let attachment = try source.attachments.attachCopy(of: file, to: note)
        let originalHash = try #require(attachment.contentHash)

        let bundle = Self.exportDestination()
        defer { try? FileManager.default.removeItem(at: bundle) }
        _ = try source.exporter.write(format: .markdownBundle, to: bundle)

        // The file the archive names is actually in the bundle.
        let inBundle = bundle.appending(path: "Attachments/\(attachment.id.uuidString)/diagram.txt")
        #expect(FileManager.default.fileExists(atPath: inBundle.path(percentEncoded: false)))
        #expect(try Self.sha256(ofFileAt: inBundle) == originalHash)

        // And it comes back into a different library, as a file rather than a row describing one.
        let destination = try Library()
        defer { destination.cleanUp() }

        let report = try destination.importer.importBundle(at: bundle)
        #expect(report.attachmentsCreated == 1)

        let restored = try #require(
            try destination.context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).first
        )
        #expect(restored.id == attachment.id)
        #expect(restored.isReferenceLost == false)

        let restoredFile = destination.location
            .attachmentDirectory(id: restored.id)
            .appending(path: "diagram.txt", directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: restoredFile.path(percentEncoded: false)))
        #expect(try Self.sha256(ofFileAt: restoredFile) == originalHash)
        #expect(try String(contentsOf: restoredFile, encoding: .utf8) == "the shape of the thing")
    }

    /// Elephruit does not own a referenced file, so an export records that it existed and leaves it
    /// where the user put it. It must also not *claim* a path it never wrote — which is exactly what
    /// every archive used to do.
    @Test("A referenced file is recorded without its bytes being copied")
    func referencesAreRecordedNotCopied() throws {
        let library = try Library()
        defer { library.cleanUp() }

        let note = try library.items.create(ItemDraft(kind: .note, title: "With a reference"))
        let file = try library.scratchFile("elsewhere.txt", contents: "not ours")
        let attachment = try library.attachments.attachReference(to: file, from: note)

        let archive = try library.exporter.buildArchive()
        let record = try #require(archive.attachments.first { $0.id == attachment.id })
        #expect(record.bundlePath == nil, "an archive named a path for bytes it does not carry")
        #expect(record.filename == "elsewhere.txt")
        #expect(record.byteCount > 0)

        let bundle = Self.exportDestination()
        defer { try? FileManager.default.removeItem(at: bundle) }
        _ = try library.exporter.write(format: .markdownBundle, to: bundle)

        let attachmentsFolder = bundle.appending(path: "Attachments", directoryHint: .isDirectory)
        let copied = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsFolder.path(percentEncoded: false))) ?? []
        #expect(copied.isEmpty, "a referenced file was copied into the bundle")

        // The user's original is untouched.
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    /// Importing the JSON on its own, without the folder beside it, is a thing people will do.
    @Test("An attachment imported without its folder is a lost reference, not a failure")
    func missingBytesBecomeAState() throws {
        let source = try Library()
        defer { source.cleanUp() }

        let note = try source.items.create(ItemDraft(kind: .note, title: "With a diagram"))
        let file = try source.scratchFile("diagram.txt", contents: "bytes")
        _ = try source.attachments.attachCopy(of: file, to: note)

        let archive = try source.exporter.buildArchive()

        let destination = try Library()
        defer { destination.cleanUp() }

        let report = try destination.importer.apply(archive)
        #expect(report.attachmentsCreated == 1)
        #expect(report.warnings.contains { $0.contains("diagram.txt") })

        let restored = try #require(
            try destination.context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).first
        )
        #expect(restored.isReferenceLost, "a row promised bytes that are not there")
        #expect(restored.filename == "diagram.txt")
    }

    // MARK: - Time

    @Test("Tracked time survives an export and import")
    func timeSurvivesTheRoundTrip() throws {
        let source = try Library()
        defer { source.cleanUp() }

        let task = try source.items.create(ItemDraft(kind: .task, title: "Draft the brief"))
        let started = source.clock.now.addingTimeInterval(-7200)
        let stopped = source.clock.now.addingTimeInterval(-3600)
        let entry = try source.entries.addManual(
            item: task,
            description: "Drafting",
            startedAt: started,
            endedAt: stopped,
            tagSlugs: []
        )

        let archive = try source.exporter.buildArchive()
        #expect(archive.timeEntries.count == 1)

        let destination = try Library()
        defer { destination.cleanUp() }
        let report = try destination.importer.apply(archive)
        #expect(report.timeEntriesCreated == 1)

        let restored = try #require(try destination.context.fetch(FetchDescriptor<TimeEntry>()).first)
        #expect(restored.id == entry.id)
        #expect(restored.startedAt == started)
        #expect(restored.endedAt == stopped)
        #expect(restored.entryDescription == "Drafting")
        #expect(restored.duration() == 3600)
        // The link to the task, not a copy of its title.
        #expect(restored.item?.id == task.id)
    }

    /// Closing it would invent an end the user never recorded.
    @Test("A timer that was running when the export was taken comes back running")
    func runningTimersStayRunning() throws {
        let source = try Library()
        defer { source.cleanUp() }

        let running = try source.entries.start(item: nil, description: "In progress", tagSlugs: [])
        #expect(running.isRunning)

        let archive = try source.exporter.buildArchive()

        let destination = try Library()
        defer { destination.cleanUp() }
        _ = try destination.importer.apply(archive)

        let restored = try #require(try destination.context.fetch(FetchDescriptor<TimeEntry>()).first)
        #expect(restored.isRunning)
        #expect(restored.endedAt == nil)
        #expect(restored.startedAt == running.startedAt)
    }

    @Test("An interval that ends before it starts is refused rather than imported")
    func invertedIntervalsAreRejected() throws {
        let library = try Library()
        defer { library.cleanUp() }

        let archive = ArchiveDocument(
            schemaVersion: "test",
            exportedAt: library.clock.now,
            timeEntries: [
                ArchiveTimeEntry(
                    id: UUID(),
                    startedAt: library.clock.now,
                    endedAt: library.clock.now.addingTimeInterval(-60),
                    source: "manual",
                    createdAt: library.clock.now,
                    updatedAt: library.clock.now
                )
            ]
        )

        let report = try library.importer.apply(archive)
        #expect(report.timeEntriesCreated == 0)
        #expect(report.warnings.count == 1)
        #expect(try library.context.fetch(FetchDescriptor<TimeEntry>()).isEmpty)
    }

    // MARK: - Compatibility

    /// The format's own rule is that additive changes keep the version and rely on tolerant
    /// decoding. That is only true if decoding is actually tolerant, which synthesised `Codable`
    /// would not have been — a missing `timeEntries` key would have failed the whole read.
    @Test("An archive written before time entries existed still imports")
    func archivesWithoutTimeEntriesStillImport() throws {
        let library = try Library()
        defer { library.cleanUp() }

        let json = """
        {
          "attachments" : [],
          "collections" : [],
          "exportedAt" : "2026-01-01T00:00:00Z",
          "formatVersion" : 1,
          "generator" : "Elephruit",
          "items" : [],
          "links" : [],
          "savedSearches" : [],
          "schemaVersion" : "1.0.0",
          "tags" : []
        }
        """

        let archive = try ArchiveDocument.decoded(from: Data(json.utf8))
        #expect(archive.timeEntries.isEmpty)
        #expect(archive.formatVersion == 1)

        let report = try library.importer.apply(archive)
        #expect(report.timeEntriesCreated == 0)
    }

    /// The oldest shape of all: a file missing several collections at once.
    @Test("An archive missing whole record collections still imports")
    func archivesMissingCollectionsStillImport() throws {
        let json = """
        { "formatVersion" : 1, "items" : [] }
        """

        let archive = try ArchiveDocument.decoded(from: Data(json.utf8))
        #expect(archive.items.isEmpty)
        #expect(archive.tags.isEmpty)
        #expect(archive.attachments.isEmpty)
        #expect(archive.timeEntries.isEmpty)
    }

    @Test("A bundle with no archive beside it explains itself")
    func bundleWithoutArchive() throws {
        let library = try Library()
        defer { library.cleanUp() }

        let empty = Self.exportDestination()
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(throws: AppError.self) {
            _ = try library.importer.importBundle(at: empty)
        }
    }

    @Test("Re-importing a bundle does not duplicate its files or its time")
    func reimportIsIdempotent() throws {
        let source = try Library()
        defer { source.cleanUp() }

        let note = try source.items.create(ItemDraft(kind: .note, title: "With a diagram"))
        let file = try source.scratchFile("diagram.txt", contents: "bytes")
        _ = try source.attachments.attachCopy(of: file, to: note)
        _ = try source.entries.addManual(
            item: note,
            description: "Reading",
            startedAt: source.clock.now.addingTimeInterval(-600),
            endedAt: source.clock.now,
            tagSlugs: []
        )

        let bundle = Self.exportDestination()
        defer { try? FileManager.default.removeItem(at: bundle) }
        _ = try source.exporter.write(format: .markdownBundle, to: bundle)

        let destination = try Library()
        defer { destination.cleanUp() }

        _ = try destination.importer.importBundle(at: bundle)
        let second = try destination.importer.importBundle(at: bundle)

        #expect(second.attachmentsCreated == 0)
        #expect(second.timeEntriesCreated == 0)
        #expect(try destination.context.fetch(FetchDescriptor<ElephruitModel.Attachment>()).count == 1)
        #expect(try destination.context.fetch(FetchDescriptor<TimeEntry>()).count == 1)
    }
}
