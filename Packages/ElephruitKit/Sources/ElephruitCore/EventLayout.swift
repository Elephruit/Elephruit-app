import Foundation

/// One event's place in a time grid.
///
/// Fractions rather than points, so the same layout serves a day column, a week column, and a
/// printed page — and so the arithmetic can be asserted without a view.
public struct PositionedEvent: Sendable, Hashable, Identifiable {
    public var event: CalendarEventSummary

    /// Distance from the top of the grid, as a fraction of the visible span.
    public var top: Double

    /// Height, as a fraction of the visible span. Never zero.
    public var height: Double

    /// Leading edge within the column, 0–1.
    public var leading: Double

    /// Width within the column, 0–1.
    public var width: Double

    /// Draw order. Higher sits in front.
    public var depth: Int

    public var id: String { event.id }

    public init(
        event: CalendarEventSummary,
        top: Double,
        height: Double,
        leading: Double,
        width: Double,
        depth: Int = 0
    ) {
        self.event = event
        self.top = top
        self.height = height
        self.leading = leading
        self.width = width
        self.depth = depth
    }
}

/// Turns a day's events into positions.
///
/// ### Why overlap layout is its own problem
/// Two meetings at the same time are not two rectangles side by side. Three meetings where the first
/// two overlap each other and the third overlaps only the second is a graph-colouring problem, and
/// the naive answer — divide the column by the number of events in the day — makes a day with one
/// early clash draw every later event at a third of the width for no reason.
///
/// The approach here is the one Calendar.app and Google Calendar both use: split the day into
/// **clusters** of transitively-overlapping events, and within each cluster assign columns
/// greedily, so an event is only ever as narrow as its own clash requires.
public enum EventLayout {
    /// Lays out the timed events of one day.
    ///
    /// - Parameters:
    ///   - events: The day's events. All-day and multi-day events are excluded by the caller, which
    ///     draws them in a band of their own.
    ///   - day: The day being drawn.
    ///   - visibleHours: The span the grid shows, as hours from midnight. A grid showing the whole
    ///     day passes `0..<24`.
    ///   - calendar: The calendar to measure the day in — already in the display zone.
    public static func positions(
        for events: [CalendarEventSummary],
        on day: Date,
        visibleHours: Range<Double> = 0..<24,
        calendar: Calendar
    ) -> [PositionedEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let span = max(0.5, visibleHours.upperBound - visibleHours.lowerBound)

        // Clipped to the day, so a meeting running from last night occupies the morning rather than
        // starting at a negative offset and being drawn off the top of the grid.
        let bounded = events.compactMap { event -> (event: CalendarEventSummary, start: Double, end: Double)? in
            let startHours = event.startAt.timeIntervalSince(dayStart) / 3_600
            let endHours = event.endAt.timeIntervalSince(dayStart) / 3_600

            // Tested against the event's real hours rather than its clipped ones. Clipping first
            // would give a 3 a.m. event on a grid starting at eight a start of eight and a minimum
            // height, and it would be drawn at the top of the morning as though it were happening.
            let minimumEnd = max(endHours, startHours + 0.25)
            guard minimumEnd > visibleHours.lowerBound, startHours < visibleHours.upperBound else {
                return nil
            }

            let clippedStart = max(startHours, visibleHours.lowerBound)
            // A zero-length event still needs a body to be clickable; fifteen minutes is the
            // smallest block that can hold a title, and is what every calendar uses.
            let clippedEnd = min(max(minimumEnd, clippedStart + 0.25), visibleHours.upperBound)

            return (event, clippedStart, clippedEnd)
        }
        .sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            // Longer events first within a start time, so the short one sits in front of the long
            // one rather than being hidden behind it.
            return left.end > right.end
        }

        var positioned: [PositionedEvent] = []

