import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData

/// What to write, and in what shape.
public enum ExportFormat: String, Sendable, Hashable, CaseIterable {
    /// One versioned JSON file. Complete, round-trippable, identifiers preserved.
    case jsonArchive

    /// A directory of Markdown files with YAML front-matter, plus the JSON archive alongside.
    ///
    /// Both, deliberately: the Markdown is what a human reads and what another app can import,
    /// and the archive is what guarantees a lossless return trip. Offering only Markdown would
    /// mean quietly losing links, order, and identifiers.
    case markdownBundle

    /// CSV for tabular entities. A convenience for spreadsheets, never a complete export.
    case csv

    public var displayName: String {
        switch self {
        case .jsonArchive: "JSON Archive"
        case .markdownBundle: "Markdown Bundle"
        case .csv: "CSV"
        }
    }

    public var explanation: String {
        switch self {
        case .jsonArchive:
            "One file containing everything, including links and identifiers. Re-imports exactly."
        case .markdownBundle:
            "A folder of readable Markdown files, with a JSON archive alongside so nothing is lost."
        case .csv:
            "Spreadsheet-friendly tables. Does not include note bodies or links."
        }
    }

    /// Whether the format writes a directory rather than a single file.
    public var isDirectory: Bool {
        self != .jsonArchive
    }

    public var fileExtension: String? {
        switch self {
        case .jsonArchive: "json"
        case .markdownBundle, .csv: nil
        }
    }
}

/// What an export produced.
public struct ExportReport: Sendable, Hashable {
    public var format: ExportFormat
    public var destination: URL
    public var itemCount: Int
    public var fileCount: Int
    public var summary: String

    public init(format: ExportFormat, destination: URL, itemCount: Int, fileCount: Int, summary: String) {
        self.format = format
        self.destination = destination
        self.itemCount = itemCount
        self.fileCount = fileCount
        self.summary = summary
    }
}

/// Writes the user's data out.
///
/// `@MainActor` because it reads `Item` objects, which must not cross an isolation boundary.
/// The reading is fast; the file writing is the slow part and is the only thing worth moving
/// off the main actor later, at which point it will already be operating on `Sendable` archive
/// records rather than models.
@MainActor
public struct Exporter {
    private let items: any ItemRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    /// Where managed attachment bytes live, so a bundle export can copy them.
    ///
    /// Optional because an in-memory library — previews, tests — has no file storage. Without it an
    /// export still carries every record; it simply has no bytes to copy.
    private let location: StoreLocation?

    public init(
        items: any ItemRepository,
        context: ModelContext,
        dateProvider: any DateProvider,
        location: StoreLocation? = nil
    ) {
        self.items = items
        self.context = context
        self.dateProvider = dateProvider
        self.location = location
    }

    // MARK: - Building the archive

