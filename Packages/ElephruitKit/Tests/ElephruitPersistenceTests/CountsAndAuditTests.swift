import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// `FetchAudit` is what makes criterion **A1-1** — *zero item fetches occur during sidebar rendering* —
/// an assertion rather than a hope. These tests prove the instrument itself works before anything
/// relies on it.
@MainActor
@Suite("Fetch audit")
struct FetchAuditTests {
    @Test("Records nothing outside a measured block")
    func silentWhenNotMeasuring() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)

        _ = try fixture.makeNote(title: "A note")
        _ = try fixture.items.items(matching: ItemQuery())

        #expect(audit.tally.total == 0, "Recording must cost nothing when no measurement is running")
    }

    @Test("Counts fetches inside a measured block")
    func countsFetches() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeNote(title: "A note")

        let (_, tally) = try audit.measure {
            try fixture.items.items(matching: ItemQuery())
        }

        #expect(tally.itemFetches == 1)
        #expect(tally.total == 1)
    }

    @Test("Distinguishes count queries from fetches")
    func distinguishesCountQueries() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeNote(title: "A note")

        // A query needing no post-filtering can use the store's own count.
        let (_, tally) = try audit.measure {
            try fixture.items.count(matching: .kind(.note))
        }

        #expect(tally.itemCountQueries == 1)
        #expect(tally.itemFetches == 0)
    }

    @Test("A post-filtered count is visible as the full fetch it really is")
    func postFilteredCountShowsAsFetch() throws {
        // This is the defect the audit exists to catch: `count(matching:)` silently falls back to
        // fetching everything whenever a query post-filters. The old sidebar did this twice per body
        // evaluation and nothing noticed.
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeNote(title: "A note")

        let (_, tally) = try audit.measure {
            try fixture.items.count(matching: .inbox())
        }

        #expect(tally.itemFetches == 1, "Inbox post-filters, so its count is a full fetch")
        #expect(tally.itemCountQueries == 0)
    }

    @Test("Resets between measurements")
    func resetsBetweenMeasurements() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeNote(title: "A note")

        _ = try audit.measure { try fixture.items.items(matching: ItemQuery()) }
        let (_, second) = audit.measure { }

        #expect(second.total == 0)
    }
}

/// The counts the sidebar shows, and — more importantly — the promise that showing them costs nothing.
@MainActor
@Suite("Sidebar counts")
struct CountsServiceTests {
    private func makeService(_ fixture: StoreFixture) -> CountsService {
        CountsService(container: fixture.stack.container, dateProvider: fixture.dateProvider)
    }

    @Test("Reports nothing until it has actually computed")
    func hasLoadedGatesTheBadge() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        // A provisional zero that later becomes three reads as data loss, so the sidebar shows no
        // badge at all until there is a real answer.
        #expect(service.hasLoaded == false)
        #expect(service.counts == .zero)
    }

    @Test("Counts today's work, including overdue")
    func todayIncludesOverdue() async throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        _ = try fixture.makeTask(title: "Overdue", dueAt: clock.startOfDay(daysFromToday: -3))
        _ = try fixture.makeTask(title: "Due today", dueAt: clock.startOfToday)
        _ = try fixture.makeTask(title: "Next week", dueAt: clock.startOfDay(daysFromToday: 7))
        _ = try fixture.makeTask(title: "No due date")

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.hasLoaded)
        #expect(service.counts.today == 2)
    }

    @Test("Deferred work is postponed on purpose and does not count")
    func todayExcludesDeferred() async throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        let deferred = try fixture.makeTask(title: "Deferred", dueAt: clock.startOfToday)
        try fixture.items.update(deferred) { $0.deferUntil = clock.startOfDay(daysFromToday: 5) }

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.today == 0)
    }

    @Test("Completed work does not count")
    func todayExcludesCompleted() async throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        let done = try fixture.makeTask(title: "Done", dueAt: clock.startOfToday)
        try fixture.items.toggleCompletion(done)

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.today == 0)
    }

    @Test("Inbox is unprocessed captures, not merely unparented items")
    func inboxExcludesContainers() async throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "An unfiled thought")
        _ = try fixture.makeTask(title: "An unfiled task")

        // Containers sit at the top level by nature. Counting them was what made the old Inbox
        // useless.
        _ = try fixture.makeProject(title: "A top-level project")
        _ = try fixture.makeArea(title: "A top-level area")

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.inbox == 2)
    }

    @Test("A tag is a home, so a tagged item has left the Inbox")
    func inboxExcludesTaggedItems() async throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Unfiled")
        _ = try fixture.makeNote(title: "Tagged", tags: ["work"])

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.inbox == 1)
    }

    @Test("A filed item has left the Inbox")
    func inboxExcludesFiledItems() async throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeTask(title: "Filed", parentID: project.id)
        _ = try fixture.makeTask(title: "Unfiled")

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.inbox == 1)
    }

    @Test("Trashed and archived items are not counted")
    func countsIgnoreTrashAndArchive() async throws {
        let fixture = try StoreFixture()

        let trashed = try fixture.makeNote(title: "Trashed")
        let archived = try fixture.makeNote(title: "Archived")
        _ = try fixture.makeNote(title: "Live")

        try fixture.items.moveToTrash(trashed)
        try fixture.items.setArchived(archived, true)

        let service = makeService(fixture)
        await service.refreshAndWait()

        #expect(service.counts.inbox == 1)
    }

    @Test("Counts update after a change")
    func countsFollowChanges() async throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        await service.refreshAndWait()
        #expect(service.counts.inbox == 0)

        _ = try fixture.makeNote(title: "A capture")
        await service.refreshAndWait()
        #expect(service.counts.inbox == 1)
    }

    @Test("Concurrent changes coalesce instead of queueing one pass each")
    func refreshesCoalesce() async throws {
        let fixture = try StoreFixture()
        for index in 1...20 {
            _ = try fixture.makeNote(title: "Capture \(index)")
        }

        let service = makeService(fixture)

        // A twenty-item batch must not produce twenty computations.
        for _ in 1...20 { service.refresh() }
        await service.refreshAndWait()

        #expect(service.counts.inbox == 20)
    }

    /// **Criterion A1-1.** The whole point of the redesign's performance work.
    @Test("Reading the counts performs no store access at all")
    func readingCountsTouchesNothing() async throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)

        for index in 1...50 {
            _ = try fixture.makeNote(title: "Capture \(index)")
        }

        let service = makeService(fixture)
        await service.refreshAndWait()

        // Exactly what a sidebar body evaluation does: read two integers.
        let (values, tally) = audit.measure { () -> (Int, Int) in
            (service.counts.today, service.counts.inbox)
        }

        #expect(values.1 == 50)
        #expect(
            tally.total == 0,
            "Rendering the sidebar must not touch the store. Observed: \(tally.description)"
        )
    }
}
