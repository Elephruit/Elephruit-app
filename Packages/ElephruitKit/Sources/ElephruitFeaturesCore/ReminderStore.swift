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
public final class ReminderStore {
    private let items: any ItemRepository
    private let lifecycle: ReminderLifecycleService
    private let dateProvider: any DateProvider

    public init(
        items: any ItemRepository,
        lifecycle: ReminderLifecycleService,
        dateProvider: any DateProvider
    ) {
        self.items = items
        self.lifecycle = lifecycle
        self.dateProvider = dateProvider
    }

    public var reminders: [Item] {
        var query = ItemQuery()
        query.kinds = [.reminder, .task]
        query.scope = .active
        query.sort = .createdNewestFirst
        return (try? items.items(matching: query)) ?? []
    }

    /// The scheduling buckets the whole module rests on, in reading order.
    ///
    /// The list was one flat query in creation order — every reminder ever made, newest first,
    /// with the overdue and the someday interleaved. These are the five answers the scheduling
    /// model already distinguishes: a deadline that has passed, work that belongs to today, work
    /// with a future date, work with no date, and work deliberately parked.
    public enum Section: String, CaseIterable, Identifiable {
        case overdue, today, upcoming, anytime, someday

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .upcoming: "Upcoming"
            case .anytime: "Anytime"
            case .someday: "Someday"
            }
        }
    }

    public struct SectionGroup: Identifiable {
        public let section: Section
        public let reminders: [Item]
        public var id: String { section.id }
    }

    /// The open reminders, bucketed and ordered. Absent sections are absent, not empty.
    public var sections: [SectionGroup] {
        var query = ItemQuery()
        query.kinds = [.reminder, .task]
        query.scope = .active
        query.statuses = [.open]
        query.sort = .dueSoonestFirst
        let open = (try? items.items(matching: query)) ?? []

        var buckets: [Section: [Item]] = [:]
        for reminder in open {
            buckets[section(for: reminder), default: []].append(reminder)
        }

        return Section.allCases.compactMap { section in
            guard var bucket = buckets[section], !bucket.isEmpty else { return nil }
            switch section {
            case .overdue:
                // Oldest first — the thing most needing an answer is the one avoided longest.
                bucket.sort { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
            case .today, .upcoming:
                bucket.sort { relevantDate(of: $0) < relevantDate(of: $1) }
            case .anytime, .someday:
                bucket.sort { $0.createdAt > $1.createdAt }
            }
            return SectionGroup(section: section, reminders: bucket)
        }
    }

    /// Completed reminders, newest completion first — behind the toolbar toggle.
    public var completed: [Item] {
        var query = ItemQuery()
        query.kinds = [.reminder, .task]
        query.scope = .active
        query.statuses = [.completed]
        query.sort = .createdNewestFirst
        let done = (try? items.items(matching: query)) ?? []
        return done.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Which bucket one reminder belongs to.
    ///
    /// A deadline decides ahead of a start date, because only a deadline can make anything late;
    /// a past start date without a deadline is *available*, which is what Anytime means.
    public func section(for reminder: Item) -> Section {
        if reminder.isSomeday { return .someday }

        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday

        if let due = reminder.dueAt {
            if due < today { return .overdue }
            if calendar.isDate(due, inSameDayAs: today) { return .today }
            return .upcoming
        }

        if let start = reminder.startAt {
            if start <= today || calendar.isDate(start, inSameDayAs: today) {
                return calendar.isDate(start, inSameDayAs: today) ? .today : .anytime
            }
            return .upcoming
        }

        return .anytime
    }

    private func relevantDate(of reminder: Item) -> Date {
        reminder.dueAt ?? reminder.startAt ?? .distantFuture
    }

    @discardableResult
    public func create(
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

    public func update(_ reminder: Item, from draft: ReminderComposerDraft) throws(AppError) {
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

    public func toggleCompletion(of reminder: Item) throws(AppError) {
        if reminder.status == .completed {
            try lifecycle.reopen(reminder)
        } else {
            _ = try lifecycle.complete(reminder)
        }
    }

    public func delete(_ reminder: Item) throws(AppError) {
        try items.moveToTrash(reminder)
    }

    /// Applies state the old JSON store could hold but `ItemDraft` cannot express.
    public func finishLegacyImport(
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

    public func hasImportedLegacyReminder(id: UUID) throws(AppError) -> Bool {
        var query = ItemQuery()
        query.scope = .all
        let identifier = Self.legacySourceIdentifier(id)
        return try items.items(matching: query).contains { $0.sourceIdentifier == identifier }
    }

    public static func legacySourceIdentifier(_ id: UUID) -> String {
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
