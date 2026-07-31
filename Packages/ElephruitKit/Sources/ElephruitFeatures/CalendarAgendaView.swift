import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The chronological list.
///
/// The view for the question "what is coming up", which a grid answers badly: a week grid with three
/// meetings in it is mostly empty space, and a month grid with sixty is mostly dots. A list is the
/// only layout whose density follows the calendar's rather than the clock's.
///
/// Empty days are shown rather than skipped, because a gap in the middle of a week is information —
/// it is where the free time is — and a list that closes up the gaps makes a quiet week look like a
/// busy one.
struct CalendarAgendaView: View {
    let days: [Date]
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let timeZone: TimeZone
    let now: Date
    let annotatedKeys: Set<String>

    @Binding var selectedEventID: String?

    var onOpen: (CalendarEventSummary) -> Void
    var onCreate: (Date) -> Void

    /// Days with something on them, plus today whether or not it has anything.
    ///
    /// A run of empty days is collapsed into one row saying how many there were — thirty empty rows
    /// is a scroll through nothing, and "nothing until Thursday" is the same information in a line.
    private var sections: [AgendaSection] {
        var sections: [AgendaSection] = []
        var emptyRun: [Date] = []

        func flushEmpties() {
            guard !emptyRun.isEmpty else { return }
            sections.append(.gap(days: emptyRun))
            emptyRun = []
        }

        for day in days {
            let dayEvents = events
                .filter { $0.occurs(on: day, calendar: calendar) && $0.appearsInPlan }
                .sorted { left, right in
                    if left.isAllDay != right.isAllDay { return left.isAllDay }
                    return left.startAt < right.startAt
                }

            if dayEvents.isEmpty, !calendar.isDate(day, inSameDayAs: now) {
                emptyRun.append(day)
            } else {
                flushEmpties()
                sections.append(.day(day: day, events: dayEvents))
            }
        }
        flushEmpties()

        return sections
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        switch section {
                        case .day(let day, let dayEvents):
                            Section {
                                ForEach(dayEvents) { event in
                                    AgendaEventRow(
                                        event: event,
                                        calendar: calendar,
                                        timeZone: timeZone,
                                        isAnnotated: annotatedKeys.contains(event.id),
                                        isSelected: selectedEventID == event.id
                                    )
                                    .contentShape(.rect)
                                    .onTapGesture { selectedEventID = event.id }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(event) })
                                    .padding(.horizontal, Theme.Spacing.medium)
                                }
                            } header: {
                                AgendaDayHeader(
                                    day: day,
                                    calendar: calendar,
                                    isToday: calendar.isDate(day, inSameDayAs: now),
                                    count: dayEvents.count,
                                    onCreate: { onCreate(day) }
                                )
                                .id(day)
                            }

                        case .gap(let gapDays):
                            AgendaGapRow(days: gapDays, calendar: calendar)
                                .padding(.horizontal, Theme.Spacing.medium)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.small)
            }
            .onAppear {
                if let today = days.first(where: { calendar.isDate($0, inSameDayAs: now) }) {
                    scroller.scrollTo(today, anchor: .top)
                }
            }
        }
        .background(Theme.Colors.contentBackground)
        .accessibilityIdentifier(AccessibilityID.Calendar.workspace)
    }
}

/// One entry in the agenda: a day with events, or a run of days without.
private enum AgendaSection: Identifiable {
    case day(day: Date, events: [CalendarEventSummary])
    case gap(days: [Date])

    var id: Date {
        switch self {
        case .day(let day, _): day
        case .gap(let days): days.first ?? .distantPast
        }
    }
}

/// The sticky date above a group of events.
private struct AgendaDayHeader: View {
    let day: Date
    let calendar: Calendar
    let isToday: Bool
    let count: Int
    var onCreate: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(title)
                .font(.system(.subheadline, design: .default, weight: .semibold))
                .foregroundStyle(isToday ? Theme.Colors.currentTime : Theme.Colors.primaryText)

            Text(count == 0 ? "nothing scheduled" : "\(count)")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer(minLength: Theme.Spacing.small)

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(Theme.Text.metadata)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("New event on this day")
            .accessibilityLabel("New event on \(title)")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.windowBackground)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        return isToday ? "Today · \(day.formatted(style))" : day.formatted(style)
    }
}

