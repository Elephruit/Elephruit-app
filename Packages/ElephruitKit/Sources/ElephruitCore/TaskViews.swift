import Foundation

/// The system views a task can appear in.
///
/// Declared as a type rather than left implicit in a sidebar array so that "what does Anytime mean?"
/// has exactly one answer, and that answer is a function this file tests.
public enum TaskSystemView: String, Sendable, Hashable, CaseIterable, Codable {
    case inbox
    case today
    case upcoming
    case anytime
    case someday
    case flagged
    case waiting
    case completed
    case all

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .flagged: "Flagged"
        case .waiting: "Waiting"
        case .completed: "Logbook"
        case .all: "All Tasks"
        }
    }

    public var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .today: "circle.circle"
        case .upcoming: "calendar"
        case .anytime: "square.stack"
        case .someday: "archivebox"
        case .flagged: "flag"
        case .waiting: "hourglass"
        case .completed: "checkmark.seal"
        case .all: "list.bullet"
        }
    }

    /// What the view holds, for a tooltip. Never a restatement of the title — see
    /// ``SidebarDestination/hint`` for the rule.
    public var hint: String {
        switch self {
        case .inbox: "Captured, and not yet given a home."
        case .today: "What you chose for today, plus what today asks for."
        case .upcoming: "Dated work, by the day it arrives."
        case .anytime: "Everything you could pick up right now."
        case .someday: "Parked on purpose. Nothing here is late."
        case .flagged: "Marked as worth coming back to."
        case .waiting: "Somebody else has the next move."
        case .completed: "What you finished, and what you decided not to."
        case .all: "Every task, however it is filed."
        }
    }

    /// Whether the badge beside this view is worth showing.
    ///
    /// Only two. A number beside every destination turns a sidebar into a scoreboard, and a
    /// scoreboard is the thing this app is explicitly not.
    public var showsCount: Bool {
        self == .inbox || self == .today
    }
}

/// Which part of Today a task belongs in.
public enum TodaySection: String, Sendable, Hashable, CaseIterable, Codable {
    /// Past its deadline. Shown, and shown calmly.
    case overdue

    /// The plan.
    case today

    /// Deliberately pushed to the back half of the day.
    case laterToday

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .laterToday: "Later Today"
        }
    }

    /// Display order.
    public var rank: Int {
        switch self {
        case .overdue: 0
        case .today: 1
        case .laterToday: 2
        }
    }
}

/// Why a task appears on a given day in Upcoming.
///
/// Three reasons, kept separate on purpose. A view that renders all three identically is telling the
/// user that a task becoming available and a task being due are the same event, and the whole
/// scheduling model here exists because they are not.
public enum UpcomingReason: Sendable, Hashable {
    /// Becomes workable on this day.
    case becomesAvailable

    /// Must be finished by this day.
    case deadline

    /// Will interrupt at this time.
    case reminder(Date)

    /// A waiting task's chase date.
    case followUp

    public var title: String {
        switch self {
        case .becomesAvailable: "Starts"
        case .deadline: "Deadline"
        case .reminder: "Reminder"
        case .followUp: "Follow up"
        }
    }

    public var symbolName: String {
        switch self {
        case .becomesAvailable: "play.circle"
        case .deadline: "flag.pattern.checkered"
        case .reminder: "bell"
        case .followUp: "arrow.turn.up.right"
        }
    }

    /// Whether this reason occupies time in the day, as an event does.
    ///
    /// `false` for everything here. Nothing in this list is an appointment, and drawing an undated
    /// obligation as though it were one is how an agenda starts lying about how full a day is.
    public var occupiesTime: Bool { false }
}

/// One appearance of one task on one day.
public struct UpcomingEntry: Sendable, Hashable, Identifiable {
    public var taskID: UUID
    public var day: Date
    public var reason: UpcomingReason

    /// Unique per task *and* reason, so a task with a start date and a deadline on the same day
    /// produces two rows rather than colliding into one.
    public var id: String {
        "\(taskID.uuidString)|\(day.timeIntervalSinceReferenceDate)|\(reason)"
    }

    public init(taskID: UUID, day: Date, reason: UpcomingReason) {
        self.taskID = taskID
        self.day = day
        self.reason = reason
    }
}

// MARK: - Membership

/// Which system views a task belongs to.
///
/// Every function here is pure and takes its clock as an argument, so daylight-saving transitions,
/// year boundaries, and "what happens at 23:59" are testable rather than hopeful.
public enum TaskViewRules {
    /// Whether the task is an unprocessed capture.
    public static func isInInbox(_ facts: TaskFacts) -> Bool {
        facts.lifecycle == .inbox
    }

