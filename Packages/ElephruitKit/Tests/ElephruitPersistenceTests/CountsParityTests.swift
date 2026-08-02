import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Holds the sidebar counts equal to the model's own rules.
///
/// `CountsWorker` counts in SQL for speed, which reintroduces the risk the shared
/// `isUnprocessedCapture` property was created to end: clauses written twice can drift. This suite
/// is the mechanism that stops that — a fixture exercising every branch of both rules, asserted
/// against the answer computed by applying the model's own properties to every row. If a clause is
/// added to `hasHome` or `appearsInInbox` without teaching the worker, this fails.
@MainActor
@Suite("Sidebar count parity")
struct CountsParityTests {
    /// Every branch of the inbox rule, one row each.
    @Test("The inbox badge equals the model rule across every branch")
    func inboxParity() async throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider
        let context = fixture.context

        // Counted: a plain capture, an eligible unknown-ish kind, a bookmark.
        _ = try fixture.makeNote(title: "Plain capture")
        _ = try fixture.items.create(ItemDraft(kind: .bookmark, title: "A link"))

        // Not counted: homes of each sort.
        _ = try fixture.makeNote(title: "Tagged", tags: ["work"])
        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.makeTask(title: "Parented", parentID: project.id)

        let filedLive = try fixture.makeNote(title: "Filed under a live project")
        try fixture.items.fileItem(filedLive, under: project)

        // Counted again: a filing whose container is in the Trash is not a home.
        let doomedProject = try fixture.makeProject(title: "Doomed project")
        let filedTrashed = try fixture.makeNote(title: "Filed under a trashed project")
        try fixture.items.fileItem(filedTrashed, under: doomedProject)
        try fixture.items.moveToTrash(doomedProject)

        // Counted: a dangling wiki-style filing with no target at all.
        let filedDangling = try fixture.makeNote(title: "Filed nowhere")
        context.insert(ItemLink(kind: .filedUnder, source: filedDangling, target: nil, unresolvedTitle: "gone"))
        try context.save()

        // Not counted: ineligible kinds at the top level.
        _ = try fixture.makeArea(title: "Area")
        _ = try fixture.items.create(ItemDraft(kind: .person, title: "Somebody"))
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Loose heading"))

        // Not counted: trashed and archived captures.
        let trashed = try fixture.makeNote(title: "Trashed")
        try fixture.items.moveToTrash(trashed)
        let archived = try fixture.makeNote(title: "Archived")
        try fixture.items.setArchived(archived, true)

        // Not counted: kept in step with an external list — that list is its home.
        let synced = try fixture.items.create(
            ItemDraft(kind: .task, title: "Synced", source: ItemSource(kind: .systemStore, identifier: "rem"))
        )
        try fixture.items.recordSyncMetadata(on: synced) { $0.externalIdentifier = "reminder-1" }

        // Counted: synced but deliberately pulled into the Inbox.
        let inboxed = try fixture.items.create(
            ItemDraft(kind: .task, title: "Synced but inboxed", source: ItemSource(kind: .systemStore, identifier: "rem"))
        )
        try fixture.items.recordSyncMetadata(on: inboxed) {
            $0.externalIdentifier = "reminder-2"
            $0.inboxedAt = clock.now
        }

        // Counted: systemStore source whose link was severed — never filed anywhere.
        _ = try fixture.items.create(
            ItemDraft(kind: .task, title: "Unlinked import", source: ItemSource(kind: .systemStore, identifier: "rem"))
        )

        // The model's own answer, computed the slow way over every row — with the active-scope
        // clauses the badge has always applied, since `isUnprocessedCapture` itself does not
        // know about the Trash or the Archive.
        let all = try context.fetch(FetchDescriptor<Item>())
        let expected = all.count {
            $0.deletedAt == nil && $0.archivedAt == nil && $0.isUnprocessedCapture
        }

        let service = CountsService(container: fixture.stack.container, dateProvider: clock)
        await service.refreshAndWait()

        #expect(service.counts.inbox == expected)
        #expect(service.counts.inbox == (try fixture.items.items(matching: .inbox()).count),
                "the badge and the Inbox list disagree")
    }

    /// Every branch of the today rule, one row each.
    @Test("The today badge equals the rule it replaced across every branch")
    func todayParity() async throws {
        let fixture = try StoreFixture()
        let clock = fixture.dateProvider

        _ = try fixture.makeTask(title: "Overdue", dueAt: clock.startOfDay(daysFromToday: -3))
        _ = try fixture.makeTask(title: "Due today", dueAt: clock.startOfToday)
        _ = try fixture.makeTask(title: "Due tomorrow", dueAt: clock.startOfTomorrow)
        _ = try fixture.makeTask(title: "Undated")

        // Deferral hides work until it arrives — and only until then.
        let stillDeferred = try fixture.makeTask(title: "Deferred", dueAt: clock.startOfToday)
        try fixture.items.update(stillDeferred) { $0.deferUntil = clock.startOfDay(daysFromToday: 5) }
        let deferralArrived = try fixture.makeTask(title: "Deferral arrived", dueAt: clock.startOfToday)
        try fixture.items.update(deferralArrived) { $0.deferUntil = clock.now.addingTimeInterval(-3_600) }

        let done = try fixture.makeTask(title: "Done", dueAt: clock.startOfDay(daysFromToday: -1))
        try fixture.items.toggleCompletion(done)

        // A due project counts. (A due note cannot exist: validation rejects the field for the
        // kind, which is itself part of why the kind clause in the count is safe.)
        let dueProject = try fixture.makeProject(title: "Due project")
        try fixture.items.update(dueProject) { $0.dueAt = clock.startOfToday }

        let trashed = try fixture.makeTask(title: "Trashed due", dueAt: clock.startOfToday)
        try fixture.items.moveToTrash(trashed)

        // The rule the fetch-everything implementation applied, computed over every row.
        let all = try fixture.context.fetch(FetchDescriptor<Item>())
        let startOfTomorrow = clock.startOfTomorrow
        let expected = all.count { item in
            guard item.deletedAt == nil, item.archivedAt == nil else { return false }
            guard [.task, .project, .goal].contains(item.kind), item.status == .open else { return false }
            guard let dueAt = item.dueAt, dueAt < startOfTomorrow else { return false }
            guard let deferUntil = item.deferUntil else { return true }
            return deferUntil <= clock.now
        }

        let service = CountsService(container: fixture.stack.container, dateProvider: clock)
        await service.refreshAndWait()

        #expect(service.counts.today == expected)
        #expect(expected == 4, "overdue, due today, deferral arrived, due project")
    }
}
