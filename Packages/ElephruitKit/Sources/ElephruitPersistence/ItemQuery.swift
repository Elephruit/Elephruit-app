import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// A description of which items to fetch.
///
/// A `Sendable` value type rather than a `Predicate`, for three reasons: it can be built
/// on any actor, it can be compared for equality so a view knows when to refetch, and it
/// keeps the mapping from *intent* to *predicate* in one testable place.
public struct ItemQuery: Sendable, Hashable {
    /// Relationships a caller knows it will read for every fetched item.
    ///
    /// SwiftData relationships are lazy by default. A list that immediately reads the same
    /// relationship on hundreds of rows otherwise turns one item fetch into hundreds of hidden
    /// relationship fetches.
    public enum Prefetch: Sendable, Hashable {
        case personProfile
    }

    /// Which lifecycle states to include. Mutually exclusive by design — a list that
    /// mixed live and trashed items would be a bug, not a feature.
    public enum Scope: Sendable, Hashable, CaseIterable {
        /// Neither archived nor trashed. What almost every view wants.
        case active
        case archived
        case trashed
        /// Everything, including trashed. Used by export and integrity checks.
        case all
    }

    public enum Sort: Sendable, Hashable, CaseIterable {
        case manual
        case updatedNewestFirst
        case createdNewestFirst
        case titleAscending
        case dueSoonestFirst
        case priorityHighestFirst

        public var displayName: String {
            switch self {
            case .manual: "Manual Order"
            case .updatedNewestFirst: "Recently Modified"
            case .createdNewestFirst: "Recently Created"
            case .titleAscending: "Title"
            case .dueSoonestFirst: "Due Date"
            case .priorityHighestFirst: "Priority"
            }
        }
    }

    public var scope: Scope = .active

    /// Empty means every kind.
    public var kinds: Set<ItemKind> = []

    /// `yyyy-MM-dd`, for finding a daily entry.
    ///
    /// An equality test on a stored key rather than a date range, so "today's entry" cannot match two
    /// rows because of a timezone boundary.
    public var dayKey: String?

    /// Empty means any status.
    public var statuses: Set<ItemStatus> = []

    /// Tag slugs that must *all* be present. Applied after the fetch — see
    /// ``ItemQuery/requiresPostFiltering``.
    public var tagSlugs: Set<String> = []

    /// Restrict to children of a particular item.
    public var parentID: UUID?

    /// `true` restricts to items with no parent.
    ///
    /// Used for sibling ordering at the top level. The Inbox no longer builds itself out of this and
    /// two neighbours — see ``unprocessedCapturesOnly``.
    public var hasNoParent: Bool?

    /// `true` restricts to unprocessed captures — the Inbox, asked as one question.
    ///
    /// ### Why one flag replaced four
    /// It was `hasNoParent`, `requiresNoTags`, `requiresNoFiling` and `inboxEligibleKindsOnly`,
    /// spelled out here and spelled out a second time inside `CountsWorker.inboxCount()` under a
    /// comment reading "must match `ItemQuery.inbox()` exactly, or the badge and the list disagree."
    /// Four clauses kept in step by a comment is four clauses that will not be, and the fifth clause
    /// — that a reminder synchronised with a list already has a home — would have had to be added in
    /// both places or the badge really would have said four hundred over an empty list.
    ///
    /// Both now ask ``ElephruitModel/Item/isUnprocessedCapture``, which is one sentence in one file.
    public var unprocessedCapturesOnly = false

    /// Whether structural kinds — headings — may appear.
    ///
    /// `false` for every ordinary content view, so a heading never turns up beside notes and tasks.
    /// The views that legitimately need one opt in: a project's own contents, Archive, Trash, and
    /// export. Naming a non-content kind in ``ItemQuery/kinds`` also opts in, which is what makes
    /// `type:heading` work without a second mechanism.
    public var includesNonContentKinds = false

    public var isFavorite: Bool?
    public var isPinned: Bool?

    /// Half-open due-date window.
    public var dueFrom: Date?
    public var dueBefore: Date?

    /// Exclude items deferred past this instant, so Today does not show work the user
    /// has explicitly postponed.
    public var notDeferredAfter: Date?

    /// Free text. Matched against `searchText` by the fetch as a fallback; the search
    /// module's index is the fast path.
    public var text: String?

    public var sort: Sort = .updatedNewestFirst
    public var limit: Int?
    public var prefetches: Set<Prefetch> = []

    public init() {}
}

// MARK: - Named queries

extension ItemQuery {
    /// Unprocessed captures: active, unfiled, untagged, and not a container.
    ///
    /// An item leaves the Inbox by acquiring a home — a container, a filing, a tag, or the list in
    /// another application it is being kept in step with. Kinds that are never "processed" are
    /// excluded outright by ``ItemKind/appearsInInbox``: a top-level project is not an unprocessed
    /// capture, and a person never becomes one.
    ///
    /// The rule itself lives on ``ElephruitModel/Item/isUnprocessedCapture``, so the list and the
    /// badge over it cannot disagree.
    public static func inbox() -> ItemQuery {
        var query = ItemQuery()
        query.unprocessedCapturesOnly = true
        query.sort = .createdNewestFirst
        return query
    }

