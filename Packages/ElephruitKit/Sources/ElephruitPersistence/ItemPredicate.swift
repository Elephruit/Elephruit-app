import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Store-side predicates for ``ItemQuery``.
///
/// ### Why this is four small functions rather than one general one
///
/// `#Predicate` expands into a large expression tree, and the constraint solver has a
/// time-based budget for the expression that contains it. Two things push a general-purpose
/// predicate over that budget, both measured rather than assumed:
///
/// 1. **Clause count.** Every `(!flag || column …)` pair adds work. With `ElephruitCore`
///    imported — which brings `ItemFields: OptionSet` and so further `contains` overload
///    candidates — a six-clause predicate sits right at the edge and compiles only
///    sometimes. That is worse than failing outright, because it fails later, on someone
///    else's machine.
/// 2. **Derived captures.** Computing the captured values in the same function body as the
///    macro makes the solver consider both at once. Every parameter here is therefore
///    pre-computed and explicitly typed by the caller.
///
/// Splitting on ``ItemQuery/Scope`` — of which there are exactly four, known at compile
/// time — removes the "don't care" flags entirely. Each builder states its scope directly,
/// so the widest is four clauses with comfortable headroom. It also emits tighter SQL: the
/// active-items query, which is the overwhelming majority of all queries, becomes two plain
/// `IS NULL` checks rather than four guarded ones.
enum ItemPredicateBuilder {
    /// The predicate for a query's scope, kinds, and statuses.
    ///
    /// Every other filter is applied by ``ItemQuery/postFilter(_:)`` in ordinary Swift. The
    /// boundary between the two is documented on ``ItemQuery/requiresPostFiltering``.
    /// The containment clause a query wants pushed to the store.
    ///
    /// Only the two forms hot paths ask for: a specific parent (a project's contents, a heading's
    /// tasks) and the top level (sibling ordering). `hasNoParent == false` — "anything with *a*
    /// parent" — stays a post-filter: nothing hot asks it, and a clause nothing exercises is a
    /// clause nothing would notice breaking.
    enum ParentFilter {
        case id(UUID)
        case unparented
    }

    static func make(
        scope: ItemQuery.Scope,
        kindRaws: [String],
        statusRaws: [String],
        dueFrom: Date?,
        dueBefore: Date?,
        isPinned: Bool? = nil,
        dayRelevantBefore: Date? = nil,
        isFlagged: Bool? = nil,
        parent: ParentFilter? = nil,
        tagSlug: String? = nil
    ) -> Predicate<Item> {
        let filterByKind = !kindRaws.isEmpty
        let filterByStatus = !statusRaws.isEmpty

        // The due bound goes to the store only in the active scope, which is where Today and Upcoming
        // live and where it matters. Adding it to all four builders would push each past the clause
        // ceiling; the other scopes are small enough that post-filtering costs nothing.
        if scope == .active, dueFrom != nil || dueBefore != nil {
            return activeWithDueBound(
                filterByKind, kindRaws, filterByStatus, statusRaws,
                dueFrom ?? .distantPast, dueBefore ?? .distantFuture
            )
        }

        // The containment clause rides along on the same terms as the due bound: one focused
        // variant per combination that actually occurs, never stacked with another rider, and the
        // caller keeps post-filtering either way so every combination stays correct. It exists in
        // the two scopes hot paths use — `.active` for a container's contents, `.all` for sibling
        // renumbering, where trashed and archived siblings must keep counting.
        if let parent {
            switch (scope, parent) {
            case (.active, .id(let parentID)):
                return activeParent(filterByKind, kindRaws, filterByStatus, statusRaws, parentID)
            case (.active, .unparented):
                return activeUnparented(filterByKind, kindRaws, filterByStatus, statusRaws)
            case (.all, .id(let parentID)):
                return anyScopeParent(filterByKind, kindRaws, filterByStatus, statusRaws, parentID)
            case (.all, .unparented):
                return anyScopeUnparented(filterByKind, kindRaws, filterByStatus, statusRaws)
            default:
                break  // Archived and Trash are small; the post-filter answers there.
            }
        }

        // One tag, on the same terms. A tag page post-filtered its slugs, which fetched every
        // active content item to keep the tagged few. The store narrows by *one* slug — for a
        // multi-tag query, any one of them — and the post-filter still requires them all, so the
        // clause only ever shrinks what is materialised.
        if scope == .active, let tagSlug {
            return activeTagged(filterByKind, kindRaws, filterByStatus, statusRaws, tagSlug)
        }

        // The pinned clause rides along on the same terms as the due bound, and for the same
        // reason: the sidebar's pinned rows are recomputed after every save, and post-filtering
        // them meant materialising every active item to find half a dozen pins. Only in the active
        // scope, and never alongside a due bound — the caller keeps post-filtering either way, so
        // every combination stays correct.
        if scope == .active, let isPinned {
            return activePinned(filterByKind, kindRaws, filterByStatus, statusRaws, isPinned)
        }

        // The Today window's riders, on the same terms as the pinned clause: one focused variant
        // each, never stacked with another rider, and the caller keeps post-filtering either way.
        // Two variants rather than one carrying `key < end || flagged`, because that disjunction
        // would sit at the measured clause ceiling where compilation is unreliable — the caller
        // that wants both runs both queries and unions the rows.
        if scope == .active, let dayRelevantBefore {
            return activeDayRelevant(filterByKind, kindRaws, filterByStatus, statusRaws, dayRelevantBefore)
        }

        if scope == .active, let isFlagged {
            return activeFlagged(filterByKind, kindRaws, filterByStatus, statusRaws, isFlagged)
        }

        switch scope {
        case .active:
            return active(filterByKind, kindRaws, filterByStatus, statusRaws)
        case .archived:
            return archived(filterByKind, kindRaws, filterByStatus, statusRaws)
        case .trashed:
            return trashed(filterByKind, kindRaws, filterByStatus, statusRaws)
        case .all:
            return anyScope(filterByKind, kindRaws, filterByStatus, statusRaws)
        }
    }

