import ElephruitCore
import ElephruitModel
import Foundation

/// The exact shape written by the former independent `Reminders.json` store.
private struct LegacyReminderRecord: Decodable {
    struct Step: Decodable {
        var id: UUID
        var title: String
        var isCompleted: Bool
    }

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
        checklist = try values.decode([Step].self, forKey: .checklist)
        isCompleted = try values.decode(Bool.self, forKey: .isCompleted)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

struct LegacyReminderMigrationReport: Sendable, Hashable {
    var examined = 0
    var imported = 0
    var alreadyImported = 0
}

/// Imports the former JSON reminders into the item graph and then sets the source file aside.
@MainActor
enum LegacyReminderArchiveMigration {
    static func plan(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return 0 }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LegacyReminderRecord].self, from: data).count
    }

    @discardableResult
    static func apply(
        from url: URL,
        using store: ReminderStore
    ) throws -> LegacyReminderMigrationReport {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return LegacyReminderMigrationReport()
        }

        let data = try Data(contentsOf: url)
        let records = try JSONDecoder().decode([LegacyReminderRecord].self, from: data)
        var report = LegacyReminderMigrationReport(examined: records.count)

        for record in records {
            if try store.hasImportedLegacyReminder(id: record.id) {
                report.alreadyImported += 1
                continue
            }

            var draft = ReminderComposerDraft()
            draft.title = record.title
            draft.notes = record.notes
            draft.startAt = record.startAt
            draft.dueAt = record.dueAt
            draft.isSomeday = record.isSomeday
            draft.tagSlugs = record.tagSlugs
            draft.personNames = record.personNames
            draft.projectTitle = record.projectTitle
            draft.checklist = record.checklist.map {
                ChecklistItem(id: $0.id, title: $0.title, isCompleted: $0.isCompleted)
            }

            let source = ItemSource(
                kind: .otherImport,
                identifier: ReminderStore.legacySourceIdentifier(record.id)
            )
            let reminder: Item
            do {
                reminder = try store.create(from: draft, id: record.id, source: source)
            } catch AppError.duplicateIdentifier {
                // A UUID collision with an unrelated library item must not cost the reminder. Its
                // original identity remains in provenance, which also makes a retry idempotent.
                reminder = try store.create(from: draft, source: source)
            }
            try store.finishLegacyImport(
                reminder,
                createdAt: record.createdAt,
                isCompleted: record.isCompleted
            )
            report.imported += 1
        }

        let destination = url.deletingLastPathComponent().appending(
            path: "Reminders.pre-consolidation-\(UUID().uuidString).json",
            directoryHint: .notDirectory
        )
        try FileManager.default.moveItem(at: url, to: destination)
        return report
    }
}
