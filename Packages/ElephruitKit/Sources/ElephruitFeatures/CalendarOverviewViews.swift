import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Three months at once.
///
/// ### Why this is not a bigger month view
/// Because at a quarter's zoom, an event is two pixels. Drawing every one of them produces a texture
/// that says nothing, and the question somebody actually has at this zoom is not "what is on the
/// 14th" — it is *where the shape of the quarter is*: which weeks are full, where the clear runs
/// are, and what the few things worth remembering were.
///
/// So each month is a small grid of days shaded by how busy they were, with the events that stand
/// out — all-day and multi-day ones, which are the milestones — listed beside it. Clicking any day
/// opens it.
struct CalendarQuarterView: View {
    let range: Range<Date>
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let workingHours: WorkingHours
    let now: Date

    var onOpenDay: (Date) -> Void
    var onOpen: (CalendarEventSummary) -> Void

    private var months: [Date] {
        var months: [Date] = []
        var cursor = calendar.dateInterval(of: .month, for: range.lowerBound)?.start ?? range.lowerBound

        while cursor < range.upperBound, months.count < 4 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack(alignment: .top, spacing: Theme.Spacing.section) {
                    ForEach(months, id: \.self) { month in
                        MonthDensityGrid(
                            month: month,
                            events: events,
                            calendar: calendar,
                            workingHours: workingHours,
                            now: now,
                            onOpenDay: onOpenDay
                        )
                    }
                }

                milestones
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.contentBackground)
    }

    /// The events worth naming at this zoom: whole days and multi-day runs.
    private var milestoneEvents: [CalendarEventSummary] {
        events
            .filter { $0.occupiesAllDayRow(calendar: calendar) && $0.appearsInPlan }
            .sorted { $0.startAt < $1.startAt }
    }

    @ViewBuilder
    private var milestones: some View {
        if milestoneEvents.isEmpty {
            EmptyStateView(
                symbolName: "calendar",
                headline: "No whole-day events this quarter",
                message: "Trips, leave, and anything spanning several days will appear here.",
                tone: .neutral
            )
            .frame(height: 160)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionHeader("Spanning days", count: milestoneEvents.count)

                ForEach(milestoneEvents) { event in
                    HStack(spacing: Theme.Spacing.small) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                            .frame(width: 3, height: 16)

                        Text(event.displayTitle)
                            .font(Theme.Text.rowTitle)
                            .lineLimit(1)

                        Text(dateRange(of: event))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .hoverHighlight(extending: Theme.Spacing.small)
                    .onTapGesture { onOpen(event) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func dateRange(of event: CalendarEventSummary) -> String {
        var style = Date.FormatStyle().day().month(.abbreviated)
        style.timeZone = calendar.timeZone

        let days = event.days(in: calendar)
        guard let first = days.first, let last = days.last, days.count > 1 else {
            return event.startAt.formatted(style)
        }
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }
}

/// One month as a grid of shaded squares.
private struct MonthDensityGrid: View {
    let month: Date
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let workingHours: WorkingHours
    let now: Date

    var onOpenDay: (Date) -> Void

    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end, days.count < 31 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private var density: [DayDensity] {
        EventLayout.density(of: events, acrossDays: days, workingHours: workingHours, calendar: calendar)
    }

    /// Leading blanks so the first day lands under the right weekday.
    private var leadingBlanks: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(monthName)
                .font(.system(.subheadline, design: .default, weight: .semibold))

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(18), spacing: 2),
                    count: 7
                ),
                spacing: 2
            ) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: 18, height: 18)
                }

                ForEach(density) { entry in
                    DensitySquare(
                        entry: entry,
                        calendar: calendar,
                        isToday: calendar.isDate(entry.day, inSameDayAs: now),
                        size: 18
                    )
                    .onTapGesture { onOpenDay(entry.day) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(monthName)
    }

    private var monthName: String {
        var style = Date.FormatStyle().month(.wide)
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }
}

/// The whole year as a density map.
///
/// One square per day, shaded by how much of it was spoken for. A year of a working calendar is
/// several thousand events, and the only honest thing to draw at that scale is *how busy* rather
/// than *what* — which is the question people bring to a year view anyway: when was the quiet
/// stretch, when did it get bad, is the same week bad every year.
struct CalendarYearView: View {
    let range: Range<Date>
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let workingHours: WorkingHours
    let now: Date

    var onOpenDay: (Date) -> Void

    private var months: [Date] {
        var months: [Date] = []
        var cursor = calendar.dateInterval(of: .year, for: range.lowerBound)?.start ?? range.lowerBound
        while cursor < range.upperBound, months.count < 12 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                legend

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.large)],
                    alignment: .leading,
                    spacing: Theme.Spacing.large
                ) {
                    ForEach(months, id: \.self) { month in
                        MonthDensityGrid(
                            month: month,
                            events: events,
                            calendar: calendar,
                            workingHours: workingHours,
                            now: now,
                            onOpenDay: onOpenDay
                        )
                    }
                }

                busiest
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.contentBackground)
    }

    private var legend: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Quiet")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)

            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Colors.selection.opacity(0.1 + level * 0.7))
                    .frame(width: 12, height: 12)
            }

            Text("Full")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shading runs from a quiet day to a full one")
    }

    /// The handful of days worth pointing at, so the view says something as well as showing it.
    @ViewBuilder
    private var busiest: some View {
        let allDays = months.flatMap { month -> [Date] in
            guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
            var days: [Date] = []
            var cursor = interval.start
            while cursor < interval.end {
                days.append(cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return days
        }

        let ranked = EventLayout
            .density(of: events, acrossDays: allDays, workingHours: workingHours, calendar: calendar)
            .filter { !$0.isEmpty }
            .sorted { $0.busyHours > $1.busyHours }
            .prefix(5)

        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                SectionHeader("Busiest days")

                ForEach(Array(ranked)) { entry in
                    HStack(spacing: Theme.Spacing.small) {
                        Text(dayLabel(entry.day))
                            .font(Theme.Text.rowSubtitle)
                        Text("\(entry.eventCount) events · \(hoursLabel(entry.busyHours))")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .hoverHighlight(extending: Theme.Spacing.small)
                    .onTapGesture { onOpenDay(entry.day) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    private func hoursLabel(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        return rounded == 1 ? "1 hour" : "\(rounded.formatted(.number.precision(.fractionLength(0...1)))) hours"
    }
}

/// One day, shaded by how busy it was.
private struct DensitySquare: View {
    let entry: DayDensity
    let calendar: Calendar
    let isToday: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Theme.Colors.currentTime, lineWidth: 1.5)
                }
            }
            .overlay {
                Text(dayNumber)
                    .font(.system(size: 8))
                    .foregroundStyle(entry.intensity > 0.55 ? Theme.Colors.onAccent : Theme.Colors.tertiaryText)
            }
            .contentShape(.rect)
            .hoverHighlight(cornerRadius: 2)
            .help(tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltip)
            .accessibilityAddTraits(.isButton)
    }

    /// Empty days are drawn rather than left blank, so the grid keeps its shape and a clear day is
    /// visibly a day rather than a hole.
    private var fill: Color {
        entry.isEmpty
            ? Theme.Colors.subtleFill
            : Theme.Colors.selection.opacity(0.15 + entry.intensity * 0.65)
    }

    private var dayNumber: String {
        "\(calendar.component(.day, from: entry.day))"
    }

    private var tooltip: String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        let name = entry.day.formatted(style)

        guard !entry.isEmpty else { return "\(name) — nothing scheduled" }
        return "\(name) — \(entry.eventCount) event\(entry.eventCount == 1 ? "" : "s")"
    }
}
