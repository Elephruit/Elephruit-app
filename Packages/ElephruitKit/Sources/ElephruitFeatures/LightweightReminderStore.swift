import ElephruitCore
import Foundation
import Observation

/// One deliberately small reminder. It is not an `Item`, does not enter Tasks, and is never
/// indexed, filed into a project, or passed through task lifecycle rules.
struct LightweightReminder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var startAt: Date?
    var dueAt: Date?
    var isSomeday: Bool
    var tagSlugs: [String]
    var personNames: [String]
    var projectTitle: String?
    var checklist: [ReminderChecklistItem]
    var isCompleted: Bool
    var createdAt: Date

    init(id: UUID = UUID(), draft: ReminderComposerDraft, now: Date) {
        self.id = id
        self.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startAt = draft.startAt
        self.dueAt = draft.dueAt
        self.isSomeday = draft.isSomeday
        self.tagSlugs = draft.tagSlugs
        self.personNames = draft.personNames
        self.projectTitle = draft.projectTitle
        self.checklist = draft.checklist
        self.isCompleted = false
        self.createdAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, startAt, dueAt, isSomeday, tagSlugs
        case personNames, projectTitle, checklist, isCompleted, createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        notes = try values.decode(String.self, forKey: .notes)
        startAt = try values.decodeIfPresent(Date.self, forKey: .startAt)
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt)
        isSomeday = try values.decode(Bool.self, forKey: .isSomeday)
        tagSlugs = try values.decode([String].self, forKey: .tagSlugs)
        personNames = try values.decodeIfPresent([String].self, forKey: .personNames) ?? []
        projectTitle = try values.decodeIfPresent(String.self, forKey: .projectTitle)
        checklist = try values.decode([ReminderChecklistItem].self, forKey: .checklist)
        isCompleted = try values.decode(Bool.self, forKey: .isCompleted)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

struct ReminderChecklistItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var isCompleted = false
}

/// The Reminders module's independent store.
///
/// The entire file is decoded once at launch and replaced atomically only after a user action.
/// Typing never reaches disk, so the composer remains a local value mutation on every keystroke.
@Observable
@MainActor
final class LightweightReminderStore {
    private(set) var reminders: [LightweightReminder]
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LightweightReminder].self, from: data)
        else {
            reminders = []
            return
        }
        reminders = decoded
    }

    func create(from draft: ReminderComposerDraft, now: Date) throws(AppError) {
        reminders.insert(LightweightReminder(draft: draft, now: now), at: 0)
        try persist()
    }

    func update(_ id: UUID, from draft: ReminderComposerDraft) throws(AppError) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let existing = reminders[index]
        var updated = LightweightReminder(id: id, draft: draft, now: existing.createdAt)
        updated.isCompleted = existing.isCompleted
        reminders[index] = updated
        try persist()
    }

    func toggleCompletion(of id: UUID) throws(AppError) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isCompleted.toggle()
        try persist()
    }

    func delete(_ id: UUID) throws(AppError) {
        reminders.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws(AppError) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .writeFailed(
                path: fileURL.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }
}
