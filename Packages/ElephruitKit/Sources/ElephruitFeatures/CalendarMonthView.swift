import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The month grid.
///
/// ### What a month view is for
/// Not for reading an event — a cell four rows down is too small for that, and pretending otherwise
/// produces six weeks of unreadable slivers. It is for seeing *shape*: which weeks are full, where
/// the gaps are, and how a deadline on the 1st relates to a trip that ends on the 30th. So each cell
/// shows as much as it can read and says plainly how much it is not showing, and the detail lives one
/// click away in a popover.
struct CalendarMonthView: View {
    let days: [Date]
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let anchorMonth: Date
    let density: CalendarDensity
    let workingHours: WorkingHours
    let now: Date
    let showsWeekNumbers: Bool
    let annotatedKeys: Set<String>

    @Binding var selectedEventID: String?
    @Binding var focusedDay: Date?

    var onOpenDay: (Date) -> Void
    var onCreate: (Date) -> Void
    var onOpen: (CalendarEventSummary) -> Void

    @State private var popoverDay: Date?

    /// Six rows of seven. Fixed, so the grid does not change height as the months go by.
    private var weeks: [[Date]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Divider()

            GeometryReader { proxy in
                let rowHeight = max(
                    Theme.CalendarMetrics.monthCellMinimumHeight,
                    proxy.size.height / CGFloat(max(1, weeks.count))
                )

                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            if showsWeekNumbers, let first = week.first {
                                WeekNumberLabel(week: first, calendar: calendar)
                            }

                            ForEach(week, id: \.self) { day in
                                cell(day)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: rowHeight)
                        .overlay(alignment: .top) { Divider() }
                    }
                }
            }
        }
        .background(Theme.Colors.contentBackground)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            if showsWeekNumbers {
                Text("Wk")
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 28)
            }

            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(Theme.Text.keyHint)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityHidden(true)
    }

    /// Weekday names starting on the locale's first day.
    ///
    /// Rotated rather than assumed: a week starts on Sunday in the United States, Monday across most
    /// of Europe, and Saturday in much of the Middle East, and a grid whose header disagrees with its
    /// columns is worse than one with no header.
    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        guard offset > 0, offset < symbols.count else { return symbols }
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func cell(_ day: Date) -> some View {
        let dayEvents = events
            .filter { $0.occurs(on: day, calendar: calendar) && $0.appearsInPlan }
            .sorted { left, right in
                if left.isAllDay != right.isAllDay { return left.isAllDay }
                return left.startAt < right.startAt
            }

        return MonthCell(
            day: day,
            events: dayEvents,
            calendar: calendar,
            isInAnchorMonth: calendar.isDate(day, equalTo: anchorMonth, toGranularity: .month),
            isToday: calendar.isDate(day, inSameDayAs: now),
            isFocused: focusedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
            isWorkingDay: workingHours.includes(weekday: calendar.component(.weekday, from: day)),
            limit: density.monthCellEventLimit,
            annotatedKeys: annotatedKeys,
            onSelect: { selectedEventID = $0.id },
            onOpen: onOpen
        )
        .contentShape(.rect)
        // One single-tap gesture, not two. A second `.onTapGesture` on the same view does not add
        // behaviour — it replaces the first, silently — so the version with both had a line setting
        // the keyboard focus that never ran.
        .onTapGesture {
            focusedDay = day
            // A cell that is hiding events opens its popover on a click, rather than asking somebody
            // to hit the "+2 more" text exactly.
            if dayEvents.count > density.monthCellEventLimit { popoverDay = day }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenDay(day) })
        .popover(isPresented: popoverBinding(for: day), arrowEdge: .trailing) {
            DayDetailPopover(
                day: day,
                events: dayEvents,
                calendar: calendar,
                annotatedKeys: annotatedKeys,
                onOpen: onOpen,
                onCreate: { onCreate(day) },
                onOpenDay: { onOpenDay(day) }
            )
        }
        .contextMenu {
            Button("New Event…") { onCreate(day) }
            Button("Open This Day") { onOpenDay(day) }
            if dayEvents.count > density.monthCellEventLimit {
                Button("Show All \(dayEvents.count)") { popoverDay = day }
            }
        }
    }

    private func popoverBinding(for day: Date) -> Binding<Bool> {
        Binding(
            get: { popoverDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false },
            set: { shown in popoverDay = shown ? day : nil }
        )
    }
}

