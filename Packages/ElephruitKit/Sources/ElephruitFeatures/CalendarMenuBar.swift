import ElephruitCore
import ElephruitDesign
import SwiftUI

/// What the menu bar shows about the calendar.
///
/// ### Why a calendar belongs in the menu bar at all
/// The same argument as the timer: the thing you need to know about your next meeting is needed
/// while you are doing something *else*. A calendar you can only see by switching to Elephruit is
/// one you switch to Elephruit to check, which is a worse version of not having it.
///
/// What is deliberately absent, per the module's scope: no task list, no weather, no availability,
/// no conferencing controls, and nothing that publishes anything.
public struct CalendarMenuBarContent: View {
    private let services: AppServices

    /// Opening the main window at the calendar.
    private let onOpenCalendar: () -> Void

    /// Opening quick entry without going through a window first.
    private let onQuickEntry: () -> Void

    @State private var today: [CalendarEventSummary] = []
    @State private var next: CalendarEventSummary?
    @State private var window: [CalendarEventSummary] = []

    public init(
        services: AppServices,
        onOpenCalendar: @escaping () -> Void,
        onQuickEntry: @escaping () -> Void
    ) {
        self.services = services
        self.onOpenCalendar = onOpenCalendar
        self.onQuickEntry = onQuickEntry
    }

    public var body: some View {
        Group {
            if !services.calendar.isEnabled {
                Button("Turn On Calendar…", action: onOpenCalendar)
            } else if !services.calendar.authorization.canRead {
                Text(services.calendar.authorization.explanation ?? "Calendar unavailable")
                Button("Open Elephruit", action: onOpenCalendar)
            } else {
                nextEvent
                Divider()
                agenda
                Divider()
                actions
            }
        }
        .task { await refresh() }
    }

    // MARK: The next thing

    @ViewBuilder
    private var nextEvent: some View {
        if let next {
            Button {
                onOpenCalendar()
            } label: {
                Text("Next: \(next.displayTitle) · \(countdown(to: next))")
            }
            .help(nextTooltip(next))
        } else {
            Text("Nothing left today")
        }
    }

    private func countdown(to event: CalendarEventSummary) -> String {
        let minutes = Int(event.startAt.timeIntervalSince(services.dateProvider.now) / 60)

        switch minutes {
        case ..<0: return "now"
        case 0: return "now"
        case 1..<60: return "in \(minutes) min"
        default:
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = services.calendar.timeZoneDisplay.displayZone
            return "at \(event.startAt.formatted(style))"
        }
    }