    /// Which part of Today the task belongs to, or `nil` if it does not belong there.
    ///
    /// Today is the union of three things, and only three:
    ///
    /// 1. Work the user **chose** for today, which is the part that makes Today a plan.
    /// 2. Work whose **start date is today**, because that is what a start date is for.
    /// 3. Work whose **deadline** is today or has passed, because that is a commitment coming due.
    ///
    /// Deliberately **not** included: everything else that happens to be active. A Today that fills
    /// itself is a second Anytime with a more stressful name.
    public static func todaySection(
        for facts: TaskFacts,
        now: Date,
        calendar: Calendar
    ) -> TodaySection? {
        guard facts.lifecycle.isOpen, !facts.isSomeday else { return nil }

        // Waiting work belongs to Waiting. It reappears here when its follow-up date arrives, which
        // is the only day chasing somebody is actually the next action.
        if facts.lifecycle == .waiting {
            guard let followUpAt = facts.followUpAt,
                  calendar.startOfDay(for: followUpAt) <= calendar.startOfDay(for: now)
            else { return nil }
            return .today
        }

        let today = calendar.startOfDay(for: now)

        // Overdue is decided by the deadline alone. A start date that has passed does not make
        // anything late — it makes it available, which is the opposite of a problem.
        if let deadlineAt = facts.deadlineAt, calendar.startOfDay(for: deadlineAt) < today {
            return .overdue
        }

        let committed = facts.isCommittedToToday(on: now, calendar: calendar)
        let startsToday = facts.startAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        let dueToday = facts.deadlineAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false

        guard committed || startsToday || dueToday else { return nil }

        // Later Today only applies to a commitment made for today. A carried-over one has no back
        // half of the day to sit in — see `TaskInvariants`.
        if facts.isLaterToday, facts.isCommittedForExactly(now, calendar: calendar) {
            return .laterToday
        }
        return .today
    }

    /// Whether the task can be picked up right now.
    ///
    /// Anytime is the honest answer to "what could I do?", so it excludes anything the user has
    /// deliberately put out of reach: a future start date, Someday, and waiting. It **includes**
    /// work already committed to today, because that work is still available — Today is a plan laid
    /// over Anytime, not a separate pile.
    public static func isInAnytime(_ facts: TaskFacts, now: Date, calendar: Calendar) -> Bool {
        facts.availability(on: now, calendar: calendar).isAvailable
    }

    public static func isInSomeday(_ facts: TaskFacts) -> Bool {
        facts.lifecycle == .someday
    }

    /// A flag is a bookmark, not a priority and not a deadline.
    ///
    /// Which is why this asks nothing about dates: the whole value of a flag is that it means
    /// exactly what the user decided it means.
    public static func isInFlagged(_ facts: TaskFacts) -> Bool {
        facts.isFlagged && facts.lifecycle.isOpen
    }

    public static func isInWaiting(_ facts: TaskFacts) -> Bool {
        facts.lifecycle == .waiting
    }

    /// Completed **and** cancelled. Both are history, and a log that omits what you decided against
    /// is a log that makes you re-decide it.
    public static func isInCompleted(_ facts: TaskFacts) -> Bool {
        !facts.lifecycle.isOpen
    }

    /// Every entry this task contributes to a dated agenda, within `range`.
    ///
    /// A task can contribute more than one: "start planning the trip next Monday, deadline
    /// September 1" is two rows on two days, and collapsing them would hide one of the two facts the
    /// user took the trouble to record.
    public static func upcomingEntries(
        for facts: TaskFacts,
        in range: Range<Date>,
        calendar: Calendar
    ) -> [UpcomingEntry] {
        guard facts.lifecycle.isOpen, !facts.isSomeday else { return [] }

        var entries: [UpcomingEntry] = []

        func append(_ date: Date?, _ reason: UpcomingReason) {
            guard let date, range.contains(date) else { return }
            entries.append(
                UpcomingEntry(taskID: facts.id, day: calendar.startOfDay(for: date), reason: reason)
            )
        }

        append(facts.startAt, .becomesAvailable)
        append(facts.deadlineAt, .deadline)
        if let reminderAt = facts.reminderAt {
            append(reminderAt, .reminder(reminderAt))
        }
        if facts.lifecycle == .waiting {
            append(facts.followUpAt, .followUp)
        }

        return entries
    }
}

// MARK: - Agenda grouping

/// How far out an agenda still shows individual days.
public struct AgendaHorizon: Sendable, Hashable {
    /// Days shown one at a time.
    public var dayCount: Int

    /// Weeks shown after that.
    public var weekCount: Int

    /// Whether anything beyond the weeks collapses into months.
    public var collapsesRemainderIntoMonths: Bool

