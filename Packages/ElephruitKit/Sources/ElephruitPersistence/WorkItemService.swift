import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What a bulk edit actually managed to do.
///
/// Carries the refusals rather than swallowing them, so the interface can say "14 of 20 changed"
/// instead of claiming twenty and quietly meaning fourteen. A bulk action that reports success it
/// did not have is how people stop trusting bulk actions.
public struct BulkOutcome: Sendable, Hashable {
    public var changedIDs: [UUID]
    public var refusedIDs: [UUID]

    public var changedCount: Int { changedIDs.count }
    public var refusedCount: Int { refusedIDs.count }
    public var wasCompletelySuccessful: Bool { refusedIDs.isEmpty }
}

/// Creating and changing work, and writing down that it changed.
///
/// Every mutation here records an ``ItemActivity``, and only when something actually changed —
/// setting the priority to what it already was writes no history, because a history full of
/// non-events is a history nobody reads.
@MainActor
public final class WorkItemService {
    private let items: any ItemRepository
    private let workspace: ProjectWorkspaceService
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(
        items: any ItemRepository,
        workspace: ProjectWorkspaceService,
        context: ModelContext,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.workspace = workspace
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Creating

    /// Creates work inside a project: reference key, board placement, bug record and history, in one
    /// call.
    ///
    /// One call because these are not four independent decisions. Work created without a reference
    /// cannot be talked about, work created without a column is invisible on the board, and a bug
    /// created without a record reads as "not a bug" until somebody edits it.
    @discardableResult
    public func createWorkItem(
        title: String,
        kind: ItemKind = .task,
        in project: Item,
        stage: WorkflowStage? = nil,
        parent: Item? = nil,
        severity: BugSeverity? = nil,
        bugFacts: BugFacts? = nil
    ) throws(AppError) -> Item {
        var draft = ItemDraft(kind: kind, title: title)
        let container = parent ?? project
        if container.kind.canContain(kind) {
            draft.parentID = container.id
        }

        let item = try items.create(draft)

        if item.parent == nil, container.kind.canContain(kind) {
            item.parent = container
        }

        // Allocated without saving; this method saves once at the end. Three saves per created
        // item — one in `create`, one here, one in the allocator — is three write transactions for
        // one logical act.
        item.referenceKey = workspace.takeReferenceKey(in: project)

        let landing = stage ?? firstOpenStage(in: project)
        if kind.isWorkItem {
            item.workflowStageID = landing?.id
            item.boardOrder = nextBoardOrder(in: project)
        }

        if kind == .bug {
            var facts = bugFacts ?? BugFacts()
            if let severity { facts.severity = severity }
            let record = BugRecord(facts: facts)
            record.item = item
            context.insert(record)
        }

        record(.created, on: item)
        try save()
        return item
    }

    /// Gives existing work a reference, for anything that predates the project having a key.
    @discardableResult
    public func backfillReferenceKey(for item: Item, in project: Item) throws(AppError) -> String? {
        guard item.referenceKey == nil else { return item.referenceKey }
        item.referenceKey = try workspace.allocateReferenceKey(in: project)
        try save()
        return item.referenceKey
    }

    private func firstOpenStage(in project: Item) -> WorkflowStage? {
        workspace.stages(in: project).first { !$0.category.isTerminal }
    }

    /// Where a newly created item sits in its column.
    ///
    /// Derived from the project's reference counter, which only ever goes up, rather than from the
    /// largest board order already in the column. The obvious version walked every item in the
    /// project to find that maximum — so creating the two hundredth item walked a hundred and
    /// ninety-nine, and populating a project was quadratic. Appending only needs a number bigger
    /// than the ones already there, and a monotonic counter is one.
    private func nextBoardOrder(in project: Item) -> Double {
        Double(project.nextReferenceNumber) * ProjectWorkspaceService.orderGap
    }

    // MARK: - Assignment

    /// Assigns work to exactly one person.
    ///
    /// **The "exactly one" is enforced here rather than in the schema**, because the schema cannot
    /// express it — a link is a link — and because a store that has somehow acquired two must still
    /// open rather than refusing to load somebody's library over a duplicate row.
    public func assign(_ item: Item, to person: Item?) throws(AppError) {
        let existing = item.outgoingLinks.filter { $0.kind == .assignee }
        let previous = existing.first?.target
        guard previous?.id != person?.id else { return }

        for link in existing { context.delete(link) }

        if let person {
            try items.link(item, to: person, kind: .assignee)
            record(.assigned, on: item, newValue: person.title)
        } else {
            record(.unassigned, on: item, oldValue: previous?.title)
        }
        item.updatedAt = dateProvider.now
        try save()
    }

    // MARK: - Dependencies

    /// Records that `item` cannot proceed until `blocker` is resolved.
    ///
    /// Refuses a cycle and says so, rather than accepting it and letting the roadmap draw an arrow
    /// that loops back on itself. Returns `false` for the refusal because it is a normal thing for
    /// somebody to try, not an error they made.
    @discardableResult
    public func addDependency(_ item: Item, blockedBy blocker: Item) throws(AppError) -> Bool {
        guard item.id != blocker.id, !wouldCycle(item, blockedBy: blocker) else { return false }
        guard !item.outgoingLinks.contains(where: { $0.kind == .blockedBy && $0.target?.id == blocker.id })
        else { return true }

        try items.link(item, to: blocker, kind: .blockedBy)
        record(.blockedByAdded, on: item, newValue: blocker.title)
        try save()
        return true
    }

    public func removeDependency(_ item: Item, blockedBy blocker: Item) throws(AppError) {
        let stale = item.outgoingLinks.filter { $0.kind == .blockedBy && $0.target?.id == blocker.id }
        guard !stale.isEmpty else { return }
        for link in stale { context.delete(link) }
        record(.blockedByRemoved, on: item, oldValue: blocker.title)
        try save()
    }

    /// Whether making `item` wait on `blocker` closes a loop.
    ///
    /// Walks forward from the blocker looking for the item: if the blocker already depends, however
    /// indirectly, on the thing about to depend on it, neither can ever start.
    func wouldCycle(_ item: Item, blockedBy blocker: Item) -> Bool {
        var seen: Set<UUID> = [blocker.id]
        var queue = [blocker]
        while let next = queue.popLast() {
            if next.id == item.id { return true }
            for link in next.outgoingLinks where link.kind == .blockedBy {
                guard let target = link.target, seen.insert(target.id).inserted else { continue }
                queue.append(target)
            }
        }
        return false
    }

    // MARK: - Planning markers and duplicates

    public func setMilestone(_ milestone: Item?, on item: Item) throws(AppError) {
        try setSingleLink(kind: .targetsMilestone, from: item, to: milestone, activity: .milestoneChanged)
    }

    public func setRelease(_ release: Item?, on item: Item) throws(AppError) {
        try setSingleLink(kind: .relatesToRelease, from: item, to: release, activity: .releaseChanged)
    }

    /// Marks work as a duplicate of something else.
    ///
    /// **Cancelled, not completed.** A duplicate was never fixed — nobody did the work, somebody
    /// noticed it was already written down — and counting it as completed would inflate every
    /// velocity figure with reports rather than repairs.
    public func markDuplicate(_ item: Item, of original: Item) throws(AppError) {
        guard item.id != original.id else { return }
        try setSingleLink(kind: .duplicateOf, from: item, to: original, activity: .markedDuplicate)
        item.status = .cancelled
        item.cancelledAt = dateProvider.now
        item.completedAt = nil
        item.updatedAt = dateProvider.now
        try save()
    }

    private func setSingleLink(
        kind: LinkKind,
        from item: Item,
        to target: Item?,
        activity: ActivityKind
    ) throws(AppError) {
        let existing = item.outgoingLinks.filter { $0.kind == kind }
        let previous = existing.first?.target
        guard previous?.id != target?.id else { return }
        for link in existing { context.delete(link) }
        if let target { try items.link(item, to: target, kind: kind) }
        record(activity, on: item, oldValue: previous?.title, newValue: target?.title)
        item.updatedAt = dateProvider.now
        try save()
    }

    // MARK: - Fields

    public func setTitle(_ title: String, on item: Item) throws(AppError) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        let old = item.title
        item.title = trimmed
        item.updatedAt = dateProvider.now
        record(.titleChanged, on: item, oldValue: old, newValue: trimmed)
        try save()
    }

