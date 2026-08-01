import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// A store, the task services, and an **in-memory** Reminders store.
///
/// `FixtureRemindersProvider` is the only implementation reachable from here: this target does not
/// import EventKit and never constructs `EventKitRemindersProvider`. Nothing in this file can touch
/// a real Reminders database.
@MainActor
private struct SyncFixture {
    let store: StoreFixture
    let tasks: TaskService
    let reminders: FixtureRemindersProvider
    let engine: ReminderSyncEngine

    /// A clock that moves, because the sync decides whether to push by asking whether the task has
    /// been edited since the last pass — and under a frozen clock no edit ever changes `updatedAt`.
    let clock = TickingDateProvider()

    init(authorization: IntegrationAuthorization = .authorized) throws {
        store = try StoreFixture(dateProvider: clock)
        tasks = TaskService(items: store.items, context: store.context, dateProvider: store.dateProvider)
        reminders = FixtureRemindersProvider(authorization: authorization)
        engine = ReminderSyncEngine(
            items: store.items,
            tasks: tasks,
            context: store.context,
            dateProvider: store.dateProvider,
            provider: reminders
        )
    }

    func day(_ offset: Int) -> Date { store.dateProvider.startOfDay(daysFromToday: offset) }

    @discardableResult
    func task(_ title: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .task, title: title))
    }

    func snapshot(_ id: String) async throws -> ReminderSnapshot {
        guard let value = await reminders.reminder(withIdentifier: id) else {
            throw AppError.itemNotFound(id: UUID())
        }
        return value
    }

    /// Edits a task the way a person at a keyboard would: some time after the last thing that
    /// happened to it.
    func touch(_ task: Item, _ change: @escaping (Item) -> Void) throws {
        clock.advance()
        try store.items.update(task) { change($0) }
    }
}

@Suite("Bringing reminders in")
@MainActor
struct ReminderImportTests {
    @Test("An imported reminder becomes a task carrying its mapped fields and its provenance")
    func importMapsFields() async throws {
        let fixture = try SyncFixture()
        let remote = try await fixture.snapshot("rem-invoice")

        let task = try fixture.engine.importReminder(remote)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.title == "Send the invoice")
        #expect(stored.startAt != nil)
        #expect(stored.dueAt != nil)
        // EventKit priority 3 is inside its "high" band.
        #expect(stored.priority == .high)
        #expect(stored.source.kind == .systemStore)
        #expect(stored.syncState == .linked)
        #expect(stored.externalIdentifier == "rem-invoice")
    }

    @Test("An all-day reminder does not acquire a time")
    func allDayStaysAllDay() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.dueAt != nil)
        #expect(stored.reminderAt == nil)
        #expect(stored.reminderOwner == .none)
    }

    @Test("A reminder carrying an alarm hands the notification to the system")
    func systemOwnsItsOwnAlarm() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-call"))
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.reminderAt != nil)
        // The alarm already exists in Reminders. Scheduling a second one here is how somebody gets
        // told twice about the same task.
        #expect(stored.reminderOwner == .system)
    }

    @Test("Importing as local-only leaves nothing linked and never writes")
    func localOnlyImport() async throws {
        let fixture = try SyncFixture()

        let task = try fixture.engine.importAsLocalOnly(try await fixture.snapshot("rem-milk"))
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.syncState == .local)
        #expect(stored.externalIdentifier == nil)
        #expect(stored.title == "Oat milk")
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }

    @Test("Already-linked reminders are not offered again")
    func unlinkedDiscovery() async throws {
        let fixture = try SyncFixture()
        let before = await fixture.engine.unlinkedReminders(inLists: ["list-personal"])

        try fixture.engine.importReminder(try await fixture.snapshot("rem-call"))
        let after = await fixture.engine.unlinkedReminders(inLists: ["list-personal"])

        #expect(before.count == after.count + 1)
        #expect(!after.contains { $0.id == "rem-call" })
    }

    @Test("Nothing is offered and nothing fails when access has not been granted")
    func deniedAccessIsAState() async throws {
        let fixture = try SyncFixture(authorization: .denied)

        #expect(await fixture.engine.lists().isEmpty)
        #expect(await fixture.engine.unlinkedReminders(inLists: []).isEmpty)

        let report = await fixture.engine.reconcile()
        #expect(report.examined == 0)
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }
}