    /// Everything due or scheduled today, plus anything overdue.
    public static func today(using dateProvider: any DateProvider) -> ItemQuery {
        var query = ItemQuery()
        query.kinds = [.task, .project, .goal]
        query.statuses = [.open]
        query.dueBefore = dateProvider.startOfTomorrow
        query.notDeferredAfter = dateProvider.now
        query.sort = .dueSoonestFirst
        return query
    }

    /// Open work due within the next `days` days, excluding today.
    public static func upcoming(days: Int, using dateProvider: any DateProvider) -> ItemQuery {
        var query = ItemQuery()
        query.kinds = [.task, .project, .goal]
        query.statuses = [.open]
        query.dueFrom = dateProvider.startOfTomorrow
        query.dueBefore = dateProvider.startOfDay(daysFromToday: days + 1)
        query.sort = .dueSoonestFirst
        return query
    }

    public static func kind(_ kind: ItemKind, sort: Sort = .updatedNewestFirst) -> ItemQuery {
        var query = ItemQuery()
        query.kinds = [kind]
        query.sort = sort
        return query
    }

    public static func tag(slug: String) -> ItemQuery {
        var query = ItemQuery()
        query.tagSlugs = [slug]
        return query
    }

    public static func children(of parentID: UUID, sort: Sort = .manual) -> ItemQuery {
        var query = ItemQuery()
        query.parentID = parentID
        query.sort = sort
        // A project's own contents include its headings — that is the one place they belong.
        query.includesNonContentKinds = true
        return query
    }

    public static func trash() -> ItemQuery {
        var query = ItemQuery()
        query.scope = .trashed
        query.sort = .updatedNewestFirst
        // A trashed heading must be visible in order to be restored.
        query.includesNonContentKinds = true
        return query
    }

    /// Everything in the store, for export.
    public static func everything() -> ItemQuery {
        var query = ItemQuery()
        query.scope = .all
        query.sort = .createdNewestFirst
        query.includesNonContentKinds = true
        return query
    }
}

// MARK: - Translation

extension ItemQuery {
    /// Filters this query applies in Swift rather than in SQL.
    ///
    /// ### Why there is a split at all
    /// `#Predicate` has a hard practical ceiling — see ``ItemPredicateBuilder`` for the
    /// measurements. Beyond that ceiling, not every Swift expression translates to SQL, and
    /// the ones that do not fail at *runtime*, in front of the user.
    ///
    /// So the split is deliberate rather than incidental. The store-side predicate carries
    /// the three clauses that eliminate the most rows and appear on nearly every query —
    /// trash/archive scope, kind, and status. Everything else is applied to the fetched rows
    /// in ``ItemQuery/postFilter(_:)``, where it is ordinary Swift: fully expressive,
    /// trivially testable, and incapable of failing at runtime.
    ///
    /// Free text is post-filtered too. That is not a compromise: `searchText` matching is
    /// only ever the *fallback* path, kept correct for a cold index, and the real answer is
    /// the inverted index in `docs/adr/0004-search-is-derived.md`.
    ///
    /// The cost is that a query filtering only by, say, favourite fetches every active item
    /// first. For a single person's library that is thousands of rows, not millions, and the
    /// escalation path if it ever matters is that same derived index — not a bigger predicate.
    public var requiresPostFiltering: Bool {
        !tagSlugs.isEmpty
            || parentID != nil
            || hasNoParent != nil
            || isFavorite != nil
            || isPinned != nil
            || notDeferredAfter != nil
            || unprocessedCapturesOnly
            || (text?.isEmpty == false)
    }

    /// The kinds the fetch actually asks for.
    ///
    /// Excluding headings could have been a post-filter, but that would have forced *every* content
    /// query through `postFilter` and destroyed the `fetchCount` fast path for all of them. Inverting
    /// it costs nothing: when the caller names no kinds and structural ones are unwanted, the query
    /// asks for the content kinds by name instead. That is one `IN` clause either way — the same
    /// single clause the predicate already had room for.
    var effectiveKindRaws: [String] {
        if !kinds.isEmpty {
            // Naming a kind is asking for it, which is what makes `type:heading` work.
            return kinds.map(\.rawValue)
        }
        if includesNonContentKinds {
            return []
        }
        return ItemKind.allCases.filter(\.participatesInContentViews).map(\.rawValue)
    }

