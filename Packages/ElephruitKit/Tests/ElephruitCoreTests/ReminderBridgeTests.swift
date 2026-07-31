import ElephruitCore
import Foundation
import Testing

private let clock = FixedDateProvider.reference
private var calendar: Calendar { clock.calendar }
private var now: Date { clock.now }

private func snapshot(
    title: String = "Buy milk",
    listID: String = "list-1",
    isReadOnly: Bool = false,
    _ configure: (inout ReminderSnapshot) -> Void = { _ in }
) -> ReminderSnapshot {
    var value = ReminderSnapshot(id: "rem-1", listID: listID, title: title, isReadOnly: isReadOnly)
    configure(&value)
    return value
}

private func link(
    to remote: ReminderSnapshot,
    syncedAt: Date = clock.now,
    localStamp: Date = clock.now
) -> ReminderLinkState {
    ReminderLinkState(
        externalID: remote.id,
        listID: remote.listID,
        lastSyncedFingerprint: remote.fingerprint,
        lastSyncedAt: syncedAt,
        lastSyncedLocalStamp: localStamp
    )
}

@Suite("Reconciling one linked reminder")
struct ReminderReconciliationTests {
    @Test("Neither side moved")
    func quiet() {
        let remote = snapshot()
        #expect(
            ReminderReconciliation.decide(link: link(to: remote), remote: remote, localUpdatedAt: now)
                == .unchanged
        )
    }

    @Test("Only the reminder moved: adopt it")
    func remoteOnly() {
        let before = snapshot()
        let state = link(to: before)
        let after = snapshot(title: "Buy oat milk")

        #expect(
            ReminderReconciliation.decide(link: state, remote: after, localUpdatedAt: now) == .adoptRemote
        )
    }

    @Test("Only the task moved: push it")
    func localOnly() {
        let remote = snapshot()
        let state = link(to: remote)

        #expect(
            ReminderReconciliation.decide(
                link: state, remote: remote, localUpdatedAt: now.addingTimeInterval(60)
            ) == .pushLocal
        )
    }

    @Test("Both moved: a conflict, and nothing is overwritten")
    func conflict() {
        let state = link(to: snapshot())
        let after = snapshot(title: "Buy oat milk")

        let decision = ReminderReconciliation.decide(
            link: state, remote: after, localUpdatedAt: now.addingTimeInterval(60)
        )
        #expect(decision == .conflict)
        #expect(!ReminderReconciliation.writesToSystemStore(decision))
        #expect(ReminderReconciliation.state(after: decision) == .conflicted)
    }

    @Test("A local edit on a read-only list is reported, not attempted")
    func readOnlyList() {
        let remote = snapshot(isReadOnly: true)
        let decision = ReminderReconciliation.decide(
            link: link(to: remote), remote: remote, localUpdatedAt: now.addingTimeInterval(60)
        )

        #expect(decision == .remoteReadOnly)
        #expect(!ReminderReconciliation.writesToSystemStore(decision))
    }

    @Test("A vanished reminder is never a deletion here")
    func missing() {
        let decision = ReminderReconciliation.decide(
            link: link(to: snapshot()), remote: nil, localUpdatedAt: now
        )

        #expect(decision == .remoteMissing)
        #expect(ReminderReconciliation.state(after: decision) == .externalMissing)
        // Keeping the task is offered first, because it loses nothing.
        #expect(MissingReminderChoice.allCases.first == .keepAsLocal)
    }

    @Test("Pushing is the only decision that writes to the user's store")
    func onlyPushWrites() {
        let writing = [
            ReminderMergeDecision.unchanged, .adoptRemote, .pushLocal,
            .conflict, .remoteMissing, .remoteReadOnly,
        ].filter(ReminderReconciliation.writesToSystemStore)

        #expect(writing == [.pushLocal])
    }

    @Test("Running the same pass twice changes nothing the second time")
    func idempotence() {
        var remote = snapshot()
        var state = link(to: remote, localStamp: now)
        var localUpdatedAt = now.addingTimeInterval(60)

        // First pass: the task moved, so it is pushed.
        #expect(
            ReminderReconciliation.decide(link: state, remote: remote, localUpdatedAt: localUpdatedAt)
                == .pushLocal
        )

        // The engine writes the reminder and records what it wrote.
        remote.title = "Buy oat milk"
        state = ReminderLinkState(
            externalID: remote.id,
            listID: remote.listID,
            lastSyncedFingerprint: remote.fingerprint,
            lastSyncedAt: localUpdatedAt,
            lastSyncedLocalStamp: localUpdatedAt
        )

        // Second pass, with nothing else having happened. This is the case that produces duplicate
        // work — and an endless push loop — if the local stamp comparison is not strict.
        #expect(
            ReminderReconciliation.decide(link: state, remote: remote, localUpdatedAt: localUpdatedAt)
                == .unchanged
        )

        // And a third, after the store-change notification the write itself provoked.
        localUpdatedAt = state.lastSyncedLocalStamp
        #expect(
            ReminderReconciliation.decide(link: state, remote: remote, localUpdatedAt: localUpdatedAt)
                == .unchanged
        )
    }
}

