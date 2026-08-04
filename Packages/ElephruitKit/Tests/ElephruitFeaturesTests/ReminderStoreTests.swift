import ElephruitCore
@testable import ElephruitFeatures
@testable import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@MainActor
@Suite("First-class reminder store")
struct ReminderStoreTests {
    private func services() -> AppServices {
        AppServices.inMemory(populated: false)
    }

    @Test("A reminder is an Item linked to its project and people")
    func reminderJoinsTheGraph() throws {
        let services = services()
        let project = try services.items.create(ItemDraft(kind: .project, title: "Home"))
        let person = try services.items.create(ItemDraft(kind: .person, title: "Jordan Lee"))

        var draft = ReminderComposerDraft()
        draft.title = "Call the dentist"
        draft.notes = "Ask about Thursday"
        draft.tagSlugs = ["personal"]
        draft.personNames = [person.title]
        draft.projectTitle = project.title
        draft.pendingStep = "Find insurance card"
        draft.commitPendingStep()

        let reminder = try services.reminderStore.create(from: draft)

        #expect(reminder.kind == .reminder)
        #expect(reminder.body == "Ask about Thursday")
        #expect(reminder.parent?.id == project.id)
        #expect(reminder.tagSlugs == ["personal"])
        #expect((reminder.outgoingLinks ?? []).first { $0.kind == .mentions }?.target?.id == person.id)
        #expect(reminder.checklist.items.map(\.title) == ["Find insurance card"])
    }

    @Test("Editing preserves identity and completion")
    func updatePreservesIdentity() throws {
        let services = services()
        var original = ReminderComposerDraft()
        original.title = "Old title"
        let reminder = try services.reminderStore.create(from: original)
        let id = reminder.id
        try services.reminderStore.toggleCompletion(of: reminder)

        var edited = ReminderComposerDraft()
        edited.title = "New title"
        try services.reminderStore.update(reminder, from: edited)

        #expect(reminder.id == id)
        #expect(reminder.title == "New title")
        #expect(reminder.status == .completed)
        #expect(reminder.completedAt != nil)
    }

    @Test("The old JSON archive imports once and is set aside")
    func importsLegacyArchive() throws {
        struct Step: Encodable {
            var id: UUID
            var title: String
            var isCompleted: Bool
        }
        struct Record: Encodable {
            var id: UUID
            var title: String
            var notes: String
            var startAt: Date?
            var dueAt: Date?
            var isSomeday: Bool
            var tagSlugs: [String]
            var personNames: [String]
            var projectTitle: String?
            var checklist: [Step]
            var isCompleted: Bool
            var createdAt: Date
        }

        let services = services()
        let directory = URL.temporaryDirectory.appending(
            path: "ReminderStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Reminders.json")
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let record = Record(
            id: id,
            title: "Already saved",
            notes: "Keep every word",
            isSomeday: true,
            tagSlugs: ["legacy"],
            personNames: ["Person who is not here"],
            projectTitle: "Project that is not here",
            checklist: [Step(id: UUID(), title: "One step", isCompleted: true)],
            isCompleted: true,
            createdAt: createdAt
        )
        try JSONEncoder().encode([record]).write(to: file)

        let report = try LegacyReminderArchiveMigration.apply(
            from: file,
            using: services.reminderStore
        )
        let reminder = try #require(services.reminderStore.reminders.first { $0.id == id })

        #expect(report.imported == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(reminder.createdAt == createdAt)
        #expect(reminder.status == .completed)
        #expect(reminder.userMetadata["migration.unresolvedPeople"] != nil)
        #expect(reminder.userMetadata["migration.unresolvedProject"] != nil)
        #expect(try services.reminderStore.hasImportedLegacyReminder(id: id))
    }

    @Test("Typing only mutates a draft")
    func typingDoesNotPersist() {
        let services = services()
        var draft = ReminderComposerDraft()

        draft.title = "Every keystroke stays local"
        draft.notes = "Still local"

        #expect(services.reminderStore.reminders.isEmpty)
        #expect(!draft.isEmpty)
    }
}