@Suite("Keeping a linked task in step")
@MainActor
struct ReminderReconcileTests {
    @Test("A quiet pass writes nothing at all")
    func quietPassIsSilent() async throws {
        let fixture = try SyncFixture()
        try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        let report = await fixture.engine.reconcile()

        #expect(report.examined == 1)
        #expect(!report.changedAnything)
        // The claim that matters: reading somebody's Reminders never writes to them.
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }

    @Test("A change made elsewhere is adopted, and app-only data survives it")
    func externalChangeIsAdopted() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        // App-only context the reminder knows nothing about.
        try fixture.store.items.setTags(task, slugs: ["errands"])
        try fixture.tasks.setFlagged(true, on: task)
        try fixture.tasks.commitToToday(task)
        _ = await fixture.engine.reconcile()

        await fixture.reminders.simulateExternalChange(to: "rem-milk") { $0.title = "Oat milk, the big one" }
        let report = await fixture.engine.reconcile()
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(report.adopted == 1)
        #expect(stored.title == "Oat milk, the big one")
        // None of this has anywhere to live in Reminders, and none of it is lost.
        #expect(stored.tags.map(\.slug) == ["errands"])
        #expect(stored.isFlagged)
        #expect(stored.todayCommittedOn != nil)
    }

    @Test("A local edit is pushed out")
    func localEditIsPushed() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        try fixture.touch(task) { $0.title = "Almond milk" }
        let report = await fixture.engine.reconcile()

        #expect(report.pushed == 1)
        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk")?.title == "Almond milk")
    }

    @Test("Running the pass again does nothing, however many times")
    func passIsIdempotent() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        try fixture.touch(task) { $0.title = "Almond milk" }

        let first = await fixture.engine.reconcile()
        let second = await fixture.engine.reconcile()
        let third = await fixture.engine.reconcile()

        #expect(first.pushed == 1)
        // The bug this guards is real and self-reinforcing: record a fingerprint of what was *sent*
        // rather than what came back, and every pass sees a difference, pushes again, and eventually
        // reports a conflict against itself.
        #expect(second.pushed == 0)
        #expect(third.pushed == 0)
        #expect(await fixture.reminders.appliedWrites.count == 1)
    }

    @Test("Repeated syncing never creates a duplicate task")
    func noDuplicates() async throws {
        let fixture = try SyncFixture()
        try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        for _ in 0..<5 { _ = await fixture.engine.reconcile() }

        let tasks = try fixture.store.items.items(matching: {
            var query = ItemQuery()
            query.kinds = [.task]
            return query
        }())
        #expect(tasks.count == 1)
    }

    @Test("Completing here completes there")
    func completionCrosses() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        fixture.clock.advance()
        try fixture.tasks.complete(task)
        _ = await fixture.engine.reconcile()

        let remote = try await fixture.snapshot("rem-milk")
        #expect(remote.isCompleted)
        #expect(remote.completionDate != nil)
    }

    @Test("Completing there completes here")
    func completionArrives() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        let completedOn = fixture.day(0)
        await fixture.reminders.simulateExternalChange(to: "rem-milk") { snapshot in
            snapshot.isCompleted = true
            snapshot.completionDate = completedOn
        }
        _ = await fixture.engine.reconcile()

        #expect(try fixture.store.requireItem(id: task.id).status == .completed)
    }

    @Test("A read-only list is reported rather than written to")
    func readOnlyList() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-boiler"))
        _ = await fixture.engine.reconcile()

        try fixture.touch(task) { $0.title = "Boiler service — booked" }
        let report = await fixture.engine.reconcile()

        #expect(report.readOnly == 1)
        #expect(report.pushed == 0)
        #expect(try fixture.store.requireItem(id: task.id).syncState == .externalReadOnly)
        #expect(await fixture.reminders.reminder(withIdentifier: "rem-boiler")?.title == "Boiler service")
    }
}

