import ElephruitCore
import ElephruitModel
import Foundation

/// What a parsed entry would become, once the store has had its say.
///
/// ### Why resolution is separate from parsing
/// The parser is pure and knows nothing about the library, which is what lets the whole grammar be
/// tested with string literals. But `/Work /Acme` names a project that may or may not exist, `@Maya`
/// names a person who may be one of three, and "waiting for Jordan" names somebody who may be nobody
/// at all. Deciding what to do about that needs the store.
///
/// So this is the second half, and it is a **preview**: it says what would happen, including what
/// would have to be created, before anything is written. Nothing in the entry surface performs an
/// externally visible action until the user confirms.
public struct TaskEntryPlan: Sendable {
    public var title: String
    public var notes: String

    /// The container the task will land in, if one was named and found.
    public var destinationID: UUID?
    public var destinationTitle: String?

    /// A container the entry named that does not exist yet, and would be created.
    ///
    /// Reported rather than created silently: quietly making a project called "Acmee" because
    /// somebody mistyped is how a library acquires clutter nobody remembers asking for.
    public var destinationToCreate: [String]

    public var personIDs: [UUID]
    public var unresolvedPeople: [String]

    public var waitingOnPersonID: UUID?
    public var waitingOnName: String?

    public var startAt: Date?
    public var deadlineAt: Date?
    public var reminderAt: Date?
    public var reminderIsTimed: Bool
    public var recurrence: RecurrenceRule?
    public var isSomeday: Bool
    public var isFlagged: Bool
    public var priority: Priority?
    public var tagSlugs: [String]

    public init(
        title: String = "",
        notes: String = "",
        destinationID: UUID? = nil,
        destinationTitle: String? = nil,
        destinationToCreate: [String] = [],
        personIDs: [UUID] = [],
        unresolvedPeople: [String] = [],
        waitingOnPersonID: UUID? = nil,
        waitingOnName: String? = nil,
        startAt: Date? = nil,
        deadlineAt: Date? = nil,
        reminderAt: Date? = nil,
        reminderIsTimed: Bool = false,
        recurrence: RecurrenceRule? = nil,
        isSomeday: Bool = false,
        isFlagged: Bool = false,
        priority: Priority? = nil,
        tagSlugs: [String] = []
    ) {
        self.title = title
        self.notes = notes
        self.destinationID = destinationID
        self.destinationTitle = destinationTitle
        self.destinationToCreate = destinationToCreate
        self.personIDs = personIDs
        self.unresolvedPeople = unresolvedPeople
        self.waitingOnPersonID = waitingOnPersonID
        self.waitingOnName = waitingOnName
        self.startAt = startAt
        self.deadlineAt = deadlineAt
        self.reminderAt = reminderAt
        self.reminderIsTimed = reminderIsTimed
        self.recurrence = recurrence
        self.isSomeday = isSomeday
        self.isFlagged = isFlagged
        self.priority = priority
        self.tagSlugs = tagSlugs
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Things the user should see before committing, in plain words.
    public var warnings: [String] {
        var result: [String] = []
        if !destinationToCreate.isEmpty {
            result.append("Will create " + destinationToCreate.map { "“\($0)”" }.joined(separator: " ▸ "))
        }
        for name in unresolvedPeople {
            result.append("No one called “\(name)” yet — they will be added")
        }
        if let startAt, let deadlineAt, startAt > deadlineAt {
            _ = startAt
            _ = deadlineAt
            result.append("The start date is after the deadline")
        }
        return result
    }
}

/// Turns a parsed entry into something the store can make, and then makes it.
///
/// `@MainActor` because it hands back `Item` objects, on the same terms as `ItemRepository`.
@MainActor
public final class TaskEntryComposer {
    private let items: any ItemRepository
    private let tasks: TaskService
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, tasks: TaskService, dateProvider: any DateProvider) {
        self.items = items
        self.tasks = tasks
        self.dateProvider = dateProvider
    }

    // MARK: - Planning

    /// Resolves a draft against the library. Writes nothing.
    public func plan(_ draft: TaskEntryDraft) -> TaskEntryPlan {
        var plan = TaskEntryPlan(title: draft.title, notes: draft.notes)

        plan.startAt = draft.startDate?.day.resolve(using: dateProvider)
        plan.deadlineAt = draft.deadline?.day.resolve(using: dateProvider)
        if let reminder = draft.reminder {
            plan.reminderAt = reminder.resolve(using: dateProvider)
            plan.reminderIsTimed = reminder.time != nil
        }
        plan.recurrence = draft.recurrence
        plan.isSomeday = draft.isSomeday
        plan.isFlagged = draft.isFlagged
        plan.priority = draft.priority
        plan.tagSlugs = draft.tagSlugs

        resolveDestination(draft.destinationPath, into: &plan)
        resolvePeople(draft, into: &plan)

        return plan
    }

