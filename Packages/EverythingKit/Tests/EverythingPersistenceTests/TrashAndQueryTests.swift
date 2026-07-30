import EverythingCore
import EverythingModel
import EverythingPersistence
import Foundation
import SwiftData
import Testing

/// Soft deletion, restoration, and the promise that nothing disappears without being asked
/// for twice. Invariants 1 and 8 from `docs/04-domain-model.md`.
@MainActor
@Suite("Trash and restoration")
struct TrashTests {
    @Test("Trashing hides an item from active views but keeps it in the store")
    func trashingHidesWithoutDestroying() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "Doomed")

        try fixture.items.moveToTrash(note)

        #expect(try fixture.items.items(matching: ItemQuery()).isEmpty)
        #expect(try fixture.items.items(matching: .trash()).count == 1)
        #expect(try fixture.items.items(matching: .everything()).count == 1)
    }

    @Test("Trashing a project takes its tasks with it")
    func trashingCascadesToChildren() throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Q3 Launch")
        let taskA = try fixture.makeTask(title: "Task A", parentID: project.id)
        let taskB = try fixture.makeTask(title: "Task B", parentID: project.id)

        try fixture.items.moveToTrash(project)

        #expect(try fixture.requireItem(id: taskA.id).deletedAt != nil)
        #expect(try fixture.requireItem(id: taskB.id).deletedAt != nil)
        #expect(try fixture.items.items(matching: .trash()).count == 3)
    }

    @Test("Restoring brings back exactly what was trashed together")
    func restoreReattachesTheSameSet() throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Q3 Launch")
        let keptTask = try fixture.makeTask(title: "Kept", parentID: project.id)
        let separatelyDeleted = try fixture.makeTask(title: "Deleted earlier", parentID: project.id)

        // Deleted deliberately, on its own, before the project went.
        try fixture.items.moveToTrash(separatelyDeleted)

        // A distinct instant, so the two deletions are distinguishable.
        let laterFixtureDate = FixedDateProvider(
            now: fixture.dateProvider.now.addingTimeInterval(3600),
            calendar: fixture.dateProvider.calendar
        )
        let laterItems = SwiftDataItemRepository(
            context: fixture.context,
            dateProvider: laterFixtureDate,
            tags: fixture.tags
        )
        try laterItems.moveToTrash(project)

        try laterItems.restore(project)

        #expect(try fixture.requireItem(id: project.id).deletedAt == nil)
        #expect(try fixture.requireItem(id: keptTask.id).deletedAt == nil, "Trashed with the project, so restored with it")
        #expect(
            try fixture.requireItem(id: separatelyDeleted.id).deletedAt != nil,
            "Deleted deliberately beforehand — restoring the project must not resurrect it"
        )
    }

    @Test("Restoring an item whose parent is still trashed detaches it rather than hiding it")
    func restoreDetachesFromTrashedParent() throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Project")
        let task = try fixture.makeTask(title: "Task", parentID: project.id)

        try fixture.items.moveToTrash(project)
        try fixture.items.restore(task)

        let restored = try fixture.requireItem(id: task.id)
        #expect(restored.deletedAt == nil)
        #expect(restored.parent == nil, "A restored item must be reachable, not orphaned inside the Trash")

        // And it is genuinely visible again.
        #expect(try fixture.items.items(matching: ItemQuery()).contains { $0.id == task.id })
    }

    @Test("Emptying the trash removes only trashed items")
    func emptyTrashSparesLiveItems() throws {
        let fixture = try StoreFixture()

        let live = try fixture.makeNote(title: "Live")
        let doomed = try fixture.makeNote(title: "Doomed")
        try fixture.items.moveToTrash(doomed)

        try fixture.items.emptyTrash()

        let remaining = try fixture.items.items(matching: .everything())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == live.id)
    }

    @Test("Archiving is not deletion")
    func archivingIsDistinctFromTrashing() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "Reference material")

        try fixture.items.setArchived(note, true)

        #expect(try fixture.items.items(matching: ItemQuery()).isEmpty)
        #expect(try fixture.items.items(matching: .trash()).isEmpty)

        var archivedQuery = ItemQuery()
        archivedQuery.scope = .archived
        #expect(try fixture.items.items(matching: archivedQuery).count == 1)

        try fixture.items.setArchived(note, false)
        #expect(try fixture.items.items(matching: ItemQuery()).count == 1)
    }
}

