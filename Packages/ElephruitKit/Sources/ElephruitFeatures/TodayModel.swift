import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// What Today is currently showing, and everything it needs to draw it.
///
/// ### Why a model rather than state on the view
/// Because the page reads the library and the page is redrawn constantly — a hover, a scroll, a
/// window resize. Every fetch has to happen on change and none during a render; that is the standing
/// rule `FetchAudit` enforces, and a view holding `@State` arrays is exactly how it gets broken. So
/// the assembly happens here, once, and the view reads stored values.
///
/// It also holds the *records*. A day plan names tasks by identifier, because the rules that produced
/// it are pure values; the rows that draw them need the `Item`. Materialising them once per reload,
/// into a dictionary, is the difference between one traversal and one fetch per visible row.
@Observable
@MainActor
public final class TodayModel {
    // MARK: What the reader has asked for

    /// The day with the strongest emphasis. Not persisted — see ``TodayPreferences``.
    public private(set) var selectedDate: Date

    /// Whether the days before the selected one are on screen.
    ///
    /// Off by default and behind a deliberate control. Yesterday is not a plan; it is a record, and
    /// putting it above today means opening the app and reading what you already did.
    public private(set) var isShowingPreviousDays = false

    /// How many days after the selected one are drawn compactly.
    public private(set) var futureDayCount = TodayModel.initialFutureDayCount

    /// Future days the reader has opened out.
    public private(set) var expandedDays: Set<Date> = []

    static let initialFutureDayCount = 4
    static let previousDayCount = 3
    static let dayLoadIncrement = 7

    // MARK: What it found

    public private(set) var days: [DayPlan] = []
    public private(set) var tasksByID: [UUID: Item] = [:]
    public private(set) var peopleByID: [UUID: Item] = [:]

    /// The projects and lists the visible days actually draw work from, for the filter menu.
    ///
    /// Computed here rather than in the menu because a menu's contents are built during a render,
    /// and a list of every project in the library is both a scroll pit and a fetch in the wrong
    /// place. Anything already hidden stays in the list whether or not it contributed this time —
    /// a switch you cannot find again is a switch that has trapped you.
    public private(set) var activeContainers: [Item] = []

    /// True only while the *first* assembly is running.
    ///
    /// A reload triggered by ticking something off must not blank the page — the row the user just
    /// touched would vanish and come back, which reads as the app having lost it.
    public private(set) var isLoadingInitially = true

    /// The last failure, shown in place rather than as an alert.
    ///
    /// A day that could not be assembled is a page-shaped problem, and a modal over an empty page
    /// leaves somebody with nothing behind it to look at.
    public private(set) var failure: AppError?

    // MARK: Wiring

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var reloadGeneration = 0

    public init(services: AppServices) {
        self.services = services
        self.selectedDate = services.dateProvider.startOfToday
    }

    private var calendar: Calendar { services.dateProvider.calendar }
    private var today: Date { services.dateProvider.startOfToday }

    public var isOnToday: Bool { calendar.isDate(selectedDate, inSameDayAs: today) }

    /// The plan for the day with the emphasis, if it has been assembled.
    public var selectedPlan: DayPlan? {
        days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// The days before the selected one, oldest first. Empty unless the reader asked for them.
    public var previousDays: [DayPlan] {
        days.filter { $0.date < selectedDate }
    }

    /// The days after the selected one, in order.
    public var followingDays: [DayPlan] {
        days.filter { $0.date > selectedDate }
    }

    public func isExpanded(_ plan: DayPlan) -> Bool {
        expandedDays.contains(plan.date)
    }

    public func toggleExpanded(_ plan: DayPlan) {
        if expandedDays.contains(plan.date) {
            expandedDays.remove(plan.date)
        } else {
            expandedDays.insert(plan.date)
        }
    }

    // MARK: - Moving between days

    public func select(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard !calendar.isDate(day, inSameDayAs: selectedDate) else { return }
        selectedDate = day
        // The window travels with the selection, so the days after it are the days after *it* rather
        // than the days after wherever the page was opened.
        futureDayCount = Self.initialFutureDayCount
        expandedDays = []
    }

    public func step(days count: Int) {
        guard let moved = calendar.date(byAdding: .day, value: count, to: selectedDate) else { return }
        select(moved)
    }

    public func returnToToday() {
        select(today)
        isShowingPreviousDays = false
    }

    public func showPreviousDays() {
        isShowingPreviousDays = true
    }

    public func hidePreviousDays() {
        isShowingPreviousDays = false
    }

    public func loadMoreDays() {
        futureDayCount += Self.dayLoadIncrement
    }

    // MARK: - Assembly

    /// Everything a reload depends on.
    ///
    /// A value rather than a list of `onChange` handlers, so a new dependency is one line here and
    /// cannot be added to the model without also being watched.
    public struct ReloadToken: Equatable {
        var date: Date
        var showsPrevious: Bool
        var futureCount: Int
        var filters: TodayFilters
        var changeToken: Int
        var calendarIsEnabled: Bool
        var calendarRevision: Int
    }

    public var reloadToken: ReloadToken {
        ReloadToken(
            date: selectedDate,
            showsPrevious: isShowingPreviousDays,
            futureCount: futureDayCount,
            filters: services.todayPreferences.filters,
            changeToken: services.changeToken,
            calendarIsEnabled: services.calendar.isEnabled,
            calendarRevision: services.calendar.revision
        )
    }

    /// Assembles every day on screen.
    ///
    /// Asynchronous because the calendar is, and only because the calendar is. The window is loaded
    /// once for the whole span and each day is then assembled from what is in memory — one round
    /// trip rather than one per day drawn.
    public func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration

        let first = firstVisibleDay
        let count = visibleDayCount
        guard let last = calendar.date(byAdding: .day, value: count - 1, to: first) else { return }

        await services.dailyPlan.loadCalendar(from: first, through: last)

        // A second reload started while the calendar was loading — the reader stepped a day, or
        // ticked something off. Its answer is the current one; this one would overwrite it with
        // stale days.
        guard generation == reloadGeneration else { return }

        // The per-assembly caches exist to stop one pass reading the same person four times. Keeping
        // them across a reload would mean an edit to somebody's role never appearing.
        services.dailyPlan.invalidateCaches()

        do {
            let assembled = try services.dailyPlan.plans(
                from: first,
                count: count,
                filters: services.todayPreferences.filters
            )
            days = assembled
            materialiseRecords(for: assembled)
            failure = nil
        } catch {
            failure = error
        }

        isLoadingInitially = false
    }

