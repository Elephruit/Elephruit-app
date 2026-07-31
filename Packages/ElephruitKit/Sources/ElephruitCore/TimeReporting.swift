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
        now: Date
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

        return TimeReport(
            rows: rows.values.sorted(by: ordering(for: grouping)),
            total: total,
            billable: billable,
            entryCount: counted,
            range: range
        )
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
        case .item, .project, .tag:
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

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This Week"
        case .lastWeek: "Last Week"
        case .thisMonth: "This Month"
        }
    }

    public var symbolName: String {
        switch self {
        case .today: "circle.circle"
        case .yesterday: "arrow.uturn.backward.circle"
        case .thisWeek: "calendar"
        case .lastWeek: "calendar.badge.clock"
        case .thisMonth: "calendar.badge.exclamationmark"
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
        }
    }

    public func range(using dateProvider: any DateProvider) -> Range<Date> {
        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday

        switch self {
        case .today:
            return today..<addingDays(1, to: today, calendar: calendar)

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
            let components = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: components) ?? today
            let end = calendar.date(byAdding: DateComponents(month: 1), to: start) ?? today
            return start..<end
        }
    }

    private func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return addingDays(-offset, to: date, calendar: calendar)
    }

    private func addingDays(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}
