import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Everything specific to defects.
///
/// Separate from ``WorkItemService`` because a bug's questions are not a task's questions — can you
/// still reproduce it, which build broke it, has anybody checked the fix — and answering them needs
/// its own vocabulary rather than four more parameters on a general-purpose method.
@MainActor
public final class BugService {
    private let items: any ItemRepository
    private let workItems: WorkItemService
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(
        items: any ItemRepository,
        workItems: WorkItemService,
        context: ModelContext,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.workItems = workItems
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - The record

    /// The bug's record, creating it if this is the first time anybody asked.
    ///
    /// Lazy creation is the cost of letting a bug be filed in eight seconds with only a title. The
    /// consequence lives in `Item.taskFacts()`, which substitutes `.minor` rather than reporting no
    /// severity at all — otherwise a freshly filed bug falls out of every severity band and appears
    /// under "Not a bug", which is a judgement nobody made.
    @discardableResult
    public func record(for item: Item) throws(AppError) -> BugRecord? {
        guard item.kind == .bug else { return nil }
        if let existing = item.bugRecord { return existing }

        let record = BugRecord(facts: BugFacts(severity: .minor))
        record.item = item
        context.insert(record)
        try save()
        return record
    }

    /// Turns existing work into a bug, or creates one outright.
    @discardableResult
    public func fileBug(
        title: String,
        in project: Item,
        severity: BugSeverity = .minor,
        facts: BugFacts? = nil
    ) throws(AppError) -> Item {
        let item = try workItems.createWorkItem(
            title: title,
            kind: .bug,
            in: project,
            severity: severity
        )
        if let facts, let record = try record(for: item) {
            var updated = facts
            updated.severity = severity
            record.facts = updated
            record.updatedAt = dateProvider.now
            try save()
        }
        return item
    }

    /// Edits the report.
    ///
    /// Touches the owning item as well as the record, so the search index reindexes — reproduction
    /// steps are folded into `Item.searchText`, and an edit that left the item untouched would leave
    /// the new steps unfindable until something else changed.
    public func update(_ item: Item, _ mutate: (inout BugFacts) -> Void) throws(AppError) {
        guard let record = try record(for: item) else { return }
        var facts = record.facts
        let before = facts
        mutate(&facts)
        guard facts != before else { return }

        record.facts = facts
        record.updatedAt = dateProvider.now
        item.updatedAt = dateProvider.now
        item.refreshSearchText()

        if facts.severity != before.severity {
            workItems.record(
                .severityChanged,
                on: item,
                oldValue: before.severity.displayName,
                newValue: facts.severity.displayName
            )
        }
        try save()
    }

    public func setSeverity(_ severity: BugSeverity, on item: Item) throws(AppError) {
        try update(item) { $0.severity = severity }
    }

    // MARK: - Verification

    /// Records that somebody checked the fix and it works.
    ///
    /// **Fixed and verified are two different claims by two different people**, which is why this is
    /// not the item's status. Whoever wrote the fix says fixed; whoever tested it says verified. The
    /// gap between them is the only list anybody preparing a release actually wants.
    public func markVerified(_ item: Item) throws(AppError) {
        guard let record = try record(for: item) else { return }
        guard record.verifiedAt == nil else { return }
        record.verifiedAt = dateProvider.now
        record.updatedAt = dateProvider.now
        item.updatedAt = dateProvider.now
        workItems.record(.verified, on: item)
        try save()
    }

    public func clearVerification(_ item: Item) throws(AppError) {
        guard let record = item.bugRecord, record.verifiedAt != nil else { return }
        record.verifiedAt = nil
        record.updatedAt = dateProvider.now
        item.updatedAt = dateProvider.now
        workItems.record(.reopened, on: item)
        try save()
    }

    public func isVerified(_ item: Item) -> Bool {
        item.bugRecord?.verifiedAt != nil
    }

    public func isClosed(_ item: Item) -> Bool {
        item.status == .completed || item.status == .cancelled
    }

    // MARK: - Queries

    /// Bugs marked fixed that nobody has checked.
    ///
    /// The list a release is actually held up by, and the reason `verifiedAt` exists at all.
    public func awaitingVerification(in project: Item) -> [Item] {
        project.descendantWork().filter {
            $0.kind == .bug && $0.status == .completed && $0.bugRecord?.verifiedAt == nil
        }
    }

    public func openBugs(in project: Item) -> [Item] {
        project.descendantWork().filter { $0.kind == .bug && !isClosed($0) }
    }

    public func duplicates(of item: Item) -> [Item] {
        item.incomingLinks
            .filter { $0.kind == .duplicateOf }
            .compactMap(\.source)
    }

    /// Moves unresolved bugs from one release to the next.
    ///
    /// Named for what it is rather than done silently at release time: deciding that eleven open
    /// defects are somebody else's problem next month is a decision, and it should look like one.
    @discardableResult
    public func rolloverUnresolvedBugs(from release: Item, to next: Item) throws(AppError) -> [Item] {
        let carried = release.incomingLinks
            .filter { $0.kind == .relatesToRelease }
            .compactMap(\.source)
            .filter { $0.kind == .bug && !isClosed($0) }

        for bug in carried {
            try workItems.setRelease(next, on: bug)
        }
        return carried
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "bug", reason: error.localizedDescription)
        }
    }
}