    private var firstVisibleDay: Date {
        guard isShowingPreviousDays,
              let earlier = calendar.date(byAdding: .day, value: -Self.previousDayCount, to: selectedDate)
        else { return selectedDate }
        return earlier
    }

    private var visibleDayCount: Int {
        (isShowingPreviousDays ? Self.previousDayCount : 0) + 1 + futureDayCount
    }

    /// Fetches the records the rows will need, once.
    ///
    /// ### Why this is a dictionary and not a lookup
    /// A row asking the repository for its own task is a fetch during a render, which is the thing
    /// `FetchAudit` fails a build over — and at forty rows across five days it is forty fetches per
    /// frame of a scroll. Everything the visible days name is read here, on change, and the rows
    /// read a dictionary.
    private func materialiseRecords(for plans: [DayPlan]) {
        var wantedTasks = Set<UUID>()
        var wantedPeople = Set<UUID>()

        for plan in plans {
            for task in plan.tasks { wantedTasks.insert(task.taskID) }
            wantedTasks.formUnion(plan.completedTaskIDs)
            for event in plan.events {
                wantedTasks.formUnion(event.preparation.openPreparationTaskIDs)
            }
            for person in plan.people {
                if let id = person.personID { wantedPeople.insert(id) }
            }
        }

        var tasks: [UUID: Item] = [:]
        for id in wantedTasks {
            // Reuse what is already in hand: SwiftData returns the same registered object, so this
            // saves the round trip rather than the object.
            if let existing = tasksByID[id], existing.deletedAt == nil {
                tasks[id] = existing
                continue
            }
            if let fetched = try? services.items.item(id: id) { tasks[id] = fetched }
        }

        var people: [UUID: Item] = [:]
        for id in wantedPeople {
            if let existing = peopleByID[id], existing.deletedAt == nil {
                people[id] = existing
                continue
            }
            if let fetched = try? services.items.item(id: id) { people[id] = fetched }
        }

        tasksByID = tasks
        peopleByID = people
        activeContainers = containers(among: tasks.values)
    }

    private func containers(among tasks: some Collection<Item>) -> [Item] {
        var found: [UUID: Item] = [:]

        for id in services.todayPreferences.filters.hiddenContainerIDs {
            if let item = try? services.items.item(id: id) { found[id] = item }
        }
        for task in tasks {
            let enclosing = task.enclosingContainers()
            guard let container = enclosing.project ?? enclosing.list else { continue }
            found[container.id] = container
        }

        return found.values.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    // MARK: - Reading records

    public func task(_ id: UUID) -> Item? { tasksByID[id] }
    public func person(_ id: UUID?) -> Item? { id.flatMap { peopleByID[$0] } }

    /// Open tasks for a day, in the order the rules put them.
    public func openTasks(in plan: DayPlan) -> [(day: DayTask, item: Item)] {
        plan.tasks.compactMap { day in
            guard let item = tasksByID[day.taskID] else { return nil }
            return (day: day, item: item)
        }
    }

    public func completedTasks(in plan: DayPlan) -> [Item] {
        plan.completedTaskIDs.compactMap { tasksByID[$0] }
    }
}
