import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What a new item should look like.
///
/// A `Sendable` value type so a capture panel, an importer, or a command can describe an
/// item without touching a `ModelContext`.
public struct ItemDraft: Sendable, Hashable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var body: String
    public var tagSlugs: [String]
    public var parentID: UUID?
    public var dueAt: Date?
    public var startAt: Date?

    /// When this should come back into view. Never overdue — see ``Item/deferUntil``.
    public var deferUntil: Date?

    public var priority: Priority
    public var source: ItemSource
    public var url: URL?
    public var dayKey: String?

    public init(
        id: UUID = UUID(),
        kind: ItemKind = .note,
        title: String = "",
        body: String = "",
        tagSlugs: [String] = [],
        parentID: UUID? = nil,
        dueAt: Date? = nil,
        startAt: Date? = nil,
        deferUntil: Date? = nil,
        priority: Priority = .normal,
        source: ItemSource = .manual,
        url: URL? = nil,
        dayKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.tagSlugs = tagSlugs
        self.parentID = parentID
        self.dueAt = dueAt
        self.startAt = startAt
        self.deferUntil = deferUntil
        self.priority = priority
        self.source = source
        self.url = url
        self.dayKey = dayKey
    }
}

/// Reading and writing items.
///
/// `@MainActor` because it hands out `Item` objects, which are not `Sendable` and must not
/// leave the context that owns them. Bulk work that should not run on the main actor uses
/// ``BackgroundStoreWorker`` instead, which exchanges ``ItemSnapshot`` values.
///
/// A protocol so features can be tested against a double, and so the SwiftData dependency
/// stops at this boundary.
@MainActor
public protocol ItemRepository: AnyObject {
    func item(id: UUID) throws(AppError) -> Item?
    func items(matching query: ItemQuery) throws(AppError) -> [Item]
    func count(matching query: ItemQuery) throws(AppError) -> Int

    @discardableResult
    func create(_ draft: ItemDraft) throws(AppError) -> Item

    /// Applies a mutation, then validates, refreshes derived values, and saves as one
    /// unit. Nothing else is a sanctioned way to change an item.
    func update(_ item: Item, _ mutate: (Item) throws -> Void) throws(AppError)

    func moveToTrash(_ item: Item) throws(AppError)
    func restore(_ item: Item) throws(AppError)
    func deletePermanently(_ item: Item) throws(AppError)
    func emptyTrash() throws(AppError)

    func setArchived(_ item: Item, _ archived: Bool) throws(AppError)
    func toggleCompletion(_ item: Item) throws(AppError)
    func setKind(_ item: Item, to kind: ItemKind) throws(AppError) -> [String]
    func setParent(_ item: Item, to parent: Item?) throws(AppError)
    func setTags(_ item: Item, slugs: [String]) throws(AppError)
    func move(_ item: Item, after predecessor: Item?, before successor: Item?) throws(AppError)

    /// Rebuilds `.wiki` links from an item's body text.
    func reconcileWikiLinks(for item: Item) throws(AppError)

    /// Files an item under a container, or removes it from one.
    ///
    /// Filing replaces any previous filing under the *same* container only; an item filed under three
    /// projects stays filed under the other two. Passing `nil` removes every filing.
    func fileItem(_ item: Item, under container: Item?) throws(AppError)

    /// Creates a link between two items, if one of that kind does not already exist.
    func link(_ source: Item, to target: Item, kind: LinkKind) throws(AppError)

    /// Removes one filing without touching the others.
    func unfileItem(_ item: Item, from container: Item) throws(AppError)

    // MARK: Headings

    /// Moves a heading's tasks up to the project, leaving the heading empty.
    ///
    /// The non-destructive half of removing a heading: the section goes, the work stays.
    func moveTasksOut(of heading: Item) throws(AppError)

    // MARK: Project completion

    /// Records that the user declined to complete this project.
    func dismissCompletionSuggestion(for project: Item) throws(AppError)

    /// Marks a project complete, along with nothing else.
    func completeProject(_ project: Item) throws(AppError)
}

