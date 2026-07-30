import EverythingCore
import Foundation
import SwiftData

/// The single node type of the content graph.
///
/// Notes, tasks, projects, areas, people, bookmarks, and daily entries are all `Item`,
/// discriminated by ``Item/kind``. See `docs/adr/0002-single-item-entity.md` for why,
/// and `docs/04-domain-model.md` for the field-by-field breakdown.
///
/// **CloudKit compliance, honoured from v1** even though sync ships later, because
/// retrofitting these onto a populated store is a data migration:
/// every attribute has a default value; there are no unique constraints; every to-one
/// relationship is optional; every relationship pair declares an inverse; no delete
/// rule is `.deny`.
@Model
public final class Item {
    // MARK: Identity

    /// Stable across export and import.
    ///
    /// Not `@Attribute(.unique)` — CloudKit mirroring forbids unique constraints.
    /// Uniqueness is enforced by `ItemRepository` on insert and by the importer, and is
    /// covered by a test that attempts a duplicate.
    public var id: UUID = UUID()

    /// ``ItemKind`` raw value.
    ///
    /// Stored as a string rather than an enum so a store written by a newer build — one
    /// containing kinds this build has never heard of — reads without loss. Unknown
    /// values surface as ``ItemKind/reference`` for display and are never written back.
    public var kindRaw: String = ItemKind.note.rawValue

    // MARK: Content

    public var title: String = ""

    /// Markdown-compatible plain text. Always plain text — see the editor's scope note
    /// in `docs/08-risks.md`.
    public var body: String = ""

    /// Denormalised projection of title, body, tag slugs, and person names.
    ///
    /// A derived value, recomputed on every save by ``Item/refreshSearchText()``, so it
    /// cannot become a second source of truth. It exists so the predicate-only search
    /// path stays correct before the in-memory index warms or after a cache purge.
    public var searchText: String = ""

    // MARK: Timestamps

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var startAt: Date?
    public var dueAt: Date?

    /// Hidden from Today until this date arrives.
    public var deferUntil: Date?

    public var completedAt: Date?

    /// Non-nil means archived: kept, but out of the way.
    public var archivedAt: Date?

    /// Non-nil means in Trash. Soft deletion is the only deletion the UI performs.
    public var deletedAt: Date?

    // MARK: State

    /// ``ItemStatus`` raw value.
    public var statusRaw: String = ItemStatus.none.rawValue

    /// ``Priority`` raw value.
    public var priorityRaw: String = Priority.normal.rawValue

    public var isFavorite: Bool = false
    public var isPinned: Bool = false

    /// Sparse, gap-based ordering, so a manual reorder writes one row rather than
    /// renumbering the whole list.
    public var sortOrder: Double = 0

    /// JSON-encoded ``RecurrenceRule``. `nil` means the item does not repeat.
    public var recurrenceData: Data?

    // MARK: Presentation

    /// User's SF Symbol override. `nil` falls back to the kind's symbol.
    public var symbolName: String?

    /// Semantic palette key, resolved by the design system. Never a raw colour value,
    /// so appearance stays correct in light, dark, and increased-contrast modes.
    public var colorName: String?

    // MARK: Provenance

    /// ``SourceKind`` raw value.
    public var sourceKindRaw: String = SourceKind.manual.rawValue

    /// The item's own URL, for bookmarks, or where it came from.
    public var sourceURLString: String?

    /// Meaningful to whatever created this — an importer name, a source file path.
    public var sourceIdentifier: String?

    // MARK: Extension

    /// JSON-encoded `[String: MetadataValue]`. The escape hatch for fields the app does
    /// not model. App logic never reads it.
    public var userMetadataData: Data?

    /// `yyyy-MM-dd`, for ``ItemKind/dailyEntry``. Indexed.
    public var dayKey: String?

    // MARK: Relationships

    /// The containing item. The one containment hierarchy:
    /// Area ▸ Project ▸ Task ▸ Subtask, with notes attachable to any container.
    public var parent: Item?

    /// Contained items. Cascades: trashing a project trashes its tasks.
    @Relationship(deleteRule: .cascade, inverse: \Item.parent)
    public var children: [Item] = []

    @Relationship(inverse: \Tag.items)
    public var tags: [Tag] = []

    /// Links *from* this item. Cascade: the link belongs to its source.
    @Relationship(deleteRule: .cascade, inverse: \ItemLink.source)
    public var outgoingLinks: [ItemLink] = []

