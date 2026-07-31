import ElephruitCore
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

    /// A JSON-encoded ``TaskFilter``, when this saved search is a **task smart list**.
    ///
    /// ### Why this is a column here rather than an entity of its own
    /// A smart list needs everything a saved search already has — a name, a symbol, a colour, a
    /// place in the sidebar, an order, a soft delete — and differs in exactly one respect: how its
    /// membership is decided. Adding an entity would have duplicated six fields and their handling
    /// in the sidebar, the command palette, export, and trash.
    ///
    /// It is not the ``queryString`` because the two are genuinely different things. A saved search
    /// stores the text the user typed, deliberately, so it survives a grammar change and can be
    /// edited by hand. A smart list is built from menus, has to round-trip *back* into those menus,
    /// and half its conditions name records by identity — and an identity cannot be written into a
    /// string that is meant to survive a rename.
    ///
    /// `nil` means an ordinary saved search. Both are never set at once; ``isTaskSmartList`` is what
    /// every reader asks.
    public var taskFilterData: Data?

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
        symbolName ?? (isTaskSmartList ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
    }

    /// Whether this row is a task smart list rather than a saved text search.
    public var isTaskSmartList: Bool {
        taskFilterData != nil
    }

    /// The rules, when this is a smart list.
    ///
    /// Setting a filter clears the query string, because a row that carried both would have two
    /// answers to "what is in here" and no way to say which won.
    public var taskFilter: TaskFilter? {
        get { TaskFilter.decode(from: taskFilterData) }
        set {
            taskFilterData = newValue?.encoded()
            if newValue != nil { queryString = "" }
        }
    }
}
