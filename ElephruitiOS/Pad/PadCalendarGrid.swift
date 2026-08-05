import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The calendar on the iPad: the phone's month-and-agenda, or a real time grid.
///
/// The phone's screen argues its own case — "the Mac's week and quarter grids trade on width; a
/// phone trades on scrolling" — and that argument is about the phone. A landscape iPad has 1,376
/// points, which is more than the Mac's default window, so the trade the phone could not make is
/// available here and the grid the Mac has had all along arrives with it.
///
/// Three views, not six. A day and a week are what a time grid is *for*: seeing where the gaps
/// are, and how long a thing actually takes. A month is the orienting view and already exists
/// above the agenda; a quarter and a year are planning surfaces that read as heat maps, and
/// shipping them at half their Mac size would be shipping the picture without the resolution that
/// makes it worth looking at.
struct PadCalendarScreen: View {
    @Environment(\.services) private var services

    @SceneStorage("pad.calendar.view") private var view = PadCalendarView.agenda

    var body: some View {
        Group {
            switch view {
            case .agenda: CalendarScreen()
            case .week: PadCalendarTimeGrid(dayCount: 7)
            case .day: PadCalendarTimeGrid(dayCount: 1)
            }
        }
        // A review launch names the view outright, so a screenshot run never depends on which
        // view the last session happened to leave in scene storage.
        .task {
            if let requested = PadReviewLaunch.requestedCalendarView { view = requested }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Calendar view", selection: $view) {
                    ForEach(PadCalendarView.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("pad.calendar.view")
            }
        }
    }
}

/// What the iPad's calendar can be.
enum PadCalendarView: String, CaseIterable, Hashable {
    case agenda
    case week
    case day

    var title: String {
        switch self {
        case .agenda: "Month"
        case .week: "Week"
        case .day: "Day"
        }
    }
}

/// A time grid: hours down the side, days across the top, events in their real proportions.
///
/// The layout maths is `EventLayout`, which lives in `ElephruitCore` and is the same code the Mac's
/// grid uses — overlap clustering, column assignment, the fifteen-minute floor that keeps a
/// zero-length event tappable, and the clipping that stops a meeting from last night being drawn
/// as this morning. Two calendars that disagreed about which of two overlapping events sits in
/// front would be two calendars.
struct PadCalendarTimeGrid: View {
    @Environment(\.services) private var services
    @Environment(PadShellModel.self) private var pad

    /// Seven for a week, one for a day. The only difference between the two views.
    let dayCount: Int

    @State private var anchor = Date()
    @State private var isCreatingEvent = false

    /// How tall an hour is. Enough that a half-hour meeting has room for its title, and that a
    /// working day fits a landscape iPad without scrolling.
    private static let hourHeight: CGFloat = 52

    /// Where the grid opens. Seven, so the hour before a working day is visible above it.
    private static let openingHour = 7

    /// The width of the hour-label gutter.
    @ScaledMetric(relativeTo: .caption) private var gutterWidth: CGFloat = 52

    var body: some View {
        Group {
            if let services, services.calendar.isEnabled, services.calendar.authorization == .authorized {
                grid(services)
            } else {
                // Permission and enablement are the phone screen's job, and it says all of it
                // well; a second copy here would be a second wording to keep in step.
                CalendarScreen()
            }
        }
        .navigationTitle(rangeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCreatingEvent) {
            EventEditorSheet(existing: nil, defaultDay: anchor)
        }
    }

    // MARK: - The grid