        for cluster in clusters(of: bounded) {
            let columns = assignColumns(in: cluster)
            let columnCount = max(1, (columns.map(\.column).max() ?? 0) + 1)

            for entry in columns {
                let width = 1.0 / Double(columnCount)
                positioned.append(
                    PositionedEvent(
                        event: entry.event,
                        top: (entry.start - visibleHours.lowerBound) / span,
                        height: (entry.end - entry.start) / span,
                        leading: Double(entry.column) * width,
                        // A hair of overlap so adjacent blocks read as a group rather than as a
                        // gapped set of unrelated slivers.
                        width: width * (columnCount == 1 ? 1 : 1.04),
                        depth: entry.column
                    )
                )
            }
        }

        return positioned
    }

    private struct Bounded {
        var event: CalendarEventSummary
        var start: Double
        var end: Double
        var column: Int = 0
    }

    /// Groups events into runs where each overlaps at least one other in the run.
    ///
    /// Transitive on purpose: A overlapping B and B overlapping C puts all three in one cluster even
    /// when A and C do not touch, because they still have to share the column's width between them.
    private static func clusters(
        of events: [(event: CalendarEventSummary, start: Double, end: Double)]
    ) -> [[Bounded]] {
        var clusters: [[Bounded]] = []
        var current: [Bounded] = []
        var clusterEnd = -Double.infinity

        for entry in events {
            let bounded = Bounded(event: entry.event, start: entry.start, end: entry.end)

            if bounded.start >= clusterEnd, !current.isEmpty {
                clusters.append(current)
                current = []
                clusterEnd = -Double.infinity
            }

            current.append(bounded)
            clusterEnd = max(clusterEnd, bounded.end)
        }

        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Greedy column assignment within one cluster: the first column whose last event has finished.
    private static func assignColumns(in cluster: [Bounded]) -> [Bounded] {
        var columnEnds: [Double] = []
        var result: [Bounded] = []

        for var entry in cluster {
            var placed = false

            for (index, end) in columnEnds.enumerated() where entry.start >= end {
                entry.column = index
                columnEnds[index] = entry.end
                placed = true
                break
            }

            if !placed {
                entry.column = columnEnds.count
                columnEnds.append(entry.end)
            }

            result.append(entry)
        }

        return result
    }
}

// MARK: - All-day bars

/// A multi-day or all-day event's run across a set of columns.
public struct EventBar: Sendable, Hashable, Identifiable {
    public var event: CalendarEventSummary

    /// The first column the bar touches, as an index into the days being shown.
    public var startColumn: Int

    /// How many columns it spans. Always at least one.
    public var columnSpan: Int

    /// Which stacked row of the all-day band it sits in.
    public var row: Int

    /// Whether the event began before the first visible day, so the bar should be drawn as
    /// continuing rather than starting.
    public var continuesBefore: Bool

    /// Whether it runs past the last visible day.
    public var continuesAfter: Bool

    public var id: String { event.id }

    public init(
        event: CalendarEventSummary,
        startColumn: Int,
        columnSpan: Int,
        row: Int,
        continuesBefore: Bool = false,
        continuesAfter: Bool = false
    ) {
        self.event = event
        self.startColumn = startColumn
        self.columnSpan = max(1, columnSpan)
        self.row = row
        self.continuesBefore = continuesBefore
        self.continuesAfter = continuesAfter
    }
}