    private func nextTooltip(_ event: CalendarEventSummary) -> String {
        var parts = [event.timeSummary(
            in: services.calendar.timeZoneDisplay.displayZone,
            calendar: services.calendar.displayCalendar
        )]
        if let location = event.locationName, !location.isEmpty { parts.append(location) }
        if let name = event.calendarName { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    // MARK: Today

    @ViewBuilder
    private var agenda: some View {
        if today.isEmpty {
            Text("Nothing scheduled today")
        } else {
            ForEach(today.prefix(8)) { event in
                Button {
                    onOpenCalendar()
                } label: {
                    Text("\(timeLabel(event))  \(event.displayTitle)")
                }
                .help(nextTooltip(event))
            }

            if today.count > 8 {
                Text("…and \(today.count - 8) more")
            }
        }
    }

    private func timeLabel(_ event: CalendarEventSummary) -> String {
        guard !event.isAllDay else { return "All day" }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = services.calendar.timeZoneDisplay.displayZone
        return event.startAt.formatted(style)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        Button("New Event…", action: onQuickEntry)
            .shortcut(.newEvent, in: services.shortcuts)

        Menu("Calendar Set") {
            Button("All Calendars") {
                Task { await services.calendar.activate(setID: nil) }
            }
            ForEach(services.calendar.sets) { set in
                Button(set.name) {
                    Task { await services.calendar.activate(setID: set.id) }
                }
            }
        }

        Button("Open Calendar", action: onOpenCalendar)
    }

    // MARK: Loading

    /// Reads a day either side of now.
    ///
    /// A day either side rather than exactly today, because "next" at half past eleven at night is
    /// tomorrow morning's meeting, and a menu that says "nothing left today" while somebody has a
    /// 7 a.m. flight is the wrong answer to the question they asked.
    private func refresh() async {
        // Starting the service here as well as in a window, because the menu bar can be the first
        // thing on screen — the app may be launched into the background by a Shortcut, and a menu
        // that says "nothing scheduled" because nobody opened a window is worse than an empty one.
        await services.calendar.start()

        let calendar = services.calendar.displayCalendar
        let start = calendar.startOfDay(for: services.dateProvider.now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }

        // `peek` rather than `load`: a window is showing a month and this wants two days, and
        // whichever called `load` last would decide what the other reloaded on the next change.
        window = await services.calendar.peek(range: start..<end)

        let today = calendar.startOfDay(for: services.dateProvider.now)
        self.today = window.filter { $0.occurs(on: today, calendar: calendar) && $0.appearsInPlan }
        next = window
            .filter { $0.startAt > services.dateProvider.now && $0.appearsInPlan && !$0.isAllDay }
            .min { $0.startAt < $1.startAt }
    }
}

/// The menu bar's label: the next meeting, or the date.
///
/// A label rather than an icon, because the fact worth having in the menu bar is *when the next
/// thing is*, and an icon can only say that something exists.
public struct CalendarMenuBarLabel: View {
    private let services: AppServices

    @State private var next: CalendarEventSummary?

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        Group {
            if let next {
                Label(shortLabel(next), systemImage: "calendar")
            } else {
                Label(dayLabel, systemImage: "calendar")
            }
        }
        .task { await refresh() }
        .accessibilityLabel(accessibilityDescription)
    }

    private func shortLabel(_ event: CalendarEventSummary) -> String {
        let minutes = Int(event.startAt.timeIntervalSince(services.dateProvider.now) / 60)
        let title = event.displayTitle.prefix(18)

        switch minutes {
        case ..<1: return "\(title) now"
        case 1..<60: return "\(title) \(minutes)m"
        default:
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = services.calendar.timeZoneDisplay.displayZone
            return "\(title) \(event.startAt.formatted(style))"
        }
    }

    private var dayLabel: String {
        var style = Date.FormatStyle().weekday(.abbreviated).day()
        style.timeZone = services.calendar.timeZoneDisplay.displayZone
        return services.dateProvider.now.formatted(style)
    }

    private var accessibilityDescription: String {
        guard let next else { return "Calendar. Nothing left today." }
        return "Calendar. Next: \(next.displayTitle), \(next.startAt.formatted(date: .omitted, time: .shortened))"
    }

    private func refresh() async {
        await services.calendar.start()
        guard services.calendar.isEnabled, services.calendar.authorization.canRead else { return }

        let calendar = services.calendar.displayCalendar
        let start = calendar.startOfDay(for: services.dateProvider.now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }

        next = await services.calendar.peek(range: start..<end)
            .filter { $0.startAt > services.dateProvider.now && $0.appearsInPlan && !$0.isAllDay }
            .min { $0.startAt < $1.startAt }
    }
}

/// The mini month, for the menu bar panel.
///
/// Small, dense, and read-only: it answers "what day is the 14th" and "how full is next week",
/// which are the two questions a menu bar calendar is actually for. Clicking a day opens the main
/// window there.
public struct MiniMonthView: View {
    private let month: Date
    private let calendar: Calendar
    private let density: [DayDensity]
    private let now: Date
    private let onSelect: (Date) -> Void

    public init(
        month: Date,
        calendar: Calendar,
        events: [CalendarEventSummary],
        workingHours: WorkingHours,
        now: Date,
        onSelect: @escaping (Date) -> Void
    ) {
        self.month = month
        self.calendar = calendar
        self.now = now
        self.onSelect = onSelect

        let days = Self.days(of: month, calendar: calendar)
        self.density = EventLayout.density(
            of: events, acrossDays: days, workingHours: workingHours, calendar: calendar
        )
    }

    private static func days(of month: Date, calendar: Calendar) -> [Date] {
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

    private var leadingBlanks: Int {
        guard let first = density.first?.day else { return 0 }
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(monthName)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 1), count: 7), spacing: 1) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: 20, height: 18)
                }

                ForEach(density) { entry in
                    Button {
                        onSelect(entry.day)
                    } label: {
                        Text("\(calendar.component(.day, from: entry.day))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .frame(width: 20, height: 18)
                            .background {
                                if calendar.isDate(entry.day, inSameDayAs: now) {
                                    Circle().fill(Theme.Colors.currentTime.opacity(0.25))
                                } else if !entry.isEmpty {
                                    Circle().fill(Theme.Colors.selection.opacity(0.12 + entry.intensity * 0.3))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(tooltip(entry))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini calendar for \(monthName)")
    }

    private var monthName: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }

    private func tooltip(_ entry: DayDensity) -> String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        let name = entry.day.formatted(style)
        return entry.isEmpty ? name : "\(name) — \(entry.eventCount) event\(entry.eventCount == 1 ? "" : "s")"
    }
}
