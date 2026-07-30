import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData

/// How to treat an incoming record that already exists.
public enum DuplicatePolicy: String, Sendable, Hashable, CaseIterable {
    /// Leave the existing item alone. The safe default: an import should never destroy something
    /// the user has since edited.
    case skip

    /// Overwrite the existing item with the incoming one.
    case replace

    /// Insert the incoming record under a fresh identifier, keeping both.
    case keepBoth

    public var displayName: String {
        switch self {
        case .skip: "Skip duplicates"
        case .replace: "Replace existing"
        case .keepBoth: "Keep both"
        }
    }

    public var explanation: String {
        switch self {
        case .skip: "Items already in your library are left untouched."
        case .replace: "Items already in your library are overwritten by the imported version."
        case .keepBoth: "Imported copies are added alongside what you already have."
        }
    }
}

/// What an import did.
///
/// Reported in full, including what was skipped and why. An import that says only "done" leaves
/// the user unable to tell whether it worked.
public struct ImportReport: Sendable, Hashable {
    public var format: String
    public var itemsCreated: Int = 0
    public var itemsUpdated: Int = 0
    public var itemsSkipped: Int = 0
    public var tagsCreated: Int = 0
    public var linksCreated: Int = 0
    public var collectionsCreated: Int = 0
    public var savedSearchesCreated: Int = 0

    /// Non-fatal problems: a record that could not be read, a relationship whose target was
    /// absent. Surfaced rather than swallowed.
    public var warnings: [String] = []

    public init(format: String) {
        self.format = format
    }

    public var totalItemsTouched: Int {
        itemsCreated + itemsUpdated
    }

    public var summary: String {
        var parts: [String] = []
        if itemsCreated > 0 { parts.append("\(itemsCreated) added") }
        if itemsUpdated > 0 { parts.append("\(itemsUpdated) updated") }
        if itemsSkipped > 0 { parts.append("\(itemsSkipped) skipped") }
        if tagsCreated > 0 { parts.append("\(tagsCreated) new tags") }
        if linksCreated > 0 { parts.append("\(linksCreated) links") }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: ", ")
    }
}