    /// Active, restricted to one container's children. Five clauses.
    private static func activeParent(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ parentID: UUID
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.parent?.id == parentID
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, restricted to the top level. Five clauses.
    private static func activeUnparented(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.parent == nil
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Every scope, restricted to one container's children. Three clauses.
    private static func anyScopeParent(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ parentID: UUID
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.parent?.id == parentID
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Every scope, restricted to the top level. Three clauses.
    private static func anyScopeUnparented(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.parent == nil
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, bounded by due date.
    ///
    /// Six clauses — the measured ceiling for this module. Adding a seventh will fail to compile
    /// rather than fail at runtime, which is the right way round.
    ///
    /// Compares against `dueSortKey` rather than `dueAt`: a non-optional mirror, so there is no
    /// optional comparison and therefore no guarded force unwrap.
    private static func activeWithDueBound(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ dueFrom: Date,
        _ dueBefore: Date
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.dueSortKey >= dueFrom
                && item.dueSortKey < dueBefore
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, restricted to items carrying one tag. Five clauses and a subquery.
    private static func activeTagged(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ tagSlug: String
    ) -> Predicate<Item> {
        // `?.contains … == true` is the optional-relationship form the macro translates to
        // SQL — a `?? []` here is an array literal the store cannot express, and six clauses
        // with one already blows the type-checker's budget.
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.tags?.contains { $0.slug == tagSlug } == true
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, bounded by the day-relevance projection. Five clauses.
    ///
    /// Compares against `dayRelevanceKey` — a non-optional mirror, like `dueSortKey`, so there is
    /// no optional comparison. Rows from before the column existed carry `.distantPast` and match
    /// every bound, which is the safe direction: over-fetched, never hidden.
    private static func activeDayRelevant(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ before: Date
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.dayRelevanceKey < before
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, restricted by the task flag. Five clauses.
    private static func activeFlagged(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ isFlagged: Bool
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.isFlagged == isFlagged
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Active, restricted by the pinned flag. Five clauses.
    private static func activePinned(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String],
        _ isPinned: Bool
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.isPinned == isPinned
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Neither trashed nor archived.
    private static func active(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Archived but not trashed — archiving is a way of keeping something, not of losing it.
    private static func archived(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt != nil
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// In the Trash, archived or not.
    private static func trashed(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt != nil
                && (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }

    /// Every row, including trashed. Export and integrity checks only.
    private static func anyScope(
        _ filterByKind: Bool,
        _ kindRaws: [String],
        _ filterByStatus: Bool,
        _ statusRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            (!filterByKind || kindRaws.contains(item.kindRaw))
                && (!filterByStatus || statusRaws.contains(item.statusRaw))
        }
    }
}
