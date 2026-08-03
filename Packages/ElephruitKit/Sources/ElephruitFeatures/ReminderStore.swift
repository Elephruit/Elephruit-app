import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The Reminders module's first-class view of the item graph.
///
/// This intentionally owns no second copy. Every row returned here is the same `Item` that Projects,
/// People, search, time tracking, backlinks, and the Apple Reminders bridge use.
@Observable
@MainActor
final class ReminderStore {
    private let items: any ItemRepository
    private let lifecycle: TaskService
    private let dateProvider: any DateProvider

    init(
        items: any ItemRepository,
        lifecycle: TaskService,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.lifecycle = lifecycle
        self.dateProvider = dateProvider
    }

    var reminders: [Item] {
        var query = ItemQuery()
        query.kinds = [.reminder, .task]
        query.scope = .active
        query.sort = .createdNewestFirst
        return (try? items.items(matching: query)) ?? []
    }

    @discardableResult
    func create(
        from draft: ReminderComposerDraft,
        id: UUID = UUID(),
        source: ItemSource = .manual
    ) throws(AppError) -> Item {
        let project = try uniquelyNamedItem(draft.projectTitle, kinds: [.project])
        let relatedPeople = try people(named: draft.personNames)
        let reminder = try items.create(
            ItemDraft(
                id: id,
                kind: .reminder,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                tagSlugs: draft.tagSlugs,
                parentID: project?.id,
                dueAt: draft.dueAt,
                startAt: draft.startAt,
                source: source
            )
        )

        try lifecycle.mutate(reminder) { subject in
            subject.isSomeday = draft.isSomeday
            subject.checklist = TaskChecklist(items: draft.checklist)
        }
        try lifecycle.setRelatedPeople(relatedPeople, on: reminder)
        try preserveUnresolvedNames(
            from: draft,
            resolvedProject: project,
            resolvedPeople: relatedPeople,
            on: reminder
        )
        return reminder
    }

    func update(_ reminder: Item, from draft: ReminderComposerDraft) throws(AppError) {
        let project = try uniquelyNamedItem(draft.projectTitle, kinds: [.project])

        try lifecycle.mutate(reminder) { subject in
            subject.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            subject.body = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            subject.startAt = draft.startAt
            subject.dueAt = draft.dueAt
            subject.isSomeday = draft.isSomeday
            subject.checklist = TaskChecklist(items: draft.checklist)
        }
        try items.setTags(reminder, slugs: draft.tagSlugs)
        try items.setParent(reminder, to: project)
        try lifecycle.setRelatedPeople(try people(named: draft.personNames), on: reminder)
    }

    func toggleCompletion(of reminder: Item) throws(AppError) {
        if reminder.status == .completed {
            try lifecycle.reopen(reminder)
        } else {
            _ = try lifecycle.complete(reminder)
        }
    }

    func delete(_ reminder: Item) throws(AppError) {
        try items.moveToTrash(reminder)
    }

    /// Applies state the old JSON store could hold but `ItemDraft` cannot express.
    func finishLegacyImport(
        _ reminder: Item,
        createdAt: Date,
        isCompleted: Bool
    ) throws(AppError) {
        try lifecycle.mutate(reminder) { subject in
            subject.createdAt = createdAt
            if isCompleted {
                subject.status = .completed
                // The old store kept only a Boolean. Record the migration instant rather than
                // pretending the original completion date is known.
                subject.completedAt = self.dateProvider.now
                var metadata = subject.userMetadata
                metadata["migration.completionDateInferred"] = .flag(true)
                subject.userMetadata = metadata
            }
        }
    }

    func hasImportedLegacyReminder(id: UUID) throws(AppError) -> Bool {
        var query = ItemQuery()
        query.scope = .all
        let identifier = Self.legacySourceIdentifier(id)
        return try items.items(matching: query).contains { $0.sourceIdentifier == identifier }
    }

    static func legacySourceIdentifier(_ id: UUID) -> String {
        "lightweight-reminder:\(id.uuidString)"
    }

    private func people(named names: [String]) throws(AppError) -> [Item] {
        var resolved: [Item] = []
        for name in names {
            if let person = try uniquelyNamedItem(name, kinds: [.person, .organization]) {
                resolved.append(person)
            }
        }
        return resolved
    }

    private func uniquelyNamedItem(
        _ title: String?,
        kinds: Set<ItemKind>
    ) throws(AppError) -> Item? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var query = ItemQuery()
        query.kinds = kinds
        query.scope = .active
        let wanted = TextNormalizer.foldedForMatching(title)
        let matches = try items.items(matching: query).filter {
            TextNormalizer.foldedForMatching($0.title) == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func preserveUnresolvedNames(
        from draft: ReminderComposerDraft,
        resolvedProject: Item?,
        resolvedPeople: [Item],
        on reminder: Item
    ) throws(AppError) {
        let resolvedNames = Set(resolvedPeople.map { TextNormalizer.foldedForMatching($0.title) })
        let unresolvedPeople = draft.personNames.filter {
            !resolvedNames.contains(TextNormalizer.foldedForMatching($0))
        }
        let unresolvedProject = resolvedProject == nil ? draft.projectTitle : nil
        guard !unresolvedPeople.isEmpty || unresolvedProject != nil else { return }

        try lifecycle.mutate(reminder) { subject in
            var metadata = subject.userMetadata
            if !unresolvedPeople.isEmpty {
                metadata["migration.unresolvedPeople"] = .text(unresolvedPeople.joined(separator: " | "))
            }
            if let unresolvedProject {
                metadata["migration.unresolvedProject"] = .text(unresolvedProject)
            }
            subject.userMetadata = metadata
        }
    }
}
