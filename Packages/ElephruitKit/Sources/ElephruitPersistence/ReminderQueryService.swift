import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// One block of a reminder query, with the heading it sits under.
///
/// Sections are computed here rather than in a view because "which section is this in?" is the
/// scheduling model's question, and a view that answered it would be a second, quieter copy of
/// ``TaskViewRules``.
public struct TaskSectionGroup: Identifiable, Sendable {
    public enum Heading: Sendable, Hashable {
        case today(TodaySection)
        /// A container — an area, a project, or a list.
        case container(id: UUID, title: String, symbolName: String, colorName: String?)
        /// Work filed nowhere.
        case unfiled
        /// A day, for the log.
        case day(Date)
        /// No heading at all; the list is flat.
        case none

        public var title: String {
            switch self {
            case .today(let section): section.title
            case .container(_, let title, _, _): title
            case .unfiled: "No project"
            case .day: ""
            case .none: ""
            }
        }
    }

    public var heading: Heading
    public var taskIDs: [UUID]

    public var id: String {
        switch heading {
        case .today(let section): "today-\(section.rawValue)"
        case .container(let id, _, _, _): "container-\(id.uuidString)"
        case .unfiled: "unfiled"
        case .day(let date): "day-\(date.timeIntervalSinceReferenceDate)"
        case .none: "flat"
        }
    }

    public init(heading: Heading, taskIDs: [UUID]) {
        self.heading = heading
        self.taskIDs = taskIDs
    }
}

