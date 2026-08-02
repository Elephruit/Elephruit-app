import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The containment clause moved into the store, and these tests hold every semantic it had as a
/// post-filter: scopes, kinds, statuses, headings, ordering, limits, and both directions of
/// `hasNoParent` — plus the renumbering path, whose whole point is that trashed, archived, and
/// structural siblings keep counting.
@MainActor
@Suite("Parent queries answer from the store")
struct ParentQueryTests {
    /// A library with every corner the clause has to get right.
    private func makeLibrary() throws -> (fixture: StoreFixture, project: Item, other: Item) {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Target project")
        let other = try fixture.makeProject(title: "Other project")

        _ = try fixture.makeTask(title: "Open child", parentID: project.id)
        let done = try fixture.makeTask(title: "Done child", parentID: project.id)
        try fixture.items.toggleCompletion(done)
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Section", parentID: project.id))

        let trashedChild = try fixture.makeTask(title: "Trashed child", parentID: project.id)
        try fixture.items.moveToTrash(trashedChild)
        let archivedChild = try fixture.makeTask(title: "Archived child", parentID: project.id)
        try fixture.items.setArchived(archivedChild, true)

        _ = try fixture.makeTask(title: "Stranger", parentID: other.id)
        _ = try fixture.makeNote(title: "Top-level note")

        return (fixture, project, other)
    }

