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
/// Both counts need a clause the store-side predicate cannot express (a comparison against an optional
/// date; the absence of tags). Rather than materialise everything and filter, each fetch is narrowed
/// by a small, translatable predicate first — open actionable items for Today, unparented active items
/// for Inbox — and the remainder is decided in Swift over a set that is already small.
@ModelActor
actor CountsWorker {
    func counts(startOfTomorrow: Date, now: Date) throws -> SidebarCounts {
        SidebarCounts(
            today: try todayCount(startOfTomorrow: startOfTomorrow, now: now),
            inbox: try inboxCount()
        )
    }

    private func todayCount(startOfTomorrow: Date, now: Date) throws -> Int {
        var query = ItemQuery()
        query.kinds = [.task, .project, .goal]
        query.statuses = [.open]

        // Store-side: active scope, kind, status. Everything an actionable item could be — typically a
        // few hundred rows even in a mature library.
        let candidates = try modelContext.fetch(FetchDescriptor<Item>(predicate: query.predicate()))

        return candidates.count { item in
            guard let dueAt = item.dueAt, dueAt < startOfTomorrow else { return false }
            guard let deferUntil = item.deferUntil else { return true }
            return deferUntil <= now
        }
    }

    private func inboxCount() throws -> Int {
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { item in
                item.deletedAt == nil && item.archivedAt == nil && item.parent == nil
            }
        )

        let unparented = try modelContext.fetch(descriptor)

        return unparented.count { item in
            item.kind.appearsInInbox && item.tags.isEmpty
        }
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
