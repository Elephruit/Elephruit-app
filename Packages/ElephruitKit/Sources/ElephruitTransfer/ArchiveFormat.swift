import ElephruitCore
import Foundation

/// The versioned JSON archive — Elephruit's complete, durable export format.
///
/// ### Contract
/// 1. **Versioned.** ``ArchiveDocument/formatVersion`` is checked on import. A newer archive is
///    refused with an explanation rather than partially read.
/// 2. **Identifier-preserving.** Every entity keeps its `UUID`, so export → import is a true
///    round trip and re-importing an archive updates rather than duplicates.
/// 3. **Relationship-preserving.** Relationships are stored as identifier references, resolved
///    in a second pass, so the order of records in the file does not matter.
/// 4. **Forward-tolerant.** Unknown fields are ignored on read and unknown item kinds are
///    preserved verbatim, so an archive from a later version loses as little as possible.
/// 5. **Human-inspectable.** Sorted keys, pretty-printed, ISO 8601 dates. An archive should be
///    readable in a text editor and diffable in version control — that is a large part of what
///    makes "you own your data" true rather than a slogan.
public struct ArchiveDocument: Codable, Sendable, Hashable {
    /// Bumped only for a breaking change. Additive changes keep the version and rely on
    /// tolerant decoding.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var generator: String
    public var schemaVersion: String
    public var exportedAt: Date

    public var items: [ArchiveItem]
    public var tags: [ArchiveTag]
    public var links: [ArchiveLink]
    public var collections: [ArchiveCollection]
    public var savedSearches: [ArchiveSavedSearch]
    public var attachments: [ArchiveAttachment]

    /// Tracked time.
    ///
    /// Absent from the format until this was noticed: an export claimed to be a backup and
    /// destroyed every interval the user had recorded. Additive, so an older build reading a
    /// newer archive ignores it and a newer build reading an older one sees none.
    public var timeEntries: [ArchiveTimeEntry]

    public init(
        formatVersion: Int = ArchiveDocument.currentFormatVersion,
        generator: String = "Elephruit",
        schemaVersion: String,
        exportedAt: Date,
        items: [ArchiveItem] = [],
        tags: [ArchiveTag] = [],
        links: [ArchiveLink] = [],
        collections: [ArchiveCollection] = [],
        savedSearches: [ArchiveSavedSearch] = [],
        attachments: [ArchiveAttachment] = [],
        timeEntries: [ArchiveTimeEntry] = []
    ) {
        self.formatVersion = formatVersion
        self.generator = generator
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.items = items
        self.tags = tags
        self.links = links
        self.collections = collections
        self.savedSearches = savedSearches
        self.attachments = attachments
        self.timeEntries = timeEntries
    }