    public func setPriority(_ priority: Priority, on item: Item) throws(AppError) {
        guard item.priority != priority else { return }
        let old = item.priority
        item.priority = priority
        item.updatedAt = dateProvider.now
        record(.priorityChanged, on: item, oldValue: old.displayName, newValue: priority.displayName)
        try save()
    }

    public func setDueDate(_ date: Date?, on item: Item) throws(AppError) {
        guard item.dueAt != date else { return }
        let old = item.dueAt
        item.dueAt = date
        item.updatedAt = dateProvider.now
        record(.dueDateChanged, on: item, oldValue: Self.dateText(old), newValue: Self.dateText(date))
        try save()
    }

    public func setEstimate(_ minutes: Int?, on item: Item) throws(AppError) {
        guard item.estimateMinutes != minutes else { return }
        let old = item.estimateMinutes
        item.estimateMinutes = minutes
        item.updatedAt = dateProvider.now
        record(
            .estimateChanged,
            on: item,
            oldValue: Self.durationText(old),
            newValue: Self.durationText(minutes)
        )
        try save()
    }

    // MARK: - Comments

    @discardableResult
    public func addComment(
        _ body: String,
        to item: Item,
        authorID: UUID? = nil,
        mentioning people: [UUID] = []
    ) throws(AppError) -> ItemComment? {
        guard let text = body.nilIfBlank else { return nil }
        let comment = ItemComment(body: text, authorID: authorID)
        comment.mentionedPersonIDs = people
        comment.item = item
        context.insert(comment)
        record(.commented, on: item)
        item.updatedAt = dateProvider.now
        try save()
        return comment
    }

