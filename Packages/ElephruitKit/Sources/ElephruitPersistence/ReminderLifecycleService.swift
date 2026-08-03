import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What completing a reminder or project work record actually did.
///
/// Returned rather than inferred, because completing a repeating task is two facts — this occurrence
/// is done, and the next one exists — and a caller that has to work out which happened by re-reading
/// the store will get it wrong the first time somebody completes the last occurrence of a series.
public struct WorkItemCompletionOutcome: Sendable, Hashable {
    /// The occurrence that was just finished.
    public var completedID: UUID

    /// The next occurrence, when the series continues.
    public var nextOccurrenceID: UUID?

    /// Set when the series has just ended.
    public var seriesEnded: Bool

    /// Whether a linked system reminder now needs writing out.
    public var needsReminderPush: Bool

    public init(
        completedID: UUID,
        nextOccurrenceID: UUID? = nil,
        seriesEnded: Bool = false,
        needsReminderPush: Bool = false
    ) {
        self.completedID = completedID
        self.nextOccurrenceID = nextOccurrenceID
        self.seriesEnded = seriesEnded
        self.needsReminderPush = needsReminderPush
    }
}

/// Every way a task can change, and the one place the invariants are applied.
///
/// ### Why this exists rather than views calling `ItemRepository.update`
/// The rules in ``TaskInvariants`` are reachable from a context menu, the inspector, a batch action,
/// a drag onto a day, the reminder sync, and the recurrence roll-forward. Applying them at each site
/// means applying them six times and forgetting once — and the forgotten one is a task that reads as
/// completed in one column and waiting in another.
///
/// So every mutation here funnels through ``ReminderLifecycleService/mutate(_:_:)``, which runs the invariants
/// after the change and before the save. A view that reaches past this to `update` can still write
/// an inconsistent task; that is what `TaskInvariantCoverageTests` is for.
///
/// `@MainActor` for the reason `ItemRepository` is: it hands back `Item` objects, which belong to
/// the context that owns them.
@MainActor
public final class ReminderLifecycleService {
    private let items: any ItemRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, context: ModelContext, dateProvider: any DateProvider) {
        self.items = items
        self.context = context
        self.dateProvider = dateProvider
    }

    private var calendar: Calendar { dateProvider.calendar }

    // MARK: - The funnel

    /// Applies a change, then brings the task's marks into agreement, then saves.
    ///
    /// Returns what the invariants had to correct, so a caller can tell the user rather than letting
    /// a mark disappear silently.
    @discardableResult
    public func mutate(
        _ task: Item,
        _ change: (Item) throws -> Void
    ) throws(AppError) -> [TaskInvariants.Correction] {
        var corrections: [TaskInvariants.Correction] = []

        try items.update(task) { subject in
            try change(subject)

            var facts = subject.taskFacts()
            corrections = TaskInvariants.normalise(&facts)
            Self.apply(facts, to: subject)
        }

        return corrections
    }

    /// Writes the normalised marks back onto the stored object.
    ///
    /// Only the fields ``TaskInvariants`` can touch. Copying the whole of `TaskFacts` back would
    /// write derived values — the container identifiers, the search text — over the real ones.
    private static func apply(_ facts: TaskFacts, to item: Item) {
        item.status = facts.status
        item.completedAt = facts.completedAt
        item.cancelledAt = facts.cancelledAt
        item.startAt = facts.startAt
        item.dueAt = facts.deadlineAt
        item.reminderAt = facts.reminderAt
        item.reminderIsTimed = facts.reminderIsTimed
        item.reminderOwner = facts.reminderOwner
        item.todayCommittedOn = facts.todayCommittedOn
        item.isLaterToday = facts.isLaterToday
        item.isSomeday = facts.isSomeday
        item.isFlagged = facts.isFlagged
        item.waitingSince = facts.waitingSince
        item.followUpAt = facts.followUpAt
    }

    // MARK: - Dates

    /// Sets when the task becomes actionable. `nil` makes it available now.
    ///
    /// Normalised to the start of the day: availability is a property of a *day*, and a start date
    /// carrying 14:37 because that is when it was dragged would make a task appear halfway through
    /// an afternoon for no reason anybody chose.
    public func setStartDate(_ date: Date?, on task: Item) throws(AppError) {
        try mutate(task) { $0.startAt = date.map(self.calendar.startOfDay) }
    }

    /// Sets the date by which the task must be finished. `nil` removes the commitment.
    ///
    /// Also normalised to the start of the day. A deadline with a time on it is the ambiguity the
    /// migration exists to avoid re-creating — if the user wants to be told at five o'clock, that is
    /// a reminder, and there is a field for it.
    public func setDeadline(_ date: Date?, on task: Item) throws(AppError) {
        try mutate(task) { $0.dueAt = date.map(self.calendar.startOfDay) }
    }

    /// Sets when to interrupt. Independent of both dates, and never derived from either.
    ///
    /// - Parameter timed: Whether `date` names a time of day. A date-only reminder is delivered in
    ///   the morning rather than at midnight, which is the scheduler's business rather than this
    ///   one's — see `TaskNotificationScheduler`.
    public func setReminder(_ date: Date?, timed: Bool, on task: Item) throws(AppError) {
        try mutate(task) { subject in
            subject.reminderAt = date
            subject.reminderIsTimed = date == nil ? false : timed
            // A task whose alarm the system already owns keeps that ownership; otherwise this app
            // takes it. Never both — see `ReminderOwner`.
            if date != nil, subject.reminderOwner != .system {
                subject.reminderOwner = .app
            }
        }
    }

    /// Moves whichever dates the caller names, and no others.
    ///
    /// ### Why dragging cannot be a single date
    /// A task in Upcoming may appear on two days for two reasons. Dragging the row that says
    /// "Deadline" to another day must move the deadline; dragging the one that says "Starts" must
    /// move the start date. An API taking one `Date` forces the call site to decide, and the call
    /// site is a drag handler that knows only where the finger went.
    ///
    /// So the reason travels with the drop, and this is the only way to apply it.
    public func reschedule(
        _ task: Item,
        reason: UpcomingReason,
        to day: Date
    ) throws(AppError) {
        let start = calendar.startOfDay(for: day)

        switch reason {
        case .becomesAvailable:
            try setStartDate(start, on: task)

        case .deadline:
            try setDeadline(start, on: task)

        case .reminder(let previous):
            // The time of day survives the move. A reminder dragged from Tuesday to Thursday is
            // still a nine o'clock reminder.
            let components = calendar.dateComponents([.hour, .minute], from: previous)
            let moved = calendar.date(
                bySettingHour: components.hour ?? 9,
                minute: components.minute ?? 0,
                second: 0,
                of: start
            )
            try setReminder(moved ?? start, timed: task.reminderIsTimed, on: task)

        case .followUp:
            try mutate(task) { $0.followUpAt = start }
        }
    }

    // MARK: - Today

    /// Chooses this task for today.
    ///
    /// Idempotent: committing something already committed does not restart the clock on it, so a
    /// task carried over from Monday stays carried over rather than looking freshly planned.
    public func commitToToday(_ task: Item) throws(AppError) {
        guard !task.isCommittedTo(today: dateProvider) else { return }
        let order = try nextTodayOrder()
        try mutate(task) { subject in
            subject.todayCommittedOn = self.dateProvider.startOfToday
            subject.isLaterToday = false
            subject.todayOrder = order
        }
    }

    public func removeFromToday(_ task: Item) throws(AppError) {
        try mutate(task) { subject in
            subject.todayCommittedOn = nil
            subject.isLaterToday = false
        }
    }

    /// Chooses this task for a particular day.
    ///
    /// ### Why this is a commitment and not a start date
    /// Because they answer different questions and the model has always kept them apart. A start
    /// date says *this cannot be worked on before then*; a commitment says *I intend to do this on
    /// that day*. Somebody dragging a task onto Thursday in a day planner is doing the second, and
    /// writing the first instead would silently make the task unavailable in Anytime until Thursday
    /// arrived — a task quietly disappearing from the list of what you could pick up, because you
    /// said when you meant to do it.
    ///
    /// ``commitToToday(_:)`` is this for the one day that has an idempotency rule of its own: a task
    /// carried over from Monday must stay carried over rather than looking freshly planned, which is
    /// what the guard there protects and what makes it worth keeping as its own method.
    public func commit(_ task: Item, to day: Date) throws(AppError) {
        let start = calendar.startOfDay(for: day)
        guard start != dateProvider.startOfToday else {
            try commitToToday(task)
            return
        }

        let order = try nextTodayOrder()
        try mutate(task) { subject in
            subject.todayCommittedOn = start
            // Only meaningful while the commitment is for today itself — see `TaskInvariants`.
            subject.isLaterToday = false
            subject.todayOrder = order
        }
    }

    /// Pushes a task to the back half of today.
    ///
    /// Commits it first if it was not already: "later today" is a statement about today's plan, and
    /// something that is not on the plan cannot be later in it.
    public func moveToLaterToday(_ task: Item) throws(AppError) {
        let order = try nextTodayOrder()
        try mutate(task) { subject in
            subject.todayCommittedOn = self.dateProvider.startOfToday
            subject.isLaterToday = true
            subject.todayOrder = order
        }
    }

    /// Reorders Today without touching any project's order.
    ///
    /// The whole reason ``Item/todayOrder`` is a second column: the order of a project's steps is
    /// the order they have to happen in, and the order of today is the order you feel like doing
    /// them. Rewriting one from the other loses whichever was rewritten.
    public func reorderToday(_ ordered: [Item]) throws(AppError) {
        for (offset, task) in ordered.enumerated() {
            let position = Double(offset + 1) * Self.orderGap
            guard task.todayOrder != position else { continue }
            try mutate(task) { $0.todayOrder = position }
        }
    }

    /// Sparse, gap-based, so inserting between two neighbours writes one row — the same scheme
    /// ``Item/sortOrder`` uses.
    private static let orderGap: Double = 1_024

    private func nextTodayOrder() throws(AppError) -> Double {
        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = [.open]
        let open = try items.items(matching: query)
        let highest = open.map(\.todayOrder).max() ?? 0
        return highest + Self.orderGap
    }

    // MARK: - Marks

    /// Parks a task, or brings it back.
    /// Applies one answer to *when is this for*.
    ///
    /// ### The property this exists to make checkable
    /// **No case here writes a deadline.** Every route sets a start date, a commitment, or Someday —
    /// three things that can never make a task late — and a deadline is the one date that can. The
    /// distinction is what the whole scheduling model rests on, and a control that quietly crossed it
    /// would make everything downstream wrong while looking right.
    ///
    /// A day chosen here also un-parks the task, because Someday means "no date, deliberately" and a
    /// task both parked and scheduled for Thursday is a contradiction somebody would otherwise have
    /// to resolve on the user's behalf.
    public func apply(_ choice: TaskWhenChoice, to task: Item) throws(AppError) {
        switch choice {
        case .today:
            try commitToToday(task)

        case .thisEvening:
            try moveToLaterToday(task)

        case .someday:
            try setSomeday(true, on: task)

        case .startingOn(let date):
            try setStartDate(date, on: task)
            if task.isSomeday { try setSomeday(false, on: task) }

        case .clear:
            try setStartDate(nil, on: task)
            try setSomeday(false, on: task)
            try removeFromToday(task)
        }
    }

    public func setSomeday(_ isSomeday: Bool, on task: Item) throws(AppError) {
        try mutate(task) { $0.isSomeday = isSomeday }
    }

    /// A flag means what the user decided it means, and implies nothing else.
    public func setFlagged(_ isFlagged: Bool, on task: Item) throws(AppError) {
        try mutate(task) { $0.isFlagged = isFlagged }
    }

    /// Puts a synchronised task into the Inbox for triage, or takes it back out.
    ///
    /// ### Why this needs an action at all
    /// The Inbox is defined by absences — no container, no filing, no tags — and a reminder kept in
    /// step with a list in Apple Reminders is filed *there*, which is why it is not in the Inbox by
    /// default. See ``ElephruitModel/Item/hasHome``. But "I want to deal with that one here" is a
    /// real thing to want, and the only way to say it in a vocabulary made of absences would be to
    /// break the link — which would stop the reminder syncing, on somebody's phone, as a side effect
    /// of them wanting to think about it.
    ///
    /// So it is one date, set by this, and it changes nothing else: the link is untouched, the
    /// reminder is untouched, and the task keeps syncing while it sits in the Inbox. Filing it
    /// anywhere real clears it, because a task in a project is not an unprocessed capture whatever
    /// anybody meant last week.
    ///
    /// A no-op on a task that is not synchronised: an ordinary local capture with no home is already
    /// in the Inbox, and one *with* a home should be moved rather than marked.
    public func setInInbox(_ isInInbox: Bool, on task: Item) throws(AppError) {
        guard task.isKeptInStepWithAnExternalList else { return }
        try mutate(task) { $0.inboxedAt = isInInbox ? self.dateProvider.now : nil }
    }

    public func setPriority(_ priority: Priority, on task: Item) throws(AppError) {
        try mutate(task) { $0.priority = priority }
    }

    /// Records that the next move belongs to somebody else.
    ///
    /// The person is a link rather than a column, so the task turns up on their page, in their
    /// timeline, and in the brief for the next meeting with them — by the traversal those already do.
    public func markWaiting(
        _ task: Item,
        on person: Item?,
        since: Date? = nil,
        followUp: Date? = nil
    ) throws(AppError) {
        try mutate(task) { subject in
            subject.waitingSince = since ?? self.dateProvider.now
            subject.followUpAt = followUp.map(self.calendar.startOfDay)
        }

        try clearWaitingLinks(on: task)
        if let person {
            try items.link(task, to: person, kind: .waitingOn)
        }
    }

    public func clearWaiting(_ task: Item) throws(AppError) {
        try mutate(task) { subject in
            subject.waitingSince = nil
            subject.followUpAt = nil
        }
        try clearWaitingLinks(on: task)
    }

    /// Records that this task is something the user owes somebody.
    public func markPromised(_ task: Item, to person: Item) throws(AppError) {
        try items.link(task, to: person, kind: .promisedTo)
    }

    /// Who is on this task, as a whole set.
    ///
    /// ### Why this touches `.mentions` and nothing else
    /// A task can point at a person in four ways, and three of them mean something specific:
    /// ``LinkKind/waitingOn`` is the person who has the next move, ``LinkKind/promisedTo`` is
    /// somebody owed, ``LinkKind/participant`` belongs to meetings. Only ``LinkKind/mentions`` means
    /// the plain thing — *this involves them* — so only that kind is replaced here.
    ///
    /// The alternative, replacing every person link, would mean that adding a second name to a task
    /// waiting on Ana silently stopped it waiting on Ana. A control that quietly undoes a different
    /// control is worse than one that does less.
    ///
    /// Whole-set rather than add and remove, because the picker hands back a list and diffing it in
    /// the view would put the "which ones went?" question in the surface rather than in the store.
    public func setRelatedPeople(_ people: [Item], on task: Item) throws(AppError) {
        let wanted = Set(people.map(\.id))
        let existing = task.outgoingLinks.filter { $0.kind == .mentions && $0.target?.kind == .person }
        let stale = existing.filter { link in
            guard let id = link.target?.id else { return true }
            return !wanted.contains(id)
        }

        if !stale.isEmpty {
            do {
                for link in stale { context.delete(link) }
                try context.save()
            } catch {
                throw .writeFailed(path: "mentions", reason: error.localizedDescription)
            }
        }

        // `link` is idempotent, so the ones already there cost nothing and the ones that are not are
        // added. No diff to get wrong.
        for person in people {
            try items.link(task, to: person, kind: .mentions)
        }
    }

    private func clearWaitingLinks(on task: Item) throws(AppError) {
        let stale = task.outgoingLinks.filter { $0.kind == .waitingOn }
        guard !stale.isEmpty else { return }

        do {
            for link in stale { context.delete(link) }
            try context.save()
        } catch {
            throw .writeFailed(path: "waitingOn", reason: error.localizedDescription)
        }
    }

    // MARK: - Completion

    /// Marks a task done, rolling a repeating series forward.
    ///
    /// ### What happens to a repeating task
    /// The completed occurrence stays, exactly as it was, as history — with its checklist ticks, its
    /// links, and its dates. A **new** row carries the series forward with the next dates and a
    /// fresh checklist. Nothing is destroyed, and "when did I last do this?" is answerable.
    ///
    /// The alternative — moving the same row's dates forward and logging nothing — is what most apps
    /// do, and it means a weekly task has exactly one completion in its history however many years
    /// it has been running.
    @discardableResult
    public func complete(_ task: Item) throws(AppError) -> WorkItemCompletionOutcome {
        let now = dateProvider.now
        let facts = task.taskFacts()

        // The next occurrence is worked out *before* the completion is written, because the roll
        // forward is measured from this occurrence's dates and completing clears some of them.
        let advance = facts.recurrenceAdvance(
            rule: task.recurrence,
            completedAt: now,
            occurrencesSoFar: task.occurrenceCount,
            calendar: calendar
        )

        try mutate(task) { subject in
            subject.status = .completed
            subject.completedAt = now
        }

        guard let rule = task.recurrence, let advance else {
            return WorkItemCompletionOutcome(
                completedID: task.id,
                seriesEnded: task.recurrence != nil,
                needsReminderPush: task.syncState == .linked
            )
        }

        let next = try makeNextOccurrence(of: task, rule: rule, advance: advance)
        return WorkItemCompletionOutcome(
            completedID: task.id,
            nextOccurrenceID: next.id,
            needsReminderPush: task.syncState == .linked
        )
    }

    /// Abandons a task. The record of *not* doing it is worth keeping.
    ///
    /// A cancelled occurrence does **not** roll the series forward: skipping one Friday is not the
    /// same as doing it, and generating the next occurrence from a skip would make a series the user
    /// is trying to stop feel unstoppable.
    public func cancel(_ task: Item) throws(AppError) {
        try mutate(task) { subject in
            subject.status = .cancelled
            subject.cancelledAt = self.dateProvider.now
        }
    }

    /// Reopens a finished task, leaving every other mark where the invariants put it.
    public func reopen(_ task: Item) throws(AppError) {
        try mutate(task) { subject in
            subject.status = .open
            subject.completedAt = nil
            subject.cancelledAt = nil
        }
    }

    /// Builds the row that carries a repeating series forward.
    private func makeNextOccurrence(
        of task: Item,
        rule: RecurrenceRule,
        advance: RecurrenceAdvance
    ) throws(AppError) -> Item {
        let seriesID = task.seriesID ?? UUID()

        var draft = ItemDraft(
            kind: .reminder,
            title: task.title,
            body: task.body,
            tagSlugs: task.tags.map(\.slug),
            parentID: task.parent?.id,
            dueAt: advance.deadlineAt,
            startAt: advance.startAt,
            priority: task.priority,
            source: ItemSource(kind: .generated, identifier: "recurrence")
        )
        draft.id = UUID()

        let next = try items.create(draft)

        try items.update(next) { subject in
            subject.recurrence = rule
            subject.seriesID = seriesID
            subject.occurrenceCount = advance.occurrenceCount
            subject.reminderAt = advance.reminderAt
            subject.reminderIsTimed = task.reminderIsTimed
            subject.reminderOwner = advance.reminderAt == nil ? .none : task.reminderOwner
            subject.sortOrder = task.sortOrder
            // The steps are the point of a repeating task; regenerating them would lose any the user
            // had edited. They come across unticked.
            var checklist = task.checklist
            checklist.reset()
            subject.checklistData = checklist.encoded()
            // A new occurrence is not linked to anything in the system store. The link belongs to
            // the reminder that was completed, and inheriting it would make two tasks claim one
            // reminder — which is how a sync pass starts deleting things.
            subject.setReminderLink(nil)
        }

        // The completed occurrence keeps the series identity too, so history and the live row are
        // found by the same lookup.
        if task.seriesID == nil {
            try items.update(task) { $0.seriesID = seriesID }
        }
        try items.link(next, to: task, kind: .recurrenceSeries)

        return next
    }

    // MARK: - Checklist

    public func addChecklistItem(_ title: String, to task: Item) throws(AppError) {
        try mutate(task) { subject in
            var checklist = subject.checklist
            checklist.append(title)
            subject.checklistData = checklist.encoded()
        }
    }

    public func setChecklistItem(_ id: UUID, completed: Bool, on task: Item) throws(AppError) {
        try mutate(task) { subject in
            var checklist = subject.checklist
            checklist.setCompleted(id, completed, at: self.dateProvider.now)
            subject.checklistData = checklist.encoded()
        }
    }

    public func removeChecklistItem(_ id: UUID, from task: Item) throws(AppError) {
        try mutate(task) { subject in
            var checklist = subject.checklist
            checklist.remove(id)
            subject.checklistData = checklist.encoded()
        }
    }

    public func setChecklist(_ checklist: TaskChecklist, on task: Item) throws(AppError) {
        try mutate(task) { $0.checklistData = checklist.encoded() }
    }

    /// Turns a checklist step into a real subtask.
    ///
    /// Offered, never automatic — see ``TaskChecklist/promotable(_:)``. The step is removed and a
    /// child task takes its place, so nothing is duplicated and the count does not double.
    @discardableResult
    public func promoteChecklistItem(_ id: UUID, of task: Item) throws(AppError) -> Item? {
        var checklist = task.checklist
        guard let step = checklist.items.first(where: { $0.id == id }) else { return nil }

        let subtask = try items.create(
            ItemDraft(kind: .reminder, title: step.title, parentID: task.id)
        )
        if step.isCompleted {
            try mutate(subtask) { subject in
                subject.status = .completed
                subject.completedAt = step.completedAt ?? self.dateProvider.now
            }
        }

        checklist.remove(id)
        try setChecklist(checklist, on: task)
        return subtask
    }

    /// Turns a task that grew into the project it turned out to be.
    ///
    /// ### Why this is a conversion rather than "make a project and move things"
    /// Because the thing being kept is the task's *identity*. Everything pointing at it — a link from
    /// a meeting note, a person's timeline, a mention in somebody's body text, a search result
    /// somebody has open — points at this row, and the manual route (make a project, drag the
    /// subtasks over, delete the task) breaks all of it silently. Changing the kind keeps every one.
    ///
    /// ### What has to happen in order, and why
    /// 1. **Steps become subtasks first.** A project has no checklist, so `ItemValidator.conform`
    ///    would drop them on the floor — and a conversion that silently discards six steps is not one
    ///    anybody would have agreed to. A step is a small action; inside a project a small action is a
    ///    task, which is what it becomes.
    /// 2. **Detach, convert, re-home** — in that order, when the current parent cannot hold a
    ///    project. A project may live under an area or a goal; a task may live under a heading or
    ///    another task. Neither half of the move is legal on its own: moving the task to the area
    ///    first is a *task* under an area, which containment forbids, and changing the kind first is
    ///    a *project* inside a heading, which it also forbids. Going via the top level is the one
    ///    path where every intermediate state is valid, and an unparented task and an unparented
    ///    project are both ordinary things.
    /// 3. **The kind change** clears the fields a project does not have — a reminder, a recurrence —
    ///    and returns their names so the caller can say what went.
    ///
    /// Existing subtasks need no move at all: they are already children, and a project accepts
    /// exactly the children a task does.
    ///
    /// - Returns: the names of the fields that could not come across.
    @discardableResult
    public func convertToProject(_ task: Item) throws(AppError) -> [String] {
        guard task.kind == .task || task.kind == .reminder else { return [] }

        for step in task.checklist.items {
            _ = try promoteChecklistItem(step.id, of: task)
        }

        let parent = task.parent
        let mustMove = parent.map { !$0.kind.canContain(.project) } ?? false
        let home = mustMove ? parent.flatMap { Self.nearestHome(for: .project, above: $0) } : nil

        if mustMove { try items.setParent(task, to: nil) }
        let cleared = try items.setKind(task, to: .project)
        if mustMove, let home { try items.setParent(task, to: home) }

        return cleared
    }

    /// The closest ancestor that may hold `kind`, or `nil` for the top level.
    ///
    /// `nil` is a real answer rather than a failure: an unfiled project is an ordinary thing, and it
    /// is a better outcome than refusing the conversion because the task happened to sit under a
    /// heading.
    private static func nearestHome(for kind: ItemKind, above item: Item) -> Item? {
        var cursor: Item? = item
        while let candidate = cursor {
            if candidate.kind.canContain(kind) { return candidate }
            cursor = candidate.parent
        }
        return nil
    }

    /// Turns a subtask back into a step of its parent.
    ///
    /// The reverse door, because the first conversion is often a mistake and the alternative is a
    /// stray task in Anytime that nobody remembers creating.
    public func demoteToChecklistItem(_ subtask: Item) throws(AppError) {
        guard let parent = subtask.parent, parent.kind.isWorkItem else { return }

        var checklist = parent.checklist
        checklist.items.append(
            ChecklistItem(
                title: subtask.title,
                isCompleted: subtask.status == .completed,
                completedAt: subtask.completedAt
            )
        )
        try setChecklist(checklist, on: parent)
        try items.moveToTrash(subtask)
    }

    // MARK: - Structure

    /// Makes a task a subtask of the one above it.
    ///
    /// Returns whether anything moved, so a keyboard handler can decline the event rather than
    /// consuming a Tab that did nothing.
    @discardableResult
    public func indent(_ task: Item, under predecessor: Item?) throws(AppError) -> Bool {
        guard let predecessor, predecessor.id != task.id else { return false }
        guard predecessor.kind.canContain(task.kind) else { return false }
        // A task cannot become its own descendant's child; `ItemValidator` would refuse the save,
        // and refusing here means the user gets nothing rather than an error sheet.
        guard !predecessor.ancestors().contains(where: { $0.id == task.id }) else { return false }

        try items.setParent(task, to: predecessor)
        return true
    }

    /// Lifts a subtask up one level.
    @discardableResult
    public func outdent(_ task: Item) throws(AppError) -> Bool {
        guard let parent = task.parent, parent.kind.isWorkItem else { return false }
        try items.setParent(task, to: parent.parent)
        return true
    }

    // MARK: - Reading

    /// The scheduling facts for one task.
    public func facts(for task: Item) -> TaskFacts {
        task.taskFacts()
    }

    /// Whether this task is on today's plan, according to the injected clock.
    public func isCommittedToToday(_ task: Item) -> Bool {
        task.isCommittedTo(today: dateProvider)
    }
}

// MARK: - Convenience

extension Item {
    /// Whether the task is on today's plan.
    ///
    /// On `Item` rather than only on `TaskFacts` so a row can ask without building a whole snapshot
    /// — which, in a list of five hundred, is five hundred traversals for one Boolean.
    public func isCommittedTo(today dateProvider: any DateProvider) -> Bool {
        guard let todayCommittedOn else { return false }
        return dateProvider.calendar.startOfDay(for: todayCommittedOn) <= dateProvider.startOfToday
    }
}

extension TaskFacts {
    /// The next occurrence's dates, or `nil` when there is no rule or the series has ended.
    fileprivate func recurrenceAdvance(
        rule: RecurrenceRule?,
        completedAt: Date,
        occurrencesSoFar: Int,
        calendar: Calendar
    ) -> RecurrenceAdvance? {
        guard let rule else { return nil }
        return TaskRecurrence.advance(
            self,
            rule: rule,
            completedAt: completedAt,
            occurrencesSoFar: occurrencesSoFar,
            calendar: calendar
        )
    }
}
