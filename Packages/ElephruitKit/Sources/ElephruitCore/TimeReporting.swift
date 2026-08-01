import Foundation

/// Turns tracked time into totals.
///
/// Pure functions over ``TimeEntrySnapshot`` values, so every rule here — how a session that crosses
/// midnight is counted, what happens to an entry with two tags, how a running timer is treated — is
/// testable without a store, a window, or a clock.
///
/// ### No rollup table
/// A week touches a few hundred rows and a year-by-project report a few tens of thousands. Both are
/// fast enough in Swift over a date-bounded fetch that a derived `TimeDayRollup` would be a second
/// source of truth maintained for no measured benefit. It is designed for and built only if
/// measurement demands it — see the benchmark.
public enum TimeReporting {
    /// Builds a report.
    ///
    /// - Parameters:
    ///   - entries: everything overlapping `range`. Entries wholly outside it contribute nothing.
    ///   - now: how a still-running entry is measured.
    public static func report(
        entries: [TimeEntrySnapshot],
        grouping: TimeGrouping,
        range: Range<Date>,
        calendar: Calendar,
        now: Date,
        rounding: TimeRounding = .exact
    ) -> TimeReport {
        guard !entries.isEmpty else { return .empty(range: range) }

        var rows: [String: TimeSummaryRow] = [:]
        var total: TimeInterval = 0
        var billable: TimeInterval = 0
        var counted = 0

        for entry in entries {
            let clipped = clip(entry, to: range, now: now)
            guard clipped > 0 else { continue }

            counted += 1
            total += clipped
            if entry.isBillable { billable += clipped }

            for slice in slices(for: entry, grouping: grouping, clippedTo: range, calendar: calendar, now: now) {
                rows[slice.key, default: TimeSummaryRow(
                    key: slice.key,
                    title: slice.title,
                    total: 0,
                    billable: 0,
                    entryCount: 0,
                    itemID: slice.itemID
                )].add(slice.duration, billable: entry.isBillable)
            }
        }

        // ### Why rounding lands on the row and not on the entry
        // A six-minute unit applied per *entry* bills eight two-minute interruptions as forty-eight
        // minutes of work, which is not what anybody means by rounding up to the nearest tenth of an
        // hour. It is the line on the invoice that rounds, so it is the row — and the report's own
        // total rounds once, independently, rather than by adding rounded rows together.
        return TimeReport(
            rows: rows.values.map { $0.rounded(by: rounding) }.sorted(by: ordering(for: grouping)),
            total: rounding.apply(total),
            billable: rounding.apply(billable),
            entryCount: counted,
            range: range
        )
    }

    /// The report, cut both ways at once: how much of each day went to each row.
    ///
    /// ### Why this is here and not in the view that draws it
    /// Because it is the same question the table below the chart answers, asked per day, and this
    /// file's standing promise is that there is no second set of rules about what counts. A view
    /// that walked the entries itself would be a second implementation of what a day is, what a
    /// midnight-crossing session is worth, and where an entry with no project goes — and the first
    /// time one of those drifted, the chart and the table under it would disagree about the same
    /// week. Built from the same ``slices(for:grouping:clippedTo:calendar:now:)`` both already use,
    /// so they cannot.
    ///
    /// ### What the cells sum to
    /// A day's cells sum to that day's total **only when the grouping's rows cannot overlap** — see
    /// ``ElephruitCore/TimeGrouping/rowsCanOverlap``. Under `.tag` or `.person` an hour counts in
    /// full under each tag and each person, exactly as it does in the table, so the cells of one day
    /// can sum to more than the day held. That is the right answer to "how much of Tuesday carried
    /// this tag" and the wrong thing to stack into a bar, which is why the caller checks before it
    /// stacks rather than this function quietly halving anything.
    ///
    /// Unrounded, deliberately. Rounding is a rule about the line on an invoice — see the note on
    /// ``report(entries:grouping:range:calendar:now:rounding:)`` — and applying it to a cell would
    /// round the same minute once per day it touched. A caller that needs the bar to match a rounded
    /// total scales the cells to it; the shares are what this returns.
    public static func dailyBreakdown(
        entries: [TimeEntrySnapshot],
        grouping: TimeGrouping,
        range: Range<Date>,
        calendar: Calendar,
        now: Date
    ) -> [TimeDayCell] {
        guard !entries.isEmpty, grouping != .day else { return [] }

        var cells: [String: TimeDayCell] = [:]

        for entry in entries {
            let days = daySlices(for: entry, clippedTo: range, calendar: calendar, now: now)
            guard !days.isEmpty else { continue }

            let rows = slices(for: entry, grouping: grouping, clippedTo: range, calendar: calendar, now: now)
            guard !rows.isEmpty else { continue }

            // The day slices say *when* this entry happened and the row slices say *what* it was.
            // Each day's portion is attributed to each row the entry belongs to — which is one row
            // for a project and may be several for a tag, on the same terms as the table.
            for day in days {
                for row in rows {
                    let id = "\(day.key)\u{1f}\(row.key)"
                    cells[id, default: TimeDayCell(
                        dayKey: day.key,
                        rowKey: row.key,
                        title: row.title,
                        total: 0,
                        itemID: row.itemID
                    )].total += day.duration
                }
            }
        }

        return cells.values.sorted {
            $0.dayKey == $1.dayKey ? $0.total > $1.total : $0.dayKey < $1.dayKey
        }
    }