    /// Walks the named path, matching what exists and reporting what does not.
    ///
    /// Matching is on the folded title, so case and accents do not matter — the same normalisation
    /// `[[wiki links]]` already use, and for the same reason.
    ///
    /// ### On the cost of this
    /// `plan(_:)` runs on every keystroke, so both fetches here are guarded: nothing is read unless
    /// the text actually named a destination or a person. The container list is read **once** and
    /// walked, rather than once per path segment — which is what it was, and which made `/Work/Acme`
    /// two fetches per character typed.
    private func resolveDestination(_ path: [String], into plan: inout TaskEntryPlan) {
        guard !path.isEmpty else { return }

        let candidates = containers()
        var parentID: UUID?
        var missing: [String] = []

        for segment in path {
            let key = TextNormalizer.foldedForMatching(segment)
            let match = candidates.first { candidate in
                candidate.titleMatchKey == key && candidate.parent?.id == parentID
            }

            if let match {
                parentID = match.id
                plan.destinationID = match.id
                plan.destinationTitle = match.displayTitle
                missing.removeAll()
            } else {
                missing.append(segment)
            }
        }

        plan.destinationToCreate = missing
    }

    private func containers() -> [Item] {
        var query = ItemQuery()
        query.kinds = [.area, .project, .list]
        return (try? items.items(matching: query)) ?? []
    }

    private func resolvePeople(_ draft: TaskEntryDraft, into plan: inout TaskEntryPlan) {
        // Nothing named, nothing to read. Most keystrokes mention nobody.
        guard !draft.personHints.isEmpty || draft.waitingForHint != nil else { return }

        var query = ItemQuery()
        query.kinds = [.person]
        let people = (try? items.items(matching: query)) ?? []

        func match(_ name: String) -> Item? {
            let key = TextNormalizer.foldedForMatching(name)
            // Exact first, then a prefix — "@Maya" should find "Maya Okafor" without also finding
            // "Maya" inside "Amaya", which a `contains` would.
            return people.first { $0.titleMatchKey == key }
                ?? people.first { $0.titleMatchKey.hasPrefix(key) }
        }

        for hint in draft.personHints {
            if let person = match(hint) {
                plan.personIDs.append(person.id)
            } else {
                plan.unresolvedPeople.append(hint)
            }
        }

        if let waiting = draft.waitingForHint {
            plan.waitingOnName = waiting
            if let person = match(waiting) {
                plan.waitingOnPersonID = person.id
            } else if !plan.unresolvedPeople.contains(waiting) {
                plan.unresolvedPeople.append(waiting)
            }
        }
    }

    // MARK: - Committing

    /// Creates everything the plan describes, in one go.
    ///
    /// Containers and people named but missing are created here — after the user has seen the
    /// warning that says so, which is what makes it their decision rather than the app's.
    @discardableResult
    public func commit(_ plan: TaskEntryPlan, source: ItemSource = .quickCapture) throws(AppError) -> Item {
        let destinationID = try resolvedDestination(plan)

        var draft = ItemDraft(
            kind: .task,
            title: plan.title,
            body: plan.notes,
            tagSlugs: plan.tagSlugs,
            parentID: destinationID,
            source: source
        )
        draft.id = UUID()

        let task = try items.create(draft)

        try tasks.mutate(task) { subject in
            subject.startAt = plan.startAt
            subject.dueAt = plan.deadlineAt
            subject.reminderAt = plan.reminderAt
            subject.reminderIsTimed = plan.reminderIsTimed
            subject.reminderOwner = plan.reminderAt == nil ? .none : .app
            subject.recurrence = plan.recurrence
            subject.isSomeday = plan.isSomeday
            subject.isFlagged = plan.isFlagged
            if let priority = plan.priority { subject.priority = priority }
        }

        for personID in plan.personIDs {
            guard let person = try items.item(id: personID) else { continue }
            try items.link(task, to: person, kind: .mentions)
        }

        if plan.waitingOnPersonID != nil || plan.waitingOnName != nil {
            let person = try waitingPerson(plan)
            try tasks.markWaiting(task, on: person)
        }

        return task
    }

    /// The container the task lands in, creating any the plan said it would.
    private func resolvedDestination(_ plan: TaskEntryPlan) throws(AppError) -> UUID? {
        guard !plan.destinationToCreate.isEmpty else { return plan.destinationID }

        var parentID = plan.destinationID
        var created: Item?

        for (offset, name) in plan.destinationToCreate.enumerated() {
            // The first missing segment under an area becomes a project; deeper segments cannot be
            // containers of containers, so anything past the second is folded into the same project
            // rather than inventing a hierarchy the model does not have.
            let kind: ItemKind = (parentID == nil && offset == 0) ? .area : .project
            let container = try items.create(
                ItemDraft(kind: kind, title: name, parentID: parentID, source: .quickCapture)
            )
            parentID = container.id
            created = container
        }

        return created?.id ?? parentID
    }

    private func waitingPerson(_ plan: TaskEntryPlan) throws(AppError) -> Item? {
        if let id = plan.waitingOnPersonID { return try items.item(id: id) }
        guard let name = plan.waitingOnName else { return nil }
        return try items.create(ItemDraft(kind: .person, title: name, source: .quickCapture))
    }
}