    /// Decoding is tolerant of a missing collection, so an archive written before a record type
    /// existed still reads. Synthesised decoding would have made adding `timeEntries` a breaking
    /// change to a format already in users' hands — which is the opposite of point 4 above.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        generator = try container.decodeIfPresent(String.self, forKey: .generator) ?? "Elephruit"
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "unknown"
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        items = try container.decodeIfPresent([ArchiveItem].self, forKey: .items) ?? []
        tags = try container.decodeIfPresent([ArchiveTag].self, forKey: .tags) ?? []
        links = try container.decodeIfPresent([ArchiveLink].self, forKey: .links) ?? []
        collections = try container.decodeIfPresent([ArchiveCollection].self, forKey: .collections) ?? []
        savedSearches = try container.decodeIfPresent([ArchiveSavedSearch].self, forKey: .savedSearches) ?? []
        attachments = try container.decodeIfPresent([ArchiveAttachment].self, forKey: .attachments) ?? []
        timeEntries = try container.decodeIfPresent([ArchiveTimeEntry].self, forKey: .timeEntries) ?? []
    }

    /// A count summary, for the import and export confirmation UI.
    public var summary: String {
        var parts: [String] = []
        if !items.isEmpty { parts.append("\(items.count) item\(items.count == 1 ? "" : "s")") }
        if !tags.isEmpty { parts.append("\(tags.count) tag\(tags.count == 1 ? "" : "s")") }
        if !links.isEmpty { parts.append("\(links.count) link\(links.count == 1 ? "" : "s")") }
        if !collections.isEmpty { parts.append("\(collections.count) collections") }
        if !savedSearches.isEmpty { parts.append("\(savedSearches.count) saved searches") }
        if !attachments.isEmpty { parts.append("\(attachments.count) attachments") }
        if !timeEntries.isEmpty { parts.append("\(timeEntries.count) time entries") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

// MARK: - Records

/// An item, as written to an archive.
///
/// The kind is a raw `String` rather than an ``ItemKind``, so an archive written by a version
/// that knows about kinds this build does not still imports without losing the field.
public struct ArchiveItem: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: String
    public var title: String
    public var body: String

    public var createdAt: Date
    public var updatedAt: Date
    public var startAt: Date?
    public var dueAt: Date?
    public var deferUntil: Date?
    public var completedAt: Date?
    public var archivedAt: Date?
    public var deletedAt: Date?

    public var status: String
    public var priority: String
    public var isFavorite: Bool
    public var isPinned: Bool
    public var sortOrder: Double

    public var recurrence: RecurrenceRule?
    public var symbolName: String?
    public var colorName: String?
    public var dayKey: String?

    public var sourceKind: String
    public var sourceURL: String?
    public var sourceIdentifier: String?

    /// Tag identifiers, not names — names can be renamed, identifiers cannot.
    public var tagIDs: [UUID]
    public var parentID: UUID?
    public var userMetadata: [String: MetadataValue]

    public init(
        id: UUID,
        kind: String,
        title: String,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        startAt: Date? = nil,
        dueAt: Date? = nil,
        deferUntil: Date? = nil,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        status: String,
        priority: String,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        sortOrder: Double = 0,
        recurrence: RecurrenceRule? = nil,
        symbolName: String? = nil,
        colorName: String? = nil,
        dayKey: String? = nil,
        sourceKind: String,
        sourceURL: String? = nil,
        sourceIdentifier: String? = nil,
        tagIDs: [UUID] = [],
        parentID: UUID? = nil,
        userMetadata: [String: MetadataValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startAt = startAt
        self.dueAt = dueAt
        self.deferUntil = deferUntil
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.status = status
        self.priority = priority
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.recurrence = recurrence
        self.symbolName = symbolName
        self.colorName = colorName
        self.dayKey = dayKey
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.sourceIdentifier = sourceIdentifier
        self.tagIDs = tagIDs
        self.parentID = parentID
        self.userMetadata = userMetadata
    }

    /// Tolerant decoding: a missing optional or absent newer field must not fail the import.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ItemKind.note.rawValue
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        startAt = try container.decodeIfPresent(Date.self, forKey: .startAt)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        deferUntil = try container.decodeIfPresent(Date.self, forKey: .deferUntil)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ItemStatus.none.rawValue
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? Priority.normal.rawValue
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        recurrence = try container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        dayKey = try container.decodeIfPresent(String.self, forKey: .dayKey)
        sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind) ?? SourceKind.archiveImport.rawValue
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceIdentifier)
        tagIDs = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        userMetadata = try container.decodeIfPresent([String: MetadataValue].self, forKey: .userMetadata) ?? [:]
    }
}

public struct ArchiveTag: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var colorName: String?
    public var createdAt: Date
    public var isImplicit: Bool
    public var parentID: UUID?

    public init(
        id: UUID,
        name: String,
        slug: String,
        colorName: String? = nil,
        createdAt: Date,
        isImplicit: Bool = false,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.colorName = colorName
        self.createdAt = createdAt
        self.isImplicit = isImplicit
        self.parentID = parentID
    }
}

public struct ArchiveLink: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: String
    public var sourceID: UUID?
    public var targetID: UUID?
    public var displayText: String?
    public var unresolvedTitle: String?
    public var createdAt: Date

    public init(
        id: UUID,
        kind: String,
        sourceID: UUID?,
        targetID: UUID?,
        displayText: String? = nil,
        unresolvedTitle: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.sourceID = sourceID
        self.targetID = targetID
        self.displayText = displayText
        self.unresolvedTitle = unresolvedTitle
        self.createdAt = createdAt
    }
}

public struct ArchiveCollection: Codable, Sendable, Hashable {
    /// One membership, carrying the position that makes a collection ordered.
    public struct Member: Codable, Sendable, Hashable {
        public var itemID: UUID
        public var position: Double
        public var addedAt: Date
        public var note: String

        public init(itemID: UUID, position: Double, addedAt: Date, note: String = "") {
            self.itemID = itemID
            self.position = position
            self.addedAt = addedAt
            self.note = note
        }
    }

    public var id: UUID
    public var name: String
    public var summary: String
    public var symbolName: String?
    public var colorName: String?
    public var createdAt: Date
    public var sortOrder: Double
    public var isPinned: Bool
    public var members: [Member]

