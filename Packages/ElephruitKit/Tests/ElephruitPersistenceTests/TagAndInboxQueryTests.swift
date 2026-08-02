import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The tag clause moved into the store as a one-slug subquery, and the Inbox list took the same
/// store-side shape its badge already uses. These tests hold both to the post-filter semantics
/// they replaced.
@MainActor
@Suite("Tag and Inbox queries answer from the store")
struct TagAndInboxQueryTests {
    @Test("A tag page shows exactly the items carrying the tag")
    func singleTag() throws {
        let fixture = try StoreFixture()
        _ = try fixture.makeNote(title: "Tagged work", tags: ["work"])
        _ = try fixture.makeNote(title: "Tagged home", tags: ["home"])
        _ = try fixture.makeNote(title: "Untagged")

        let archivedTagged = try fixture.makeNote(title: "Archived tagged", tags: ["work"])
        try fixture.items.setArchived(archivedTagged, true)
        let trashedTagged = try fixture.makeNote(title: "Trashed tagged", tags: ["work"])
        try fixture.items.moveToTrash(trashedTagged)

        let rows = try fixture.items.items(matching: .tag(slug: "work"))
        #expect(rows.map(\.title) == ["Tagged work"])
    }

    @Test("A multi-tag query still requires every slug, not merely the narrowed one")
    func multiTagStaysConjunctive() throws {
        let fixture = try StoreFixture()
        _ = try fixture.makeNote(title: "Both", tags: ["work", "urgent"])
        _ = try fixture.makeNote(title: "Only work", tags: ["work"])
        _ = try fixture.makeNote(title: "Only urgent", tags: ["urgent"])

        var query = ItemQuery()
        query.tagSlugs = ["work", "urgent"]
        #expect(try fixture.items.items(matching: query).map(\.title) == ["Both"])
    }

    @Test("A tag query combined with a kind filter narrows by both")
    func tagWithKind() throws {
        let fixture = try StoreFixture()
        _ = try fixture.makeNote(title: "Tagged note", tags: ["work"])
        let task = try fixture.makeTask(title: "Tagged task")
        try fixture.items.setTags(task, slugs: ["work"])

        var query = ItemQuery.tag(slug: "work")
        query.kinds = [.task]
        #expect(try fixture.items.items(matching: query).map(\.title) == ["Tagged task"])
    }

    @Test("The Inbox list still answers the model rule, including its corners")
    func inboxListSemantics() throws {
        let fixture = try StoreFixture()

        _ = try fixture.makeNote(title: "Plain capture")
        _ = try fixture.makeNote(title: "Tagged", tags: ["work"])

        let project = try fixture.makeProject(title: "Project")
        let filedLive = try fixture.makeNote(title: "Filed live")
        try fixture.items.fileItem(filedLive, under: project)

        // A filing whose container is in the Trash is not a home, so this one is still unprocessed.
        let doomed = try fixture.makeProject(title: "Doomed")
        let filedTrashed = try fixture.makeNote(title: "Filed under trashed")
        try fixture.items.fileItem(filedTrashed, under: doomed)
        try fixture.items.moveToTrash(doomed)

        // Kept in step with an external list — that list is its home, and only Swift can see it.
        let synced = try fixture.items.create(
            ItemDraft(kind: .task, title: "Synced", source: ItemSource(kind: .systemStore, identifier: "rem"))
        )
        try fixture.items.recordSyncMetadata(on: synced) { $0.externalIdentifier = "reminder-1" }

        let titles = Set(try fixture.items.items(matching: .inbox()).map(\.title))
        #expect(titles == ["Plain capture", "Filed under trashed"])
    }
}