    /// How much of an entry falls inside the window.
    ///
    /// A report for Tuesday should show the two hours of a session that began on Monday night, not
    /// the whole seven — and not nothing.
    static func clip(_ entry: TimeEntrySnapshot, to range: Range<Date>, now: Date) -> TimeInterval {
        let start = max(entry.startedAt, range.lowerBound)
        let end = min(entry.endedAt ?? now, range.upperBound)
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - Slicing

    private struct Slice {
        var key: String
        var title: String
        var duration: TimeInterval
        var itemID: UUID?
    }

    private static func slices(
        for entry: TimeEntrySnapshot,
        grouping: TimeGrouping,
        clippedTo range: Range<Date>,
        calendar: Calendar,
        now: Date
    ) -> [Slice] {
        switch grouping {
        case .day:
            return daySlices(for: entry, clippedTo: range, calendar: calendar, now: now)

        case .item:
            let duration = clip(entry, to: range, now: now)
            guard let itemID = entry.itemID else {
                return [Slice(key: "\u{1}unassigned", title: "No item", duration: duration)]
            }
            return [Slice(
                key: itemID.uuidString,
                title: entry.itemTitle ?? "Untitled",
                duration: duration,
                itemID: itemID
            )]

        case .project:
            let duration = clip(entry, to: range, now: now)
            guard let projectID = entry.projectID else {
                return [Slice(key: "\u{1}unassigned", title: "No project", duration: duration)]
            }
            return [Slice(
                key: projectID.uuidString,
                title: entry.projectTitle ?? "Untitled",
                duration: duration,
                itemID: projectID
            )]

        case .tag:
            let duration = clip(entry, to: range, now: now)
            guard !entry.tagSlugs.isEmpty else {
                return [Slice(key: "\u{1}untagged", title: "Untagged", duration: duration)]
            }
            // An entry with two tags counts in full under each. That means the rows of a tag report
            // sum to more than its total, which is correct — "how much time carried this tag" is a
            // different question from "how much time was there" — and is why `TimeReport.total` is
            // computed independently of the rows rather than by adding them up.
            return entry.tagSlugs.map { Slice(key: $0, title: $0, duration: duration) }

        case .person:
            let duration = clip(entry, to: range, now: now)
            guard !entry.people.isEmpty else {
                return [Slice(key: "\u{1}alone", title: "On your own", duration: duration)]
            }
            // Counted in full under each person, on exactly the same terms as a tag: an hour spent
            // with two colleagues is an hour with each of them, not half an hour each. Splitting it
            // would answer a question nobody asked — how much of each person the hour contained —
            // and would make one-to-one time look smaller than time in a crowd.
            return entry.people.map {
                Slice(key: $0.id.uuidString, title: $0.name, duration: duration, itemID: $0.id)
            }

        case .kind:
            let duration = clip(entry, to: range, now: now)
            guard let kind = entry.itemKind else {
                return [Slice(key: "\u{1}unassigned", title: "Unfiled", duration: duration)]
            }
            return [Slice(key: kind.rawValue, title: kind.pluralDisplayName, duration: duration)]
        }
    }

    /// One slice per calendar day the entry touches.
    ///
    /// A session from 23:00 to 01:00 is an hour on each day, not two hours on whichever day it
    /// happened to start. Anything else makes a daily chart lie about a late night.
    private static func daySlices(
        for entry: TimeEntrySnapshot,
        clippedTo range: Range<Date>,
        calendar: Calendar,
        now: Date
    ) -> [Slice] {
        let start = max(entry.startedAt, range.lowerBound)
        let end = min(entry.endedAt ?? now, range.upperBound)
        guard end > start else { return [] }

        var slices: [Slice] = []
        var cursor = start

        // Bounded, so a corrupt entry with an absurd end date cannot spin here.
        var guardCount = 0
        while cursor < end, guardCount < 1_000 {
            guardCount += 1

            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let sliceEnd = min(nextDay, end)

            let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
            let key = DayKey.string(
                year: components.year ?? 0,
                month: components.month ?? 0,
                day: components.day ?? 0
            )

            slices.append(Slice(
                key: key,
                title: key,
                duration: sliceEnd.timeIntervalSince(cursor)
            ))

            cursor = sliceEnd
        }

        return slices
    }

    // MARK: - Ordering

    private static func ordering(for grouping: TimeGrouping) -> (TimeSummaryRow, TimeSummaryRow) -> Bool {
        switch grouping {
        case .day:
            // Chronological. A daily chart out of date order is not a chart.
            return { $0.key < $1.key }
        case .item, .project, .tag, .person, .kind:
            // Largest first: the question is where the time went, and the answer is the top row.
            return { left, right in
                left.total == right.total ? left.title < right.title : left.total > right.total
            }
        }
    }
}

extension TimeSummaryRow {
    fileprivate mutating func add(_ duration: TimeInterval, billable isBillable: Bool) {
        total += duration
        if isBillable { billable += duration }
        entryCount += 1
    }