/// Reads data in.
///
/// ### Order of operations
/// Validation happens *before* anything is written, and the whole import is one save. A failed
/// import therefore leaves the store exactly as it was — which is the only acceptable behaviour
/// for an operation the user cannot undo by hand.
///
/// Relationships are resolved in a second pass over identifier references, so record order in the
/// file is irrelevant and a parent may appear after its child.
@MainActor
public struct Importer {
    private let items: any ItemRepository
    private let tags: TagRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(
        items: any ItemRepository,
        tags: TagRepository,
        context: ModelContext,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.tags = tags
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - JSON archive

    /// Imports a versioned JSON archive, preserving identifiers and relationships.
    public func importArchive(
        _ data: Data,
        policy: DuplicatePolicy = .skip
    ) throws(AppError) -> ImportReport {
        let archive = try ArchiveDocument.decoded(from: data)
        return try apply(archive, policy: policy)
    }

    /// Applies a decoded archive.
    public func apply(
        _ archive: ArchiveDocument,
        policy: DuplicatePolicy = .skip
    ) throws(AppError) -> ImportReport {
        var report = ImportReport(format: "JSON archive")

        // Tags first: items reference them.
        var tagsByArchiveID: [UUID: ElephruitModel.Tag] = [:]
        for record in archive.tags {
            let (tag, created) = try resolveTag(record)
            tagsByArchiveID[record.id] = tag
            if created { report.tagsCreated += 1 }
        }
        for record in archive.tags {
            guard let parentID = record.parentID,
                  let tag = tagsByArchiveID[record.id],
                  let parent = tagsByArchiveID[parentID]
            else { continue }
            tag.parent = parent
        }

        // Items, without relationships.
        var itemsByArchiveID: [UUID: Item] = [:]
        for record in archive.items {
            switch try resolveItem(record, policy: policy, tagsByArchiveID: tagsByArchiveID) {
            case .created(let item):
                itemsByArchiveID[record.id] = item
                report.itemsCreated += 1
            case .updated(let item):
                itemsByArchiveID[record.id] = item
                report.itemsUpdated += 1
            case .skipped(let existing):
                // Still mapped, so incoming links can point at what is already there.
                itemsByArchiveID[record.id] = existing
                report.itemsSkipped += 1
            }
        }

        // Second pass: containment.
        for record in archive.items {
            guard let parentID = record.parentID,
                  let item = itemsByArchiveID[record.id],
                  let parent = itemsByArchiveID[parentID]
            else {
                if record.parentID != nil {
                    report.warnings.append("“\(record.title)” referenced a container that was not in the archive.")
                }
                continue
            }

            // An archive from a newer version could contain a hierarchy this build considers
            // illegal. Dropping the parent keeps the item rather than failing the whole import.
            if parent.kind.canContain(item.kind), parent.id != item.id {
                item.parent = parent
            } else {
                report.warnings.append("“\(record.title)” could not be placed inside “\(parent.title)”.")
            }
        }

        // Links.
        let existingLinkIDs = try fetchExistingLinkIDs()
        for record in archive.links where !existingLinkIDs.contains(record.id) {
            let link = ItemLink(
                id: record.id,
                kind: LinkKind(rawValue: record.kind) ?? .related,
                source: record.sourceID.flatMap { itemsByArchiveID[$0] },
                target: record.targetID.flatMap { itemsByArchiveID[$0] },
                displayText: record.displayText,
                unresolvedTitle: record.unresolvedTitle,
                createdAt: record.createdAt
            )

            // A link with no source is not a link; it is a dangling row.
            guard link.source != nil else {
                report.warnings.append("A link was dropped because its source item was missing.")
                continue
            }

            context.insert(link)
            report.linksCreated += 1
        }

        // Collections and their ordering.
        let existingCollectionIDs = try fetchExistingCollectionIDs()
        for record in archive.collections where !existingCollectionIDs.contains(record.id) {
            let collection = ItemCollection(
                id: record.id,
                name: record.name,
                summary: record.summary,
                symbolName: record.symbolName,
                colorName: record.colorName,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt
            )
            collection.isPinned = record.isPinned
            context.insert(collection)

            for member in record.members {
                guard let item = itemsByArchiveID[member.itemID] else { continue }
                context.insert(
                    CollectionMembership(
                        collection: collection,
                        item: item,
                        position: member.position,
                        note: member.note,
                        addedAt: member.addedAt
                    )
                )
            }

            report.collectionsCreated += 1
        }

        // Saved searches.
        let existingSearchIDs = try fetchExistingSavedSearchIDs()
        for record in archive.savedSearches where !existingSearchIDs.contains(record.id) {
            let search = SavedSearch(
                id: record.id,
                name: record.name,
                queryString: record.queryString,
                symbolName: record.symbolName,
                colorName: record.colorName,
                showsInSidebar: record.showsInSidebar,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt
            )
            context.insert(search)
            report.savedSearchesCreated += 1
        }

        // Search text depends on tags, which were attached above.
        for item in itemsByArchiveID.values {
            item.refreshSearchText()
        }

        try save()

        Diagnostics.transfer.info(
            "Imported archive: \(report.itemsCreated) created, \(report.itemsUpdated) updated, \(report.itemsSkipped) skipped"
        )
        return report
    }

    // MARK: - Markdown

    /// Imports one or more Markdown files.
    ///
    /// A file's front-matter identifier is honoured when present, so a bundle exported by
    /// Elephruit round-trips. A file without front-matter — the usual case for Markdown from
    /// elsewhere — becomes a new note titled by its first heading or its filename.
    public func importMarkdownFiles(
        _ files: [(filename: String, contents: String)],
        policy: DuplicatePolicy = .skip
    ) throws(AppError) -> ImportReport {
        var report = ImportReport(format: "Markdown")

        for file in files {
            let (fields, body) = MarkdownFrontMatter.parse(file.contents)

            let identifier = fields["id"].flatMap(UUID.init(uuidString:)) ?? UUID()
            let kindRaw = fields["kind"] ?? ItemKind.note.rawValue
            let kind = ItemKind(rawValue: kindRaw) ?? .note

            let title = fields["title"] ?? Self.inferTitle(fromBody: body, filename: file.filename)
            let tagNames = fields["tags"].map(MarkdownFrontMatter.parseList) ?? []

            if let existing = try items.item(id: identifier) {
                switch policy {
                case .skip:
                    report.itemsSkipped += 1
                    continue
                case .replace:
                    try items.update(existing) { item in
                        item.title = title
                        item.body = body
                    }
                    if !tagNames.isEmpty {
                        try items.setTags(existing, slugs: tagNames)
                    }
                    report.itemsUpdated += 1
                    continue
                case .keepBoth:
                    break  // Falls through to a create with a fresh identifier.
                }
            }

            var draft = ItemDraft(
                id: policy == .keepBoth ? UUID() : identifier,
                kind: kind,
                title: title,
                body: body,
                tagSlugs: tagNames,
                source: ItemSource(kind: .markdownImport, identifier: file.filename)
            )

            let fields2 = fields  // Captured for clarity below.
            if kind.supportedFields.contains(.dueDate) {
                draft.dueAt = fields2["due"].flatMap(MarkdownFrontMatter.date(from:))
            }
            if kind.supportedFields.contains(.startDate) {
                draft.startAt = fields2["start"].flatMap(MarkdownFrontMatter.date(from:))
            }
            if kind.supportedFields.contains(.dayKey) {
                draft.dayKey = fields2["day"]
            }

            do {
                let created = try items.create(draft)
                try applyMarkdownState(fields: fields, to: created)
                report.itemsCreated += 1
            } catch {
                // One bad file must not abandon the rest of the import.
                report.warnings.append("“\(file.filename)” could not be imported: \(error.errorDescription ?? "unknown reason")")
            }
        }

        try save()
        Diagnostics.transfer.info("Imported \(report.itemsCreated, privacy: .public) Markdown file(s)")
        return report
    }

    /// Applies front-matter state that has to be set after creation, because creation enforces
    /// its own defaults.
    private func applyMarkdownState(fields: [String: String], to item: Item) throws(AppError) {
        try items.update(item) { subject in
            if let statusRaw = fields["status"], let status = ItemStatus(rawValue: statusRaw),
               subject.kind.supportsStatus {
                subject.status = status
                // Keeps the completion invariant: a completed item must carry a date.
                if status == .completed {
                    subject.completedAt = fields["completed"].flatMap(MarkdownFrontMatter.date(from:))
                        ?? self.dateProvider.now
                } else {
                    subject.completedAt = nil
                }
            }

            if let priorityRaw = fields["priority"], let priority = Priority(rawValue: priorityRaw),
               subject.kind.supportedFields.contains(.priority) {
                subject.priority = priority
            }

            subject.isFavorite = fields["favorite"] == "true"
            subject.isPinned = fields["pinned"] == "true"
            subject.archivedAt = fields["archived"].flatMap(MarkdownFrontMatter.date(from:))

            if let created = fields["created"].flatMap(MarkdownFrontMatter.date(from:)) {
                subject.createdAt = created
            }
        }
    }

    /// A title from the body's first heading, else from the filename.
    static func inferTitle(fromBody body: String, filename: String) -> String {
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }

        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "Untitled" : stem
    }

