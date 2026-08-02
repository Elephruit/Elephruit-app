import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The ordering invariants of `create(_:)` itself.
///
/// `nextSortOrder(parentID:)` used to be a full-store fetch with a Swift post-filter and now asks
/// the store for the single highest sibling. These tests pin the behaviour that rewrite had to
/// preserve: every sibling counts — trashed, archived, and structural kinds included — because
/// ordering is structural, and an item that reuses a trashed sibling's order would collide with it
/// the moment that sibling is restored.
@MainActor
@Suite("Create-time ordering")
struct CreateOrderingTests {
    @Test("Successive top-level creates take strictly increasing orders")
    func topLevelCreatesIncrease() throws {
        let fixture = try StoreFixture()
        let first = try fixture.makeNote(title: "First")
        let second = try fixture.makeNote(title: "Second")
        let third = try fixture.makeNote(title: "Third")

        #expect(first.sortOrder < second.sortOrder)
        #expect(second.sortOrder < third.sortOrder)
    }

    @Test("A new child lands after its siblings, not after unrelated top-level items")
    func childOrdersAreScopedToTheParent() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")
        let sibling = try fixture.makeTask(title: "Existing", parentID: project.id)

        // Push an unrelated top-level item far beyond the project's children.
        let outsider = try fixture.makeNote(title: "Outsider")
        try fixture.items.update(outsider) { $0.sortOrder = 1_000_000 }

        let child = try fixture.makeTask(title: "New", parentID: project.id)

        #expect(child.sortOrder > sibling.sortOrder)
        #expect(child.sortOrder < 1_000_000, "a child's order came from a top-level stranger")
    }

    @Test("A trashed sibling still counts, so restoring it cannot collide")
    func trashedSiblingsStillCount() throws {
        let fixture = try StoreFixture()
        let doomed = try fixture.makeNote(title: "Doomed")
        let doomedOrder = doomed.sortOrder
        try fixture.items.moveToTrash(doomed)

        let successor = try fixture.makeNote(title: "Successor")
        #expect(successor.sortOrder > doomedOrder)
    }

    @Test("An archived sibling still counts")
    func archivedSiblingsStillCount() throws {
        let fixture = try StoreFixture()
        let shelved = try fixture.makeNote(title: "Shelved")
        let shelvedOrder = shelved.sortOrder
        try fixture.items.setArchived(shelved, true)

        let successor = try fixture.makeNote(title: "Successor")
        #expect(successor.sortOrder > shelvedOrder)
    }

    @Test("Two headings created in the same project take distinct orders")
    func headingsAreSiblingsToo() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")

        let first = try fixture.items.create(ItemDraft(kind: .heading, title: "One", parentID: project.id))
        let second = try fixture.items.create(ItemDraft(kind: .heading, title: "Two", parentID: project.id))

        #expect(first.sortOrder != second.sortOrder)
        #expect(second.sortOrder > first.sortOrder)
    }

    @Test("A create performs a bounded number of fetches regardless of store size")
    func createFetchCountIsFixed() throws {
        let audit = FetchAudit()
        let fixture = try StoreFixture(audit: audit)
        for index in 0..<25 {
            try fixture.makeNote(title: "Seed \(index)")
        }

        let tally = try audit.measure {
            try fixture.items.create(ItemDraft(kind: .note, title: "Audited", body: "Plain body."))
        }.tally

        // Duplicate-ID lookup + sibling top-1 lookup, and the unresolved-link resolution fetch.
        // A create that starts fetching more than this has grown a hidden scan.
        #expect(tally.itemFetches == 2, "expected 2 item fetches, saw \(tally.description)")
        #expect(tally.otherFetches == 1, "expected 1 link fetch, saw \(tally.description)")
    }
}
