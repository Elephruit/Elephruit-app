import ElephruitCore
import ElephruitIntegrations
import Foundation
import Testing

/// The Reminders integration is the first thing in this app that writes to somebody else's data.
///
/// ### Why the guarantee had to change shape rather than hold
/// The calendar and the address book are read-only **by construction**: their protocols have no
/// write method, so writing is a compile error rather than a rule anybody could forget. That is not
/// available here. A task manager linked to Reminders that cannot tick a reminder off is not linked
/// to anything, and the whole point of the integration is the second direction.
///
/// So the claim being defended is narrower and has to be checked rather than compiled:
///
/// 1. There is exactly **one** method that writes, and it takes a value the app could have shown the
///    user first.
/// 2. Nothing else in the adapter calls a mutating EventKit API.
/// 3. A **deletion** cannot be reached except from an explicit choice the user made.
@Suite("Reminders write safety")
struct RemindersWriteSafetyTests {
    private static func sourceRoot() -> URL {
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent().appending(path: "Sources", directoryHint: .isDirectory)
    }

    private static func adapterSource() throws -> String {
        let url = sourceRoot()
            .appending(path: "ElephruitIntegrations", directoryHint: .isDirectory)
            .appending(path: "EventKitRemindersProvider.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines of code, with comments removed — so a call *named* in a doc comment does not read as a
    /// call made.
    private static func codeLines(_ source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
            }
    }

    @Test("Every EventKit write in the adapter is one of the three the design allows")
    func writesAreCounted() throws {
        let lines = Self.codeLines(try Self.adapterSource())

        let saves = lines.count { $0.contains("store.save(") }
        let removes = lines.count { $0.contains("store.remove(") }
        let commits = lines.count { $0.contains("store.commit(") }

        // One `save` — inside the private funnel every create and update goes through — and one
        // `remove`, inside the delete branch of `apply(_:)`. `commit:` is passed to both, so no
        // separate commit is needed and one appearing would mean a second, unaudited write path.
        //
        // This is a count rather than a ban because banning is not available: the app has to write.
        // If a legitimate fourth write is ever added, updating this number is the moment somebody
        // has to justify it in a commit message.
        #expect(saves == 1, "Expected exactly one store.save in the Reminders adapter, found \(saves)")
        #expect(removes == 1, "Expected exactly one store.remove in the Reminders adapter, found \(removes)")
        #expect(commits == 0, "store.commit would be a second write path")
    }

    @Test("Reading never writes")
    func readingPathsAreClean() throws {
        let source = try Self.adapterSource()

        // The reading half of the adapter, up to where writing begins. Every method that answers a
        // question — lists, reminders, reminder(withIdentifier:) — lives above this marker, and a
        // write appearing among them would mean a fetch had a side effect.
        guard let boundary = source.range(of: "// MARK: - Writing") else {
            Issue.record("The adapter's reading and writing halves must stay separated by a marker")
            return
        }

        let readingHalf = Self.codeLines(String(source[source.startIndex..<boundary.lowerBound]))
        let offenders = readingHalf.filter {
            $0.contains("store.save(") || $0.contains("store.remove(") || $0.contains("store.commit(")
        }

        #expect(offenders.isEmpty, "A read path writes to the user's store: \(offenders)")
    }

    @Test("Only an explicit deletion choice can produce a delete")
    func deletionIsAlwaysAChoice() {
        // The type system carries this: `ReminderWrite.delete` is the only destructive case, and the
        // sync engine constructs one only from a `LinkedDeletionChoice`. Asserted here so that the
        // shape of the write enum cannot quietly grow a second destructive case.
        let destructive = [
            ReminderWrite.create(ReminderSnapshot(id: "a", listID: "l")),
            .update(ReminderSnapshot(id: "a", listID: "l")),
            .delete(id: "a"),
        ].filter(\.isDestructive)

        #expect(destructive == [.delete(id: "a")])
        #expect(LinkedDeletionChoice.allCases.contains(.removeLocally))
    }

    @Test("Every write can be described before it happens")
    func writesArePreviewable() {
        // The preview is the substitute for "there is no write method". A write nobody can read out
        // loud is one nobody can consent to.
        let writes: [ReminderWrite] = [
            .create(ReminderSnapshot(id: "", listID: "l", title: "Buy milk")),
            .update(ReminderSnapshot(id: "a", listID: "l", title: "Buy oat milk")),
            .delete(id: "a"),
        ]

        #expect(writes.allSatisfy { !$0.summary.isEmpty })
        #expect(writes[0].summary.contains("Buy milk"))
    }
}

@Suite("The inert provider is what the app holds until the user says otherwise")
struct NoRemindersProviderTests {
    @Test("It reports no decision and returns nothing")
    func inertByDefault() async {
        // Typed as the protocol, because that is how the app holds it — and because the
        // protocol's `authorization` is `get async` while the concrete one is not.
        let provider: any RemindersProviding = NoRemindersProvider()

        #expect(await provider.authorization == .notRequested)
        #expect(await provider.lists().isEmpty)
        #expect(await provider.reminders(inLists: [], includingCompleted: true).isEmpty)
        #expect(await provider.reminder(withIdentifier: "anything") == nil)
    }