    /// The clauses that go to the store: scope, kind, and status.
    ///
    /// Built by ``ItemPredicateBuilder``, which explains why it is split by scope. Contains
    /// no force unwraps and no optional comparisons — Swift defines no ordering between
    /// optionals and SwiftData translates neither `??` nor `flatMap` to SQL, so avoiding
    /// them is what keeps this both translatable and free of the guarded-unwrap idiom.
    public func predicate() -> Predicate<Item> {
        ItemPredicateBuilder.make(
            scope: scope,
            kindRaws: effectiveKindRaws,
            statusRaws: statuses.map { $0.rawValue },
            // Only the active scope pushes the due bound to the store; elsewhere post-filtering
            // still applies, so both paths stay correct.
            dueFrom: scope == .active ? dueFrom : nil,
            dueBefore: scope == .active ? dueBefore : nil
        )
    }

    /// Sort descriptors for the fetch.
    ///
    /// Manual order and priority both fall back to a secondary key, so a list never
    /// reorders arbitrarily between launches when the primary keys tie.
    public func sortDescriptors() -> [SortDescriptor<Item>] {
        switch sort {
        case .manual:
            [SortDescriptor(\Item.sortOrder), SortDescriptor(\Item.createdAt, order: .reverse)]
        case .updatedNewestFirst:
            [SortDescriptor(\Item.updatedAt, order: .reverse)]
        case .createdNewestFirst:
            [SortDescriptor(\Item.createdAt, order: .reverse)]
        case .titleAscending:
            [SortDescriptor(\Item.title, comparator: .localizedStandard), SortDescriptor(\Item.createdAt)]
        case .dueSoonestFirst:
            // `nil` due dates sort last in SwiftData's ordering of optionals ascending,
            // which is what a due-date list wants.
            [SortDescriptor(\Item.dueAt), SortDescriptor(\Item.priorityRaw, order: .reverse), SortDescriptor(\Item.createdAt)]
        case .priorityHighestFirst:
            [SortDescriptor(\Item.priorityRaw, order: .reverse), SortDescriptor(\Item.dueAt), SortDescriptor(\Item.createdAt)]
        }
    }

    /// A `FetchDescriptor` for this query.
    ///
    /// The limit is deliberately *not* applied when post-filtering is required, because
    /// filtering after a limit would silently drop matches. It is applied in
    /// ``ItemQuery/postFilter(_:)`` instead.
    public func fetchDescriptor() -> FetchDescriptor<Item> {
        var descriptor = FetchDescriptor<Item>(predicate: predicate(), sortBy: sortDescriptors())
        if let limit, !requiresPostFiltering {
            descriptor.fetchLimit = limit
        }
        if prefetches.contains(.personProfile) {
            descriptor.relationshipKeyPathsForPrefetching = [\.personProfile]
        }
        return descriptor
    }

    /// Applies the clauses the store could not, preserving the fetch's order.
    ///
    /// Ordinary Swift, so every clause here is directly unit-testable without a store and
    /// none of them can fail at runtime the way an untranslatable predicate would.
    public func postFilter(_ items: [Item]) -> [Item] {
        var result = items

        if let parentID {
            result = result.filter { $0.parent?.id == parentID }
        }

        if let hasNoParent {
            result = result.filter { ($0.parent == nil) == hasNoParent }
        }

        if let isFavorite {
            result = result.filter { $0.isFavorite == isFavorite }
        }

        if let isPinned {
            result = result.filter { $0.isPinned == isPinned }
        }

        // Applied here only for the scopes the predicate does not cover; in the active scope the
        // store has already done it and these are no-ops over an already-narrow set.
        if let dueFrom, scope != .active {
            result = result.filter { item in
                guard let dueAt = item.dueAt else { return false }
                return dueAt >= dueFrom
            }
        }

        if let dueBefore, scope != .active {
            result = result.filter { item in
                guard let dueAt = item.dueAt else { return false }
                return dueAt < dueBefore
            }
        }

        if let notDeferredAfter {
            result = result.filter { item in
                guard let deferUntil = item.deferUntil else { return true }
                return deferUntil <= notDeferredAfter
            }
        }

        if unprocessedCapturesOnly {
            result = result.filter(\.isUnprocessedCapture)
        }

        if !tagSlugs.isEmpty {
            let required = tagSlugs
            result = result.filter { item in
                required.isSubset(of: Set(item.tags.map(\.slug)))
            }
        }

        if let text, !text.isEmpty {
            let folded = TextNormalizer.foldedForMatching(text)
            if !folded.isEmpty {
                result = result.filter { $0.searchText.contains(folded) }
            }
        }

        if let limit, result.count > limit {
            result = Array(result.prefix(limit))
        }

        return result
    }
}

extension ItemQuery {
    /// Archived items — kept deliberately, out of the way, and never in the Trash.
    public static func archive() -> ItemQuery {
        var query = ItemQuery()
        query.scope = .archived
        query.sort = .updatedNewestFirst
        // An archived heading must be visible in order to be brought back.
        query.includesNonContentKinds = true
        return query
    }
}
