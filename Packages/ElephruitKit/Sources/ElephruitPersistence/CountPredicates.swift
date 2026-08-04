import ElephruitModel
import Foundation
import SwiftData

/// The predicates behind the sidebar counts.
///
/// A file of its own, and **deliberately without `import ElephruitCore`**. The solver budget
/// ``ItemPredicateBuilder`` documents is spent partly on overload resolution, and `ElephruitCore`
/// brings `OptionSet` conformances whose `contains` candidates push a five-clause predicate over
/// the edge in any file that imports it — measured here, twice, before the import was removed.
/// Every raw value is therefore passed in by the caller rather than derived from core types.
enum CountPredicates {
    /// Everything open, actionable, and due before the bound. Five clauses.
    ///
    /// Compares `dueSortKey`, not `dueAt` — the same non-optional mirror the Today view's own
    /// predicate uses, so the badge and the list read the same column.
    static func dueOpen(
        kindRaws: [String],
        statusRaw: String,
        dueBefore: Date
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && item.dueSortKey < dueBefore
                && kindRaws.contains(item.kindRaw)
                && item.statusRaw == statusRaw
        }
    }

    /// The rows ``dueOpen(kindRaws:statusRaw:dueBefore:)`` counted that also carry a deferral.
    ///
    /// Five clauses: the archive clause is deliberately missing — a sixth is over budget even in
    /// this file — and the caller re-applies it in Swift over the handful that comes back.
    static func dueOpenDeferred(
        kindRaws: [String],
        statusRaw: String,
        dueBefore: Date
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.dueSortKey < dueBefore
                && kindRaws.contains(item.kindRaw)
                && item.statusRaw == statusRaw
                && item.deferUntil != nil
        }
    }

    /// Everything inbox-shaped as far as the store can see.
    ///
    /// `ineligibleKindRaws` *excludes* rather than includes, so a kind this build has never heard
    /// of counts — exactly as it does in Swift, where an unknown raw value reads as `.reference`
    /// and `appearsInInbox` says yes.
    ///
    /// The filing subquery mirrors ``ElephruitModel/Item/filedUnderContainers()`` clause for
    /// clause: a filing is a home only when its target exists and is not in the Trash.
    static func inboxShaped(
        ineligibleKindRaws: [String],
        filedRaw: String
    ) -> Predicate<Item> {
        // The `#Predicate` this expresses is:
        //
        //     item.deletedAt == nil
        //         && item.archivedAt == nil
        //         && item.parent == nil
        //         && !ineligibleKindRaws.contains(item.kindRaw)
        //         && (item.tags?.isEmpty ?? true)
        //         && !(item.outgoingLinks?.contains {
        //             $0.kindRaw == filedRaw && $0.target != nil && $0.target?.deletedAt == nil
        //         } ?? false)
        //
        // written as the expansion the macro itself produces (`-dump-macro-expansions`), because
        // the macro form of six clauses plus a subquery is over the type-checker's wall-clock
        // budget: it compiled in one target and not in this one. The expansion type-checks
        // deterministically because every node is explicit, and it is byte-for-byte what the
        // macro would have emitted, so the SQL is the same.
        Predicate<Item>({ item -> any StandardPredicateExpression<Bool> in
            let notDeleted = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.deletedAt
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let notArchived = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.archivedAt
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let unparented = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.parent
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let eligibleKind = PredicateExpressions.build_Negation(
                PredicateExpressions.build_contains(
                    PredicateExpressions.build_Arg(ineligibleKindRaws),
                    PredicateExpressions.build_KeyPath(
                        root: PredicateExpressions.build_Arg(item),
                        keyPath: \.kindRaw
                    )
                )
            )
            // Optional since the relationships became optional for CloudKit — and phrased as
            // "contains nothing" rather than "isEmpty": `isEmpty` reaches the store as a bare
            // `tags.@count`, which the count-request path refuses outright ("KVC aggregate
            // where there shouldn't be one", a crash), while `contains` reaches it as the
            // SUBQUERY the filing clause below has always used. A `nil` collection and an
            // empty one both mean untagged, which is what the coalesce says.
            let untagged = PredicateExpressions.build_Negation(
                PredicateExpressions.build_NilCoalesce(
                    lhs: PredicateExpressions.build_flatMap(
                        PredicateExpressions.build_KeyPath(
                            root: PredicateExpressions.build_Arg(item),
                            keyPath: \.tags
                        )
                    ) { tags in
                        PredicateExpressions.build_contains(tags) { _ in
                            PredicateExpressions.build_Arg(true)
                        }
                    },
                    rhs: PredicateExpressions.build_Arg(false)
                )
            )
            // Same shape for the filing subquery: no links and no live filing read alike.
            let notLiveFiled = PredicateExpressions.build_Negation(
                PredicateExpressions.build_NilCoalesce(
                    lhs: PredicateExpressions.build_flatMap(
                        PredicateExpressions.build_KeyPath(
                            root: PredicateExpressions.build_Arg(item),
                            keyPath: \.outgoingLinks
                        )
                    ) { links in
                        PredicateExpressions.build_contains(links) {
                    PredicateExpressions.build_Conjunction(
                        lhs: PredicateExpressions.build_Conjunction(
                            lhs: PredicateExpressions.build_Equal(
                                lhs: PredicateExpressions.build_KeyPath(
                                    root: PredicateExpressions.build_Arg($0),
                                    keyPath: \.kindRaw
                                ),
                                rhs: PredicateExpressions.build_Arg(filedRaw)
                            ),
                            rhs: PredicateExpressions.build_NotEqual(
                                lhs: PredicateExpressions.build_KeyPath(
                                    root: PredicateExpressions.build_Arg($0),
                                    keyPath: \.target
                                ),
                                rhs: PredicateExpressions.build_NilLiteral()
                            )
                        ),
                        rhs: PredicateExpressions.build_Equal(
                            lhs: PredicateExpressions.build_flatMap(
                                PredicateExpressions.build_KeyPath(
                                    root: PredicateExpressions.build_Arg($0),
                                    keyPath: \.target
                                )
                            ) {
                                PredicateExpressions.build_KeyPath(
                                    root: PredicateExpressions.build_Arg($0),
                                    keyPath: \.deletedAt
                                )
                            },
                            rhs: PredicateExpressions.build_NilLiteral()
                        )
                    )
                        }
                    },
                    rhs: PredicateExpressions.build_Arg(false)
                )
            )

            let scope = PredicateExpressions.build_Conjunction(lhs: notDeleted, rhs: notArchived)
            let structure = PredicateExpressions.build_Conjunction(lhs: scope, rhs: unparented)
            let kinded = PredicateExpressions.build_Conjunction(lhs: structure, rhs: eligibleKind)
            let homeless = PredicateExpressions.build_Conjunction(lhs: kinded, rhs: untagged)
            return PredicateExpressions.build_Conjunction(lhs: homeless, rhs: notLiveFiled)
        })
    }

    /// Active work whose sync state the user has to do something about. Four clauses.
    ///
    /// Semantically identical to filtering `taskFacts().syncState.needsAttention` over every work
    /// item: the facts read the same column through `TaskSyncState(rawValue:)`, whose unknown-raw
    /// fallback is `.local` — not an attention state — so an unknown raw is excluded on both paths.
    static func syncAttention(
        workItemKindRaws: [String],
        attentionStateRaws: [String]
    ) -> Predicate<Item> {
        #Predicate<Item> { item in
            item.deletedAt == nil
                && item.archivedAt == nil
                && workItemKindRaws.contains(item.kindRaw)
                && attentionStateRaws.contains(item.syncStateRaw)
        }
    }

    /// The rows that could carry the one home the store cannot express: an external list.
    ///
    /// A superset on purpose — membership in the counted set is decided by the caller in Swift,
    /// with the same properties ``ElephruitModel/Item/hasHome`` reads.
    static func externallyHomedCandidates(systemStoreRaw: String) -> Predicate<Item> {
        // The `#Predicate` this expresses is:
        //
        //     item.deletedAt == nil
        //         && item.archivedAt == nil
        //         && item.parent == nil
        //         && item.sourceKindRaw == systemStoreRaw
        //         && item.externalIdentifier != nil
        //         && item.inboxedAt == nil
        //
        // hand-expanded for the reason ``inboxShaped(ineligibleKindRaws:filedRaw:)`` documents.
        Predicate<Item>({ item -> any StandardPredicateExpression<Bool> in
            let notDeleted = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.deletedAt
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let notArchived = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.archivedAt
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let unparented = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.parent
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let fromSystemStore = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.sourceKindRaw
                ),
                rhs: PredicateExpressions.build_Arg(systemStoreRaw)
            )
            let linked = PredicateExpressions.build_NotEqual(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.externalIdentifier
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )
            let notInboxed = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(
                    root: PredicateExpressions.build_Arg(item),
                    keyPath: \.inboxedAt
                ),
                rhs: PredicateExpressions.build_NilLiteral()
            )

            let scope = PredicateExpressions.build_Conjunction(lhs: notDeleted, rhs: notArchived)
            let structure = PredicateExpressions.build_Conjunction(lhs: scope, rhs: unparented)
            let synced = PredicateExpressions.build_Conjunction(lhs: structure, rhs: fromSystemStore)
            let external = PredicateExpressions.build_Conjunction(lhs: synced, rhs: linked)
            return PredicateExpressions.build_Conjunction(lhs: external, rhs: notInboxed)
        })
    }
}