    public init(dayCount: Int = 10, weekCount: Int = 6, collapsesRemainderIntoMonths: Bool = true) {
        self.dayCount = max(1, dayCount)
        self.weekCount = max(0, weekCount)
        self.collapsesRemainderIntoMonths = collapsesRemainderIntoMonths
    }

    public static let standard = AgendaHorizon()
}

/// One band of an agenda: a single day near at hand, or a wider span further out.
public struct AgendaGroup: Sendable, Hashable, Identifiable {
    public enum Span: Sendable, Hashable {
        case day(Date)
        case week(start: Date)
        case month(start: Date)
    }

    public var span: Span
    public var entries: [UpcomingEntry]

    public var id: String {
        switch span {
        case .day(let date): "day-\(date.timeIntervalSinceReferenceDate)"
        case .week(let start): "week-\(start.timeIntervalSinceReferenceDate)"
        case .month(let start): "month-\(start.timeIntervalSinceReferenceDate)"
        }
    }

    public var start: Date {
        switch span {
        case .day(let date), .week(let date), .month(let date): date
        }
    }

    public init(span: Span, entries: [UpcomingEntry]) {
        self.span = span
        self.entries = entries
    }
}

/// Turns a flat list of dated obligations into the bands an agenda draws.
///
/// ### Why bands rather than a continuous calendar
/// A month of individually-headed days is mostly empty headings, and an infinite scroll of them is
/// a scroll pit with no landmarks. Precision is worth most where the user can still act — the next
/// week and a half — and worth almost nothing in November. So the near future is by day and the far
/// future collapses, and the collapse is a property of *distance*, not of how busy the days are.
public enum UpcomingAgenda {
    /// Groups entries, dropping empty days beyond the first stretch.
    ///
    /// Near days are emitted **even when empty**, because an empty Thursday is information: it is
    /// where the next thing could go. Far bands are emitted only when they hold something, because
    /// an empty week in September is not.
    public static func groups(
        from entries: [UpcomingEntry],
        startingAt now: Date,
        horizon: AgendaHorizon = .standard,
        calendar: Calendar
    ) -> [AgendaGroup] {
        let today = calendar.startOfDay(for: now)
        var remaining = entries.sorted { $0.day < $1.day }
        var groups: [AgendaGroup] = []

        // MARK: Individual days

        var dayCursor = today
        for _ in 0..<horizon.dayCount {
            let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) ?? dayCursor
            let (taken, rest) = remaining.split { $0.day < next }
            groups.append(AgendaGroup(span: .day(dayCursor), entries: taken))
            remaining = rest
            dayCursor = next
        }

        // MARK: Weeks

        guard horizon.weekCount > 0 else {
            return groups + monthGroups(from: remaining, calendar: calendar, enabled: horizon.collapsesRemainderIntoMonths)
        }

        // Aligned to the user's own first weekday, so "next week" means what their calendar says.
        var weekCursor = calendar.dateInterval(of: .weekOfYear, for: dayCursor)?.start ?? dayCursor
        for _ in 0..<horizon.weekCount {
            let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekCursor) ?? weekCursor
            let (taken, rest) = remaining.split { $0.day < next }
            // The first week band can overlap the day bands it follows; anything already taken has
            // been removed, so an empty band here means genuinely nothing left in that week.
            if !taken.isEmpty {
                groups.append(AgendaGroup(span: .week(start: max(weekCursor, dayCursor)), entries: taken))
            }
            remaining = rest
            weekCursor = next
        }

        return groups + monthGroups(from: remaining, calendar: calendar, enabled: horizon.collapsesRemainderIntoMonths)
    }

    private static func monthGroups(
        from entries: [UpcomingEntry],
        calendar: Calendar,
        enabled: Bool
    ) -> [AgendaGroup] {
        guard enabled, !entries.isEmpty else { return [] }

        var byMonth: [Date: [UpcomingEntry]] = [:]
        for entry in entries {
            let start = calendar.dateInterval(of: .month, for: entry.day)?.start ?? entry.day
            byMonth[start, default: []].append(entry)
        }

        return byMonth
            .sorted { $0.key < $1.key }
            .map { AgendaGroup(span: .month(start: $0.key), entries: $0.value) }
    }
}

extension Array {
    /// Splits a sorted array at the first element failing `predicate`.
    ///
    /// A helper rather than two `filter` passes, because the agenda walks a sorted list once and
    /// filtering it per band is quadratic in the number of bands.
    fileprivate func split(while predicate: (Element) -> Bool) -> ([Element], [Element]) {
        guard let index = firstIndex(where: { !predicate($0) }) else { return (self, []) }
        return (Array(self[..<index]), Array(self[index...]))
    }
}
