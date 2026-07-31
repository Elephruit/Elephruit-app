import ElephruitCore
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
    /// Ordering by creation date, for the index rebuild.
    ///
    /// `IndexWorker` streams the whole store in cursor-paged batches ordered by `createdAt`, and
    /// without an index every page was a sort over the table: a 50,000-item rebuild measured 6.15 s
    /// against a 6 s budget, the one published figure the project has missed. The fix was known and
    /// declined at the time because it is a schema change to real user data — which this slice is.
    #Index<Item>([\.createdAt])

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

    /// The title in matching form — case-folded, diacritic-stripped, whitespace collapsed.
    ///
    /// Denormalised so that resolving `[[Some Note]]` is an indexed equality lookup rather than a
    /// fetch of every active item followed by folding each title in Swift. That scan was O(n) *per
    /// newly-typed link*, which is the worst possible shape: it got slower exactly as the library
    /// grew and exactly while the user was typing.
    ///
    /// Derived, recomputed on every save alongside ``Item/searchText``, so it cannot drift.
    public var titleMatchKey: String = ""

    /// ``Item/dueAt``, or `.distantFuture` when there is none.
    ///
    /// A non-optional mirror, so a due-date bound can live in the store-side predicate. Swift defines
    /// no ordering between optionals and SwiftData translates neither `??` nor `flatMap` to SQL, so
    /// the alternative was either a guarded force unwrap or post-filtering — and post-filtering meant
    /// Today materialised every open item and then discarded most of them, which measured at 72 ms
    /// against a 30 ms budget on a *reduced* corpus.
    ///
    /// `.distantFuture` for "no due date" is the right sentinel: an item with no deadline sorts last
    /// and matches no upper bound, which is exactly how a missing due date should behave.
    ///
    /// Derived, refreshed on every save alongside the other projections.
    public var dueSortKey: Date = Date.distantFuture

    // MARK: Timestamps

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var startAt: Date?
    public var dueAt: Date?

    /// Hidden from Today until this date arrives.
    public var deferUntil: Date?

    public var completedAt: Date?

    /// When the task was deliberately abandoned.
    ///
    /// Distinct from ``completedAt`` because "I did it" and "I decided not to" are different facts,
    /// and a log that cannot tell them apart is a log that makes you re-decide things. Both leave the
    /// item resolved; only one of them is an achievement.
    public var cancelledAt: Date?

    /// When to interrupt the user. **Not** a date the item is visible from, and not a deadline.
    ///
    /// Never written as a side effect of setting either of the other two. Visibility and
    /// interruption are separate requests, and an app that turns the first into the second is one
    /// people switch notifications off in.
    public var reminderAt: Date?

    /// Whether ``reminderAt`` names a time of day, or only a day.
    ///
    /// Stored rather than inferred from the time component: midnight is a legitimate time, and
    /// "is the hour zero?" is not the same question as "did the user give an hour?".
    public var reminderIsTimed: Bool = false

    /// ``ReminderOwner`` raw value: who delivers the notification.
    ///
    /// Recorded rather than inferred, because both this app and a linked system reminder can hold an
    /// alarm for the same task, and the user would then be told twice.
    public var reminderOwnerRaw: String = ReminderOwner.none.rawValue

    /// Non-nil means archived: kept, but out of the way.
    public var archivedAt: Date?

    /// Non-nil means in Trash. Soft deletion is the only deletion the UI performs.
    public var deletedAt: Date?

    // MARK: State

    /// ``ItemStatus`` raw value.
    public var statusRaw: String = ItemStatus.none.rawValue

    /// ``Priority`` raw value.
    public var priorityRaw: String = Priority.normal.rawValue

    /// How long this was expected to take, in minutes. `nil` means no estimate was given.
    ///
    /// Deliberately not a `TimeInterval`: an estimate is something a person types, and nobody
    /// estimates in seconds. Minutes make the stored value the same one that was entered.
    ///
    /// This is an *estimate*, and the actual is derived from ``Item/timeEntries``. The two are never
    /// reconciled into a single number — a plan and what happened are different facts, and averaging
    /// them would destroy both.
    public var estimateMinutes: Int?

    public var isFavorite: Bool = false
    public var isPinned: Bool = false

    /// Sparse, gap-based ordering, so a manual reorder writes one row rather than
    /// renumbering the whole list.
    public var sortOrder: Double = 0

    /// JSON-encoded ``RecurrenceRule``. `nil` means the item does not repeat.
    public var recurrenceData: Data?

    // MARK: Planning

    /// The day the user chose to work on this. `nil` means they have not chosen.
    ///
    /// A *day* rather than a flag, so a commitment made last Thursday can be told from one made this
    /// morning. That distinction is what makes carrying work forward a fact in the data rather than
    /// a guess in a view — and it is what lets Later Today apply only to a plan made for today.
    public var todayCommittedOn: Date?

    /// Pushed to the back half of today. Meaningful only alongside a commitment made for today.
    public var isLaterToday: Bool = false

    /// Position within Today, independent of position within the owning project.
    ///
    /// A second ordering rather than a reuse of ``sortOrder``, because the two answer different
    /// questions: the order of a project's steps is the order they must happen in, and the order of
    /// today is the order you feel like doing them. Reordering one must not disturb the other.
    public var todayOrder: Double = 0

    /// Parked by choice. Not overdue, not neglected, and never in a count.
    public var isSomeday: Bool = false

    /// Marked as worth coming back to.
    ///
    /// Deliberately **not** ``isFavorite``, which is library vocabulary applying to every kind. A
    /// flag is task vocabulary and carries no implication of priority, deadline, or Today — which is
    /// the whole value of it: it means exactly what the user decided it means.
    public var isFlagged: Bool = false

    /// When this task started waiting on somebody or something else.
    public var waitingSince: Date?

    /// When to chase. Only meaningful while waiting.
    public var followUpAt: Date?

    /// JSON-encoded ``TaskChecklist`` — lightweight steps inside a single action.
    ///
    /// One column rather than an entity: checklist items are never queried on their own, never
    /// linked to, and never appear in a list of their own, so a table of them would be one whose
    /// every row is read through its parent. Subtasks, which *are* queried and linked and listed,
    /// are ordinary child items.
    public var checklistData: Data?

    // MARK: Recurrence series

    /// Which repeating series this occurrence belongs to.
    ///
    /// Shared by the completed occurrences left behind as history and by the one live row that
    /// carries the series forward, so "show me this task's history" is an indexed lookup rather than
    /// a walk through links.
    public var seriesID: UUID?

    /// How many occurrences the series has produced, for a rule that ends after a count.
    public var occurrenceCount: Int = 0

    // MARK: External link

    /// ``TaskSyncState`` raw value.
    public var syncStateRaw: String = TaskSyncState.local.rawValue

    /// EventKit's `calendarItemIdentifier` for the linked reminder.
    public var externalIdentifier: String?

    /// The reminder calendar the linked reminder lives in.
    public var externalListIdentifier: String?

    /// When the last successful reconciliation happened.
    public var externalSyncedAt: Date?

    /// The linked reminder's fingerprint at that moment — see `ReminderSnapshot.fingerprint`.
    public var externalFingerprint: String?

    /// This item's own ``updatedAt`` at that moment, so a later local edit is detectable.
    ///
    /// Stored rather than compared against `externalSyncedAt`: the two differ by however long the
    /// write took, and using the wrong one makes every pass look like a local edit — which turns
    /// every subsequent pass into a conflict.
    public var externalLocalStamp: Date?

    /// Set by the task migration when an imported date could have meant more than one thing.
    ///
    /// A marker, not a correction. The migration never guesses which of the three dates an old value
    /// was, and this is how it says so without touching the value.
    public var dateReviewRaw: String?

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

    /// When the user last declined the suggestion to complete this project.
    ///
    /// An optional attribute with a `nil` default, so it migrates lightweightly and satisfies every
    /// CloudKit constraint. It lives on the project rather than in a preference because a dismissal
    /// is a property of *that project* — declining on one Mac should be a decline everywhere, not a
    /// per-device setting that re-asks the moment you sit at the other machine.
    public var completionPromptDismissedAt: Date?

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

    /// Time tracked against this item.
    ///
    /// **Not** `.cascade`, unlike every other relationship here. Deleting a task must not destroy the
    /// record that four hours were spent on it — that is a fact about the past, and about work
    /// someone may still need to bill for. The entries are nullified and survive as untethered time,
    /// which is recoverable; a cascade would not be.
    ///
    /// The inverse is declared rather than left one-way because CloudKit mirroring requires inverse
    /// relationships, and the decision of record is that deferring sync must not make adopting it
    /// harder later.
    @Relationship(deleteRule: .nullify)
    public var timeEntries: [TimeEntry] = []

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
        self.titleMatchKey = TextNormalizer.foldedForMatching(title)
        self.dueSortKey = Date.distantFuture
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
    /// Recomputes the derived text columns. Called on every save path.
    public func refreshSearchText() {
        titleMatchKey = TextNormalizer.foldedForMatching(title)
        dueSortKey = dueAt ?? Date.distantFuture
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

    /// This item's headings, in the user's order.
    ///
    /// Empty for anything that is not a project. An empty heading is legitimate — it is a
    /// placeholder for work not yet written down — and is never pruned automatically.
    public func orderedHeadings() -> [Item] {
        children
            .filter { $0.kind == .heading && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Direct child tasks that sit outside any heading, in order.
    public func ungroupedTasks() -> [Item] {
        children
            .filter { $0.kind == .task && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Every task beneath this item, flattened through headings and subtasks.
    ///
    /// Bounded, so a containment cycle introduced by a bug cannot hang the interface.
    public func descendantTasks(limit: Int = 10_000) -> [Item] {
        var result: [Item] = []
        var seen: Set<UUID> = [id]
        var queue = children

        while let next = queue.popLast(), result.count < limit {
            guard next.deletedAt == nil, seen.insert(next.id).inserted else { continue }
            if next.kind == .task { result.append(next) }
            // Descend through headings and tasks alike: a heading holds tasks, a task holds subtasks.
            if next.kind == .heading || next.kind == .task {
                queue.append(contentsOf: next.children)
            }
        }

        return result
    }

    /// Completed and total task counts.
    ///
    /// Headings are excluded on both sides — a heading is scaffolding, never work — so a project
    /// whose only remaining children are empty headings reads as finished.
    public func taskProgress() -> (completed: Int, total: Int) {
        let tasks = descendantTasks()
        return (tasks.count { $0.status == .completed }, tasks.count)
    }

    /// Whether this project has any work at all. An empty project is not a finished one.
    public var hasAnyTasks: Bool {
        !descendantTasks(limit: 1).isEmpty
    }

    /// Whether any task beneath this item is still open.
    public var hasOpenTasks: Bool {
        descendantTasks().contains { $0.status == .open }
    }

    /// Whether to offer completing this project.
    ///
    /// Every condition is deliberate:
    ///
    /// - **A project.** Areas are ongoing by definition and are never "finished".
    /// - **Still open.** Nothing to suggest about a project already completed.
    /// - **Not dismissed.** "Not yet" means not yet, and is remembered.
    /// - **Has at least one task.** An empty project is not a finished one — and a project holding
    ///   only empty headings has no tasks, because headings are not work.
    /// - **Nothing open.** The actual trigger.
    public var shouldSuggestCompletion: Bool {
        kind == .project
            && status == .open
            && deletedAt == nil
            && archivedAt == nil
            && completionPromptDismissedAt == nil
            && hasAnyTasks
            && !hasOpenTasks
    }

    /// Containers this item is deliberately filed under.
    ///
    /// A note may be filed under several projects at once — that is the whole reason filing is a link
    /// rather than a parent.
    public func filedUnderContainers() -> [Item] {
        outgoingLinks
            .filter { $0.kind == .filedUnder }
            .compactMap(\.target)
            .filter { $0.deletedAt == nil }
    }

    /// Content deliberately filed under this container — the project's **Project notes**.
    ///
    /// Distinct from what merely mentions it. Nothing here is *owned* by the container, so archiving
    /// or completing it leaves all of this untouched.
    public func filedItems() -> [Item] {
        incomingLinks
            .filter { $0.kind == .filedUnder }
            .compactMap(\.source)
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Content that mentions this container without being filed under it — **Related notes**.
    public func mentioningItems() -> [Item] {
        var seen = Set<UUID>()
        let filed = Set(filedItems().map(\.id))

        return incomingLinks
            .filter { $0.kind != .filedUnder && $0.kind.appearsInBacklinks }
            .compactMap(\.source)
            .filter { $0.deletedAt == nil && !filed.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The project this item sits inside, if any.
    public func enclosingProject() -> Item? {
        ancestors().first { $0.kind == .project }
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