    @ViewBuilder
    private func grid(_ services: AppServices) -> some View {
        let calendar = services.calendar
        let displayCalendar = calendar.displayCalendar
        let days = days(displayCalendar)

        VStack(spacing: 0) {
            header(days: days, displayCalendar: displayCalendar)
            allDayBand(days: days, calendar: calendar, displayCalendar: displayCalendar)
            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    hourCanvas(days: days, calendar: calendar, displayCalendar: displayCalendar)
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    // Opened on the working day rather than on midnight. A grid that starts at
                    // 00:00 spends its first screen on the hours nothing happens in, and every
                    // arrival costs a scroll before the calendar says anything.
                    scroller.scrollTo(Self.openingHour, anchor: .top)
                }
            }
        }
        // Top-aligned explicitly: the columns are taller than the stage, and a `VStack` handed
        // more content than room centres it — which left a screen of white above the weekday
        // header and the last hours of the day cut off below.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.contentBackground)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: Theme.Spacing.tight) {
                    Button("Previous", systemImage: "chevron.left") { step(by: -1, displayCalendar) }
                        .accessibilityIdentifier("pad.calendar.previous")
                    Button("Today") {
                        withCalmAnimation(Theme.Motion.standard) { anchor = services.dateProvider.now }
                    }
                    Button("Next", systemImage: "chevron.right") { step(by: 1, displayCalendar) }
                        .accessibilityIdentifier("pad.calendar.next")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreatingEvent = true
                } label: {
                    Label("New Event", systemImage: "plus")
                }
            }
        }
        .task(id: anchorKey(displayCalendar)) {
            await calendar.load(range: loadRange(displayCalendar))
        }
        .task {
            await calendar.start()
        }
    }

    /// The day names and numbers, aligned with the columns beneath them.
    private func header(days: [Date], displayCalendar: Calendar) -> some View {
        HStack(spacing: 0) {
            // Fixed in both axes. A bare `Color` is greedy in the axis nobody constrained, and one
            // sized only by width stretched the whole header row to the height of the stage — a
            // screen of white above the week, with the weekday names floating in the middle of it.
            Color.clear.frame(width: gutterWidth, height: 1)

            ForEach(days, id: \.self) { day in
                let isToday = displayCalendar.isDateInToday(day)
                VStack(spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text("\(displayCalendar.component(.day, from: day))")
                        .font(Theme.Text.rowTitle)
                        .monospacedDigit()
                        .fontWeight(isToday ? .bold : .regular)
                        .foregroundStyle(isToday ? Theme.Colors.onAccent : Theme.Colors.primaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isToday ? Theme.Colors.selection : .clear))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.tight)
                .contentShape(Rectangle())
                .onTapGesture { withCalmAnimation(Theme.Motion.standard) { anchor = day } }
                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            }
        }
    }

    /// All-day and multi-day events, above the grid and spanning the days they cover.
    ///
    /// Absent when there are none: a permanently reserved strip would cost every day two lines of
    /// height to say nothing on most of them.
    @ViewBuilder
    private func allDayBand(days: [Date], calendar: CalendarService, displayCalendar: Calendar)
        -> some View {
        let spanning = days
            .flatMap { calendar.events(on: $0) }
            .filter { $0.isAllDay || !displayCalendar.isDate($0.startAt, inSameDayAs: $0.endAt) }
        let unique = Array(Set(spanning)).sorted { $0.startAt < $1.startAt }
        let bars = EventLayout.bars(for: unique, acrossDays: days, calendar: displayCalendar)

        if !bars.isEmpty {
            let rowCount = (bars.map(\.row).max() ?? 0) + 1
            HStack(spacing: 0) {
                Text("all-day")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: gutterWidth)

                GeometryReader { proxy in
                    let columnWidth = proxy.size.width / CGFloat(days.count)
                    ForEach(bars) { bar in
                        allDayBar(bar)
                            .frame(width: columnWidth * CGFloat(bar.columnSpan) - 4, height: 20)
                            .offset(
                                x: columnWidth * CGFloat(bar.startColumn) + 2,
                                y: CGFloat(bar.row) * 24
                            )
                    }
                }
                .frame(height: CGFloat(rowCount) * 24)
            }
            .padding(.bottom, Theme.Spacing.tight)
        }
    }

    private func allDayBar(_ bar: EventBar) -> some View {
        Button {
            pad.route(.event(bar.event.identity.storageKey))
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                // The continuity flags are the point of drawing bars rather than chips: a
                // conference that started last week should look like one that started last week.
                if bar.continuesBefore {
                    Image(systemName: "chevron.compact.left").font(.caption2)
                }
                Text(bar.event.displayTitle)
                    .font(Theme.Text.metadata)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if bar.continuesAfter {
                    Image(systemName: "chevron.compact.right").font(.caption2)
                }
            }
            .padding(.horizontal, Theme.Spacing.tight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Theme.Colors.primaryText)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Palette.color(named: bar.event.calendarColorName).opacity(0.22))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pad.calendar.allDay.\(bar.event.id)")
    }

    /// The hours, the day columns, and the events inside them.
    private func hourCanvas(days: [Date], calendar: CalendarService, displayCalendar: Calendar)
        -> some View {
        let height = Self.hourHeight * 24

        return HStack(alignment: .top, spacing: 0) {
            hourGutter
                .frame(width: gutterWidth, height: height)
                .overlay(alignment: .top) {
                    // Invisible anchors, one per hour, so the opening scroll names an hour rather
                    // than guessing an offset.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(height: Self.hourHeight).id(hour)
                        }
                    }
                }

            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    dayColumn(day, calendar: calendar, displayCalendar: displayCalendar)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle()
                                    .fill(Theme.Colors.separator)
                                    .frame(width: 0.5)
                            }
                        }
                }
            }
        }
    }

    /// The hour labels, sitting on their own rules rather than between them.
    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, Theme.Spacing.tight)
                    .frame(height: Self.hourHeight, alignment: .top)
                    // Half a line up, so the label sits *on* the rule it names.
                    .offset(y: -6)
            }
        }
    }

    private func dayColumn(_ day: Date, calendar: CalendarService, displayCalendar: Calendar)
        -> some View {
        let timed = calendar.events(on: day).filter {
            !$0.isAllDay && displayCalendar.isDate($0.startAt, inSameDayAs: $0.endAt)
        }
        let positions = EventLayout.positions(for: timed, on: day, calendar: displayCalendar)
        let height = Self.hourHeight * 24

        return ZStack(alignment: .topLeading) {
            hourRules

            GeometryReader { proxy in
                ForEach(positions) { positioned in
                    eventBlock(positioned)
                        .frame(
                            width: max(24, proxy.size.width * positioned.width - 3),
                            height: max(16, height * positioned.height - 2)
                        )
                        .offset(
                            x: proxy.size.width * positioned.leading + 1.5,
                            y: height * positioned.top + 1
                        )
                }

                if let now = nowOffset(on: day, displayCalendar: displayCalendar) {
                    nowLine.offset(y: height * now)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var hourRules: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Theme.Colors.separator)
                        .frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(height: Self.hourHeight)
            }
        }
    }

    private func eventBlock(_ positioned: PositionedEvent) -> some View {
        let event = positioned.event
        let tint = Theme.Palette.color(named: event.calendarColorName)

        return Button {
            pad.route(.event(event.identity.storageKey))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(event.displayTitle)
                    .font(Theme.Text.metadata)
                    .fontWeight(.medium)
                    .strikethrough(event.isCancelled)
                    .lineLimit(2)
                if let location = event.locationName, !location.isEmpty {
                    Text(location)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Theme.Colors.primaryText)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(tint.opacity(0.20))
            )
            .overlay(alignment: .leading) {
                // A bar rather than a border: at 20% fill two adjacent events of different
                // calendars are hard to tell apart, and the edge is where the eye already is.
                Capsule().fill(tint).frame(width: 3).padding(.vertical, 2)
            }
        }
        .buttonStyle(.plain)
        // Declined and cancelled events are drawn, not hidden — knowing a thing was on the
        // calendar and is off it is the point.
        .opacity(event.isCancelled || event.participation == .declined ? 0.55 : 1)
        .accessibilityLabel(
            "\(event.displayTitle), \(event.startAt.formatted(date: .omitted, time: .shortened))"
        )
        .accessibilityIdentifier("pad.calendar.event.\(event.id)")
    }

    /// The current time, on today's column only.
    private var nowLine: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.destructive)
                .frame(height: 1.5)
            Circle()
                .fill(Theme.Colors.destructive)
                .frame(width: 6, height: 6)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Windows

    private func days(_ displayCalendar: Calendar) -> [Date] {
        guard dayCount > 1 else { return [displayCalendar.startOfDay(for: anchor)] }
        let interval = displayCalendar.dateInterval(of: .weekOfYear, for: anchor)
        let start = interval?.start ?? displayCalendar.startOfDay(for: anchor)
        return (0..<dayCount).compactMap { displayCalendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func step(by direction: Int, _ displayCalendar: Calendar) {
        withCalmAnimation(Theme.Motion.standard) {
            anchor = displayCalendar.date(
                byAdding: dayCount > 1 ? .weekOfYear : .day,
                value: direction,
                to: anchor
            ) ?? anchor
        }
    }

    private func loadRange(_ displayCalendar: Calendar) -> Range<Date> {
        let days = days(displayCalendar)
        let start = days.first ?? displayCalendar.startOfDay(for: anchor)
        let end = displayCalendar.date(byAdding: .day, value: 1, to: days.last ?? start) ?? start
        return start..<end
    }

    private func anchorKey(_ displayCalendar: Calendar) -> String {
        let start = days(displayCalendar).first ?? anchor
        return "\(dayCount)-\(start.timeIntervalSinceReferenceDate)"
    }

    /// Where the current time falls in the day, as a fraction — `nil` on any day but today.
    private func nowOffset(on day: Date, displayCalendar: Calendar) -> Double? {
        guard let now = services?.dateProvider.now,
            displayCalendar.isDate(day, inSameDayAs: now)
        else { return nil }
        let start = displayCalendar.startOfDay(for: now)
        return now.timeIntervalSince(start) / 86_400
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private var rangeTitle: String {
        let displayCalendar = services?.calendar.displayCalendar ?? .current
        let days = days(displayCalendar)
        guard let first = days.first, let last = days.last, dayCount > 1 else {
            return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        if displayCalendar.isDate(first, equalTo: last, toGranularity: .month) {
            return first.formatted(.dateTime.month(.wide).year())
        }
        return "\(first.formatted(.dateTime.month(.abbreviated))) – "
            + last.formatted(.dateTime.month(.abbreviated).year())
    }
}