    public func removeComment(_ comment: ItemComment) throws(AppError) {
        context.delete(comment)
        try save()
    }

    public func comments(on item: Item) -> [ItemComment] {
        item.comments.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - History

    public func history(of item: Item) -> [ItemActivity] {
        item.activities.sorted { $0.at > $1.at }
    }

    /// Writes one line of history.
    ///
    /// Internal rather than private so `AutomationEngine` can attribute its own changes: a change
    /// nobody made by hand has to say which rule made it, or the first surprising one costs an
    /// afternoon of looking for a person who did not do it.
    func record(
        _ kind: ActivityKind,
        on item: Item,
        field: String? = nil,
        oldValue: String? = nil,
        newValue: String? = nil,
        automationRuleID: UUID? = nil
    ) {
        let activity = ItemActivity(
            at: dateProvider.now,
            kind: kind,
            field: field,
            oldValue: oldValue,
            newValue: newValue,
            automationRuleID: automationRuleID
        )
        activity.item = item
        context.insert(activity)
    }

    // MARK: - Bulk

    /// Applies a change to many items, reporting what refused.
    public func bulk(_ targets: [Item], _ change: (Item) throws(AppError) -> Bool) -> BulkOutcome {
        var changed: [UUID] = []
        var refused: [UUID] = []
        for item in targets {
            do {
                if try change(item) { changed.append(item.id) } else { refused.append(item.id) }
            } catch {
                refused.append(item.id)
            }
        }
        return BulkOutcome(changedIDs: changed, refusedIDs: refused)
    }

    // MARK: - Formatting

    static func dateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func durationText(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "workItem", reason: error.localizedDescription)
        }
    }
}