    /// Reads the whole store into archive records.
    ///
    /// Includes trashed items: an export is a backup, and a backup that silently omits the Trash
    /// would lose data the user could still have recovered.
    public func buildArchive() throws(AppError) -> ArchiveDocument {
        let allItems = try items.items(matching: .everything())

        let tags: [ElephruitModel.Tag]
        let links: [ItemLink]
        let collections: [ItemCollection]
        let savedSearches: [SavedSearch]
        let attachments: [ElephruitModel.Attachment]
        let timeEntries: [TimeEntry]

        do {
            tags = try context.fetch(FetchDescriptor<ElephruitModel.Tag>(sortBy: [SortDescriptor(\.slug)]))
            links = try context.fetch(FetchDescriptor<ItemLink>())
            collections = try context.fetch(FetchDescriptor<ItemCollection>(sortBy: [SortDescriptor(\.sortOrder)]))
            savedSearches = try context.fetch(FetchDescriptor<SavedSearch>(sortBy: [SortDescriptor(\.sortOrder)]))
            attachments = try context.fetch(FetchDescriptor<ElephruitModel.Attachment>())
            // Including soft-deleted entries, for the same reason the Trash is included: an export
            // is a backup, and one that quietly drops what is still recoverable is not.
            timeEntries = try context.fetch(FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startedAt)]))
        } catch {
            throw .exportFailed(reason: error.localizedDescription)
        }

        return ArchiveDocument(
            schemaVersion: CurrentSchema.versionString,
            exportedAt: dateProvider.now,
            items: allItems.map(Self.record(for:)),
            tags: tags.map(Self.record(for:)),
            links: links.map(Self.record(for:)),
            collections: collections.map(Self.record(for:)),
            savedSearches: savedSearches.map(Self.record(for:)),
            attachments: attachments.map(Self.record(for:)),
            timeEntries: timeEntries.map(Self.record(for:))
        )
    }

    static func record(for item: Item) -> ArchiveItem {
        ArchiveItem(
            id: item.id,
            // The raw value, not `item.kind`, so an unknown future kind survives a round trip
            // rather than being flattened to `reference`.
            kind: item.kindRaw,
            title: item.title,
            body: item.body,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            startAt: item.startAt,
            dueAt: item.dueAt,
            deferUntil: item.deferUntil,
            completedAt: item.completedAt,
            archivedAt: item.archivedAt,
            deletedAt: item.deletedAt,
            status: item.statusRaw,
            priority: item.priorityRaw,
            isFavorite: item.isFavorite,
            isPinned: item.isPinned,
            sortOrder: item.sortOrder,
            recurrence: item.recurrence,
            symbolName: item.symbolName,
            colorName: item.colorName,
            dayKey: item.dayKey,
            sourceKind: item.sourceKindRaw,
            sourceURL: item.sourceURLString,
            sourceIdentifier: item.sourceIdentifier,
            tagIDs: (item.tags ?? []).map(\.id).sorted { $0.uuidString < $1.uuidString },
            parentID: item.parent?.id,
            userMetadata: item.userMetadata
        )
    }

    static func record(for tag: ElephruitModel.Tag) -> ArchiveTag {
        ArchiveTag(
            id: tag.id,
            name: tag.name,
            slug: tag.slug,
            colorName: tag.colorName,
            createdAt: tag.createdAt,
            isImplicit: tag.isImplicit,
            parentID: tag.parent?.id
        )
    }

    static func record(for link: ItemLink) -> ArchiveLink {
        ArchiveLink(
            id: link.id,
            kind: link.kindRaw,
            sourceID: link.source?.id,
            targetID: link.target?.id,
            displayText: link.displayText,
            unresolvedTitle: link.unresolvedTitle,
            createdAt: link.createdAt
        )
    }

    static func record(for collection: ItemCollection) -> ArchiveCollection {
        ArchiveCollection(
            id: collection.id,
            name: collection.name,
            summary: collection.summary,
            symbolName: collection.symbolName,
            colorName: collection.colorName,
            createdAt: collection.createdAt,
            sortOrder: collection.sortOrder,
            isPinned: collection.isPinned,
            members: (collection.memberships ?? [])
                .sorted { $0.position < $1.position }
                .compactMap { membership in
                    guard let itemID = membership.item?.id else { return nil }
                    return ArchiveCollection.Member(
                        itemID: itemID,
                        position: membership.position,
                        addedAt: membership.addedAt,
                        note: membership.note
                    )
                }
        )
    }

    static func record(for search: SavedSearch) -> ArchiveSavedSearch {
        ArchiveSavedSearch(
            id: search.id,
            name: search.name,
            queryString: search.queryString,
            symbolName: search.symbolName,
            colorName: search.colorName,
            createdAt: search.createdAt,
            sortOrder: search.sortOrder,
            showsInSidebar: search.showsInSidebar
        )
    }

    static func record(for attachment: ElephruitModel.Attachment) -> ArchiveAttachment {
        ArchiveAttachment(
            id: attachment.id,
            ownerID: attachment.owner?.id,
            filename: attachment.filename,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: attachment.byteCount,
            contentHash: attachment.contentHash,
            createdAt: attachment.createdAt,
            storageKind: attachment.storageKindRaw,
            // A path only where bytes will actually be there. A reference belongs to the user, not
            // to Elephruit, so an export records that it existed and does not copy it — and must
            // not claim a path it never wrote. Every archive used to name one regardless.
            bundlePath: attachment.storageKind == .managedCopy ? attachment.exportRelativePath : nil,
            extractedText: attachment.extractedText
        )
    }

    static func record(for entry: TimeEntry) -> ArchiveTimeEntry {
        ArchiveTimeEntry(
            id: entry.id,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            entryDescription: entry.entryDescription,
            itemID: entry.item?.id,
            tagIDs: (entry.tags ?? []).map(\.id),
            source: entry.sourceRaw,
            isBillable: entry.isBillable,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            deletedAt: entry.deletedAt,
            lastHeartbeatAt: entry.lastHeartbeatAt
        )
    }

    /// Copies managed attachment bytes into a bundle, at the path the archive names.
    ///
    /// Returns the number of files written, and appends a warning for each attachment whose bytes
    /// were expected and absent — that is a state worth reporting, not a reason to fail an export
    /// that is otherwise complete.
    func copyAttachmentBytes(
        for archive: ArchiveDocument,
        into destination: URL,
        warnings: inout [String]
    ) throws(AppError) -> Int {
        guard let location else { return 0 }
        var written = 0

        for record in archive.attachments {
            guard let relativePath = record.bundlePath else { continue }

            let source = location.attachmentDirectory(id: record.id)
                .appending(path: record.filename, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                warnings.append("The file for “\(record.filename)” was missing and could not be exported.")
                continue
            }

            let target = destination.appending(path: relativePath, directoryHint: .notDirectory)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                written += 1
            } catch {
                throw .writeFailed(path: relativePath, reason: error.localizedDescription)
            }
        }

        return written
    }

    // MARK: - Writing

    /// Writes an export to `destination`.
    ///
    /// Writes are staged and only moved into place once complete, so an interrupted export never
    /// leaves a half-written archive that looks like a good backup. On failure, partial output is
    /// removed.
    public func write(format: ExportFormat, to destination: URL) throws(AppError) -> ExportReport {
        let archive = try buildArchive()

        switch format {
        case .jsonArchive:
            let data = try archive.encoded()
            try Self.writeAtomically(data, to: destination)
            return ExportReport(
                format: format,
                destination: destination,
                itemCount: archive.items.count,
                fileCount: 1,
                summary: archive.summary
            )

        case .markdownBundle:
            return try MarkdownBundleWriter(archive: archive, exporter: self).write(to: destination)

        case .csv:
            return try CSVWriter(archive: archive).write(to: destination)
        }
    }

    /// Writes to a sibling temporary file, then replaces the destination.
    ///
    /// `Data.write(options: .atomic)` would do this too, but doing it explicitly means the same
    /// pattern is available for the multi-file bundle formats, where the framework offers nothing.
    static func writeAtomically(_ data: Data, to destination: URL) throws(AppError) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw .writeFailed(path: destination.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }
}
