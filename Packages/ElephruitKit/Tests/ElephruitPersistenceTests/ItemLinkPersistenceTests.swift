import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Verifies risk **R3** from `docs/08-risks.md`.
///
/// `ItemLink` has two relationships to `Item` — `source` and `target` — each with its own
/// inverse (`outgoingLinks`, `incomingLinks`). This shape is the foundation of the entire
/// link graph, and it is historically the most fragile thing in the schema, so it is the
/// first thing tested and every assertion goes through a **fresh context** rather than
/// reading back out of the graph that built it.
///
/// If these fail, the documented fallback is in R3: drop the inverse on `target`, store
/// `targetID: UUID?` as an indexed attribute, and compute backlinks by explicit fetch.
@MainActor
@Suite("ItemLink: two relationships to one entity")
struct ItemLinkPersistenceTests {
    @Test("Both endpoints resolve after a round trip through the store")
    func bothEndpointsSurviveRefetch() throws {
        let fixture = try StoreFixture()

        let source = try fixture.makeNote(title: "Source Note")
        let target = try fixture.makeNote(title: "Target Note")

        let link = ItemLink(kind: .related, source: source, target: target)
        fixture.context.insert(link)

        let refetchedSource = try fixture.requireItem(id: source.id)
        let refetchedTarget = try fixture.requireItem(id: target.id)

        #expect(refetchedSource.outgoingLinks.count == 1)
        #expect(refetchedSource.incomingLinks.isEmpty)
        #expect(refetchedTarget.incomingLinks.count == 1)
        #expect(refetchedTarget.outgoingLinks.isEmpty)

        #expect(refetchedSource.outgoingLinks.first?.target?.id == target.id)
        #expect(refetchedTarget.incomingLinks.first?.source?.id == source.id)
    }

    @Test("Inverses do not cross-contaminate when links run both ways")
    func bidirectionalLinksStayDistinct() throws {
        let fixture = try StoreFixture()

        let a = try fixture.makeNote(title: "Note A")
        let b = try fixture.makeNote(title: "Note B")

        fixture.context.insert(ItemLink(kind: .related, source: a, target: b))
        fixture.context.insert(ItemLink(kind: .related, source: b, target: a))

        let refetchedA = try fixture.requireItem(id: a.id)

        // The danger with two relationships to one type is that SwiftData conflates the
        // inverses, which would show up here as two entries in one collection and none in
        // the other.
        #expect(refetchedA.outgoingLinks.count == 1)
        #expect(refetchedA.incomingLinks.count == 1)
        #expect(refetchedA.outgoingLinks.first?.target?.id == b.id)
        #expect(refetchedA.incomingLinks.first?.source?.id == b.id)
    }

    @Test("An item can hold many links in both directions")
    func manyLinksInBothDirections() throws {
        let fixture = try StoreFixture()

        let hub = try fixture.makeNote(title: "Hub")
        let spokes = try (1...5).map { try fixture.makeNote(title: "Spoke \($0)") }

        for spoke in spokes {
            fixture.context.insert(ItemLink(kind: .related, source: hub, target: spoke))
            fixture.context.insert(ItemLink(kind: .mentions, source: spoke, target: hub))
        }

        let refetched = try fixture.requireItem(id: hub.id)
        #expect(refetched.outgoingLinks.count == 5)
        #expect(refetched.incomingLinks.count == 5)
    }

    @Test("Deleting an item cascades its links away rather than leaving dangling rows")
    func deletingItemCascadesLinks() throws {
        let fixture = try StoreFixture()

        let source = try fixture.makeNote(title: "Source")
        let target = try fixture.makeNote(title: "Target")
        fixture.context.insert(ItemLink(kind: .related, source: source, target: target))
        try fixture.context.save()

        let linksBefore = try fixture.freshContext().fetch(FetchDescriptor<ItemLink>())
        #expect(linksBefore.count == 1)

        try fixture.items.deletePermanently(source)

        let remaining = try fixture.freshContext().fetch(FetchDescriptor<ItemLink>())
        #expect(remaining.isEmpty, "The link belongs to its source and should go with it")
    }