@Suite("When the two sides disagree")
@MainActor
struct ReminderConflictTests {
    /// Both sides changed since the last pass.
    private func conflicted() async throws -> (SyncFixture, Item) {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        try fixture.touch(task) { $0.title = "Almond milk" }
        await fixture.reminders.simulateExternalChange(to: "rem-milk") { $0.title = "Soya milk" }

        let report = await fixture.engine.reconcile()
        #expect(report.conflicted == 1)
        return (fixture, task)
    }

    @Test("A conflict is surfaced and nothing is overwritten")
    func conflictIsSurfaced() async throws {
        let (fixture, task) = try await conflicted()

        #expect(try fixture.store.requireItem(id: task.id).syncState == .conflicted)
        #expect(try fixture.store.requireItem(id: task.id).title == "Almond milk")
        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk")?.title == "Soya milk")
        // Nothing was written while the user had not decided.
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }

    @Test("Keeping the local version writes it out and clears the conflict")
    func keepLocal() async throws {
        let (fixture, task) = try await conflicted()

        _ = await fixture.engine.resolve(task, as: .keepLocal)

        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk")?.title == "Almond milk")
        #expect(try fixture.store.requireItem(id: task.id).syncState == .linked)
        #expect(await fixture.engine.reconcile().changedAnything == false)
    }

    @Test("Keeping the remote version takes the shared fields and leaves the private ones")
    func keepRemote() async throws {
        let (fixture, task) = try await conflicted()
        try fixture.store.items.setTags(task, slugs: ["errands"])

        _ = await fixture.engine.resolve(task, as: .keepRemote)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.title == "Soya milk")
        #expect(stored.tags.map(\.slug) == ["errands"])
        #expect(stored.syncState == .linked)
    }

    @Test("Keeping both leaves the reminder alone and preserves the local edit as its own task")
    func keepBoth() async throws {
        let (fixture, task) = try await conflicted()

        _ = await fixture.engine.resolve(task, as: .keepBoth)

        // The linked task follows the reminder…
        #expect(try fixture.store.requireItem(id: task.id).title == "Soya milk")
        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk")?.title == "Soya milk")

        // …and the local version survives beside it, linked so neither is orphaned.
        var query = ItemQuery()
        query.kinds = [.task]
        let all = try fixture.store.items.items(matching: query)
        #expect(all.count == 2)

        let copy = try #require(all.first { $0.id != task.id })
        #expect(copy.title == "Almond milk")
        #expect(copy.syncState == .local)
        #expect(copy.outgoingLinks.contains { $0.kind == .conflictCopy })
    }
}

@Suite("When a reminder or its permission goes away")
@MainActor
struct ReminderLossTests {
    @Test("A reminder deleted elsewhere is reported, and nothing local is destroyed")
    func externalDeletionKeepsEverything() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        try fixture.store.items.update(task) { $0.body = "Ask about the oat one" }
        _ = await fixture.engine.reconcile()