    /// Links *to* this item — the raw material of the Backlinks section, which is a
    /// query over this and never a second stored copy.
    @Relationship(deleteRule: .cascade, inverse: \ItemLink.target)
    public var incomingLinks: [ItemLink] = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.owner)
    public var attachments: [Attachment] = []

    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.item)
    public var collectionMemberships: [CollectionMembership] = []

    /// Present only for ``ItemKind/person``.
    @Relationship(deleteRule: .cascade, inverse: \PersonProfile.item)
    public var personProfile: PersonProfile?

    /// Present only for ``ItemKind/meeting``.
    @Relationship(deleteRule: .cascade, inverse: \EventReference.item)
    public var eventReference: EventReference?

    // MARK: Init

    /// Everything defaulted, which is both a CloudKit requirement and a convenience:
    /// `Item()` is a valid empty note.
    public init(
        id: UUID = UUID(),
        kind: ItemKind = .note,
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ItemStatus = .none,
        priority: Priority = .normal,
        source: ItemSource = .manual,
        sortOrder: Double = 0
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRaw = status.rawValue
        self.priorityRaw = priority.rawValue
        self.sourceKindRaw = source.kind.rawValue
        self.sourceURLString = source.url?.absoluteString
        self.sourceIdentifier = source.identifier
        self.sortOrder = sortOrder
        self.searchText = Self.projectedSearchText(title: title, body: body, tagSlugs: [], extra: nil)
    }
}

// MARK: - Typed accessors

extension Item {
    /// The item's kind. Unknown stored values read as ``ItemKind/reference`` so a
    /// forward-compatible store still displays, and the raw value is left untouched.
    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .reference }
        set { kindRaw = newValue.rawValue }
    }

    public var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }

    public var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    public var recurrence: RecurrenceRule? {
        get { RecurrenceRule.decode(from: recurrenceData) }
        set { recurrenceData = newValue?.encoded() }
    }

    public var source: ItemSource {
        get {
            ItemSource(
                kind: SourceKind(rawValue: sourceKindRaw) ?? .manual,
                url: sourceURLString.flatMap(URL.init(string:)),
                identifier: sourceIdentifier
            )
        }
        set {
            sourceKindRaw = newValue.kind.rawValue
            sourceURLString = newValue.url?.absoluteString
            sourceIdentifier = newValue.identifier
        }
    }

    /// User-defined fields. Unreadable data reads as empty rather than throwing: a note
    /// with a corrupt metadata blob is still a perfectly good note.
    public var userMetadata: [String: MetadataValue] {
        get {
            guard let userMetadataData else { return [:] }
            return (try? JSONDecoder().decode([String: MetadataValue].self, from: userMetadataData)) ?? [:]
        }
        set {
            userMetadataData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}

// MARK: - ContentItem

extension Item: ContentItem {
    public var tagSlugs: [String] {
        tags.map(\.slug).sorted()
    }

    public var parentTitle: String? {
        guard let parent else { return nil }
        return parent.displayTitle
    }
}

// MARK: - Derived values

extension Item {
    /// Recomputes ``Item/searchText``. Called on every save path.
    public func refreshSearchText() {
        searchText = Self.projectedSearchText(
            title: title,
            body: body,
            tagSlugs: tags.map(\.slug),
            extra: personProfile?.searchableText
        )
    }

    /// The projection, as a pure function so it can be tested without a store.
    public static func projectedSearchText(
        title: String,
        body: String,
        tagSlugs: [String],
        extra: String?
    ) -> String {
        var parts = [title, body]
        parts.append(contentsOf: tagSlugs)
        if let extra { parts.append(extra) }

        return TextNormalizer.foldedForMatching(
            parts.filter { !$0.isEmpty }.joined(separator: " \n ")
        )
    }

    /// A `Sendable` copy, for crossing an isolation boundary.
    ///
    /// The only sanctioned way to hand item data to background work. A `PersistentModel`
    /// never leaves the context that owns it.
    public func snapshot() -> ItemSnapshot {
        ItemSnapshot(
            id: id,
            kind: kind,
            title: title,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: status,
            priority: priority,
            startAt: startAt,
            dueAt: dueAt,
            deferUntil: deferUntil,
            completedAt: completedAt,
            archivedAt: archivedAt,
            deletedAt: deletedAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            tagSlugs: tagSlugs,
            parentID: parent?.id,
            parentTitle: parent?.title,
            symbolName: symbolName,
            colorName: colorName,
            dayKey: dayKey,
            source: source,
            recurrence: recurrence,
            userMetadata: userMetadata,
            sortOrder: sortOrder
        )
    }

    /// Backlinks worth showing: incoming links whose kind belongs in that section and
    /// whose source is neither trashed nor the item itself.
    public func visibleBacklinks() -> [ItemLink] {
        incomingLinks.filter { link in
            guard link.kind.appearsInBacklinks else { return false }
            guard let source = link.source else { return false }
            return source.deletedAt == nil && source.id != id
        }
    }

    /// Ancestors, outermost last. Bounded, so a cycle introduced by a bug cannot hang
    /// the UI — validation prevents cycles, and this is the belt to that braces.
    public func ancestors(limit: Int = 32) -> [Item] {
        var result: [Item] = []
        var seen: Set<UUID> = [id]
        var cursor = parent

        while let current = cursor, result.count < limit, seen.insert(current.id).inserted {
            result.append(current)
            cursor = current.parent
        }

        return result
    }
}
