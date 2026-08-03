import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// What the Inbox holds once reminders can be brought in.
///
/// ### The bug these exist for
/// Nothing ever *routed* an imported reminder into the Inbox. The Inbox is a query — active,
/// unparented, untagged, unfiled, and of a kind that can be triaged — and
/// `ReminderSyncEngine.importReminder(_:into:)` creates a task with no parent, no tags and no
/// filing, because there is nothing honest to file it under: the user already filed it, in
/// Reminders. So every imported reminder matched the Inbox by construction, and connecting an
/// account meant opening the Inbox to a list of triage somebody had already done in another app.
///
/// The fix is a fourth clause in ``ElephruitModel/Item/hasHome`` rather than a filter over the
/// result: a list in Apple Reminders is a home. These tests hold that rule at the two places it has
/// to be true — the list, and the badge over it — and hold the boundaries around it, because a rule
/// that quietly swallowed *genuine* Inbox work would be a worse bug than the one it replaced.
@MainActor
private struct InboxFixture {
    let store: StoreFixture
    let tasks: ReminderLifecycleService
    let reminders: FixtureRemindersProvider
    let engine: ReminderSyncEngine

    let clock = TickingDateProvider()

    init() throws {
        store = try StoreFixture(dateProvider: clock)
        tasks = ReminderLifecycleService(items: store.items, context: store.context, dateProvider: store.dateProvider)
        reminders = FixtureRemindersProvider(authorization: .authorized)
        engine = ReminderSyncEngine(
            items: store.items,
            lifecycle: tasks,
            context: store.context,
            dateProvider: store.dateProvider,
            provider: reminders
        )
    }

    /// Everything the Inbox destination would draw.
    func inbox() throws -> [Item] {
        try store.items.items(matching: .inbox())
    }

    func inboxTitles() throws -> Set<String> {
        Set(try inbox().map(\.displayTitle))
    }

    func snapshot(_ id: String) async throws -> ReminderSnapshot {
        guard let value = await reminders.reminder(withIdentifier: id) else {
            throw AppError.itemNotFound(id: UUID())
        }
        return value
    }
}

@Suite("The Inbox, once reminders can arrive")
@MainActor
struct InboxAndImportedRemindersTests {
    // MARK: - The first import

    @Test("A first import puts nothing in the Inbox")
    func firstImportDoesNotFloodTheInbox() async throws {
        let fixture = try InboxFixture()

        let report = await fixture.engine.reconcile(
            importingFrom: ["list-personal", "list-groceries", "list-work"]
        )

        // They arrived — this is not a test that import stopped working.
        #expect(report.imported > 0)
        #expect(try fixture.store.items.items(matching: .kind(.task)).count == report.imported)

        // And none of them is an unprocessed capture, because each one is filed in the list it came
        // from. That is the whole change.
        #expect(try fixture.inbox().isEmpty)
    }

    @Test("An imported reminder says where it lives, so it is findable rather than merely absent")
    func importedRemindersKeepTheirProvenance() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-invoice"))

        #expect(task.isKeptInStepWithAnExternalList)
        #expect(task.externalListIdentifier == "list-work")
        // The identifier survives everything that can happen to the task afterwards — it is what
        // stops a second pass importing the same reminder twice.
        #expect(task.sourceIdentifier == "rem-invoice")