    @Test("children(of:) returns the container's live contents, headings included, in manual order")
    func childrenSemantics() throws {
        let (fixture, project, _) = try makeLibrary()

        let rows = try fixture.items.items(matching: .children(of: project.id))
        #expect(rows.map(\.title) == ["Open child", "Done child", "Section"],
                "active children in manual order — no trash, no archive, no strangers")
    }

    @Test("Kind and status filters still narrow a children query")
    func childrenWithFilters() throws {
        let (fixture, project, _) = try makeLibrary()

        var query = ItemQuery.children(of: project.id)
        query.kinds = [.task]
        query.statuses = [.open]
        #expect(try fixture.items.items(matching: query).map(\.title) == ["Open child"])
    }

    @Test("A limit applies after the parent clause, not before it")
    func childrenWithLimit() throws {
        let (fixture, project, _) = try makeLibrary()

        var query = ItemQuery.children(of: project.id)
        query.limit = 2
        let rows = try fixture.items.items(matching: query)
        #expect(rows.map(\.title) == ["Open child", "Done child"],
                "the first two children — a limit that bit before the parent clause would return strangers")
    }

    @Test("The archived scope still answers a parent query, through the post-filter")
    func archivedScopeChildren() throws {
        let (fixture, project, _) = try makeLibrary()

        var query = ItemQuery()
        query.scope = .archived
        query.parentID = project.id
        query.includesNonContentKinds = true
        #expect(try fixture.items.items(matching: query).map(\.title) == ["Archived child"])
    }

    @Test("The all scope sees every child: trashed, archived, and structural alike")
    func allScopeChildren() throws {
        let (fixture, project, _) = try makeLibrary()

        var query = ItemQuery()
        query.scope = .all
        query.sort = .manual
        query.includesNonContentKinds = true
        query.parentID = project.id

        let titles = Set(try fixture.items.items(matching: query).map(\.title))
        #expect(titles == ["Open child", "Done child", "Section", "Trashed child", "Archived child"])
    }

    @Test("hasNoParent answers both ways")
    func hasNoParentBothWays() throws {
        let (fixture, _, _) = try makeLibrary()

        var topLevel = ItemQuery()
        topLevel.hasNoParent = true
        topLevel.includesNonContentKinds = true
        let topTitles = Set(try fixture.items.items(matching: topLevel).map(\.title))
        #expect(topTitles == ["Target project", "Other project", "Top-level note"])

        // The false direction — "anything with a parent" — is deliberately still a post-filter.
        var parented = ItemQuery()
        parented.hasNoParent = false
        parented.includesNonContentKinds = true
        let parentedTitles = Set(try fixture.items.items(matching: parented).map(\.title))
        #expect(parentedTitles == ["Open child", "Done child", "Section", "Stranger"])
    }

    @Test("A children query materialises the children, not the library")
    func childrenFetchShape() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeTask(title: "Child", parentID: project.id)
        for index in 0..<30 {
            _ = try fixture.makeNote(title: "Unrelated \(index)")
        }

        // The row tally is the deterministic guard for the query's *shape*: the old post-filter
        // was also one fetch, but it returned all thirty-one rows to keep one. It cannot see
        // relationship faults or per-row cost — ChildrenQueryBenchmarks holds the scaling curve
        // itself and is the authoritative guard.
        let (rows, tally) = try audit.measure {
            try fixture.items.items(matching: .children(of: project.id))
        }
        #expect(rows.count == 1)
        #expect(tally.itemFetches == 1)
        #expect(tally.itemRowsMaterialized == 1,
                "the store returned \(tally.itemRowsMaterialized) rows for one child — \(tally.description)")
    }

    @Test("Tag and Inbox queries materialise their rows, not the library")
    func tagAndInboxFetchShape() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        _ = try fixture.makeNote(title: "Tagged", tags: ["work"])
        let project = try fixture.makeProject(title: "Project")
        for index in 0..<30 {
            // Filed away, so out of the Inbox and off the tag.
            let filed = try fixture.makeNote(title: "Filed \(index)")
            try fixture.items.fileItem(filed, under: project)
        }

        let (tagRows, tagTally) = try audit.measure {
            try fixture.items.items(matching: .tag(slug: "work"))
        }
        #expect(tagRows.count == 1)
        #expect(tagTally.itemRowsMaterialized == 1, "\(tagTally.description)")

        let (inboxRows, inboxTally) = try audit.measure {
            try fixture.items.items(matching: .inbox())
        }
        // The tagged note is out (a tag is a home); only nothing-shaped rows come back.
        #expect(inboxRows.isEmpty)
        #expect(inboxTally.itemRowsMaterialized == 0, "\(inboxTally.description)")
    }

    @Test("Exhausting the gap between two neighbours renumbers every sibling and keeps the order")
    func renumberingKeepsEverySibling() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")

        let first = try fixture.makeTask(title: "First", parentID: project.id)
        let last = try fixture.makeTask(title: "Last", parentID: project.id)

        // Siblings the renumbering must not skip: trashed, archived, and structural.
        let trashed = try fixture.makeTask(title: "Trashed sibling", parentID: project.id)
        try fixture.items.moveToTrash(trashed)
        let archived = try fixture.makeTask(title: "Archived sibling", parentID: project.id)
        try fixture.items.setArchived(archived, true)
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Section", parentID: project.id))

        // Insert between the same two neighbours until the midpoint runs out of doubles, which is
        // what forces `renumberSiblings`. Sixty halvings of a 1024 gap is far past exhaustion.
        var upper = last
        for index in 0..<60 {
            let inserted = try fixture.makeTask(title: "Wedge \(index)", parentID: project.id)
            try fixture.items.move(inserted, after: first, before: upper)
            upper = inserted
        }

        // Order must hold across the whole family, and no two siblings may share an order —
        // including the trashed, archived, and heading rows a scope-narrowed renumbering would
        // have skipped and collided with.
        var query = ItemQuery()
        query.scope = .all
        query.sort = .manual
        query.includesNonContentKinds = true
        query.parentID = project.id

        let family = try fixture.items.items(matching: query)
        #expect(family.count == 65)

        let orders = family.map(\.sortOrder)
        #expect(Set(orders).count == orders.count, "two siblings share a sort order after renumbering")
        #expect(family.first?.title == "First")

        // The live list, in full: First, then the wedges newest-first — each was placed directly
        // after First — then Last, then the Section, which was created after Last and so follows it.
        let live = try fixture.items.items(matching: .children(of: project.id))
        let expected = ["First"] + (0..<60).reversed().map { "Wedge \($0)" } + ["Last", "Section"]
        #expect(live.map(\.title) == expected)
    }
}