/// "Nothing until Thursday" — a run of empty days, in one line.
private struct AgendaGapRow: View {
    let days: [Date]
    let calendar: Calendar

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)

            Text(message)
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize()

            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)
        }
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private var message: String {
        guard days.count > 1, let next = days.last.flatMap({
            calendar.date(byAdding: .day, value: 1, to: $0)
        }) else {
            return "Nothing scheduled"
        }

        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = calendar.timeZone
        return "\(days.count) clear days · next on \(next.formatted(style))"
    }
}

/// One event, in a list.
struct AgendaEventRow: View {
    let event: CalendarEventSummary
    let calendar: Calendar
    let timeZone: TimeZone
    let isAnnotated: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            timeColumn

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                .frame(width: 3)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(event.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .strikethrough(event.isCancelled, color: Theme.Colors.tertiaryText)
                        .rowForeground(event.isCancelled ? .secondary : .primary)
                        .lineLimit(1)

                    if event.isRecurring {
                        Image(systemName: "repeat")
                            .font(Theme.Text.keyHint)
                            .rowForeground(.tertiary)
                            .accessibilityHidden(true)
                    }
                    if isAnnotated {
                        Image(systemName: "text.append")
                            .font(Theme.Text.keyHint)
                            .rowForeground(.tertiary)
                            .accessibilityHidden(true)
                            .help("You have notes about this")
                    }
                    if !event.isEditable {
                        Image(systemName: "lock")
                            .font(Theme.Text.keyHint)
                            .rowForeground(.tertiary)
                            .accessibilityHidden(true)
                            .help("This calendar is read-only")
                    }
                }

                if let context = contextLine {
                    Text(context)
                        .font(Theme.Text.metadata)
                        .rowForeground(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeight)
        .opacity(event.isCancelled ? 0.6 : 1)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.selection.opacity(0.15))
            }
        }
        .hoverHighlight(isEnabled: !isSelected, extending: Theme.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(AccessibilityID.Calendar.eventRow(id: event.id))
        .help(tooltip)
    }

    /// All-day events get a band rather than a time, because "00:00–23:59" is noise pretending to be
    /// information.
    @ViewBuilder
    private var timeColumn: some View {
        if event.isAllDay {
            Text("All day")
                .font(Theme.Text.keyHint)
                .rowForeground(.secondary)
                .padding(.horizontal, Theme.Spacing.tight)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.Colors.subtleFill)
                }
                .frame(width: 66, alignment: .leading)
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatted(event.startAt))
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .rowForeground(.secondary)
                Text(formatted(event.endAt))
                    .font(Theme.Text.keyHint)
                    .monospacedDigit()
                    .rowForeground(.tertiary)
            }
            .frame(width: 66, alignment: .trailing)
        }
    }

    private func formatted(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private var contextLine: String? {
        var parts: [String] = []
        if let location = event.locationName, !location.isEmpty { parts.append(location) }
        if !event.attendeeNames.isEmpty {
            parts.append(event.attendeeNames.prefix(3).joined(separator: ", "))
        }
        if let name = event.calendarName, !name.isEmpty { parts.append(name) }
        if event.isCancelled { parts.append("canceled") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var tooltip: String {
        var lines = [event.displayTitle]
        lines.append(event.timeSummary(in: timeZone, calendar: calendar))
        if let context = contextLine { lines.append(context) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityDescription: String {
        var parts = [event.displayTitle]
        parts.append(event.isAllDay ? "all day" : event.timeSummary(in: timeZone, calendar: calendar))
        if event.isRecurring { parts.append("repeating") }
        if event.isCancelled { parts.append("canceled") }
        if let location = event.locationName, !location.isEmpty { parts.append("at \(location)") }
        if !event.attendeeNames.isEmpty {
            parts.append("with \(event.attendeeNames.prefix(3).joined(separator: ", "))")
        }
        if let name = event.calendarName { parts.append("on \(name)") }
        if isAnnotated { parts.append("has notes") }
        return parts.joined(separator: ", ")
    }
}