/// One day in the grid.
private struct MonthCell: View {
    let day: Date
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let isInAnchorMonth: Bool
    let isToday: Bool
    let isFocused: Bool
    let isWorkingDay: Bool
    let limit: Int
    let annotatedKeys: Set<String>

    var onSelect: (CalendarEventSummary) -> Void
    var onOpen: (CalendarEventSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            dayNumber

            ForEach(events.prefix(limit)) { event in
                MonthEventIndicator(
                    event: event,
                    calendar: calendar,
                    isAnnotated: annotatedKeys.contains(event.id)
                )
                .onTapGesture { onSelect(event) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(event) })
            }

            if events.count > limit {
                Text("\(events.count - limit) more")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .padding(.leading, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if !isWorkingDay {
                Theme.Colors.outsideWorkingHours.opacity(0.5)
            }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.Colors.selection, lineWidth: 2)
            }
        }
        .overlay(alignment: .leading) { Divider() }
        .opacity(isInAnchorMonth ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var dayNumber: some View {
        var style = Date.FormatStyle().day()
        style.timeZone = calendar.timeZone

        return Text(day.formatted(style))
            .font(.system(size: 11, weight: isToday ? .bold : .regular))
            .foregroundStyle(isToday ? Theme.Colors.onAccent : Theme.Colors.primaryText)
            .frame(minWidth: 17, minHeight: 17)
            .background {
                if isToday { Circle().fill(Theme.Colors.currentTime) }
            }
            .padding(.leading, 2)
    }

    private var accessibilityDescription: String {
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.timeZone = calendar.timeZone

        var parts = [isToday ? "Today, \(day.formatted(style))" : day.formatted(style)]
        parts.append(events.isEmpty ? "nothing scheduled" : "\(events.count) events")
        return parts.joined(separator: ", ")
    }
}

/// One event in a month cell: a coloured dot, a time, and as much title as fits.
private struct MonthEventIndicator: View {
    let event: CalendarEventSummary
    let calendar: Calendar
    let isAnnotated: Bool

    var body: some View {
        HStack(spacing: 3) {
            if event.isAllDay {
                // An all-day event is a band rather than a dot, so the two are told apart by shape
                // as well as by position — which survives greyscale and colour-blindness.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                    .frame(width: 8, height: 3)
            } else {
                Circle()
                    .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                    .frame(width: 5, height: 5)

                Text(shortTime)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Text(event.displayTitle)
                .font(.system(size: 10))
                .strikethrough(event.isCancelled)
                .lineLimit(1)
                .foregroundStyle(Theme.Colors.primaryText)

            if isAnnotated {
                Image(systemName: "circle.fill")
                    .font(.system(size: 3))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .contentShape(.rect)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.displayTitle), \(event.isAllDay ? "all day" : shortTime)")
        .help(event.displayTitle)
    }

    private var shortTime: String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return event.startAt.formatted(style)
    }
}

/// The week number down the side of a month grid.
private struct WeekNumberLabel: View {
    let week: Date
    let calendar: Calendar

    var body: some View {
        Text("\(calendar.component(.weekOfYear, from: week))")
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.tertiaryText)
            .frame(width: 28)
            .accessibilityLabel("Week \(calendar.component(.weekOfYear, from: week))")
    }
}

/// Everything on one day, for a month cell that cannot show it all.
struct DayDetailPopover: View {
    let day: Date
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let annotatedKeys: Set<String>

    var onOpen: (CalendarEventSummary) -> Void
    var onCreate: () -> Void
    var onOpenDay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(title)
                    .font(Theme.Text.title)
                Spacer(minLength: Theme.Spacing.medium)
                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New event on this day")
                .accessibilityLabel("New event")
            }

            if events.isEmpty {
                Text("Nothing scheduled.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        ForEach(events) { event in
                            AgendaEventRow(
                                event: event,
                                calendar: calendar,
                                timeZone: calendar.timeZone,
                                isAnnotated: annotatedKeys.contains(event.id),
                                isSelected: false
                            )
                            .contentShape(.rect)
                            .onTapGesture { onOpen(event) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            Button("Open This Day", action: onOpenDay)
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Calendar.dayPopover)
    }

    private var title: String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }
}