    // MARK: - Resolution

    private enum ItemResolution {
        case created(Item)
        case updated(Item)
        case skipped(Item)
    }

    private func resolveItem(
        _ record: ArchiveItem,
        policy: DuplicatePolicy,
        tagsByArchiveID: [UUID: ElephruitModel.Tag]
    ) throws(AppError) -> ItemResolution {
        let existing = try items.item(id: record.id)

        if let existing {
            switch policy {
            case .skip:
                return .skipped(existing)
            case .replace:
                apply(record, to: existing, tagsByArchiveID: tagsByArchiveID)
                return .updated(existing)
            case .keepBoth:
                break
            }
        }

        let item = Item(id: policy == .keepBoth && existing != nil ? UUID() : record.id)
        apply(record, to: item, tagsByArchiveID: tagsByArchiveID)
        context.insert(item)
        return .created(item)
    }

    /// Copies a record onto a model object.
    ///
    /// Writes `kindRaw` rather than `kind`, so an unknown future kind survives the round trip
    /// instead of being flattened. Fields the kind does not support are dropped rather than
    /// written and then rejected by validation.
    private func apply(_ record: ArchiveItem, to item: Item, tagsByArchiveID: [UUID: ElephruitModel.Tag]) {
        item.kindRaw = record.kind
        item.title = record.title
        item.body = record.body
        item.createdAt = record.createdAt
        item.updatedAt = record.updatedAt
        item.archivedAt = record.archivedAt
        item.deletedAt = record.deletedAt
        item.isFavorite = record.isFavorite
        item.isPinned = record.isPinned
        item.sortOrder = record.sortOrder
        item.symbolName = record.symbolName
        item.colorName = record.colorName
        item.userMetadata = record.userMetadata
        item.sourceKindRaw = record.sourceKind
        item.sourceURLString = record.sourceURL
        item.sourceIdentifier = record.sourceIdentifier

        let fields = item.kind.supportedFields

        if fields.contains(.status), let status = ItemStatus(rawValue: record.status) {
            item.status = status
            item.completedAt = status == .completed ? (record.completedAt ?? record.updatedAt) : nil
        } else {
            item.status = .none
            item.completedAt = nil
        }

        item.priority = fields.contains(.priority) ? (Priority(rawValue: record.priority) ?? .normal) : .normal
        item.startAt = fields.contains(.startDate) ? record.startAt : nil
        item.dueAt = fields.contains(.dueDate) ? record.dueAt : nil
        item.deferUntil = fields.contains(.deferDate) ? record.deferUntil : nil
        item.recurrence = fields.contains(.recurrence) ? record.recurrence : nil
        item.dayKey = fields.contains(.dayKey) ? record.dayKey : nil

        // A start after its due date would fail validation; the due date is the one users act on.
        if let startAt = item.startAt, let dueAt = item.dueAt, startAt > dueAt {
            item.startAt = nil
        }

        item.tags = record.tagIDs.compactMap { tagsByArchiveID[$0] }
    }