    public init(
        id: UUID,
        name: String,
        summary: String = "",
        symbolName: String? = nil,
        colorName: String? = nil,
        createdAt: Date,
        sortOrder: Double = 0,
        isPinned: Bool = false,
        members: [Member] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.colorName = colorName
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.members = members
    }
}

public struct ArchiveSavedSearch: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var queryString: String
    public var symbolName: String?
    public var colorName: String?
    public var createdAt: Date
    public var sortOrder: Double
    public var showsInSidebar: Bool

    public init(
        id: UUID,
        name: String,
        queryString: String,
        symbolName: String? = nil,
        colorName: String? = nil,
        createdAt: Date,
        sortOrder: Double = 0,
        showsInSidebar: Bool = true
    ) {
        self.id = id
        self.name = name
        self.queryString = queryString
        self.symbolName = symbolName
        self.colorName = colorName
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.showsInSidebar = showsInSidebar
    }
}

public struct ArchiveAttachment: Codable, Sendable, Hashable {
    public var id: UUID
    public var ownerID: UUID?
    public var filename: String
    public var typeIdentifier: String
    public var byteCount: Int
    public var contentHash: String?
    public var createdAt: Date
    public var storageKind: String
    /// Path within the export bundle. `nil` for a reference whose bytes were not copied.
    public var bundlePath: String?
    public var extractedText: String?

    public init(
        id: UUID,
        ownerID: UUID?,
        filename: String,
        typeIdentifier: String,
        byteCount: Int,
        contentHash: String? = nil,
        createdAt: Date,
        storageKind: String,
        bundlePath: String? = nil,
        extractedText: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.storageKind = storageKind
        self.bundlePath = bundlePath
        self.extractedText = extractedText
    }
}

/// A tracked interval, as written to an archive.
///
/// `endedAt` is optional and `nil` means **still running**, exactly as in the store. A timer that
/// was running when the export was taken re-imports as running rather than being silently closed —
/// closing it would invent an end time the user never recorded.
///
/// There is no duration field. Duration is derived from the two instants and storing it separately
/// would create a second version of the truth that could disagree with them.
public struct ArchiveTimeEntry: Codable, Sendable, Hashable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var entryDescription: String
    public var itemID: UUID?
    public var tagIDs: [UUID]
    public var source: String
    public var isBillable: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var lastHeartbeatAt: Date?

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        entryDescription: String = "",
        itemID: UUID? = nil,
        tagIDs: [UUID] = [],
        source: String,
        isBillable: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.entryDescription = entryDescription
        self.itemID = itemID
        self.tagIDs = tagIDs
        self.source = source
        self.isBillable = isBillable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.lastHeartbeatAt = lastHeartbeatAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        entryDescription = try container.decodeIfPresent(String.self, forKey: .entryDescription) ?? ""
        itemID = try container.decodeIfPresent(UUID.self, forKey: .itemID)
        tagIDs = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        isBillable = try container.decodeIfPresent(Bool.self, forKey: .isBillable) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? startedAt
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        lastHeartbeatAt = try container.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
    }
}

// MARK: - Coding

extension ArchiveDocument {
    /// The encoder used for every archive.
    ///
    /// Sorted keys and pretty printing are not cosmetic: they make an archive diffable, which
    /// means a user can keep their exports in version control and see what changed. ISO 8601
    /// dates make it readable without the app.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws(AppError) -> Data {
        do {
            return try Self.makeEncoder().encode(self)
        } catch {
            throw .exportFailed(reason: error.localizedDescription)
        }
    }

    /// Reads an archive, refusing anything this build cannot understand.
    ///
    /// A newer format version is refused *before* anything is written, so a failed import never
    /// leaves the store half-changed.
    public static func decoded(from data: Data) throws(AppError) -> ArchiveDocument {
        let document: ArchiveDocument
        do {
            document = try makeDecoder().decode(ArchiveDocument.self, from: data)
        } catch {
            throw .importFailed(format: "JSON archive", reason: error.localizedDescription)
        }

        guard document.formatVersion <= currentFormatVersion else {
            throw .importFailed(
                format: "JSON archive",
                reason: """
                    This archive was written by a newer version of Elephruit \
                    (format \(document.formatVersion); this version reads up to \
                    \(currentFormatVersion)). Update Elephruit and try again.
                    """
            )
        }

        return document
    }
}
