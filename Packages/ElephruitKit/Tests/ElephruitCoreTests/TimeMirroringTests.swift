import ElephruitCore
import Foundation
import Testing

/// What may and may not be written into a calendar on the user's behalf.
///
/// The safety half of this suite matters more than the behaviour half. A calendar event syncs to
/// every device on the account and is visible to anybody a calendar is shared with, so a leak here
/// is not a bug somebody notices in their own window — it is one their colleagues see first.
@Suite("Time mirroring")
struct TimeMirroringTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var policy: TimeMirrorPolicy {
        TimeMirrorPolicy(isEnabled: true, calendarIdentifier: "work")
    }

    private func entry(
        minutes: Double = 60,
        description: String = "",
        subject: String? = nil,
        tags: [String] = [],
        people: [TimeParticipant] = [],
        billable: Bool = false,
        running: Bool = false
    ) -> TimeEntrySnapshot {
        let start = now.addingTimeInterval(-minutes * 60)
        return TimeEntrySnapshot(
            id: UUID(),
            startedAt: start,
            endedAt: running ? nil : now,
            entryDescription: description,
            isBillable: billable,
            itemTitle: subject,
            tagSlugs: tags,
            people: people
        )
    }

    private func action(
        _ entry: TimeEntrySnapshot,
        existing: String? = nil,
        deleted: Bool = false,
        policy: TimeMirrorPolicy? = nil
    ) -> TimeMirrorAction {
        TimeMirroring.action(
            for: entry,
            existingIdentifier: existing,
            isDeleted: deleted,
            policy: policy ?? self.policy,
            now: now
        )
    }

    // MARK: - Nothing private crosses

    @Test("Who you were with is never written, whatever the settings say")
    func peopleNeverCross() throws {
        let entry = entry(
            description: "One-to-one",
            subject: "Catch-up",
            tags: ["management"],
            people: [TimeParticipant(id: UUID(), name: "Sarah Okonkwo")]
        )

        var everythingOn = policy
        everythingOn.includesTags = true
        everythingOn.includesSubject = true

        guard case .create(let fields) = action(entry, policy: everythingOn) else {
            Issue.record("Expected a create")
            return
        }

        // An hour with somebody is a fact about them as much as about you, and an event publishes it
        // to an audience they never agreed to.
        #expect(!fields.title.contains("Sarah"))
        #expect(!fields.notes.contains("Sarah"))
        #expect(!fields.title.contains("Okonkwo"))
        #expect(!fields.notes.contains("Okonkwo"))
    }

    @Test("Billability is never written")
    func billabilityNeverCrosses() throws {
        let entry = entry(description: "Client work", billable: true)

        guard case .create(let fields) = action(entry) else {
            Issue.record("Expected a create")
            return
        }

        #expect(!fields.title.lowercased().contains("billable"))
        #expect(!fields.notes.lowercased().contains("billable"))
    }

    @Test("Tags cross only when asked for")
    func tagsAreOptional() throws {
        var withTags = policy
        withTags.includesTags = true

        guard case .create(let on) = action(entry(tags: ["writing"]), policy: withTags),
              case .create(let off) = action(entry(tags: ["writing"]))
        else {
            Issue.record("Expected creates")
            return
        }

        #expect(on.notes.contains("#writing"))
        #expect(!off.notes.contains("writing"))
        #expect(off.notes == TimeMirroring.marker)
    }

    // MARK: - When nothing is written

    @Test("A mirror that is off writes nothing and tidies nothing")
    func disabledDoesNothing() {
        // Deliberately not `.remove`: turning the mirror off must not delete a month of events
        // somebody may be relying on. That is a decision with its own button.
        #expect(action(entry(), existing: "evt", policy: .disabled) == .none)
    }

    @Test("A mirror with no calendar chosen writes nothing")
    func noDestinationDoesNothing() {
        let pointless = TimeMirrorPolicy(isEnabled: true, calendarIdentifier: nil)
        #expect(action(entry(), policy: pointless) == .none)
    }

    @Test("A running timer is never written")
    func runningEntriesAreNotWritten() {
        #expect(action(entry(running: true)) == .none)
    }

    @Test("A stretch under the minimum is not written, and loses its event if it had one")
    func shortEntriesAreRemoved() {
        // Editing an entry down to two minutes has to take the event with it, or the calendar keeps
        // an hour that no longer exists.
        #expect(action(entry(minutes: 2)) == .none)
        #expect(action(entry(minutes: 2), existing: "evt") == .remove(identifier: "evt"))
    }

    @Test("A deleted entry takes its event with it")
    func deletionRemovesTheEvent() {
        #expect(action(entry(), existing: "evt", deleted: true) == .remove(identifier: "evt"))
        #expect(action(entry(), deleted: true) == .none)
    }

    @Test("Time in the future is not written")
    func futureEntriesAreNotWritten() {
        // A start date typed wrong by a year would otherwise put a phantom afternoon in next
        // spring's calendar.
        let ahead = TimeEntrySnapshot(
            id: UUID(),
            startedAt: now.addingTimeInterval(86_400),
            endedAt: now.addingTimeInterval(90_000)
        )
        #expect(action(ahead) == .none)
    }

    // MARK: - What it is called

    @Test("The subject leads and the description follows it")
    func titleOrder() {
        #expect(TimeMirroring.title(
            for: entry(description: "second pass", subject: "Draft the brief"),
            policy: policy
        ) == "Draft the brief — second pass")
    }

    @Test("A repeated title is not written twice")
    func titleDoesNotRepeatItself() {
        #expect(TimeMirroring.title(
            for: entry(description: "Draft the brief", subject: "Draft the brief"),
            policy: policy
        ) == "Draft the brief")
    }

    @Test("An entry with nothing to call it is not called Untitled")
    func namelessEntriesGetAName() {
        // A calendar full of "Untitled" is a calendar that gets deleted.
        #expect(TimeMirroring.title(for: entry(), policy: policy) == "Tracked time")
    }

    @Test("The subject can be left out without losing the description")
    func subjectIsOptional() {
        var noSubject = policy
        noSubject.includesSubject = false

        #expect(TimeMirroring.title(
            for: entry(description: "second pass", subject: "Draft the brief"),
            policy: noSubject
        ) == "second pass")
    }

    // MARK: - Keeping in step

    @Test("An entry already mirrored is updated rather than duplicated")
    func existingEventsAreUpdated() {
        guard case .update(let identifier, _) = action(entry(description: "Work"), existing: "evt") else {
            Issue.record("Expected an update")
            return
        }
        #expect(identifier == "evt")
    }

    @Test("Every mirrored event says where it came from")
    func eventsCarryTheMarker() throws {
        guard case .create(let fields) = action(entry(description: "Work")) else {
            Issue.record("Expected a create")
            return
        }
        // So that somebody reading their calendar can tell where two hundred events came from.
        #expect(fields.notes.contains(TimeMirroring.marker))
    }
}