    @Test("An unresolved link is valid and resolves when its target appears")
    func unresolvedLinkResolvesOnTargetCreation() throws {
        let fixture = try StoreFixture()

        // A wiki link to a note that does not exist yet.
        let source = try fixture.items.create(
            ItemDraft(kind: .note, title: "Source", body: "See [[Not Yet Written]] for detail.")
        )

        let refetchedSource = try fixture.requireItem(id: source.id)
        let link = try #require(refetchedSource.outgoingLinks.first)
        #expect(link.kind == .wiki)
        #expect(link.isResolved == false)
        #expect(link.unresolvedTitle == "Not Yet Written")

        // Creating the missing note should adopt the waiting link, with no user action.
        let target = try fixture.makeNote(title: "Not Yet Written")

        let resolvedSource = try fixture.requireItem(id: source.id)
        let resolvedLink = try #require(resolvedSource.outgoingLinks.first)
        #expect(resolvedLink.isResolved)
        #expect(resolvedLink.target?.id == target.id)
        #expect(resolvedLink.unresolvedTitle == nil)
        #expect(resolvedLink.unresolvedMatchKey == nil)
    }

    @Test("Backlinks exclude trashed sources and non-backlink kinds")
    func visibleBacklinksFiltersCorrectly() throws {
        let fixture = try StoreFixture()

        let target = try fixture.makeNote(title: "Target")
        let liveSource = try fixture.makeNote(title: "Live Source")
        let trashedSource = try fixture.makeNote(title: "Trashed Source")
        let seriesSource = try fixture.makeTask(title: "Recurring Occurrence")

        fixture.context.insert(ItemLink(kind: .related, source: liveSource, target: target))
        fixture.context.insert(ItemLink(kind: .related, source: trashedSource, target: target))
        fixture.context.insert(ItemLink(kind: .recurrenceSeries, source: seriesSource, target: target))
        try fixture.context.save()

        try fixture.items.moveToTrash(trashedSource)

        let refetched = try fixture.requireItem(id: target.id)
        let backlinks = refetched.visibleBacklinks()

        #expect(backlinks.count == 1)
        #expect(backlinks.first?.source?.id == liveSource.id)
    }
}

/// Verifies that wiki links are owned by the body text — added, removed, and left alone
/// according to what the text says, without disturbing links the user made deliberately.
@MainActor
@Suite("Wiki-link reconciliation")
struct WikiLinkReconciliationTests {
    @Test("Editing text away removes the link it created")
    func removingTextRemovesLink() throws {
        let fixture = try StoreFixture()

        let target = try fixture.makeNote(title: "Target")
        let source = try fixture.items.create(
            ItemDraft(kind: .note, title: "Source", body: "Points at [[Target]].")
        )

        let before = try fixture.requireItem(id: source.id)
        #expect(before.outgoingLinks.count == 1)

        try fixture.items.update(source) { $0.body = "Points at nothing now." }

        let afterSource = try fixture.requireItem(id: source.id)
        let afterTarget = try fixture.requireItem(id: target.id)
        #expect(afterSource.outgoingLinks.isEmpty)
        #expect(afterTarget.incomingLinks.isEmpty)
    }

    @Test("Reconciliation leaves deliberate links untouched")
    func deliberateLinksSurviveTextEdits() throws {
        let fixture = try StoreFixture()

        let related = try fixture.makeNote(title: "Related Note")
        let source = try fixture.makeNote(title: "Source")

        // A link made through the inspector, not written in the text.
        fixture.context.insert(ItemLink(kind: .related, source: source, target: related))
        try fixture.context.save()

        try fixture.items.update(source) { $0.body = "Some unrelated edit." }

        let refetched = try fixture.requireItem(id: source.id)
        #expect(refetched.outgoingLinks.count == 1)
        #expect(refetched.outgoingLinks.first?.kind == .related)
    }

    @Test("Repeated saves do not accumulate duplicate links")
    func reconciliationIsIdempotent() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Target")
        let source = try fixture.items.create(
            ItemDraft(kind: .note, title: "Source", body: "See [[Target]].")
        )

        for index in 1...5 {
            try fixture.items.update(source) { $0.title = "Source \(index)" }
        }

        let refetched = try fixture.requireItem(id: source.id)
        #expect(refetched.outgoingLinks.count == 1)
    }

    @Test("Alias syntax keeps the display text and still resolves the target")
    func aliasSyntaxIsPreserved() throws {
        let fixture = try StoreFixture()

        let target = try fixture.makeNote(title: "Quarterly Planning")
        let source = try fixture.items.create(
            ItemDraft(kind: .note, title: "Source", body: "See [[Quarterly Planning|the plan]].")
        )

        let refetchedSource = try fixture.requireItem(id: source.id)
        let link = try #require(refetchedSource.outgoingLinks.first)
        #expect(link.target?.id == target.id)
        #expect(link.displayText == "the plan")
        #expect(link.label == "the plan")
    }
}
