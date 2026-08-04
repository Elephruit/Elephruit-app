import ElephruitCore
import ElephruitModel
import Foundation

/// A snapshot of an item's mutable state, taken before an edit so it can be put back if the
/// edit turns out to be invalid.
///
/// ### Why this exists rather than `ModelContext.rollback()`
///
/// `rollback()` discards the context's *unsaved changes*, but — verified by
/// `itemRecoversAfterRejectedEdit` — it does **not** restore the property values already
/// written to the live model object. So after a rejected edit the object kept its invalid
/// state, and the user's next perfectly good edit failed validation too. The interface would
/// have shown an error dialogue and then refused to work.
///
/// Restoring explicitly is deterministic and does not depend on framework rollback semantics.
/// `rollback()` is still called afterwards, to discard relationship edits and any other
/// pending change this type does not track.
struct ItemRestorePoint {
    private let kindRaw: String
    private let title: String
    private let body: String
    private let statusRaw: String
    private let priorityRaw: String
    private let startAt: Date?
    private let dueAt: Date?
    private let deferUntil: Date?
    private let completedAt: Date?
    private let archivedAt: Date?
    private let deletedAt: Date?
    private let isFavorite: Bool
    private let isPinned: Bool
    private let sortOrder: Double
    private let recurrenceData: Data?
    private let symbolName: String?
    private let colorName: String?
    private let dayKey: String?
    private let updatedAt: Date
    private let searchText: String
    private let userMetadataData: Data?
    private let sourceKindRaw: String
    private let sourceURLString: String?
    private let sourceIdentifier: String?

    /// Held as object references rather than identifiers, because restoring must not need a
    /// fetch — a fetch during error recovery is one more thing that can fail.
    private let parent: Item?
    private let tags: [ElephruitModel.Tag]

    init(_ item: Item) {
        kindRaw = item.kindRaw
        title = item.title
        body = item.body
        statusRaw = item.statusRaw
        priorityRaw = item.priorityRaw
        startAt = item.startAt
        dueAt = item.dueAt
        deferUntil = item.deferUntil
        completedAt = item.completedAt
        archivedAt = item.archivedAt
        deletedAt = item.deletedAt
        isFavorite = item.isFavorite
        isPinned = item.isPinned
        sortOrder = item.sortOrder
        recurrenceData = item.recurrenceData
        symbolName = item.symbolName
        colorName = item.colorName
        dayKey = item.dayKey
        updatedAt = item.updatedAt
        searchText = item.searchText
        userMetadataData = item.userMetadataData
        sourceKindRaw = item.sourceKindRaw
        sourceURLString = item.sourceURLString
        sourceIdentifier = item.sourceIdentifier
        parent = item.parent
        tags = item.tags ?? []
    }

    /// Puts every tracked field back as it was.
    func restore(onto item: Item) {
        item.kindRaw = kindRaw
        item.title = title
        item.body = body
        item.statusRaw = statusRaw
        item.priorityRaw = priorityRaw
        item.startAt = startAt
        item.dueAt = dueAt
        item.deferUntil = deferUntil
        item.completedAt = completedAt
        item.archivedAt = archivedAt
        item.deletedAt = deletedAt
        item.isFavorite = isFavorite
        item.isPinned = isPinned
        item.sortOrder = sortOrder
        item.recurrenceData = recurrenceData
        item.symbolName = symbolName
        item.colorName = colorName
        item.dayKey = dayKey
        item.updatedAt = updatedAt
        item.searchText = searchText
        item.userMetadataData = userMetadataData
        item.sourceKindRaw = sourceKindRaw
        item.sourceURLString = sourceURLString
        item.sourceIdentifier = sourceIdentifier
        item.parent = parent
        item.tags = tags
    }
}