/// Builds every system view from the store.
///
/// ### Why one fetch and then Swift
/// The store-side predicate has a hard practical ceiling — see ``ItemPredicateBuilder`` — and none
/// of the scheduling rules translate to SQL: they compare a start date against *today* in the user's
/// calendar, they read a commitment made on an earlier day, and they consult a lifecycle that is
/// derived from four columns and a traversal.
///
/// So the split is the one ``ItemQuery`` already established. The predicate carries what eliminates
/// the most rows and always applies — kind, status, scope — and the rules run in Swift over what
/// comes back, where every one of them is directly testable and none can fail at runtime the way an
/// untranslatable predicate would.
///
/// For a single person's library that is thousands of rows, not millions. The escalation path if it
/// ever matters is the derived index in ADR 0004, not a bigger predicate.
@MainActor
public final class ReminderQueryService {
    private let items: any ItemRepository
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, context: ModelContext, dateProvider: any DateProvider) {
        self.items = items
        self.context = context
        self.dateProvider = dateProvider
    }

    private var calendar: Calendar { dateProvider.calendar }
    private var now: Date { dateProvider.now }

    // MARK: - Source rows

    /// Every open task, including subtasks.
    private func openTasks() throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = [.open]
        query.sort = .manual
        return try items.items(matching: query)
    }

    /// Finished and abandoned tasks, newest first.
    private func resolvedTasks(limit: Int) throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = [.completed, .cancelled]
        query.sort = .updatedNewestFirst
        query.limit = limit
        return try items.items(matching: query)
    }

    // MARK: - The system views

    /// Everything that belongs to a system view, in the order it should be drawn.
    public func tasks(in view: TaskSystemView) throws(AppError) -> [Item] {
        switch view {
        case .completed:
            return try resolvedTasks(limit: 500)

        case .all:
            var query = ItemQuery()
            query.kinds = ItemKind.workItemKindSet
            query.sort = .manual
            return try items.items(matching: query)

        default:
            let open = try openTasks()
            return open.filter { belongs($0, to: view) }
        }
    }

    private func belongs(_ task: Item, to view: TaskSystemView) -> Bool {
        let facts = task.taskFacts()

        switch view {
        case .inbox: return TaskViewRules.isInInbox(facts)
        case .today: return TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) != nil
        case .anytime: return TaskViewRules.isInAnytime(facts, now: now, calendar: calendar)
        case .someday: return TaskViewRules.isInSomeday(facts)
        case .flagged: return TaskViewRules.isInFlagged(facts)
        case .waiting: return TaskViewRules.isInWaiting(facts)
        case .completed: return TaskViewRules.isInCompleted(facts)
        case .upcoming:
            return !TaskViewRules.upcomingEntries(
                for: facts,
                in: dateProvider.startOfTomorrow..<dateProvider.startOfDay(daysFromToday: 400),
                calendar: calendar
            ).isEmpty
        case .all:
            return true
        }
    }

    // MARK: - Everything a workspace needs, once

    /// A system view's grouping and its tasks, from one pass over the library.
    ///
    /// A workspace needs both: the grouping to draw the sections, and the flat list to act on a
    /// selection and to say how many there are.
    ///
    /// Not `Sendable`, and cannot be: it holds `Item`, which belongs to the main actor's context.
    /// That is the same boundary every other answer from this service respects.
    public struct Contents {
        /// The sections, for the views that have them.
        public var sections: [TaskSectionGroup] = []

        /// The agenda bands. Upcoming only, which groups by date rather than by heading.
        public var agenda: [AgendaGroup] = []

        /// Every task the view names.
        public var tasks: [Item] = []
    }

    /// Everything a reminder destination needs for one query.
    ///
    /// ### Why this exists rather than two calls
    /// Because it was two calls. The workspace asked `today()` for the sections and then
    /// `tasks(in: .today)` for the flat list, and each of those fetches every open task and runs the
    /// scheduling rules over all of it — so arriving in the module traversed the library twice to
    /// answer one question. At five thousand open tasks that is about seven hundred milliseconds of
    /// blocked main thread; at a few hundred, which is a heavy real library, it is the difference
    /// between two dropped frames and four.
    ///
    /// One fetch, and the flat list comes out of the grouping that was just built rather than being
    /// derived a second time from scratch. Where a view's flat list is genuinely a different
    /// question from its grouping — Upcoming asks over a longer window than the agenda shows, the
    /// log lists tasks it has no day to file under — the second question is still asked, but of the
    /// rows already in hand.
    public func contents(of view: TaskSystemView) throws(AppError) -> Contents {
        switch view {
        case .today:
            let open = try openTasks()
            let sections = todaySections(from: open)
            return Contents(sections: sections, tasks: tasks(named: sections, from: open))

        case .anytime:
            let open = try openTasks()
            let sections = anytimeSections(from: open)
            return Contents(sections: sections, tasks: tasks(named: sections, from: open))

        case .someday:
            let open = try openTasks()
            let sections = somedaySections(from: open)
            return Contents(sections: sections, tasks: tasks(named: sections, from: open))

        case .upcoming:
            let open = try openTasks()
            return Contents(
                agenda: upcomingGroups(from: open, days: 120, horizon: .standard),
                // Not the agenda's own window: an agenda shows four months and the list is every
                // dated obligation there is. Two questions, one fetch.
                tasks: open.filter { belongs($0, to: .upcoming) }
            )

        case .completed:
            // The flat list is every resolved task; the sections skip any that carry no date to be
            // filed under, so it cannot be derived from them.
            let resolved = try resolvedTasks(limit: 500)
            return Contents(sections: logbookSections(from: resolved), tasks: resolved)

        case .inbox, .flagged, .waiting, .all:
            let tasks = try self.tasks(in: view)
            return Contents(
                sections: [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))],
                tasks: tasks
            )
        }
    }

    /// The tasks a set of sections names, in the order the sections name them.
    private func tasks(named sections: [TaskSectionGroup], from pool: [Item]) -> [Item] {
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sections.flatMap(\.taskIDs).compactMap { byID[$0] }
    }

    /// The two counts the sidebar shows.
    ///
    /// Only two, deliberately. A number beside every destination turns a sidebar into a scoreboard.
    public func badgeCount(for view: TaskSystemView) throws(AppError) -> Int? {
        guard view.showsCount else { return nil }
        return try tasks(in: view).count
    }

    /// Every badge the sidebar shows, from **one** pass over the open tasks.
    ///
    /// The sidebar recomputes its badges after every save. Asking ``badgeCount(for:)`` per view
    /// fetched and materialised every open task once *per badge* — the fetch is two-thirds of the
    /// cost of any of these questions, so two badges cost double what they needed to. One fetch,
    /// the same ``belongs(_:to:)`` rule per view over the same rows, identical answers.
    public func badgeCounts() throws(AppError) -> [TaskSystemView: Int] {
        let open = try openTasks()
        var result: [TaskSystemView: Int] = [:]
        for view in TaskSystemView.allCases where view.showsCount {
            result[view] = open.count { belongs($0, to: view) }
        }
        return result
    }

    /// How many linked tasks are waiting for the user to decide something.
    ///
    /// A store-side count. This was a `TaskFilter` pass, which fetched and materialised **every**
    /// work item including resolved ones — after every save, for a number that is almost always
    /// zero. The predicate reads the same column the facts do, and
    /// `TaskSidebarModelTests` holds the two answers equal across every sync state.
    public func syncAttentionCount() -> Int {
        let descriptor = FetchDescriptor<Item>(
            predicate: CountPredicates.syncAttention(
                workItemKindRaws: ItemKind.workItemKinds.map(\.rawValue),
                attentionStateRaws: TaskSyncState.allCases.filter(\.needsAttention).map(\.rawValue)
            )
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Today

    /// Today, in its three sections.
    ///
    /// Overdue is ordered by how late it is, oldest first — the thing you most need to deal with is
    /// the thing you have been avoiding longest. The plan is in the user's own order, which is
    /// ``Item/todayOrder`` and not the order of any project.
    public func today() throws(AppError) -> [TaskSectionGroup] {
        todaySections(from: try openTasks())
    }

    private func todaySections(from open: [Item]) -> [TaskSectionGroup] {
        var buckets: [TodaySection: [Item]] = [:]

        for task in open {
            let facts = task.taskFacts()
            guard let section = TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) else {
                continue
            }
            buckets[section, default: []].append(task)
        }

        return TodaySection.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { section in
                guard let tasks = buckets[section], !tasks.isEmpty else { return nil }
                let ordered = section == .overdue
                    ? tasks.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
                    : tasks.sorted { lhs, rhs in
                        lhs.todayOrder == rhs.todayOrder
                            ? lhs.sortOrder < rhs.sortOrder
                            : lhs.todayOrder < rhs.todayOrder
                    }
                return TaskSectionGroup(heading: .today(section), taskIDs: ordered.map(\.id))
            }
    }

    /// What a planning session should offer to pull in.
    ///
    /// Available work, **not** already committed, ordered by how much the day is asking for it: a
    /// deadline this week first, then flagged work, then whatever has been waiting longest.
    ///
    /// Bounded. An unbounded "everything you could do" is the pile the user opened Today to escape.
    public func todaySuggestions(limit: Int = 12) throws(AppError) -> [Item] {
        let open = try openTasks()

        let candidates = open.filter { task in
            let facts = task.taskFacts()
            guard TaskViewRules.isInAnytime(facts, now: now, calendar: calendar) else { return false }
            return TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil
        }

        return Array(
            candidates
                .sorted { lhs, rhs in
                    let left = weight(lhs)
                    let right = weight(rhs)
                    return left == right ? lhs.updatedAt < rhs.updatedAt : left > right
                }
                .prefix(limit)
        )
    }

    /// How strongly a task asks to be picked today. Ranking only — never shown as a number.
    ///
    /// A visible score would be a productivity metric, which this app does not have. This exists so
    /// that the twelve suggestions are the twelve worth suggesting rather than the twelve most
    /// recently touched.
    private func weight(_ task: Item) -> Int {
        var score = 0
        let facts = task.taskFacts()

        switch facts.deadlineUrgency(on: now, calendar: calendar) {
        case .overdue: score += 100
        case .today: score += 80
        case .soon(let days): score += max(0, 60 - days * 5)
        case .distant: score += 5
        case .none: break
        }

        if facts.isFlagged { score += 30 }
        if facts.priority == .high { score += 20 }
        if facts.startAt != nil { score += 10 }

        return score
    }

    // MARK: - Anytime

    /// Available work, grouped by where it lives.
    ///
    /// Manual order is preserved inside every group, because the order of a project's steps is
    /// information and re-sorting it by date would throw that away.
    public func anytime() throws(AppError) -> [TaskSectionGroup] {
        anytimeSections(from: try openTasks())
    }

    private func anytimeSections(from open: [Item]) -> [TaskSectionGroup] {
        let available = open.filter {
            TaskViewRules.isInAnytime($0.taskFacts(), now: now, calendar: calendar)
        }
        return groupByContainer(available)
    }

    /// Parked work.
    public func someday() throws(AppError) -> [TaskSectionGroup] {
        somedaySections(from: try openTasks())
    }

    private func somedaySections(from open: [Item]) -> [TaskSectionGroup] {
        groupByContainer(open.filter { $0.isSomeday })
    }

    // MARK: - Upcoming

    /// Every dated obligation in the window, as agenda bands.
    ///
    /// - Parameter days: How far ahead to look. Beyond this the agenda would be mostly empty bands.
    public func upcoming(days: Int = 120, horizon: AgendaHorizon = .standard) throws(AppError) -> [AgendaGroup] {
        upcomingGroups(from: try openTasks(), days: days, horizon: horizon)
    }

    private func upcomingGroups(
        from open: [Item],
        days: Int,
        horizon: AgendaHorizon
    ) -> [AgendaGroup] {
        let window = dateProvider.startOfToday..<dateProvider.startOfDay(daysFromToday: days)

        let entries = open.flatMap {
            TaskViewRules.upcomingEntries(for: $0.taskFacts(), in: window, calendar: calendar)
        }

        return UpcomingAgenda.groups(from: entries, startingAt: now, horizon: horizon, calendar: calendar)
    }

    // MARK: - The log

    /// Finished and abandoned work, grouped by the day it was resolved.
    public func logbook(limit: Int = 500) throws(AppError) -> [TaskSectionGroup] {
        logbookSections(from: try resolvedTasks(limit: limit))
    }

    private func logbookSections(from resolved: [Item]) -> [TaskSectionGroup] {
        var byDay: [Date: [Item]] = [:]
        for task in resolved {
            guard let stamp = task.completedAt ?? task.cancelledAt else { continue }
            byDay[calendar.startOfDay(for: stamp), default: []].append(task)
        }

        return byDay
            .sorted { $0.key > $1.key }
            .map { day, tasks in
                let ordered = tasks.sorted {
                    ($0.completedAt ?? $0.cancelledAt ?? day) > ($1.completedAt ?? $1.cancelledAt ?? day)
                }
                return TaskSectionGroup(heading: .day(day), taskIDs: ordered.map(\.id))
            }
    }

    // MARK: - Smart lists

    /// Everything matching a filter.
    ///
    /// Membership is computed; a task remains owned by its area, project, or list. Nothing here
    /// moves anything.
    public func tasks(matching filter: TaskFilter) throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = filter.includesResolved ? [] : [.open]
        query.sort = .manual

        let candidates = try items.items(matching: query)
        return candidates.filter { filter.matches($0.taskFacts(), now: now, calendar: calendar) }
    }

    /// The saved smart lists, in sidebar order.
    public func smartLists() -> [SavedSearch] {
        let descriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil && $0.taskFilterData != nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Grouping

    /// Groups by the most specific *named* container above each task.
    ///
    /// A section is scaffolding inside a project, so a task in one is still shown under the project:
    /// grouping by heading would scatter one project across four groups in a list that is not that
    /// project.
    private func groupByContainer(_ tasks: [Item]) -> [TaskSectionGroup] {
        var order: [UUID?] = []
        var buckets: [UUID?: (heading: TaskSectionGroup.Heading, tasks: [Item])] = [:]

        for task in tasks {
            let containers = task.enclosingContainers()
            let owner = containers.project ?? containers.list ?? containers.area
            let key = owner?.id

            if buckets[key] == nil {
                order.append(key)
                let heading: TaskSectionGroup.Heading = owner.map {
                    .container(
                        id: $0.id,
                        title: $0.displayTitle,
                        symbolName: $0.effectiveSymbolName,
                        colorName: $0.colorName
                    )
                } ?? .unfiled
                buckets[key] = (heading, [])
            }
            buckets[key]?.tasks.append(task)
        }

        // Unfiled last: it is the leftovers, and putting it first makes every list open on the part
        // the user has not organised.
        return order
            .sorted { lhs, rhs in
                if (lhs == nil) != (rhs == nil) { return rhs == nil }
                return false
            }
            .compactMap { key in
                guard let bucket = buckets[key] else { return nil }
                let ordered = bucket.tasks.sorted { $0.sortOrder < $1.sortOrder }
                return TaskSectionGroup(heading: bucket.heading, taskIDs: ordered.map(\.id))
            }
    }
}