        await fixture.reminders.simulateExternalDeletion(of: "rem-milk")
        let report = await fixture.engine.reconcile()
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(report.missing == 1)
        #expect(stored.syncState == .externalMissing)
        #expect(stored.deletedAt == nil)
        #expect(stored.body == "Ask about the oat one")
    }

    @Test("Keeping it as a local task drops the link and nothing else")
    func keepAsLocal() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-call"))
        await fixture.reminders.simulateExternalDeletion(of: "rem-call")
        _ = await fixture.engine.reconcile()

        try fixture.engine.resolveMissing(task, as: .keepAsLocal)
        let stored = try fixture.store.requireItem(id: task.id)

        #expect(stored.syncState == .local)
        #expect(stored.externalIdentifier == nil)
        #expect(stored.title == "Call the dentist")
        // The alarm was the system's; with the link gone this app has to own it or nothing will
        // deliver it.
        #expect(stored.reminderOwner == .app)
    }

    @Test("Deleting a linked task here does not delete the reminder unless asked")
    func deletionIsAlwaysAChoice() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        _ = await fixture.engine.delete(task, choice: .removeLocally)

        #expect(try fixture.store.requireItem(id: task.id).deletedAt != nil)
        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk") != nil)
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }

    @Test("Choosing to delete both does exactly that, and only then")
    func deleteBoth() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))

        _ = await fixture.engine.delete(task, choice: .deleteBoth)

        #expect(await fixture.reminders.reminder(withIdentifier: "rem-milk") == nil)
        let writes = await fixture.reminders.appliedWrites
        #expect(writes == [.delete(id: "rem-milk")])
    }

    @Test("A whole list disappearing is the same problem, handled the same way")
    func listRemoval() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        await fixture.reminders.simulateListRemoval(of: "list-groceries")
        let report = await fixture.engine.reconcile()

        #expect(report.missing == 1)
        #expect(try fixture.store.requireItem(id: task.id).deletedAt == nil)
    }

    @Test("Permission revoked after linking leaves the library intact and quiet")
    func revocation() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.engine.importReminder(try await fixture.snapshot("rem-milk"))
        _ = await fixture.engine.reconcile()

        await fixture.reminders.setAuthorization(.denied)
        let report = await fixture.engine.reconcile()

        // No pass, no writes, no damage — and the task is still a perfectly good task.
        #expect(report.examined == 0)
        #expect(!report.changedAnything)
        #expect(try fixture.store.requireItem(id: task.id).title == "Oat milk")
        #expect(await fixture.reminders.appliedWrites.isEmpty)
    }
}

@Suite("Sending a local task out")
@MainActor
struct ReminderExportTests {
    @Test("Exporting creates a reminder and links the two")
    func export() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.task("Book the van")
        try fixture.tasks.setDeadline(fixture.day(4), on: task)

        let result = await fixture.engine.export(task, toList: "list-personal")

        guard case .saved(let saved) = result else {
            Issue.record("The export should have been accepted")
            return
        }
        #expect(saved.title == "Book the van")
        #expect(saved.dueComponents?.hour == nil)
        #expect(try fixture.store.requireItem(id: task.id).externalIdentifier == saved.id)
        #expect(try fixture.store.requireItem(id: task.id).syncState == .linked)
    }

    @Test("Exporting to a read-only list is refused rather than half-done")
    func exportToReadOnlyList() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.task("Boiler service")

        let result = await fixture.engine.export(task, toList: "list-shared")

        #expect(result == .readOnly)
        #expect(try fixture.store.requireItem(id: task.id).externalIdentifier == nil)
    }

    @Test("Nothing private is written into the reminder")
    func privateFieldsStayHere() async throws {
        let fixture = try SyncFixture()
        let maya = try fixture.store.items.create(ItemDraft(kind: .person, title: "Maya"))
        let area = try fixture.store.makeArea(title: "Work")
        let project = try fixture.store.makeProject(title: "Acme launch", parentID: area.id)
        let task = try fixture.store.items.create(
            ItemDraft(kind: .task, title: "Chase the budget", tagSlugs: ["clients"], parentID: project.id)
        )
        try fixture.tasks.markWaiting(task, on: maya)
        try fixture.tasks.commitToToday(task)

        _ = await fixture.engine.export(task, toList: "list-work")
        let identifier = try #require(fixture.store.requireItem(id: task.id).externalIdentifier)
        let remote = try await fixture.snapshot(identifier)

        // The whole of the app-only list, checked against the text that would actually appear in
        // Apple's own app on every device the user owns — and to everybody a list is shared with.
        let visible = [remote.title, remote.notes ?? ""].joined(separator: " ")
        for secret in ["Maya", "Acme launch", "Work", "clients", "waiting", "today"] {
            #expect(!visible.lowercased().contains(secret.lowercased()), "“\(secret)” leaked into the reminder")
        }
    }

    @Test("A repeat this app cannot represent is kept local rather than written out wrong")
    func unrepresentableRecurrenceStaysHere() async throws {
        let fixture = try SyncFixture()
        let task = try fixture.task("Water the plants")
        try fixture.store.items.update(task) {
            $0.recurrence = RecurrenceRule(frequency: .daily, interval: 3, anchor: .completion)
        }

        _ = await fixture.engine.export(task, toList: "list-personal")
        let identifier = try #require(try fixture.store.requireItem(id: task.id).externalIdentifier)
        let remote = try await fixture.snapshot(identifier)

        // EventKit rules are always schedule-anchored, so writing this one out would produce a
        // different task that quietly drifts from what the user asked for.
        #expect(!remote.hasRecurrence)
        #expect(try fixture.store.requireItem(id: task.id).recurrence?.anchor == .completion)
    }
}

