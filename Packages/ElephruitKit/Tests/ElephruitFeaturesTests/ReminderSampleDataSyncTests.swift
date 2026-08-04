import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// What a reviewer actually gets when they launch with `-ElephruitUseFixtureReminders`.
///
/// The whole point of that flag is that somebody can link Reminders, watch an import, and see each
/// of the four link states the app can be in — without pointing it at their own account. So the
/// states the sample data *claims* to set up are worth asserting, because when they are wrong the
/// failure looks exactly like a broken sync: everything reports a conflict and nothing settles.
@MainActor
@Suite("Sample data against the synthetic Reminders store")
struct ReminderSampleDataSyncTests {
    /// Services with the integration actually linked.
    ///
    /// Without `enable()` the service is still holding its inert adapter, so the engine reads
    /// nothing and a pass is a no-op — which would make every assertion below pass for the wrong
    /// reason.
    private func services() async -> AppServices {
        let suiteName = "reminder-sample-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let services = AppServices.inMemory(
            remindersProvider: { FixtureRemindersProvider(authorization: .authorized) },
            defaults: defaults
        )
        await services.reminders.enable()
        return services
    }

    /// Every link the sample data plants points at a reminder the fixture store actually has —
    /// except the one that is deliberately missing.
    @Test("The planted links point at the synthetic store, so a pass can reconcile them")
    func plantedLinksMatchTheFixture() async throws {
        let services = await self.services()
        let provider = FixtureRemindersProvider(authorization: .authorized)

        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.scope = .all
        let linked = try services.items.items(matching: query).filter { $0.externalIdentifier != nil }

        #expect(!linked.isEmpty, "sample data should plant some linked tasks")

        for task in linked {
            let identifier = try #require(task.externalIdentifier)
            let remote = await provider.reminder(withIdentifier: identifier)

            // `rem-gone` is the deliberately absent one; everything else must exist.
            if identifier == "rem-gone" {
                #expect(remote == nil)
            } else {
                #expect(remote != nil, "\(identifier) is planted but not in the fixture store")
            }
        }
    }

    /// The one that matters: a pass over the sample library must produce the states the sample data
    /// says it is demonstrating, not a uniform pile of conflicts.
    @Test("A pass leaves each planted link in the state it was meant to demonstrate")
    func passProducesTheIntendedStates() async throws {
        let services = await self.services()
        let lists = await services.reminderSync.lists().map(\.id)

        let report = await services.reminderSync.reconcile(importingFrom: lists)

        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.scope = .all
        let all = try services.items.items(matching: query)

        // By external identifier, not by title: the sample library also contains an ordinary,
        // unlinked "Oat milk" task, and matching on the title finds whichever comes first.
        func state(linkedTo identifier: String) throws -> TaskSyncState? {
            try #require(all.first { $0.externalIdentifier == identifier }).syncState
        }

        let milk = try state(linkedTo: "rem-milk")
        let books = try state(linkedTo: "rem-gone")
        let boiler = try state(linkedTo: "rem-boiler")
        let dentist = try state(linkedTo: "rem-call")
        let summary = report.summary

        // Planted as `.linked` against a reminder that exists and has not changed. A pass must leave
        // it alone: this is the row that demonstrates "in step".
        #expect(milk == .linked, "Oat milk: \(String(describing: milk)) — \(summary)")

        // Planted against a reminder that is not in the store at all.
        #expect(books == .externalMissing, "books: \(String(describing: books))")

        // Planted on the read-only shared list.
        #expect(boiler == .externalReadOnly, "boiler: \(String(describing: boiler))")

        // Exactly one row is meant to need a decision — the one planted as `.conflicted`.
        #expect(dentist == .conflicted, "dentist: \(String(describing: dentist))")
        #expect(report.conflicted == 1, "report: \(summary)")
    }

    /// And having reconciled once, a second pass must be quiet.
    @Test("A second pass over the sample library changes nothing")
    func secondPassIsQuiet() async throws {
        let services = await self.services()
        let lists = await services.reminderSync.lists().map(\.id)

        _ = await services.reminderSync.reconcile(importingFrom: lists)
        let second = await services.reminderSync.reconcile(importingFrom: lists)

        // "Quiet" means no writes and no new work — not an empty report. A conflicted row stays
        // conflicted until the user decides, and a reminder that has gone stays gone, so both are
        // counted again on every pass. Those are standing facts about the library, not activity.
        #expect(second.imported == 0)
        #expect(second.pushed == 0)
        #expect(second.adopted == 0, "a second pass re-adopted something it had already taken")
        #expect(second.failures.isEmpty)
    }
}