        // Reachable through the smart list that exists precisely because they left the Inbox.
        let fromReminders = BuiltInSmartList.list(id: "from-reminders")
        #expect(fromReminders != nil)
        #expect(
            fromReminders?.filter.matches(
                task.taskFacts(),
                now: fixture.clock.now,
                calendar: fixture.clock.calendar
            ) == true
        )
    }

    // MARK: - What the Inbox must keep

    @Test("Work captured here still lands in the Inbox")
    func genuineCapturesSurvive() async throws {
        let fixture = try InboxFixture()
        _ = await fixture.engine.reconcile(importingFrom: ["list-personal", "list-work"])

        let captured = try fixture.store.items.create(
            ItemDraft(kind: .note, title: "Idea from the walk", source: ItemSource(kind: .quickCapture))
        )
        let typed = try fixture.store.items.create(ItemDraft(kind: .task, title: "Ring the plumber"))

        #expect(try fixture.inboxTitles() == ["Idea from the walk", "Ring the plumber"])
        #expect(captured.isUnprocessedCapture)
        #expect(typed.isUnprocessedCapture)
    }

    @Test("A task made here and then exported to a list is not swept out of the Inbox")
    func exportingDoesNotCountAsFiling() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.store.items.create(ItemDraft(kind: .task, title: "Book the van"))
        #expect(task.isUnprocessedCapture)

        _ = await fixture.engine.export(task, toList: "list-personal")

        // It now has a link, but it was captured *here* and has not been processed by being copied
        // somewhere. Only `.systemStore` provenance plus a live link means "its home is that list".
        #expect(task.externalIdentifier != nil)
        #expect(!task.isKeptInStepWithAnExternalList)
        #expect(try fixture.inboxTitles() == ["Book the van"])
    }

    @Test("Breaking the link hands the task back to the Inbox")
    func unlinkingReturnsATaskToTheInbox() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-call"))
        #expect(try fixture.inbox().isEmpty)

        // Importing as local-only is the explicit "I want this here, not kept in step" action. The
        // list is no longer its home, so it is an unfiled local task — which is the Inbox.
        try fixture.engine.unlink(task)

        #expect(try fixture.inboxTitles() == ["Call the dentist"])
    }

    // MARK: - Sending one back deliberately

    @Test("A synchronised task can be put in the Inbox without breaking its link")
    func inboxingIsExplicitAndCostsNothing() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        #expect(try fixture.inbox().isEmpty)

        try fixture.tasks.setInInbox(true, on: task)

        #expect(try fixture.inboxTitles() == ["Oat milk"])
        // The point of the column: it keeps syncing while it sits there. A reminder that stopped
        // updating on somebody's phone because they wanted to think about it would be a bad trade.
        #expect(task.externalIdentifier == "rem-milk")
        #expect(task.syncState == .linked)

        try fixture.tasks.setInInbox(false, on: task)
        #expect(try fixture.inbox().isEmpty)
    }

    @Test("Filing an inboxed task somewhere real takes it out, whatever was marked last week")
    func realFilingWinsOverTheMark() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        try fixture.tasks.setInInbox(true, on: task)
        #expect(task.isUnprocessedCapture)

        let project = try fixture.store.items.create(ItemDraft(kind: .project, title: "Kitchen"))
        try fixture.store.items.setParent(task, to: project)

        #expect(!task.isUnprocessedCapture)
        #expect(try fixture.inbox().isEmpty)
    }

    @Test("The mark does nothing to a task that never came from a list")
    func inboxingIsRefusedForLocalTasks() throws {
        let fixture = try InboxFixture()
        let project = try fixture.store.items.create(ItemDraft(kind: .project, title: "Move house"))
        let task = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Change the address", parentID: project.id)
        )

        try fixture.tasks.setInInbox(true, on: task)

        // A filed local task is not an unprocessed capture, and marking one would be a way of
        // putting something in the Inbox that has demonstrably been processed.
        #expect(task.inboxedAt == nil)
        #expect(try fixture.inbox().isEmpty)
    }

    // MARK: - The badge

    @Test("The badge counts exactly what the list holds")
    func theBadgeAgreesWithTheList() async throws {
        let fixture = try InboxFixture()
        _ = await fixture.engine.reconcile(importingFrom: ["list-personal", "list-work"])
        _ = try fixture.store.items.create(ItemDraft(kind: .note, title: "Unfiled thought"))

        let counts = CountsService(container: fixture.store.stack.container, dateProvider: fixture.clock)
        await counts.refreshAndWait()

        // Both sides now ask `Item.isUnprocessedCapture`. They used to be two copies of the same
        // three clauses kept in step by a comment, and a badge reading 3 over a list of 2 reads as a
        // bug in the app rather than in the query.
        #expect(counts.counts.inbox == (try fixture.inbox().count))
        #expect(counts.counts.inbox == 1)
    }

    // MARK: - Syncing again

    @Test("A second pass imports nothing and changes nothing")
    func resyncIsIdempotent() async throws {
        let fixture = try InboxFixture()
        let lists = ["list-personal", "list-groceries", "list-work"]

        let first = await fixture.engine.reconcile(importingFrom: lists)
        let afterFirst = try fixture.store.items.items(matching: .kind(.task)).count

        let second = await fixture.engine.reconcile(importingFrom: lists)

        #expect(second.imported == 0)
        #expect(second.failures.isEmpty)
        #expect(try fixture.store.items.items(matching: .kind(.task)).count == afterFirst)
        #expect(afterFirst == first.imported)
        #expect(try fixture.inbox().isEmpty)
    }

    @Test("A reminder whose link the user broke is not brought in a second time")
    func unlinkedRemindersAreNotReimported() async throws {
        let fixture = try InboxFixture()

        // The explicit "bring it in but do not keep it in step" action. It leaves a task with no
        // `externalIdentifier` at all, which is what used to make the reminder look brand new.
        let task = try fixture.engine.importAsLocalOnly(try await fixture.snapshot("rem-call"))
        #expect(task.externalIdentifier == nil)

        let report = await fixture.engine.reconcile(importingFrom: ["list-personal"])

        #expect(!report.failures.contains { $0.contains("list-personal") })
        let calls = try fixture.store.items
            .items(matching: .kind(.task))
            .filter { $0.displayTitle == "Call the dentist" }
        #expect(calls.count == 1)
    }

    @Test("A reminder deleted here is not brought back by the next pass")
    func trashedImportsAreNotReimported() async throws {
        let fixture = try InboxFixture()
        _ = await fixture.engine.reconcile(importingFrom: ["list-personal"])

        let bins = try #require(
            try fixture.store.items
                .items(matching: .kind(.task))
                .first { $0.displayTitle == "Put the bins out" }
        )
        try fixture.store.items.moveToTrash(bins)

        _ = await fixture.engine.reconcile(importingFrom: ["list-personal"])

        // Restoring it from the Trash must not produce two. A reminder the user threw away here is
        // one they have decided about, and re-importing it would be the app arguing.
        var everything = ItemQuery()
        everything.kinds = [.task]
        everything.scope = .all
        let copies = try fixture.store.items
            .items(matching: everything)
            .filter { $0.displayTitle == "Put the bins out" }
        #expect(copies.count == 1)
    }

    // MARK: - Completed reminders

    @Test("A reminder already ticked off elsewhere is not imported at all")
    func completedRemindersAreNotImported() async throws {
        let fixture = try InboxFixture()

        _ = await fixture.engine.reconcile(importingFrom: ["list-personal"])

        // `rem-post` is completed in the fixture. Bringing it in would put a finished chore in a
        // task manager that never had it, and — before the Inbox rule changed — in the Inbox.
        let posted = try fixture.store.items
            .items(matching: .kind(.task))
            .filter { $0.displayTitle == "Post the parcel" }
        #expect(posted.isEmpty)
        #expect(try fixture.inbox().isEmpty)
    }

    @Test("Completing a reminder elsewhere does not push the task into the Inbox")
    func completingElsewhereKeepsItOutOfTheInbox() async throws {
        let fixture = try InboxFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        fixture.clock.advance()
        await fixture.reminders.simulateExternalChange(to: "rem-milk") { $0.isCompleted = true }
        _ = await fixture.engine.reconcile()

        #expect(task.status == .completed)
        #expect(try fixture.inbox().isEmpty)
    }
}
