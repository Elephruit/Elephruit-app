import EverythingCore
import Foundation
import SwiftData

/// A manually ordered grouping of items — the thing a tag cannot be.
///
/// Named `ItemCollection` rather than `Collection` to avoid shadowing the standard
/// library protocol.
///
/// Order is real user data, and SwiftData to-many relationships are unordered, so
/// membership is an explicit entity carrying a ``CollectionMembership/position``. This is
/// the canonical case of a relationship that needs metadata of its own.
@Model
public final class ItemCollection {
    public var id: UUID = UUID()
    public var name: String = ""

    /// Free text explaining what the collection is for.
    public var summary: String = ""

    public var symbolName: String?
    public var colorName: String?

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Position among collections in the sidebar. Sparse, like ``Item/sortOrder``.
    public var sortOrder: Double = 0

    public var isPinned: Bool = false

    /// Non-nil means in Trash.
    public var deletedAt: Date?

    /// Cascade: a membership has no meaning without its collection. The items
    /// themselves are untouched — that is the whole point of the join entity.
    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.collection)
    public var memberships: [CollectionMembership] = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        summary: String = "",
        symbolName: String? = nil,
        colorName: String? = nil,
        sortOrder: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.colorName = colorName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

extension ItemCollection {
    /// Members in the user's order, skipping trashed items and broken memberships.
    public func orderedItems() -> [Item] {
        memberships
            .sorted { $0.position < $1.position }
            .compactMap(\.item)
            .filter { $0.deletedAt == nil }
    }

    public var activeItemCount: Int {
        memberships.count { ($0.item?.deletedAt) == nil && $0.item != nil }
    }

    public var displayName: String {
        name.isEmpty ? "Untitled Collection" : name
    }

    public var effectiveSymbolName: String {
        symbolName ?? "square.stack"
    }
}

/// An item's place in a collection.
///
/// Exists so that order — and, later, per-membership notes — has somewhere to live.
@Model
public final class CollectionMembership {
    public var id: UUID = UUID()

    /// Sparse position within the collection. Gap-based, so inserting between two
    /// neighbours writes one row.
    public var position: Double = 0

    public var addedAt: Date = Date()

    /// Why this item is in this collection. Room the join entity gives us for free.
    public var note: String = ""

    public var collection: ItemCollection?
    public var item: Item?

    public init(
        id: UUID = UUID(),
        collection: ItemCollection? = nil,
        item: Item? = nil,
        position: Double = 0,
        note: String = "",
        addedAt: Date = Date()
    ) {
        self.id = id
        self.collection = collection
        self.item = item
        self.position = position
        self.note = note
        self.addedAt = addedAt
    }
}

/// A query the user chose to keep.
///
/// Stored as the **query string the user typed**, not as a compiled predicate: durable
/// across app versions, exportable as text, and editable by hand. The cost is that a
/// saved search can become invalid if the grammar changes, which is handled by showing
/// the parse error in place with the text still editable.
@Model
public final class SavedSearch {
    public var id: UUID = UUID()
    public var name: String = ""

    /// The raw query — `type:task tag:urgent due:<7d`.
    public var queryString: String = ""

    public var symbolName: String?
    public var colorName: String?

    public var createdAt: Date = Date()
    public var lastUsedAt: Date?

    public var sortOrder: Double = 0

    /// Whether it appears in the sidebar as a smart view.
    public var showsInSidebar: Bool = true

    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        queryString: String = "",
        symbolName: String? = nil,
        colorName: String? = nil,
        showsInSidebar: Bool = true,
        sortOrder: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.queryString = queryString
        self.symbolName = symbolName
        self.colorName = colorName
        self.showsInSidebar = showsInSidebar
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

extension SavedSearch {
    public var displayName: String {
        name.isEmpty ? queryString : name
    }

    public var effectiveSymbolName: String {
        symbolName ?? "line.3.horizontal.decrease.circle"
    }
}
