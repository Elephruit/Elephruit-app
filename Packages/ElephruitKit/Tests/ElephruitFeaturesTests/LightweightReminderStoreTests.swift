@testable import ElephruitFeatures
import Foundation
import Testing

@MainActor
@Suite("Lightweight reminder store")
struct LightweightReminderStoreTests {
    @Test("A reminder round-trips without becoming an Item")
    func roundTrip() throws {
        let directory = URL.temporaryDirectory
            .appending(path: "LightweightReminderStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Reminders.json")

        var draft = ReminderComposerDraft()
        draft.title = "Call the dentist"
        draft.notes = "Ask about Thursday"
        draft.tagSlugs = ["personal"]
        draft.personNames = ["Jordan Lee"]
        draft.projectTitle = "Home"
        draft.pendingStep = "Find insurance card"
        draft.commitPendingStep()

        let store = LightweightReminderStore(fileURL: file)
        try store.create(from: draft, now: Date(timeIntervalSince1970: 100))

        let reopened = LightweightReminderStore(fileURL: file)
        let reminder = try #require(reopened.reminders.first)
        #expect(reminder.title == "Call the dentist")
        #expect(reminder.notes == "Ask about Thursday")
        #expect(reminder.tagSlugs == ["personal"])
        #expect(reminder.personNames == ["Jordan Lee"])
        #expect(reminder.projectTitle == "Home")
        #expect(reminder.checklist.map(\.title) == ["Find insurance card"])
    }

    @Test("Editing replaces the reminder and preserves its identity and completion")
    func updatePreservesIdentity() throws {
        let store = LightweightReminderStore(fileURL: nil)
        var original = ReminderComposerDraft()
        original.title = "Old title"
        try store.create(from: original, now: Date(timeIntervalSince1970: 100))
        let id = try #require(store.reminders.first?.id)
        try store.toggleCompletion(of: id)

        var edited = ReminderComposerDraft()
        edited.title = "New title"
        edited.personNames = ["Sam Rivera"]
        edited.projectTitle = "Launch"
        try store.update(id, from: edited)

        let reminder = try #require(store.reminders.first)
        #expect(reminder.id == id)
        #expect(reminder.title == "New title")
        #expect(reminder.personNames == ["Sam Rivera"])
        #expect(reminder.projectTitle == "Launch")
        #expect(reminder.isCompleted)
        #expect(reminder.createdAt == Date(timeIntervalSince1970: 100))
    }

    @Test("Typing only mutates a draft")
    func typingDoesNotPersist() {
        let store = LightweightReminderStore(fileURL: nil)
        var draft = ReminderComposerDraft()

        draft.title = "Every keystroke stays local"
        draft.notes = "Still local"

        #expect(store.reminders.isEmpty)
        #expect(!draft.isEmpty)
    }
}