    private func resolveTag(_ record: ArchiveTag) throws(AppError) -> (ElephruitModel.Tag, Bool) {
        // Matched by slug rather than identifier: two libraries can have arrived at the same tag
        // independently, and merging them is right where duplicating them is not.
        if let existing = try tags.tag(slug: record.slug) {
            return (existing, false)
        }

        let tag = ElephruitModel.Tag(
            id: record.id,
            name: record.name.isEmpty ? record.slug : record.name,
            colorName: record.colorName,
            isImplicit: record.isImplicit,
            createdAt: record.createdAt
        )
        tag.slug = record.slug
        context.insert(tag)
        return (tag, true)
    }

    // MARK: - Existing identifiers

    private func fetchExistingLinkIDs() throws(AppError) -> Set<UUID> {
        do {
            return Set(try context.fetch(FetchDescriptor<ItemLink>()).map(\.id))
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func fetchExistingCollectionIDs() throws(AppError) -> Set<UUID> {
        do {
            return Set(try context.fetch(FetchDescriptor<ItemCollection>()).map(\.id))
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func fetchExistingSavedSearchIDs() throws(AppError) -> Set<UUID> {
        do {
            return Set(try context.fetch(FetchDescriptor<SavedSearch>()).map(\.id))
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func save() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw .importFailed(format: "import", reason: error.localizedDescription)
        }
    }
}