/// The SwiftData implementation.
@MainActor
public final class SwiftDataItemRepository: ItemRepository {
    private let context: ModelContext
    private let dateProvider: any DateProvider
    private let tags: TagRepository

    /// Optional store-access instrumentation. `nil` in production, so it costs one optional check.
    /// See ``FetchAudit`` for why it is not behind `#if DEBUG`.
    private let audit: FetchAudit?

    public init(
        context: ModelContext,
        dateProvider: any DateProvider,
        tags: TagRepository,
        audit: FetchAudit? = nil
    ) {
        self.context = context
        self.dateProvider = dateProvider
        self.tags = tags
        self.audit = audit
    }

    // MARK: - Reading

    public func item(id: UUID) throws(AppError) -> Item? {
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    public func items(matching query: ItemQuery) throws(AppError) -> [Item] {
        let fetched = try fetch(query.fetchDescriptor())
        return query.requiresPostFiltering ? query.postFilter(fetched) : fetched
    }

    public func count(matching query: ItemQuery) throws(AppError) -> Int {
        // Post-filtered queries cannot use the store's own count, because the filter it
        // would be counting has not been applied yet.
        guard !query.requiresPostFiltering else {
            return try items(matching: query).count
        }
        audit?.record(.itemCountQuery)
        do {
            return try context.fetchCount(query.fetchDescriptor())
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func fetch(_ descriptor: FetchDescriptor<Item>) throws(AppError) -> [Item] {
        audit?.record(.itemFetch)
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    // MARK: - Creating

    @discardableResult
    public func create(_ draft: ItemDraft) throws(AppError) -> Item {
        // Uniqueness is enforced here rather than by a store constraint, because CloudKit
        // mirroring forbids unique attributes.
        if try item(id: draft.id) != nil {
            throw .duplicateIdentifier(id: draft.id)
        }

        let now = dateProvider.now
        let item = Item(
            id: draft.id,
            kind: draft.kind,
            title: draft.title,
            body: draft.body,
            createdAt: now,
            updatedAt: now,
            status: draft.kind.supportsStatus ? .open : .none,
            priority: draft.priority,
            source: draft.source,
            sortOrder: try nextSortOrder(parentID: draft.parentID)
        )

        if let url = draft.url {
            item.source = ItemSource(kind: draft.source.kind, url: url, identifier: draft.source.identifier)
        }

        let fields = draft.kind.supportedFields
        if fields.contains(.dueDate) { item.dueAt = draft.dueAt }
        if fields.contains(.startDate) { item.startAt = draft.startAt }
        if fields.contains(.deferDate) { item.deferUntil = draft.deferUntil }
        if fields.contains(.dayKey) { item.dayKey = draft.dayKey }
        if !fields.contains(.priority) { item.priority = .normal }

        if let parentID = draft.parentID, let parent = try self.item(id: parentID) {
            // Silently dropping an invalid parent is better than refusing the capture:
            // the item still lands in the Inbox, where the user can file it.
            if parent.kind.canContain(draft.kind) {
                item.parent = parent
            }
        }

        context.insert(item)

        if !draft.tagSlugs.isEmpty {
            item.tags = try tags.ensureTags(named: draft.tagSlugs)
        }

        item.refreshSearchText()

        do {
            try ItemValidator.validate(item)
        } catch {
            // Never leave a rejected object in the context.
            context.delete(item)
            throw error
        }

        try reconcileWikiLinks(for: item)

        if item.kind == .task, item.status == .open {
            rearmCompletionSuggestion(above: item)
        }

        try save()

        Diagnostics.persistence.debug("Created item kind=\(draft.kind.rawValue, privacy: .public)")
        return item
    }

    // MARK: - Updating

    /// Applies a mutation, then validates, refreshes derived values, and saves as one unit.
    ///
    /// A rejected edit leaves the item exactly as it was. That is not what
    /// `ModelContext.rollback()` alone provides — it discards unsaved *context* changes but
    /// leaves the values already written to the live object in place, so without the explicit
    /// restore point below a validation failure would poison the object and make the user's
    /// next valid edit fail too. Covered by `itemRecoversAfterRejectedEdit`.
    public func update(_ item: Item, _ mutate: (Item) throws -> Void) throws(AppError) {
        let restorePoint = ItemRestorePoint(item)

        func abort(with error: AppError) -> AppError {
            restorePoint.restore(onto: item)
            context.rollback()
            return error
        }

        do {
            try mutate(item)
        } catch let error as AppError {
            throw abort(with: error)
        } catch {
            throw abort(with: .writeFailed(path: "store", reason: error.localizedDescription))
        }

        item.updatedAt = dateProvider.now
        item.refreshSearchText()

        do {
            try ItemValidator.validate(item)
        } catch {
            throw abort(with: error)
        }

        try reconcileWikiLinks(for: item)
        try save()
    }

    /// Archives or unarchives an item and everything it contains.
    ///
    /// Cascades for the same reason trashing does: a heading without its tasks, or a project without
    /// its tasks, is not a coherent thing to leave behind. The interface names the count before
    /// calling this — "Archive *Planning* and its 4 tasks?" — so the cascade is never a surprise.
    ///
    /// Linked content is untouched: only `children` cascade, and notes are linked rather than
    /// contained.
    public func setArchived(_ item: Item, _ archived: Bool) throws(AppError) {
        let stamp = archived ? dateProvider.now : nil
        var visited: Set<UUID> = []

        func apply(_ subject: Item) {
            guard visited.insert(subject.id).inserted else { return }
            subject.archivedAt = stamp
            subject.updatedAt = dateProvider.now
            for child in subject.children { apply(child) }
        }

        apply(item)
        try save()
    }

    // MARK: - Filing

    /// Links two items, idempotently.
    ///
    /// Linking twice is a no-op rather than an error: the caller's intent is "these are related",
    /// and a second call means that is still true.
    public func link(_ source: Item, to target: Item, kind: LinkKind) throws(AppError) {
        let existing = source.outgoingLinks.contains {
            $0.kind == kind && $0.target?.id == target.id
        }
        guard !existing else { return }

        context.insert(ItemLink(kind: kind, source: source, target: target, createdAt: dateProvider.now))
        try save()
    }

    public func fileItem(_ item: Item, under container: Item?) throws(AppError) {
        guard let container else {
            for link in item.outgoingLinks where link.kind == .filedUnder {
                context.delete(link)
            }
            try save()
            return
        }

        guard container.kind.isWorkBreakdownContainer else {
            throw .validation(
                ValidationFailure(
                    reason: .invalidContainment(parentKind: container.kind, childKind: item.kind),
                    field: "filedUnder"
                )
            )
        }

        // Already filed there — filing twice is not an error, it is a no-op.
        let existing = item.outgoingLinks.contains {
            $0.kind == .filedUnder && $0.target?.id == container.id
        }
        guard !existing else { return }

        context.insert(
            ItemLink(kind: .filedUnder, source: item, target: container, createdAt: dateProvider.now)
        )
        try save()
    }

    public func unfileItem(_ item: Item, from container: Item) throws(AppError) {
        for link in item.outgoingLinks
        where link.kind == .filedUnder && link.target?.id == container.id {
            context.delete(link)
        }
        try save()
    }

    /// Moves a heading's tasks up to whatever contains the heading.
    public func moveTasksOut(of heading: Item) throws(AppError) {
        guard heading.kind == .heading else { return }
        let destination = heading.parent

        for task in heading.children.filter({ $0.kind == .task }) {
            task.parent = destination
            task.updatedAt = dateProvider.now
        }

        try save()
        Diagnostics.persistence.debug("Moved tasks out of a heading")
    }

    // MARK: - Project completion

    public func dismissCompletionSuggestion(for project: Item) throws(AppError) {
        guard project.kind == .project else { return }
        project.completionPromptDismissedAt = dateProvider.now
        try save()
    }

    public func completeProject(_ project: Item) throws(AppError) {
        guard project.kind == .project, project.status != .completed else { return }
        try update(project) { subject in
            subject.status = .completed
            subject.completedAt = self.dateProvider.now
        }
    }

    /// Re-arms the completion suggestion on every enclosing project.
    ///
    /// Called on exactly one transition — a project gaining an open task, whether by creation, by a
    /// move, or by un-completing one. Nothing else re-arms it, so an unrelated edit cannot make a
    /// dismissed suggestion reappear.
    private func rearmCompletionSuggestion(above item: Item) {
        for ancestor in item.ancestors() where ancestor.kind == .project {
            ancestor.completionPromptDismissedAt = nil
        }
    }

    /// Completing a task also completes nothing else and un-completing restores nothing —
    /// cascading completion is a surprise, and surprises in a task manager cost trust.
    ///
    /// A recurring task is the exception: completing an occurrence advances the series.
    public func toggleCompletion(_ item: Item) throws(AppError) {
        guard item.kind.supportsStatus else {
            throw .validation(ValidationFailure(reason: .statusNotSupportedByKind(kind: item.kind), field: "status"))
        }

        let wasCompleted = item.status == .completed

        try update(item) { subject in
            if wasCompleted {
                subject.status = .open
                subject.completedAt = nil
            } else {
                subject.status = .completed
                subject.completedAt = self.dateProvider.now
            }
        }

        // Re-opening work is one of the three transitions that re-arms the suggestion.
        if wasCompleted, item.kind == .task {
            rearmCompletionSuggestion(above: item)
            try save()
        }

        if !wasCompleted, let rule = item.recurrence {
            try advanceRecurrence(of: item, using: rule)
        }
    }

    /// Creates the next occurrence of a recurring task.
    ///
    /// The completed occurrence stays as a record, and the new one is linked to it by a
    /// ``LinkKind/recurrenceSeries`` link, so the history of a habit is preserved rather
    /// than overwritten.
    private func advanceRecurrence(of completed: Item, using rule: RecurrenceRule) throws(AppError) {
        let anchor: Date? = switch rule.anchor {
        case .schedule: completed.dueAt ?? completed.completedAt
        case .completion: completed.completedAt
        }

        guard let anchor,
              let next = rule.nextOccurrence(after: anchor, calendar: dateProvider.calendar)
        else { return }

        let successor = Item(
            id: UUID(),
            kind: completed.kind,
            title: completed.title,
            body: completed.body,
            createdAt: dateProvider.now,
            updatedAt: dateProvider.now,
            status: .open,
            priority: completed.priority,
            source: ItemSource(kind: .generated, identifier: "recurrence"),
            sortOrder: completed.sortOrder
        )
        successor.dueAt = next
        successor.parent = completed.parent
        successor.tags = completed.tags
        successor.recurrence = rule
        successor.refreshSearchText()

        context.insert(successor)
        context.insert(ItemLink(kind: .recurrenceSeries, source: successor, target: completed, createdAt: dateProvider.now))

        // The completed occurrence stops repeating; the new one carries the rule.
        completed.recurrence = nil

        try save()
        Diagnostics.persistence.debug("Advanced recurrence to next occurrence")
    }

    public func setKind(_ item: Item, to kind: ItemKind) throws(AppError) -> [String] {
        var cleared: [String] = []
        try update(item) { subject in
            cleared = ItemValidator.conform(subject, to: kind)
        }
        return cleared
    }

    public func setParent(_ item: Item, to parent: Item?) throws(AppError) {
        // Validated before mutating, so a rejected drag leaves the graph untouched rather
        // than relying on a rollback to undo it.
        if let parent {
            guard parent.id != item.id else {
                throw .validation(ValidationFailure(reason: .containmentCycle, field: "parent"))
            }
            guard parent.kind.canContain(item.kind) else {
                throw .validation(
                    ValidationFailure(
                        reason: .invalidContainment(parentKind: parent.kind, childKind: item.kind),
                        field: "parent"
                    )
                )
            }
            guard !parent.ancestors().contains(where: { $0.id == item.id }) else {
                throw .validation(ValidationFailure(reason: .containmentCycle, field: "parent"))
            }
        }

        try update(item) { subject in
            subject.parent = parent
            subject.sortOrder = try self.nextSortOrder(parentID: parent?.id)
        }

        // Moving open work into a project is the third re-arming transition.
        if item.kind == .task, item.status == .open {
            rearmCompletionSuggestion(above: item)
            try save()
        }
    }

    public func setTags(_ item: Item, slugs: [String]) throws(AppError) {
        let resolved = try tags.ensureTags(named: slugs)
        try update(item) { $0.tags = resolved }
    }

    // MARK: - Ordering

    /// Places an item between two neighbours by taking the midpoint of their orders.
    ///
    /// Gap-based ordering means a drag writes one row rather than renumbering the list. If
    /// repeated insertions exhaust the gap — which needs about fifty insertions at the
    /// same point — the siblings are renumbered once and the move retried.
    public func move(_ item: Item, after predecessor: Item?, before successor: Item?) throws(AppError) {
        let lower = predecessor?.sortOrder
        let upper = successor?.sortOrder

        let newOrder: Double = switch (lower, upper) {
        case (nil, nil): 0
        case (let lower?, nil): lower + Self.orderGap
        case (nil, let upper?): upper - Self.orderGap
        case (let lower?, let upper?): (lower + upper) / 2
        }

        // Doubles run out of room between two adjacent values eventually. Detect it and
        // renumber rather than silently placing the item in the wrong position.
        if let lower, let upper, newOrder <= lower || newOrder >= upper {
            try renumberSiblings(of: item)
            try move(item, after: predecessor, before: successor)
            return
        }

        try update(item) { $0.sortOrder = newOrder }
    }

    private static let orderGap: Double = 1024

    private func nextSortOrder(parentID: UUID?) throws(AppError) -> Double {
        var query = ItemQuery()
        query.scope = .all
        query.sort = .manual
        // Ordering is structural, so it must see *every* sibling. Excluding headings here would give
        // two headings in the same project an identical sort order.
        query.includesNonContentKinds = true
        if let parentID {
            query.parentID = parentID
        } else {
            query.hasNoParent = true
        }
        query.limit = nil

        let siblings = try items(matching: query)
        let highest = siblings.map(\.sortOrder).max() ?? 0
        return highest + Self.orderGap
    }

    private func renumberSiblings(of item: Item) throws(AppError) {
        var query = ItemQuery()
        query.scope = .all
        query.sort = .manual
        query.includesNonContentKinds = true
        if let parent = item.parent {
            query.parentID = parent.id
        } else {
            query.hasNoParent = true
        }

        let siblings = try items(matching: query)
        for (index, sibling) in siblings.enumerated() {
            sibling.sortOrder = Double(index) * Self.orderGap
        }
        try save()
        Diagnostics.persistence.debug("Renumbered \(siblings.count, privacy: .public) siblings after order exhaustion")
    }

    // MARK: - Trash

    /// Soft deletion. Children go with the parent, and the timestamps are recorded so that
    /// restoring the parent can bring back exactly the set that left with it.
    public func moveToTrash(_ item: Item) throws(AppError) {
        let now = dateProvider.now
        var visited: Set<UUID> = []

        func trash(_ subject: Item) {
            guard visited.insert(subject.id).inserted else { return }
            if subject.deletedAt == nil { subject.deletedAt = now }
            subject.updatedAt = now
            for child in subject.children { trash(child) }
        }

        trash(item)
        try save()
        Diagnostics.persistence.debug("Trashed \(visited.count, privacy: .public) item(s)")
    }

    /// Restores an item and everything trashed alongside it.
    ///
    /// Descendants are restored only if they were trashed in the *same* operation — matched
    /// by timestamp — so restoring a project does not resurrect a task the user deleted
    /// deliberately a week earlier.
    public func restore(_ item: Item) throws(AppError) {
        guard let deletedAt = item.deletedAt else { return }
        let now = dateProvider.now
        var visited: Set<UUID> = []

        func restore(_ subject: Item, matching timestamp: Date) {
            guard visited.insert(subject.id).inserted else { return }
            subject.deletedAt = nil
            subject.updatedAt = now
            for child in subject.children where child.deletedAt == timestamp {
                restore(child, matching: timestamp)
            }
        }

        restore(item, matching: deletedAt)

        // A restored item whose parent is still in the Trash would vanish from every view.
        // Detaching it to the top level is recoverable; hiding it is not.
        if let parent = item.parent, parent.deletedAt != nil {
            item.parent = nil
        }

        try save()
        Diagnostics.persistence.debug("Restored \(visited.count, privacy: .public) item(s)")
    }

    /// Irreversible removal. Attachment bytes are the caller's responsibility and are
    /// removed only after this transaction commits — see
    /// `docs/adr/0003-attachments-on-disk.md`.
    public func deletePermanently(_ item: Item) throws(AppError) {
        context.delete(item)
        try save()
    }

    public func emptyTrash() throws(AppError) {
        let trashed = try items(matching: .trash())
        for item in trashed {
            context.delete(item)
        }
        try save()
        Diagnostics.persistence.info("Emptied trash, \(trashed.count, privacy: .public) item(s)")
    }

    // MARK: - Links

    /// Brings an item's `.wiki` links into agreement with its body text.
    ///
    /// Wiki links are owned by the text: this adds links for new `[[…]]`, removes links
    /// whose text is gone, and leaves every other ``LinkKind`` untouched, so deliberate
    /// associations survive editing. Targets that do not exist become *unresolved* links
    /// rather than being dropped.
    public func reconcileWikiLinks(for item: Item) throws(AppError) {
        let found = WikiLinkParser.links(in: item.body)
        let desiredKeys = Set(found.map(\.matchKey))

        // Remove wiki links no longer present in the text.
        for link in item.outgoingLinks where link.kind == .wiki {
            let key = link.target.map { TextNormalizer.foldedForMatching($0.title) }
                ?? link.unresolvedMatchKey
                ?? ""
            if !desiredKeys.contains(key) {
                context.delete(link)
            }
        }

        let existingKeys = Set(
            item.outgoingLinks
                .filter { $0.kind == .wiki }
                .compactMap { link -> String? in
                    link.target.map { TextNormalizer.foldedForMatching($0.title) } ?? link.unresolvedMatchKey
                }
        )

        // Add links for text that has none yet.
        for link in found where !existingKeys.contains(link.matchKey) {
            let target = try itemByTitle(matchKey: link.matchKey)
            let newLink = ItemLink(
                kind: .wiki,
                source: item,
                target: target,
                displayText: link.displayText,
                unresolvedTitle: target == nil ? link.targetTitle : nil,
                createdAt: dateProvider.now
            )
            context.insert(newLink)
        }

        // An item's own title may be what someone else was waiting for.
        try resolveIncomingUnresolvedLinks(to: item)
    }

    /// Points previously-unresolved links at `item` if its title is what they were after.
    ///
    /// This is what makes `[[Not Yet Written]]` become a real link the moment the note is
    /// created, with no bookkeeping asked of the user.
    private func resolveIncomingUnresolvedLinks(to item: Item) throws(AppError) {
        let key = TextNormalizer.foldedForMatching(item.title)
        guard !key.isEmpty else { return }

        let descriptor = FetchDescriptor<ItemLink>(predicate: #Predicate { $0.unresolvedMatchKey == key })
        let pending: [ItemLink]
        audit?.record(.other)
        do {
            pending = try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }

        for link in pending where link.source?.id != item.id {
            link.resolve(to: item)
        }
    }

    /// Resolves a wiki link's target by its folded title.
    ///
    /// An indexed equality lookup against `titleMatchKey`. This used to fetch every active item and
    /// fold each title in Swift — O(n) per newly-typed link, growing with the library and running
    /// while the user typed.
    private func itemByTitle(matchKey: String) throws(AppError) -> Item? {
        guard !matchKey.isEmpty else { return nil }

        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.titleMatchKey == matchKey && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1

        return try fetch(descriptor).first
    }

    // MARK: - Saving

    private func save() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            Diagnostics.persistence.error("Save failed: \(error.localizedDescription, privacy: .public)")
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