extension EventLayout {
    /// Packs all-day and multi-day events into the fewest rows that keep them from overlapping.
    ///
    /// The continuity flags are the point: a conference running Monday to Friday should be one bar
    /// across the week and, in the following week's view, a bar that visibly started earlier. Drawing
    /// it as a fresh three-day event on Monday makes it look like a different conference.
    public static func bars(
        for events: [CalendarEventSummary],
        acrossDays days: [Date],
        calendar: Calendar
    ) -> [EventBar] {
        guard let firstDay = days.first, let lastDay = days.last else { return [] }

        let dayIndex = Dictionary(uniqueKeysWithValues: days.enumerated().map { index, day in
            (calendar.startOfDay(for: day), index)
        })
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay

        // Longest first, so the bar that spans the week takes the top row and the one-day events
        // stack beneath it rather than the other way round.
        let ordered = events.sorted { left, right in
            if left.duration != right.duration { return left.duration > right.duration }
            return left.startAt < right.startAt
        }

        var rowOccupancy: [[Bool]] = []
        var bars: [EventBar] = []

        for event in ordered {
            let touched = event.days(in: calendar).compactMap { dayIndex[$0] }
            guard let first = touched.min(), let last = touched.max() else { continue }

            let span = last - first + 1
            let row = firstFreeRow(&rowOccupancy, from: first, count: span, columns: days.count)

            bars.append(
                EventBar(
                    event: event,
                    startColumn: first,
                    columnSpan: span,
                    row: row,
                    continuesBefore: event.startAt < calendar.startOfDay(for: firstDay),
                    continuesAfter: event.endAt > windowEnd
                )
            )
        }

        return bars
    }

    private static func firstFreeRow(
        _ occupancy: inout [[Bool]],
        from start: Int,
        count: Int,
        columns: Int
    ) -> Int {
        var row = 0
        while true {
            if row == occupancy.count {
                occupancy.append(Array(repeating: false, count: max(columns, start + count)))
            }

            let range = start..<min(start + count, occupancy[row].count)
            if range.allSatisfy({ !occupancy[row][$0] }) {
                for column in range { occupancy[row][column] = true }
                return row
            }
            row += 1
        }
    }
}

// MARK: - Density

/// How busy a day was, for the year and quarter overviews.
public struct DayDensity: Sendable, Hashable, Identifiable {
    public var day: Date
    public var eventCount: Int

    /// Total scheduled time, in hours. All-day events contribute a working day rather than 24 hours,
    /// because a day marked "on leave" is not more booked than one with eight meetings.
    public var busyHours: Double

    public var id: Date { day }

    public init(day: Date, eventCount: Int, busyHours: Double) {
        self.day = day
        self.eventCount = eventCount
        self.busyHours = busyHours
    }

    /// 0–1, for shading. Saturates at eight hours, past which more is still just "full".
    public var intensity: Double {
        min(1, busyHours / 8)
    }

    public var isEmpty: Bool { eventCount == 0 }
}

extension EventLayout {
    /// How busy each day in a range was.
    ///
    /// The unit of the year view. Counting events alone would make a day of six five-minute
    /// check-ins look busier than one with two three-hour workshops, so time is what is measured and
    /// the count comes along for the tooltip.
    public static func density(
        of events: [CalendarEventSummary],
        acrossDays days: [Date],
        workingHours: WorkingHours,
        calendar: Calendar
    ) -> [DayDensity] {
        var counts: [Date: (count: Int, hours: Double)] = [:]
        let allDayWeight = Double(workingHours.endMinutes - workingHours.startMinutes) / 60

        for event in events where event.appearsInPlan {
            for day in event.days(in: calendar) {
                let dayStart = calendar.startOfDay(for: day)
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

                let hours: Double
                if event.isAllDay {
                    hours = allDayWeight
                } else {
                    let overlapStart = max(event.startAt, dayStart)
                    let overlapEnd = min(event.endAt, dayEnd)
                    hours = max(0, overlapEnd.timeIntervalSince(overlapStart) / 3_600)
                }

                var existing = counts[dayStart] ?? (0, 0)
                existing.count += 1
                // Time somebody marked free is time they still have. Counting it as busy would make
                // a day of "out of office" blocks look like the busiest of the year.
                if event.availability.occupiesTime { existing.hours += hours }
                counts[dayStart] = existing
            }
        }

        return days.map { day in
            let key = calendar.startOfDay(for: day)
            let entry = counts[key] ?? (0, 0)
            return DayDensity(day: key, eventCount: entry.count, busyHours: entry.hours)
        }
    }
}