    @Test("A write refuses rather than pretending to succeed")
    func writesFailLoudly() async {
        // A caller that believed a write had landed would record a link to a reminder that does not
        // exist, and the next sync pass would report it missing and offer to delete a local task.
        let result = await NoRemindersProvider().apply(.delete(id: "anything"))

        guard case .failed = result else {
            Issue.record("An inert provider must refuse a write, not swallow it")
            return
        }
    }
}

@Suite("The fixture store stands in for a real one")
struct FixtureRemindersProviderTests {
    @Test("It offers every shape the mapping has to handle")
    func fixtureCoversTheHardCases() async {
        let provider = FixtureRemindersProvider()
        let lists = await provider.lists()
        let reminders = await provider.reminders(inLists: [], includingCompleted: true)

        #expect(lists.contains { $0.isReadOnly })
        #expect(lists.map(\.accountName).contains("iCloud"))
        #expect(reminders.contains { $0.dueComponents?.hour == nil })   // all-day
        #expect(reminders.contains { $0.dueComponents?.hour != nil })   // timed
        #expect(reminders.contains { !$0.alarmDates.isEmpty })
        #expect(reminders.contains { $0.hasRecurrence })
        #expect(reminders.contains { $0.isCompleted })
        #expect(reminders.contains { $0.priority > 0 })
    }

    @Test("Completed reminders are excluded unless asked for")
    func completedAreHiddenByDefault() async {
        let provider = FixtureRemindersProvider()

        let open = await provider.reminders(inLists: [], includingCompleted: false)
        let all = await provider.reminders(inLists: [], includingCompleted: true)

        #expect(open.allSatisfy { !$0.isCompleted })
        #expect(all.count > open.count)
    }

    @Test("A read-only list refuses writes the way a shared one does")
    func readOnlyListRefuses() async {
        let provider = FixtureRemindersProvider()
        let result = await provider.apply(
            .update(ReminderSnapshot(id: "rem-boiler", listID: "list-shared", title: "Changed"))
        )

        #expect(result == .readOnly)
    }

    @Test("Denied access reads as an empty store rather than an error at every call site")
    func deniedIsQuiet() async {
        let provider = FixtureRemindersProvider(authorization: .denied)

        #expect(await provider.lists().isEmpty)
        #expect(await provider.reminders(inLists: [], includingCompleted: true).isEmpty)
    }

    @Test("A save returns the reminder as stored, not as sent")
    func savesAreNormalised() async {
        let provider = FixtureRemindersProvider()
        var outgoing = ReminderSnapshot(id: "rem-milk", listID: "list-groceries", title: "Oat milk")
        // Sent with a completion date and not completed — the inconsistency a real store normalises.
        outgoing.completionDate = Date(timeIntervalSince1970: 0)

        let result = await provider.apply(.update(outgoing))

        guard case .saved(let saved) = result else {
            Issue.record("The update should have been accepted")
            return
        }
        // Recording a fingerprint of what was *sent* rather than what was *stored* makes the very
        // next sync pass see a difference and push again, for ever.
        #expect(saved.completionDate == nil)
        #expect(saved.fingerprint != outgoing.fingerprint)
    }
}
