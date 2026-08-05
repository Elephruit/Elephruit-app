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
/// it are pure values; the rows that draw them need the `Item`. The assembler has already read every
/// one of them, so it hands them back with the days — see ``DailyPlanService/DayWindow`` — and the
/// page never looks anything up.
@Observable
@MainActor
public final class TodayModel {
    // MARK: What the reader has asked for

    /// The day with the strongest emphasis. Not persisted — see ``TodayPreferences``.
    public private(set) var selectedDate: Date

    /// The task whose "Pick a Date…" calendar is open, if any. One at a time — two open
    /// calendars would both answer the next click.
    public var datePickerTaskID: UUID?

    /// Whether the days before the selected one are on screen.
    ///
    /// Off by default and behind a deliberate control. Yesterday is not a plan; it is a record, and
    /// putting it above today means opening the app and reading what you already did.
    public private(set) var isShowingPreviousDays = false

    /// How many days after the selected one are drawn compactly.
    public private(set) var futureDayCount = TodayModel.initialFutureDayCount

    /// Future days the reader has opened out.
    public private(set) var expandedDays: Set<Date> = []

    /// The one calendar row whose details are open. Kept on the page model rather than on each row
    /// so expanding one event closes the previous one and scrolling cannot create a stack of editors.
    public private(set) var expandedEventID: String?

    public static let initialFutureDayCount = 4
    static let previousDayCount = 3
    public static let dayLoadIncrement = 7

    /// How far ahead the window is ever allowed to reach.
    ///
    /// A feed that pages on scroll has no button to stop pressing, so the ceiling has to live here
    /// rather than in the finger. Every extension re-reads the calendar for the *whole* span and
    /// rebuilds every day in it, so an unbounded window is a page that gets slower the longer
    /// somebody looks at it. Three months is past the horizon anybody plans against on a phone,
    /// and it is a span EventKit answers for without complaint.
    public static let maximumFutureDayCount = 90

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

    public func toggleEventDetails(_ eventID: String) {
        expandedEventID = expandedEventID == eventID ? nil : eventID
    }