    fileprivate func rounded(by rounding: TimeRounding) -> TimeSummaryRow {
        guard rounding != .exact else { return self }
        var copy = self
        copy.total = rounding.apply(total)
        copy.billable = rounding.apply(billable)
        return copy
    }
}

// MARK: - Windows

/// The periods a report can cover.
///
/// Resolved against a ``DateProvider`` so "this week" honours the user's own calendar and first
/// weekday rather than an assumption baked into a query.
public enum TimeWindow: String, Sendable, Hashable, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case last7Days
    case last30Days
    case thisYear

    /// The windows the Time module's own sidebar and picker offer.
    ///
    /// A shorter list than `allCases`, deliberately. The log is a place you correct yesterday from,
    /// and a menu that offers to show a year of it is a menu you have to read before every use. The
    /// long ranges belong to Reports, which is the surface that can draw one.
    public static let logWindows: [TimeWindow] = [.today, .yesterday, .thisWeek, .lastWeek, .thisMonth]

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This Week"
        case .lastWeek: "Last Week"
        case .thisMonth: "This Month"
        case .lastMonth: "Last Month"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .thisYear: "This Year"
        }
    }

    public var symbolName: String {
        switch self {
        case .today: "circle.circle"
        case .yesterday: "arrow.uturn.backward.circle"
        case .thisWeek: "calendar"
        case .lastWeek: "calendar.badge.clock"
        case .thisMonth: "calendar.badge.exclamationmark"
        case .lastMonth: "calendar.badge.minus"
        case .last7Days: "7.circle"
        case .last30Days: "30.circle"
        case .thisYear: "calendar.circle"
        }
    }

    /// What the window covers, for a tooltip. A rule, never a restatement of the name — the same
    /// standard every other navigation row in this app is held to.
    public var hint: String {
        switch self {
        case .today: "Everything tracked since midnight."
        case .yesterday: "The whole of the previous day, for the correction you are about to make."
        case .thisWeek: "From the first day of your week, as your calendar defines it."
        case .lastWeek: "The seven days before this week began."
        case .thisMonth: "From the first of the month to now."
        case .lastMonth: "The whole of the month before this one — what an invoice covers."
        case .last7Days: "A rolling week ending today, which ignores where your week starts."
        case .last30Days: "A rolling month ending today."
        case .thisYear: "From the first of January."
        }
    }

    public func range(using dateProvider: any DateProvider) -> Range<Date> {
        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday
        let tomorrow = addingDays(1, to: today, calendar: calendar)

        switch self {
        case .today:
            return today..<tomorrow

        case .yesterday:
            let start = addingDays(-1, to: today, calendar: calendar)
            return start..<today

        case .thisWeek:
            let start = startOfWeek(containing: today, calendar: calendar)
            return start..<addingDays(7, to: start, calendar: calendar)

        case .lastWeek:
            let thisWeek = startOfWeek(containing: today, calendar: calendar)
            let start = addingDays(-7, to: thisWeek, calendar: calendar)
            return start..<thisWeek

        case .thisMonth:
            let start = startOfMonth(containing: today, calendar: calendar)
            let end = calendar.date(byAdding: DateComponents(month: 1), to: start) ?? today
            return start..<end

        case .lastMonth:
            let thisMonth = startOfMonth(containing: today, calendar: calendar)
            let start = calendar.date(byAdding: DateComponents(month: -1), to: thisMonth) ?? thisMonth
            return start..<thisMonth

        case .last7Days:
            // Rolling and inclusive of today: six days back plus today is seven days, and a "last 7
            // days" that stopped at midnight would report six.
            return addingDays(-6, to: today, calendar: calendar)..<tomorrow

        case .last30Days:
            return addingDays(-29, to: today, calendar: calendar)..<tomorrow

        case .thisYear:
            let components = calendar.dateComponents([.year], from: today)
            let start = calendar.date(from: components) ?? today
            let end = calendar.date(byAdding: DateComponents(year: 1), to: start) ?? today
            return start..<end
        }
    }

    private func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return addingDays(-offset, to: date, calendar: calendar)
    }

    private func startOfMonth(containing date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func addingDays(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}

/// The span a report covers: one of the named windows, or two dates somebody picked.
///
/// ### Why the custom case carries days rather than a `Range<Date>`
/// Because a report is asked for in days — *the 3rd to the 17th* — and a range built from two raw
/// `Date`s carries whatever times of day the pickers happened to hold. Half an afternoon would then
/// fall outside a report of the day it happened on, which is the kind of missing hour nobody ever
/// tracks down. Both ends are widened to whole days here, once, so no caller has to remember to.
public enum TimePeriod: Sendable, Hashable {
    case window(TimeWindow)
    case custom(from: Date, through: Date)

    public func range(using dateProvider: any DateProvider) -> Range<Date> {
        switch self {
        case .window(let window):
            return window.range(using: dateProvider)

        case .custom(let from, let through):
            let calendar = dateProvider.calendar
            let start = calendar.startOfDay(for: min(from, through))
            let lastDay = calendar.startOfDay(for: max(from, through))
            let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            return start..<end
        }
    }

    public var displayName: String {
        switch self {
        case .window(let window):
            return window.displayName

        case .custom(let from, let through):
            let start = min(from, through).formatted(.dateTime.day().month(.abbreviated))
            let end = max(from, through).formatted(.dateTime.day().month(.abbreviated).year())
            return "\(start) – \(end)"
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The named window this period is, or `nil` when it is a custom range.
    ///
    /// What a rail of window chips needs in order to know which one to fill: `isCustom` says a
    /// custom range is in force but not which chip is current when one is not.
    public var window: TimeWindow? {
        if case .window(let window) = self { return window }
        return nil
    }
}
