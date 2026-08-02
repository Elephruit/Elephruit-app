import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The sidebar recomputes itself after every save, so the questions it asks were rewritten to stop
/// materialising the library each time. These tests hold each rewritten question equal to the one
/// it replaced.
@MainActor
@Suite("Sidebar refresh queries")
struct SidebarRefreshQueryTests {
    private func makeViews(_ fixture: StoreFixture) -> TaskViewService {
        TaskViewService(items: fixture.items, context: fixture.context, dateProvider: fixture.dateProvider)
    }

    @Test("The single-pass badges equal the per-view counts")
    func badgeParity() throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        _ = try fixture.makeTask(title: "Loose capture")
        _ = try fixture.makeTask(title: "Due today", dueAt: clock.startOfToday)
        _ = try fixture.makeTask(title: "Overdue", dueAt: clock.startOfDay(daysFromToday: -2))
        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeTask(title: "Filed", parentID: project.id)
        let done = try fixture.makeTask(title: "Done", dueAt: clock.startOfToday)
        try fixture.items.toggleCompletion(done)

        let views = makeViews(fixture)
        let combined = try views.badgeCounts()

        for view in TaskSystemView.allCases where view.showsCount {
            #expect(combined[view] == (try views.badgeCount(for: view)),
                    "the one-pass badge for \(view) disagrees with the per-view count")
        }
        #expect(combined.values.contains { $0 > 0 }, "a fixture with due work must produce a badge")
    }

    @Test("The store-side sync-attention count equals the filter it replaced")
    func syncAttentionParity() throws {
        let fixture = try StoreFixture()

        for state in TaskSyncState.allCases {
            let task = try fixture.makeTask(title: "State \(state.rawValue)")
            try fixture.items.recordSyncMetadata(on: task) {
                $0.syncState = state
                $0.externalIdentifier = "rem-\(state.rawValue)"
            }
        }

        // A resolved task still counts — a conflict does not go away by finishing the work.
        let resolvedConflict = try fixture.makeTask(title: "Resolved conflict")
        try fixture.items.recordSyncMetadata(on: resolvedConflict) { $0.syncState = .conflicted }
        try fixture.items.toggleCompletion(resolvedConflict)

        // Trashed and archived conflicts do not: the old filter ran in the active scope.
        let trashedConflict = try fixture.makeTask(title: "Trashed conflict")
        try fixture.items.recordSyncMetadata(on: trashedConflict) { $0.syncState = .conflicted }
        try fixture.items.moveToTrash(trashedConflict)

        let archivedConflict = try fixture.makeTask(title: "Archived conflict")
        try fixture.items.recordSyncMetadata(on: archivedConflict) { $0.syncState = .conflicted }
        try fixture.items.setArchived(archivedConflict, true)

        let views = makeViews(fixture)
        let filter = TaskFilter(rules: [.syncNeedsAttention], includesResolved: true)
        let expected = try views.tasks(matching: filter).count

        #expect(views.syncAttentionCount() == expected)
        #expect(expected == 4, "conflicted, externalMissing, externalReadOnly, and the resolved conflict")
    }

    @Test("The store-side pinned clause answers exactly as the post-filter did")
    func pinnedParity() throws {
        let fixture = try StoreFixture()

        let pinnedNote = try fixture.makeNote(title: "Pinned note")
        try fixture.items.update(pinnedNote) { $0.isPinned = true }
        let pinnedProject = try fixture.makeProject(title: "Pinned project")
        try fixture.items.update(pinnedProject) { $0.isPinned = true }
        _ = try fixture.makeNote(title: "Unpinned")

        let pinnedArchived = try fixture.makeNote(title: "Pinned but archived")
        try fixture.items.update(pinnedArchived) { $0.isPinned = true }
        try fixture.items.setArchived(pinnedArchived, true)

        let pinnedTrashed = try fixture.makeNote(title: "Pinned but trashed")
        try fixture.items.update(pinnedTrashed) { $0.isPinned = true }
        try fixture.items.moveToTrash(pinnedTrashed)

        var query = ItemQuery()
        query.isPinned = true
        query.sort = .titleAscending

        let titles = try fixture.items.items(matching: query).map(\.title)
        #expect(titles == ["Pinned note", "Pinned project"])

        // The other scopes still answer through the post-filter, unchanged.
        var archivedQuery = ItemQuery()
        archivedQuery.scope = .archived
        archivedQuery.isPinned = true
        let archivedTitles = try fixture.items.items(matching: archivedQuery).map(\.title)
        #expect(archivedTitles == ["Pinned but archived"])
    }

    /// The structural guard: what one full sidebar recomputation may cost in store traffic.
    ///
    /// The exact numbers matter less than their *shape*: none of these may scale with the number
    /// of badges or grow a hidden full-store fetch back. If a legitimate feature adds a query,
    /// update the bound — knowingly.
    @Test("A full sidebar refresh performs a bounded number of item fetches")
    func refreshFetchBound() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeTask(title: "Something", dueAt: fixture.dateProvider.startOfToday)

        let views = makeViews(fixture)

        let (_, tally) = try audit.measure {
            _ = try views.badgeCounts()
        }
        #expect(tally.itemFetches == 1,
                "all badges must come from one fetch, saw \(tally.description)")

        let (_, syncTally) = audit.measure {
            _ = views.syncAttentionCount()
        }
        #expect(syncTally.itemFetches == 0,
                "the sync-attention count must not materialise items, saw \(syncTally.description)")
    }
}