    public func collapseEventDetails() {
        expandedEventID = nil
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
        expandedEventID = nil
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

    /// Whether there is any more future to ask for.
    public var canLoadMoreDays: Bool {
        futureDayCount < Self.maximumFutureDayCount
    }

    /// Whether a bigger window has been asked for and not yet drawn.
    ///
    /// Read from the days themselves rather than kept as a flag, because a flag has to be cleared
    /// on every path that can end an assembly — including the ones that fail, and the ones where
    /// the reader moved a day mid-flight — and a flag left set is a feed that stops paging.
    public var isExtendingFuture: Bool {
        followingDays.count < futureDayCount
    }

    public func loadMoreDays() {
        guard canLoadMoreDays else { return }
        futureDayCount = min(Self.maximumFutureDayCount, futureDayCount + Self.dayLoadIncrement)
    }

    /// Ask for another week, if the last week asked for has arrived.
    ///
    /// What a scroll calls. The scroll position changes many times a second near the bottom of the
    /// page and every one of them would otherwise be another week — the whole window would be
    /// requested in the time it takes to lift a thumb, and each request re-reads the calendar for a
    /// span that is about to be replaced.
    public func extendFuture() {
        guard !isExtendingFuture else { return }
        loadMoreDays()
    }

    // MARK: - Assembly

    /// What the page is *looking at*.
    ///
    /// ### Why this is separate from what it is looking at *with*
    /// Because reading the calendar and assembling a day are different operations with different
    /// costs, and mixing them made a loop. Today reloads when the calendar answers; loading the
    /// calendar makes it answer. One token driving both meant load, answer, invalidate, load — for
    /// as long as the page was on screen, which is what made a five-day window take seconds and made
    /// toggling a filter take seconds more.
    ///
    /// So the window drives the *load* and nothing else does. It changes when the reader moves a
    /// day, opens the days behind them, or asks for another week — which are the only things that
    /// change *which dates* the calendar is being asked about.
    ///
    /// The filters are deliberately **not** here. Hiding meetings does not change which days are on
    /// screen, so it has no business making the app read a calendar again; it used to, and that is
    /// most of why unticking and reticking a filter cost seconds rather than nothing.
    public struct WindowToken: Equatable {
        var date: Date
        var showsPrevious: Bool
        var futureCount: Int
        var calendarIsEnabled: Bool
    }

    public var windowToken: WindowToken {
        WindowToken(
            date: selectedDate,
            showsPrevious: isShowingPreviousDays,
            futureCount: futureDayCount,
            calendarIsEnabled: services.calendar.isEnabled
        )
    }

    /// What the page is looking at it *with*: the library, and whatever the calendar last answered.
    ///
    /// Drives ``assemble()``, which reads what is already in memory and never loads. That is what
    /// closes the loop — nothing this token watches can be changed by reacting to it.
    public struct SourceToken: Equatable {
        var changeToken: Int
        var calendarRevision: Int
        var filters: TodayFilters
    }

    public var sourceToken: SourceToken {
        SourceToken(
            changeToken: services.changeToken,
            calendarRevision: services.calendar.revision,
            filters: services.todayPreferences.filters
        )
    }

    /// Assembles the window — immediately when the calendar can already answer for it, and again
    /// once it has been re-read.
    ///
    /// Asynchronous because the calendar is, and only because the calendar is. The window is loaded
    /// once for the whole span and each day is then built from what is in memory — one round trip
    /// rather than one per day drawn.
    ///
    /// ### Why it assembles before the round trip when it can
    /// Because the calendar and the assembler both outlive this page. On every visit after the
    /// first, the events for the window and the library pass are already in memory, and making the
    /// page wait for EventKit to confirm what it already knows was the difference between Today
    /// opening instantly and Today opening behind a spinner every single time. The early assembly
    /// is skipped only for a window the calendar has never answered for — where drawing at once
    /// would tell somebody their day is clear before it has been read, which is the one thing this
    /// page must never do.
    ///
    /// The reload after the round trip is then usually free: ``assemble(force:)`` compares its
    /// tokens, and a calendar that answered the same thing bumps no revision.
    public func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration

        let first = firstVisibleDay
        let count = visibleDayCount
        guard let last = calendar.date(byAdding: .day, value: count - 1, to: first) else { return }

        if services.dailyPlan.canAnswerForCalendar(from: first, through: last) {
            assemble()
        }

        await services.dailyPlan.loadCalendar(from: first, through: last)

        // A second reload started while the calendar was loading — the reader stepped a day, or
        // ticked something off. Its answer is the current one; this one would overwrite it with
        // stale days.
        guard generation == reloadGeneration else { return }

        assemble()
    }

    /// Rebuilds the days from what is already in memory.
    ///
    /// Synchronous, and touches no integration. Called when the library changes and when the
    /// calendar reports a *different* answer — never in a way that could ask the calendar again.
    /// How many times the days have been rebuilt. Read by a test; nothing else has any use for it.
    public private(set) var assemblyCount = 0

    /// What the last assembly was true of, so an identical one is free rather than merely fast.
    ///
    /// SwiftUI is entitled to re-run a `task(id:)` or an `onChange` more than once for what a person
    /// experienced as one click, and an assembly that costs a fetch is not something to do twice on
    /// spec.
    @ObservationIgnored private var lastAssembled: (window: WindowToken, source: SourceToken)?

    public func assemble(force: Bool = false) {
        let tokens = (window: windowToken, source: sourceToken)
        if !force, let last = lastAssembled, last.window == tokens.window, last.source == tokens.source {
            return
        }
        lastAssembled = tokens
        assemblyCount &+= 1

        // The per-assembly caches exist to stop one pass reading the same person four times. Keeping
        // them across an assembly would mean an edit to somebody's role never appearing. The
        // *library* pass is not thrown away — it is keyed on the counters that say the records moved.
        services.dailyPlan.invalidateCaches()

        do {
            let window = try services.dailyPlan.window(
                from: firstVisibleDay,
                count: visibleDayCount,
                filters: services.todayPreferences.filters
            )
            days = window.days
            if let expandedEventID,
               !window.days.flatMap(\.events).contains(where: { $0.id == expandedEventID }) {
                self.expandedEventID = nil
            }
            tasksByID = window.tasks
            peopleByID = window.people
            activeContainers = window.containers
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
