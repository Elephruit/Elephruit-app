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

    /// Stages a simple imported item in the current context without saving it yet.
    /// The caller owns the surrounding batch transaction.
    @discardableResult
    func stageCreate(_ draft: ItemDraft) throws(AppError) -> Item

    /// Applies a mutation, then validates, refreshes derived values, and saves as one
    /// unit. Nothing else is a sanctioned way to change an item.
    func update(_ item: Item, _ mutate: (Item) throws -> Void) throws(AppError)

    /// Applies and validates an imported mutation without saving the surrounding batch.
    func stageUpdate(_ item: Item, _ mutate: (Item) throws -> Void) throws(AppError)

    /// Writes synchronisation bookkeeping without touching ``Item/updatedAt``.
    ///
    /// `updatedAt` answers "when did the user last change this", and the sync engine compares it
    /// against the stamp it recorded on the previous pass to decide whether there is a local edit to
    /// push. Recording that stamp through ``update(_:_:)`` makes the answer always yes: `update`
    /// stamps `updatedAt = now` *after* the closure runs, so the value written inside the closure is
    /// necessarily older than the one the write leaves behind, and the next pass reads a local edit
    /// that never happened. Every pass pushed, forever — and because a push makes EventKit post a
    /// store-changed notification, which schedules another pass, it does not settle on its own.
    func recordSyncMetadata(on item: Item, _ mutate: (Item) -> Void) throws(AppError)

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
        do {
            let rows = try context.fetch(descriptor)
            // Recorded with the row count, so a test can pin how much a query *materialises* —
            // the figure a bare fetch count cannot see. See `FetchAudit.Tally.itemRowsMaterialized`.
            audit?.record(.itemFetch, rows: rows.count)
            return rows
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    // MARK: - Creating

    @discardableResult
    public func create(_ draft: ItemDraft) throws(AppError) -> Item {
        try create(draft, stagingImport: false)
    }

    @discardableResult
    public func stageCreate(_ draft: ItemDraft) throws(AppError) -> Item {
        try create(draft, stagingImport: true)
    }

    private func create(_ draft: ItemDraft, stagingImport: Bool) throws(AppError) -> Item {
        // Uniqueness is enforced here rather than by a store constraint, because CloudKit
        // mirroring forbids unique attributes.
        if !stagingImport, try item(id: draft.id) != nil {
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
            // Contact imports are shown alphabetically and have no parent, so ordering them all at
            // zero avoids a max-order fetch for every staged person.
            sortOrder: stagingImport ? 0 : try nextSortOrder(parentID: draft.parentID)
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

        if !stagingImport { try reconcileWikiLinks(for: item) }

        if item.kind.isWorkItem, item.status == .open {
            rearmCompletionSuggestion(above: item)
        }

        if !stagingImport { try save() }

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
        try update(item, stagingImport: false, mutate)
    }

    public func stageUpdate(_ item: Item, _ mutate: (Item) throws -> Void) throws(AppError) {
        try update(item, stagingImport: true, mutate)
    }

    private func update(
        _ item: Item,
        stagingImport: Bool,
        _ mutate: (Item) throws -> Void
    ) throws(AppError) {
        let restorePoint = ItemRestorePoint(item)

        func abort(with error: AppError) -> AppError {
            restorePoint.restore(onto: item)
            // A staged contact import can share the context with already-valid staged people. A
            // rejected row restores only itself; rolling back here would discard the whole batch.
            if !stagingImport { context.rollback() }
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

        do {
            try ItemValidator.validate(item)
        } catch {
            throw abort(with: error)
        }

        // Only once the edit is known to be good. `ItemRestorePoint` restores the item and nothing
        // else, so a profile written before a rejected edit would keep the change the rollback was
        // supposed to undo. The search text follows, because it reads the parts this may correct.
        Self.syncNameParts(of: item)
        item.refreshSearchText()

        if !stagingImport { try reconcileWikiLinks(for: item) }
        if !stagingImport { try save() }
    }

    /// Sync bookkeeping, saved without restamping the item.
    ///
    /// Deliberately does not validate or reconcile links: it writes the reminder-link state and
    /// nothing a user could see, so there is nothing for the validator to have an opinion about, and
    /// running the wiki-link reconciliation on every sync pass over every linked task would be pure
    /// cost. See the protocol comment for why this cannot go through `update`.
    public func recordSyncMetadata(on item: Item, _ mutate: (Item) -> Void) throws(AppError) {
        mutate(item)
        try save()
    }

    /// Keeps a person's given and family names in step with the name they are shown under.
    ///
    /// ### Why this is here rather than at the rename
    /// The parts were split once, when the profile was created, and never again — so renaming
    /// somebody in the header changed `title` and left `givenName` and `familyName` spelling the old
    /// name for good. Nothing displayed that drift, which is why it survived: it surfaced only
    /// indirectly, as a search that still found the person by a name they no longer had, and as an
    /// address-book write that would now offer to set the wrong name entirely.
    ///
    /// Placed at the single update funnel so it cannot be forgotten by a rename path added later.
    ///
    /// ### It only acts when the parts have actually fallen behind
    /// A profile whose parts already spell the title is left alone. That matters for every name the
    /// splitter cannot get right on its own — "van der Berg", a family name written first, a title
    /// somebody typed as "Dr Chen" — because those are corrected once, deliberately, and re-splitting
    /// them on an unrelated edit would undo the correction every time.
    private static func syncNameParts(of item: Item) {
        guard item.kind == .person, let profile = item.personProfile else { return }

        // `title`, never `displayTitle`. The latter falls back to the body's first line and then to
        // "Untitled Person", and splitting a placeholder into somebody's name is how a person ends
        // up with a given name of "Untitled".
        //
        // Compared against every part rather than given + family, so a name carrying a prefix, a
        // middle name, or a suffix reads as in step rather than as drift to be re-split.
        let shown = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty, profile.assembledName != shown else { return }

        let parts = PersonDraft.nameParts(from: shown)
        profile.givenName = parts.given
        profile.familyName = parts.family
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
            for child in (subject.children ?? []) { apply(child) }
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
        let existing = (source.outgoingLinks ?? []).contains {
            $0.kind == kind && $0.target?.id == target.id
        }
        guard !existing else { return }

        context.insert(ItemLink(kind: kind, source: source, target: target, createdAt: dateProvider.now))
        try save()
    }

    public func fileItem(_ item: Item, under container: Item?) throws(AppError) {
        guard let container else {
            for link in (item.outgoingLinks ?? []) where link.kind == .filedUnder {
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
        let existing = (item.outgoingLinks ?? []).contains {
            $0.kind == .filedUnder && $0.target?.id == container.id
        }
        guard !existing else { return }

        context.insert(
            ItemLink(kind: .filedUnder, source: item, target: container, createdAt: dateProvider.now)
        )
        try save()
    }

    public func unfileItem(_ item: Item, from container: Item) throws(AppError) {
        for link in (item.outgoingLinks ?? [])
        where link.kind == .filedUnder && link.target?.id == container.id {
            context.delete(link)
        }
        try save()
    }

    /// Moves a heading's tasks up to whatever contains the heading.
    public func moveTasksOut(of heading: Item) throws(AppError) {
        guard heading.kind == .heading else { return }
        let destination = heading.parent

        for task in (heading.children ?? []).filter({ $0.kind.isWorkItem }) {
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
        if wasCompleted, item.kind.isWorkItem {
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
        if item.kind.isWorkItem, item.status == .open {
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
        // One top-1 fetch: the store finds the highest sibling order and returns a single row.
        //
        // This used to go through `ItemQuery` with `hasNoParent`/`parentID`, both of which are
        // post-filters — so every create fetched and materialised *every item in the store*, then
        // read `parent` on each to keep the siblings. That was the whole of the measured cost of
        // creating an item: ~0.1 ms per existing item, over a second at ten thousand.
        //
        // The predicate deliberately has no scope or kind clause. Ordering is structural, so it
        // must see every sibling — trashed, archived, and headings alike. Excluding headings here
        // would give two headings in the same project an identical sort order.
        let predicate: Predicate<Item>
        if let parentID {
            predicate = #Predicate { $0.parent?.id == parentID }
        } else {
            predicate = #Predicate { $0.parent == nil }
        }

        var descriptor = FetchDescriptor<Item>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        let highest = try fetch(descriptor).first?.sortOrder ?? 0
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
            for child in (subject.children ?? []) { trash(child) }
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
            for child in (subject.children ?? []) where child.deletedAt == timestamp {
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
        for link in (item.outgoingLinks ?? []) where link.kind == .wiki {
            let key = link.target.map { TextNormalizer.foldedForMatching($0.title) }
                ?? link.unresolvedMatchKey
                ?? ""
            if !desiredKeys.contains(key) {
                context.delete(link)
            }
        }

        let existingKeys = Set(
            (item.outgoingLinks ?? [])
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
