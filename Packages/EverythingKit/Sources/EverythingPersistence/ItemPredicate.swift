import EverythingCore
import EverythingModel
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
/// 1. **Clause count.** Every `(!flag || column …)` pair adds work. With `EverythingCore`
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
    static func make(
        scope: ItemQuery.Scope,
        kindRaws: [String],
        statusRaws: [String]
    ) -> Predicate<Item> {
        let filterByKind = !kindRaws.isEmpty
        let filterByStatus = !statusRaws.isEmpty

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
