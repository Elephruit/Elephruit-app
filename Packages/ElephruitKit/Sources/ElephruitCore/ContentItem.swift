import Foundation

/// A read-only view of an item, sufficient to render it.
///
/// This is the `ContentItem` concept from the brief, scoped to what it can usefully be:
/// a **display protocol**, not a storage abstraction. SwiftData relationships must name
/// a concrete `PersistentModel`, so a protocol cannot stand in for the stored entity —
/// see `docs/adr/0002-single-item-entity.md`. What it *can* do is let the design system
/// render rows without importing the model layer, and let previews supply fixtures with
/// no store at all.
///
/// Not `Sendable`: conforming types include SwiftData models, which are not. Use
/// ``ItemSnapshot`` to cross an isolation boundary.
public protocol ContentItem {
    var id: UUID { get }
    var kind: ItemKind { get }
    var title: String { get }
    var body: String { get }

    var createdAt: Date { get }
    var updatedAt: Date { get }

    var status: ItemStatus { get }
    var priority: Priority { get }

    var startAt: Date? { get }
    var dueAt: Date? { get }
    var completedAt: Date? { get }
    var archivedAt: Date? { get }
    var deletedAt: Date? { get }

    var isFavorite: Bool { get }
    var isPinned: Bool { get }

    /// Tag slugs, for rendering chips without loading tag objects.
    var tagSlugs: [String] { get }

    /// The containing item's title, if any — a task's project, a project's area.
    var parentTitle: String? { get }

    var symbolName: String? { get }
    var colorName: String? { get }
}

extension ContentItem {
    /// The title to show, falling back to the body's first line and then to a
    /// kind-specific placeholder. Never empty, so a row is never blank.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let inferred = TextNormalizer.inferredTitle(fromBody: body)
        if !inferred.isEmpty { return inferred }

        return "Untitled \(kind.displayName)"
    }

    /// Whether the title shown is a placeholder rather than something the user wrote.
    public var hasPlaceholderTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A one-line preview for list rows.
    public var excerpt: String {
        TextNormalizer.excerpt(from: body)
    }

    public var isInTrash: Bool { deletedAt != nil }
    public var isArchived: Bool { archivedAt != nil }

    /// Visible in ordinary views: neither trashed nor archived.
    public var isActive: Bool { deletedAt == nil && archivedAt == nil }

    public var isCompleted: Bool { status == .completed }

    /// Whether this asks something of the user right now.
    public var isActionable: Bool {
        isActive && kind.supportsStatus && status == .open
    }

    /// Symbol to render: the item's own override, else its kind's.
    public var effectiveSymbolName: String {
        symbolName ?? kind.symbolName
    }

    /// Whether the due date has passed, relative to the given provider.
    public func isOverdue(using dateProvider: any DateProvider) -> Bool {
        guard isActionable, let dueAt else { return false }
        return dateProvider.isOverdue(dueAt)
    }

    /// A composed VoiceOver description.
    ///
    /// Built here rather than at each call site so every list, every search result, and
    /// every inspector announce an item the same way.
    public func accessibilityDescription(using dateProvider: any DateProvider) -> String {
        var parts: [String] = [kind.displayName, displayTitle]

        if kind.supportsStatus {
            parts.append(status == .completed ? "completed" : "incomplete")
        }
        // The same date the row draws, named the same way it is named on screen.
        //
        // These two used to disagree, and the disagreement grew when the row learned to show a
        // last-edited date: the row drew one, and this announced nothing at all, so a list of notes
        // was fully dated for anybody looking at it and undated for anybody listening to it. Reading
        // from ``RowDate`` is what keeps them one decision rather than two.
        //
        // It also carries the part the screen drops. The row shows a bare date for a deadline and a
        // bare date for a last edit, and tells them apart by colour and by the row's own glyph;
        // neither of those reaches VoiceOver, so the word does.
        if let rowDate = RowDate.resolve(for: self) {
            let relative = rowDate.date.formatted(.relative(presentation: .named))
            switch rowDate.role {
            case .due:
                parts.append(dateProvider.isOverdue(rowDate.date) ? "overdue \(relative)" : "due \(relative)")
            case .deleted:
                parts.append("deleted \(relative)")
            case .archived:
                parts.append("archived \(relative)")
            case .changed:
                parts.append("edited \(relative)")
            }
        }
        if let parentTitle {
            parts.append("in \(parentTitle)")
        }
        if !tagSlugs.isEmpty {
            parts.append("tagged " + tagSlugs.joined(separator: ", "))
        }
        if isFavorite { parts.append("favorite") }
        if isPinned { parts.append("pinned") }
        // Archived and deleted are not repeated here: the date above already says both, with the
        // date attached, and "archived, archived 3 Jul" is the announcement this replaces.

        return parts.joined(separator: ", ")
    }
}

// MARK: - Snapshot

/// A `Sendable` value copy of an item.
///
/// The currency for crossing isolation boundaries. Background work — indexing,
/// exporting, importing — receives snapshots and returns identifiers, so a
/// `PersistentModel` never escapes the context that owns it. This is the mechanism
/// behind the architecture's one hard concurrency rule.
public struct ItemSnapshot: ContentItem, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: ItemStatus
    public var priority: Priority
    public var startAt: Date?
    public var dueAt: Date?
    public var deferUntil: Date?
    public var completedAt: Date?
    public var archivedAt: Date?
    public var deletedAt: Date?
    public var isFavorite: Bool
    public var isPinned: Bool
    public var tagSlugs: [String]
    public var parentID: UUID?
    public var parentTitle: String?
    public var symbolName: String?
    public var colorName: String?
    public var dayKey: String?
    public var source: ItemSource
    public var recurrence: RecurrenceRule?
    public var userMetadata: [String: MetadataValue]
    public var sortOrder: Double

    public init(
        id: UUID = UUID(),
        kind: ItemKind = .note,
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ItemStatus = .none,
        priority: Priority = .normal,
        startAt: Date? = nil,
        dueAt: Date? = nil,
        deferUntil: Date? = nil,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        tagSlugs: [String] = [],
        parentID: UUID? = nil,
        parentTitle: String? = nil,
        symbolName: String? = nil,
        colorName: String? = nil,
        dayKey: String? = nil,
        source: ItemSource = .manual,
        recurrence: RecurrenceRule? = nil,
        userMetadata: [String: MetadataValue] = [:],
        sortOrder: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.priority = priority
        self.startAt = startAt
        self.dueAt = dueAt
        self.deferUntil = deferUntil
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.tagSlugs = tagSlugs
        self.parentID = parentID
        self.parentTitle = parentTitle
        self.symbolName = symbolName
        self.colorName = colorName
        self.dayKey = dayKey
        self.source = source
        self.recurrence = recurrence
        self.userMetadata = userMetadata
        self.sortOrder = sortOrder
    }
}