// MARK: - Which adapter the engine is driving

/// The engine must ask for its adapter, not remember one.
///
/// `RemindersService` swaps an inert `NoRemindersProvider` for the real one when the user links the
/// integration, and that happens *after* `AppServices` has built the engine. An engine that captured
/// the adapter by value spent the rest of that session driving the inert one: `reconcile()` found it
/// could not read, returned an empty report, and reported no error — so linking Reminders filled in
/// the list picker and imported nothing, with nothing on screen to say why.
@Suite("The adapter the engine drives")
@MainActor
struct ReminderProviderResolutionTests {
    /// Stands in for `RemindersService`: something whose adapter changes underneath the engine.
    @MainActor
    private final class SwappableProvider {
        var current: any RemindersProviding = NoRemindersProvider()
    }

    @Test("An adapter linked after the engine was built is the one the engine uses")
    func adapterSwappedAfterConstructionIsUsed() async throws {
        let store = try StoreFixture(dateProvider: TickingDateProvider())
        let tasks = TaskService(items: store.items, context: store.context, dateProvider: store.dateProvider)
        let box = SwappableProvider()

        let engine = ReminderSyncEngine(
            items: store.items,
            tasks: tasks,
            context: store.context,
            dateProvider: store.dateProvider,
            provider: { box.current }
        )

        // Nothing is linked yet, exactly as at launch. The pass must be a no-op.
        let beforeLinking = await engine.reconcile()
        #expect(beforeLinking.imported == 0)
        #expect(beforeLinking.examined == 0)

        // The user links Reminders. This is the swap that used to be invisible to the engine.
        box.current = FixtureRemindersProvider(authorization: .authorized)

        let remote = try #require(await box.current.reminder(withIdentifier: "rem-invoice"))
        let task = try engine.importReminder(remote)

        // The import reached the store through the *new* adapter, which is the whole point.
        #expect(try store.requireItem(id: task.id).title == "Send the invoice")

        // And a pass now sees the linked task rather than bailing at the authorisation guard.
        let afterLinking = await engine.reconcile()
        #expect(afterLinking.examined >= 1)
    }

    @Test("An engine given a fixed adapter still uses it, so the fixtures are unaffected")
    func fixedAdapterStillWorks() async throws {
        let fixture = try SyncFixture()
        let remote = try await fixture.snapshot("rem-invoice")
        let task = try fixture.engine.importReminder(remote)

        #expect(try fixture.store.requireItem(id: task.id).title == "Send the invoice")
    }
}