/// Every clause of ``ItemQuery`` executed against a real store, so that the store-side
/// predicate and the Swift post-filter are both proven rather than assumed.
@MainActor
@Suite("Item queries")
struct ItemQueryTests {
    @Test("Kind filtering runs in the store")
    func filtersByKind() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "A note")
        _ = try fixture.makeNote(title: "Another note")
        _ = try fixture.makeTask(title: "A task")

        #expect(try fixture.items.items(matching: .kind(.note)).count == 2)
        #expect(try fixture.items.items(matching: .kind(.task)).count == 1)
        #expect(try fixture.items.count(matching: .kind(.note)) == 2)
    }

    @Test("Status filtering runs in the store")
    func filtersByStatus() throws {
        let fixture = try StoreFixture()

        let done = try fixture.makeTask(title: "Done")
        _ = try fixture.makeTask(title: "Not done")
        try fixture.items.toggleCompletion(done)

        var openQuery = ItemQuery()
        openQuery.statuses = [.open]
        #expect(try fixture.items.items(matching: openQuery).count == 1)

        var completedQuery = ItemQuery()
        completedQuery.statuses = [.completed]
        #expect(try fixture.items.items(matching: completedQuery).count == 1)
    }

    @Test("Tag filtering requires every named tag")
    func filtersByAllTags() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Both", tags: ["work", "urgent"])
        _ = try fixture.makeNote(title: "One", tags: ["work"])
        _ = try fixture.makeNote(title: "Neither")

        #expect(try fixture.items.items(matching: .tag(slug: "work")).count == 2)

        var bothQuery = ItemQuery()
        bothQuery.tagSlugs = ["work", "urgent"]
        let both = try fixture.items.items(matching: bothQuery)
        #expect(both.count == 1)
        #expect(both.first?.title == "Both")
    }

    @Test("Inbox is items with no home")
    func inboxIsUnparentedItems() throws {
        let fixture = try StoreFixture()

        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeTask(title: "Filed", parentID: project.id)
        _ = try fixture.makeNote(title: "Unfiled")

        let inbox = try fixture.items.items(matching: .inbox())
        // The project itself is also unparented, which is correct — it has no home either.
        #expect(inbox.contains { $0.title == "Unfiled" })
        #expect(!inbox.contains { $0.title == "Filed" })
    }

    @Test("Today includes overdue and excludes deferred and future work")
    func todayWindowIsCorrect() throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        let overdue = try fixture.makeTask(title: "Overdue", dueAt: clock.startOfDay(daysFromToday: -3))
        let dueToday = try fixture.makeTask(title: "Due today", dueAt: clock.startOfToday)
        _ = try fixture.makeTask(title: "Due next week", dueAt: clock.startOfDay(daysFromToday: 7))
        let deferred = try fixture.makeTask(title: "Deferred", dueAt: clock.startOfToday)
        try fixture.items.update(deferred) { $0.deferUntil = clock.startOfDay(daysFromToday: 5) }

        let today = try fixture.items.items(matching: .today(using: clock))
        let titles = Set(today.map(\.title))

        #expect(titles.contains("Overdue"))
        #expect(titles.contains("Due today"))
        #expect(!titles.contains("Due next week"))
        #expect(!titles.contains("Deferred"), "Deferred work is postponed on purpose")

        // Overdue sorts before today, because due-soonest-first puts the oldest first.
        #expect(today.first?.id == overdue.id)
        #expect(dueToday.dueAt != nil)
    }

    @Test("Upcoming excludes today")
    func upcomingStartsTomorrow() throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        _ = try fixture.makeTask(title: "Today", dueAt: clock.startOfToday)
        _ = try fixture.makeTask(title: "Tomorrow", dueAt: clock.startOfDay(daysFromToday: 1))
        _ = try fixture.makeTask(title: "Far future", dueAt: clock.startOfDay(daysFromToday: 30))

        let upcoming = try fixture.items.items(matching: .upcoming(days: 7, using: clock))
        let titles = Set(upcoming.map(\.title))

        #expect(titles == ["Tomorrow"])
    }

    @Test("Free-text matching is diacritic- and case-insensitive")
    func textMatchingIsFolded() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Café Planning", body: "Notes about the café")
        _ = try fixture.makeNote(title: "Something else")

        var query = ItemQuery()
        query.text = "CAFE"
        let results = try fixture.items.items(matching: query)

        #expect(results.count == 1)
        #expect(results.first?.title == "Café Planning")
    }

    @Test("A limit applies after post-filtering, so matches are not silently dropped")
    func limitAppliesAfterPostFiltering() throws {
        let fixture = try StoreFixture()

        for index in 1...10 {
            _ = try fixture.makeNote(title: "Tagged \(index)", tags: ["work"])
        }
        for index in 1...10 {
            _ = try fixture.makeNote(title: "Untagged \(index)")
        }

        var query = ItemQuery()
        query.tagSlugs = ["work"]
        query.limit = 5

        let results = try fixture.items.items(matching: query)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.tags.contains { $0.slug == "work" } })
    }

    @Test("Manual reordering places an item between its neighbours")
    func manualReorderUsesSparseOrdering() throws {
        let fixture = try StoreFixture()

        let first = try fixture.makeNote(title: "First")
        let second = try fixture.makeNote(title: "Second")
        let third = try fixture.makeNote(title: "Third")

        // Move `third` between `first` and `second`.
        try fixture.items.move(third, after: first, before: second)

        #expect(third.sortOrder > first.sortOrder)
        #expect(third.sortOrder < second.sortOrder)

        var query = ItemQuery()
        query.sort = .manual
        let ordered = try fixture.items.items(matching: query).map(\.title)
        #expect(ordered == ["First", "Third", "Second"])
    }
}