@Suite("The fingerprint notices exactly the fields that are mapped")
struct ReminderFingerprintTests {
    /// Named rather than passed as closures: `@Test(arguments:)` requires `Sendable` values, and a
    /// list of field names reads better in a failure message than a closure would.
    enum MappedField: String, CaseIterable {
        case title, notes, completion, priority, alarms, recurrence, list, due, start
    }

    @Test("A change to any mapped field changes the fingerprint", arguments: MappedField.allCases)
    func mappedFieldsAreNoticed(field: MappedField) {
        let before = snapshot()
        var after = before

        switch field {
        case .title: after.title = "Something else"
        case .notes: after.notes = "A note"
        case .completion: after.isCompleted = true
        case .priority: after.priority = 1
        case .alarms: after.alarmDates = [now]
        case .recurrence: after.hasRecurrence = true
        case .list: after.listID = "list-2"
        case .due: after.dueComponents = DateComponents(year: 2026, month: 7, day: 1)
        case .start: after.startComponents = DateComponents(year: 2026, month: 7, day: 1)
        }

        #expect(before.fingerprint != after.fingerprint, "changing \(field.rawValue) went unnoticed")
    }

    @Test("A change to an unmapped field does not")
    func unmappedFieldsAreIgnored() {
        // `lastModified` moves for changes this app does not map, and on a store synchronised
        // through iCloud it can move for no local reason at all. Reacting to it would mean a sync
        // pass every time anything anywhere touched the record.
        let before = snapshot()
        var after = before
        after.lastModified = now.addingTimeInterval(9_999)

        #expect(before.fingerprint == after.fingerprint)
    }
}

@Suite("Field mapping is explicit about what cannot cross")
struct ReminderFieldMappingTests {
    @Test("EventKit's priority scale maps onto three levels")
    func priorityScale() {
        #expect(ReminderFieldMapping.priority(fromEventKit: 0) == nil)
        #expect(ReminderFieldMapping.priority(fromEventKit: 1) == .high)
        #expect(ReminderFieldMapping.priority(fromEventKit: 4) == .high)
        #expect(ReminderFieldMapping.priority(fromEventKit: 5) == .normal)
        #expect(ReminderFieldMapping.priority(fromEventKit: 9) == .low)
    }

    @Test("The level survives a round trip even though the exact number does not")
    func priorityRoundTrip() {
        for level in [Priority.low, .normal, .high] {
            let written = ReminderFieldMapping.eventKitPriority(from: level)
            #expect(ReminderFieldMapping.priority(fromEventKit: written) == level)
        }
        // Unspecified is not the same as normal, and must not become it.
        #expect(ReminderFieldMapping.eventKitPriority(from: nil) == 0)
        #expect(ReminderFieldMapping.priority(fromEventKit: 0) == nil)
    }

    @Test("An all-day reminder does not acquire midnight as its time")
    func allDayStaysAllDay() throws {
        let components = DateComponents(year: 2026, month: 8, day: 15)
        let read = try #require(ReminderFieldMapping.date(from: components, calendar: calendar))

        #expect(!read.hasTime)
        let written = ReminderFieldMapping.components(from: read.date, hasTime: false, calendar: calendar)
        #expect(written.hour == nil)
    }

    @Test("A timed reminder keeps its time")
    func timedStaysTimed() throws {
        let components = DateComponents(year: 2026, month: 8, day: 15, hour: 9, minute: 30)
        let read = try #require(ReminderFieldMapping.date(from: components, calendar: calendar))

        #expect(read.hasTime)
        let written = ReminderFieldMapping.components(from: read.date, hasTime: true, calendar: calendar)
        #expect(written.hour == 9)
        #expect(written.minute == 30)
    }

    @Test("A completion-anchored repeat is kept local rather than written out wrong")
    func completionAnchorCannotCross() {
        #expect(ReminderFieldMapping.isRepresentableInEventKit(RecurrenceRule(frequency: .weekly)))
        #expect(
            !ReminderFieldMapping.isRepresentableInEventKit(
                RecurrenceRule(frequency: .daily, interval: 3, anchor: .completion)
            )
        )
    }

    @Test("Every app-only field carries a reason, because the honest version is a list you can read")
    func appOnlyFieldsAreExplained() {
        #expect(!ReminderFieldMapping.appOnlyFields.isEmpty)
        #expect(ReminderFieldMapping.appOnlyFields.allSatisfy { !$0.reason.isEmpty })

        // The private ones in particular. These are the fields that would end up in somebody's
        // iCloud account, and in a shared list, if they were smuggled into a title or a note.
        let named = ReminderFieldMapping.appOnlyFields.map(\.field)
        #expect(named.contains { $0.contains("Waiting") })
        #expect(named.contains { $0.contains("Linked people") })
    }
}

@Suite("Deleting is always a question")
struct LinkedDeletionTests {
    @Test("Removing a linked task offers both outcomes and defaults to neither")
    func deletionChoices() {
        #expect(LinkedDeletionChoice.allCases.count == 2)
        #expect(LinkedDeletionChoice.allCases.contains(.removeLocally))
        #expect(LinkedDeletionChoice.allCases.contains(.deleteBoth))
    }

    @Test("Every conflict resolution says what it will do before it does it")
    func resolutionsAreExplained() {
        #expect(ConflictResolution.allCases.count == 3)
        #expect(ConflictResolution.allCases.allSatisfy { !$0.explanation.isEmpty })
    }
}
