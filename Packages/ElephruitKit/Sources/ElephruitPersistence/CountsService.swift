import ElephruitCore
import ElephruitModel
import Foundation
import Observation
import SwiftData

/// The numbers the sidebar shows.
///
/// Only two, deliberately: a count is a prompt to act, and a count of every note ever written is
/// decoration.
public struct SidebarCounts: Sendable, Hashable {
    /// Open work that is overdue or due today, excluding anything deferred.
    public var today = 0

    /// Unprocessed captures — no container, no tags, and not itself a container.
    public var inbox = 0

    public init(today: Int = 0, inbox: Int = 0) {
        self.today = today
        self.inbox = inbox
    }

    public static let zero = SidebarCounts()
}

/// Computes the sidebar counts off the main actor.
///
/// A `@ModelActor`, so it owns its own `ModelContext` and never touches the one the interface uses.
/// It returns `SidebarCounts` — plain `Int`s — so no `PersistentModel` crosses an isolation boundary,
/// which is the architecture's one hard concurrency rule.
///
/// ### Why these are counts in SQL rather than fetches filtered in Swift
/// They were fetches: Today materialised every open actionable item and Inbox materialised every
/// active unparented item, each pass, on every save. Materialising a row costs ~77 µs regardless of
/// which properties are read — measured, and unchanged by `propertiesToFetch` — so on a large
/// library the badge pass took over half a second of CPU to produce two integers, while
/// `fetchCount` over the same predicates takes about a millisecond.
///
/// The two clauses SQL cannot express — a comparison against an *optional* date, and the external
/// home whose rule belongs to ``ElephruitModel/Item/hasHome`` — are still decided in Swift, but
/// over only the rows they can possibly affect: due items that carry a deferral, and unparented
/// items linked to an external list. Both sets are tiny in any real library.
///
/// `CountsParityTests` holds the store-side arithmetic equal to the model's own
/// ``ElephruitModel/Item/isUnprocessedCapture`` across every branch of the rule, so the badge
/// cannot drift from the list the way duplicated clauses once let it.
@ModelActor
actor CountsWorker {
    func counts(startOfTomorrow: Date, now: Date) throws -> SidebarCounts {
        SidebarCounts(
            today: try todayCount(startOfTomorrow: startOfTomorrow, now: now),
            inbox: try inboxCount()
        )
    }

    /// Open actionable work due before tomorrow, minus anything still deferred.
    ///
    /// Counted as a subtraction because the deferral comparison cannot go to the store — it is
    /// against an optional date. The store counts everything due, then the rows that *carry* a
    /// deferral — a handful in any real library — are fetched, and the ones whose deferral has not
    /// yet arrived come off the total. Same rule the fetch-everything version applied, evaluated
    /// over only the rows it can affect.
    private func todayCount(startOfTomorrow: Date, now: Date) throws -> Int {
        let kindRaws: [String] = [ItemKind.task, .project, .goal].map(\.rawValue)
        let openRaw: String = ItemStatus.open.rawValue

        let due = try modelContext.fetchCount(
            FetchDescriptor<Item>(
                predicate: CountPredicates.dueOpen(
                    kindRaws: kindRaws, statusRaw: openRaw, dueBefore: startOfTomorrow
                )
            )
        )

        let deferredCandidates = try modelContext.fetch(
            FetchDescriptor<Item>(
                predicate: CountPredicates.dueOpenDeferred(
                    kindRaws: kindRaws, statusRaw: openRaw, dueBefore: startOfTomorrow
                )
            )
        )

        // The candidate predicate drops the archive clause to stay under the solver ceiling, so it
        // is re-checked here; only rows the count above included may be subtracted.
        let stillHidden = deferredCandidates.count { item in
            guard item.archivedAt == nil, let deferUntil = item.deferUntil else { return false }
            return deferUntil > now
        }

        return due - stillHidden
    }

    /// Unprocessed captures, counted without materialising them.
    ///
    /// The store counts everything inbox-shaped — active, unparented, an eligible kind, untagged,
    /// and not filed under a *live* container, the same clauses ``ElephruitModel/Item/hasHome``
    /// reads. The one home the store cannot see is an external list, so the rows that could carry
    /// one are fetched — synchronised, unparented, not deliberately inboxed — and the members of
    /// the counted set among them are subtracted, using the model's own vocabulary for each clause.
    private func inboxCount() throws -> Int {
        let inboxShaped = try modelContext.fetchCount(
            FetchDescriptor<Item>(
                predicate: CountPredicates.inboxShaped(
                    ineligibleKindRaws: ItemKind.allCases.filter { !$0.appearsInInbox }.map(\.rawValue),
                    filedRaw: LinkKind.filedUnder.rawValue
                )
            )
        )

        let externallyHomed = try modelContext.fetch(
            FetchDescriptor<Item>(
                predicate: CountPredicates.externallyHomedCandidates(
                    systemStoreRaw: SourceKind.systemStore.rawValue
                )
            )
        )

        let overcounted = externallyHomed.count { item in
            item.isKeptInStepWithAnExternalList
                && item.inboxedAt == nil
                && item.kind.appearsInInbox
                && item.tags.isEmpty
                && item.filedUnderContainers().isEmpty
        }

        return inboxShaped - overcounted
    }
}

/// Holds the counts the sidebar reads.
///
/// The sidebar reads two stored `Int`s and performs **no** store access while rendering — that is the
/// primary acceptance criterion for Phase A1, and `FetchAudit` is what proves it.
///
/// Recomputation is coalesced: a change arriving while a computation is in flight marks the result
/// stale and schedules exactly one more pass, so a twenty-item batch operation produces two
/// computations rather than twenty.
@Observable
@MainActor
public final class CountsService {
    public private(set) var counts: SidebarCounts = .zero

    /// `false` until the first computation lands. The sidebar shows no badge rather than a
    /// provisional zero, because a zero that later becomes three reads as data loss.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let worker: CountsWorker
    @ObservationIgnored private let dateProvider: any DateProvider

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isStale = false

    public init(container: ModelContainer, dateProvider: any DateProvider) {
        self.worker = CountsWorker(modelContainer: container)
        self.dateProvider = dateProvider
    }

    /// Recomputes. Safe to call as often as changes occur.
    public func refresh() {
        guard refreshTask == nil else {
            // A pass is already running and will not see this change; ask it to run once more.
            isStale = true
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            repeat {
                self.isStale = false

                let startOfTomorrow = self.dateProvider.startOfTomorrow
                let now = self.dateProvider.now

                do {
                    let computed = try await self.worker.counts(startOfTomorrow: startOfTomorrow, now: now)
                    self.counts = computed
                    self.hasLoaded = true
                } catch {
                    // A failed count is not worth interrupting the user for. The badge simply keeps
                    // its previous value and the next change tries again.
                    Diagnostics.persistence.error(
                        "Sidebar counts failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            } while self.isStale && !Task.isCancelled

            self.refreshTask = nil
        }
    }

    /// Cancels any in-flight computation. For teardown and tests.
    public func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Recomputes and waits, so a test can assert on a settled value without polling.
    public func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }
}