/// Tag identity, hierarchy, and the promise that `#Work` and `#work` are one tag.
@MainActor
@Suite("Tags")
struct TagTests {
    @Test("Tags are identified by their normalised slug")
    func tagsAreDeduplicatedBySlug() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "One", tags: ["Work"])
        _ = try fixture.makeNote(title: "Two", tags: ["work"])
        _ = try fixture.makeNote(title: "Three", tags: ["WORK"])

        let allTags = try fixture.tags.allTags()
        #expect(allTags.count == 1)
        #expect(allTags.first?.slug == "work")
    }

    @Test("Hierarchical tags create their ancestors implicitly")
    func hierarchyIsCreatedImplicitly() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Note", tags: ["work/clients/acme"])

        let slugs = Set(try fixture.tags.allTags().map(\.slug))
        #expect(slugs == ["work", "work/clients", "work/clients/acme"])

        let leaf = try #require(try fixture.tags.tag(slug: "work/clients/acme"))
        #expect(leaf.isImplicit == false)
        #expect(leaf.depth == 2)
        #expect(leaf.leafName == "acme")

        let ancestor = try #require(try fixture.tags.tag(slug: "work"))
        #expect(ancestor.isImplicit, "Created as structure, not as a label the user chose")
    }

    @Test("Only the leaf tag is attached to the item")
    func onlyLeafIsAttached() throws {
        let fixture = try StoreFixture()

        let note = try fixture.makeNote(title: "Note", tags: ["work/clients"])
        #expect(note.tags.count == 1)
        #expect(note.tags.first?.slug == "work/clients")
    }

    @Test("Renaming a tag moves its descendants and refreshes search text")
    func renamePropagates() throws {
        let fixture = try StoreFixture()

        let note = try fixture.makeNote(title: "Note", tags: ["work/clients"])
        let parent = try #require(try fixture.tags.tag(slug: "work"))

        try fixture.tags.rename(parent, to: "Business")

        let slugs = Set(try fixture.tags.allTags().map(\.slug))
        #expect(slugs == ["business", "business/clients"])
        #expect(note.searchText.contains("business/clients"))
    }

    @Test("Renaming onto an existing tag is refused rather than merging silently")
    func renameOntoExistingIsRefused() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "A", tags: ["alpha"])
        _ = try fixture.makeNote(title: "B", tags: ["beta"])
        let alpha = try #require(try fixture.tags.tag(slug: "alpha"))

        #expect(throws: AppError.self) {
            try fixture.tags.rename(alpha, to: "beta")
        }
    }

    @Test("A tag that normalises to nothing is refused")
    func emptySlugIsRefused() throws {
        let fixture = try StoreFixture()

        let note = try fixture.makeNote(title: "Note", tags: ["!!!", "---"])
        #expect(note.tags.isEmpty, "Punctuation-only names are not usable tags")

        let real = try #require(try fixture.tags.ensureTags(named: ["ok"]).first)
        #expect(throws: AppError.self) {
            try fixture.tags.rename(real, to: "###")
        }
    }

    @Test("Deleting a tag orphans its children rather than destroying them")
    func deleteReparentsChildren() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Note", tags: ["work/clients/acme"])
        let middle = try #require(try fixture.tags.tag(slug: "work/clients"))

        try fixture.tags.delete(middle)

        let remaining = Set(try fixture.tags.allTags().map(\.slug))
        #expect(remaining.contains("work/clients/acme"), "The leaf and its items survive")
        #expect(!remaining.contains("work/clients"))
    }

    @Test("Pruning removes implicit tags nothing depends on")
    func pruningRemovesUnusedStructure() throws {
        let fixture = try StoreFixture()

        let note = try fixture.makeNote(title: "Note", tags: ["work/clients"])
        try fixture.items.setTags(note, slugs: [])

        // `work/clients` was explicit and stays; `work` was only ever structure.
        let leaf = try #require(try fixture.tags.tag(slug: "work/clients"))
        try fixture.tags.delete(leaf)
        try fixture.tags.pruneOrphanedImplicitTags()

        #expect(try fixture.tags.allTags().isEmpty)
    }
}
