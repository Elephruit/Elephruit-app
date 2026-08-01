import ElephruitCore
import ElephruitDesign
import SwiftUI

/// What a drag on the grid is doing.
///
/// Held as one value rather than three booleans, so the states cannot overlap — a block cannot be
/// simultaneously moving and being resized, and a `nil` here is unambiguously "nothing is happening".
enum GridDragState: Equatable {
    /// Sweeping out a new event.
    case creating(day: Date, from: Double, to: Double)

    /// Moving an existing one, by an offset in hours and days.
    case moving(id: String, dayOffset: Int, hourOffset: Double)

    /// Dragging a block's bottom edge.
    case resizing(id: String, endHour: Double)

    var draggedEventID: String? {
        switch self {
        case .creating: nil
        case .moving(let id, _, _), .resizing(let id, _): id
        }
    }
}

/// The day and week grid.
///
/// One view for both, because a day view is a week view with one column — and the alternative, two
/// views that draw the same ruler, is two places for the current-time indicator to drift out of
/// agreement.
///
/// ### What it does not own
/// It does not fetch, does not write, and does not decide what a drag means. It reports a finished
/// drag as a request — "this event, to this time" — and the caller confirms whatever needs
/// confirming before anything is saved. That separation is what makes a drag onto another calendar
/// or across a recurring series interruptible.
struct CalendarTimeGridView: View {
    let days: [Date]
    let events: [CalendarEventSummary]
    let calendar: Calendar
    let workingHours: WorkingHours
    let density: CalendarDensity
    let timeZoneDisplay: TimeZoneDisplay
    let now: Date
    let annotatedKeys: Set<String>

    @Binding var selectedEventID: String?

    /// A drag that finished on empty space — a new event between two times.
    var onCreate: (Date, Date) -> Void

    /// A block dragged to a new start.
    var onMove: (CalendarEventSummary, Date) -> Void

    /// A block's bottom edge dragged to a new end.
    var onResize: (CalendarEventSummary, Date) -> Void

    var onOpen: (CalendarEventSummary) -> Void

    @State private var drag: GridDragState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hourHeight: CGFloat { density.hourHeight }
    private var gridHeight: CGFloat { hourHeight * 24 }

    private var rulerWidth: CGFloat {
        timeZoneDisplay.secondaryZone == nil
            ? Theme.CalendarMetrics.hourRulerWidth
            : Theme.CalendarMetrics.dualHourRulerWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            allDayBand
            Divider()
            timedGrid
        }
        .background(Theme.Colors.contentBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            zoneLabels
                .frame(width: rulerWidth)

            ForEach(days, id: \.self) { day in
                DayColumnHeader(
                    day: day,
                    calendar: calendar,
                    isToday: calendar.isDate(day, inSameDayAs: now),
                    isWorkingDay: workingHours.includes(weekday: calendar.component(.weekday, from: day))
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Theme.CalendarMetrics.dayHeaderHeight)
    }

    /// The names of the zones the ruler is measuring in.
    ///
    /// Always present when a second zone is shown, because two unlabelled columns of numbers is a
    /// puzzle rather than a ruler.
    @ViewBuilder
    private var zoneLabels: some View {
        if let secondary = timeZoneDisplay.secondaryZone {
            HStack(spacing: Theme.Spacing.tight) {
                Text(TimeZoneDisplay.shortName(for: timeZoneDisplay.displayZone, at: now))
                Text(TimeZoneDisplay.shortName(for: secondary, at: now))
            }
            .font(Theme.Text.keyHint)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.tight)
            .accessibilityLabel("Times shown in two zones")
        } else if timeZoneDisplay.isShowingAnotherZone {
            Text(TimeZoneDisplay.shortName(for: timeZoneDisplay.displayZone, at: now))
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.warning)
                .help("Times are shown in another time zone")
        }
    }

    // MARK: - All-day band

    private var allDayBars: [EventBar] {
        EventLayout.bars(
            for: events.filter { $0.occupiesAllDayRow(calendar: calendar) },
            acrossDays: days,
            calendar: calendar
        )
    }

    @ViewBuilder
    private var allDayBand: some View {
        let bars = allDayBars
        let rows = (bars.map(\.row).max() ?? -1) + 1

        HStack(spacing: 0) {
            Text(rows == 0 ? "" : "All day")
                .font(Theme.Text.keyHint)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: rulerWidth, alignment: .trailing)
                .padding(.trailing, Theme.Spacing.small)

            GeometryReader { proxy in
                let columnWidth = proxy.size.width / CGFloat(max(1, days.count))

                ZStack(alignment: .topLeading) {
                    ForEach(bars) { bar in
                        EventBarView(bar: bar, isSelected: selectedEventID == bar.event.id)
                            .frame(
                                width: columnWidth * CGFloat(bar.columnSpan) - 2,
                                height: Theme.CalendarMetrics.allDayRowHeight - 2
                            )
                            .offset(
                                x: columnWidth * CGFloat(bar.startColumn) + 1,
                                y: CGFloat(bar.row) * Theme.CalendarMetrics.allDayRowHeight + 1
                            )
                            .onTapGesture { select(bar.event) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(bar.event) })
                    }
                }
            }
        }
        .frame(height: bandHeight(rows: rows))
    }

    private func bandHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return Theme.CalendarMetrics.allDayRowHeight }
        let visible = min(rows, Theme.CalendarMetrics.allDayVisibleRows)
        return CGFloat(visible) * Theme.CalendarMetrics.allDayRowHeight
    }

    // MARK: - The timed grid

    private var timedGrid: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    HourRuler(
                        hourHeight: hourHeight,
                        display: timeZoneDisplay,
                        referenceDay: days.first ?? now,
                        calendar: calendar
                    )
                    .frame(width: rulerWidth)

                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        dayColumn(day: day, index: index)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .leading) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(Theme.Colors.separator)
                                        .frame(width: 1)
                                }
                            }
                    }
                }
                .frame(height: gridHeight)
            }
            .onAppear {
                // Opened at the working day rather than at midnight, which is eight hours of empty
                // grid nobody wanted to look at.
                scroller.scrollTo(scrollAnchorHour, anchor: .top)
            }
        }
    }

    /// The hour the grid opens at: the current hour when today is on screen, otherwise the start of
    /// the working day.
    private var scrollAnchorHour: Int {
        if days.contains(where: { calendar.isDate($0, inSameDayAs: now) }) {
            return max(0, calendar.component(.hour, from: now) - 1)
        }
        return max(0, workingHours.startMinutes / 60 - 1)
    }

    private func dayColumn(day: Date, index: Int) -> some View {
        let dayEvents = events.filter {
            $0.occurs(on: day, calendar: calendar) && !$0.occupiesAllDayRow(calendar: calendar)
        }
        let positions = EventLayout.positions(for: dayEvents, on: day, calendar: calendar)

        return ZStack(alignment: .topLeading) {
            HourLines(hourHeight: hourHeight, workingHours: workingHours, day: day, calendar: calendar)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // The creation surface, beneath the blocks so a drag starting on an event moves
                    // that event rather than sweeping a new one out over the top of it.
                    Color.clear
                        .contentShape(.rect)
                        .gesture(creationGesture(day: day))
                        .onTapGesture { selectedEventID = nil }

                    ForEach(positions) { position in
                        eventBlock(position, day: day, dayIndex: index, size: proxy.size)
                    }

                    if case .creating(let dragDay, let from, let to) = drag,
                       calendar.isDate(dragDay, inSameDayAs: day) {
                        DraftBlock(from: min(from, to), to: max(from, to), hourHeight: hourHeight)
                    }

                    if calendar.isDate(day, inSameDayAs: now) {
                        CurrentTimeIndicator(now: now, day: day, hourHeight: hourHeight, calendar: calendar)
                    }
                }
            }
        }
        .frame(height: gridHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dayAccessibilityLabel(day: day, count: dayEvents.count))
    }

    private func dayAccessibilityLabel(day: Date, count: Int) -> String {
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.timeZone = calendar.timeZone
        let name = day.formatted(style)
        return count == 0 ? "\(name), nothing scheduled" : "\(name), \(count) events"
    }

    @ViewBuilder
    private func eventBlock(_ position: PositionedEvent, day: Date, dayIndex: Int, size: CGSize) -> some View {
        let isDragging = drag?.draggedEventID == position.event.id
        let offsetY = draggedOffsetY(for: position)
        let height = draggedHeight(for: position)

        EventBlockView(
            event: position.event,
            isSelected: selectedEventID == position.event.id,
            isAnnotated: annotatedKeys.contains(position.event.id),
            timeZoneDisplay: timeZoneDisplay,
            calendar: calendar,
            showsDetail: height > 30
        )
        .frame(
            width: max(8, size.width * position.width - 2),
            height: max(Theme.CalendarMetrics.minimumBlockHeight, height)
        )
        .offset(
            x: size.width * position.leading + 1 + draggedOffsetX(for: position, columnWidth: size.width),
            y: offsetY
        )
        .zIndex(isDragging ? 100 : Double(position.depth))
        .opacity(isDragging ? 0.85 : 1)
        .onTapGesture { select(position.event) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(position.event) })
        .gesture(moveGesture(position.event, day: day, columnWidth: size.width))
        .overlay(alignment: .bottom) {
            if position.event.isEditable {
                resizeHandle(position.event, day: day)
            }
        }
        .calmAnimation(Theme.Motion.appearance, value: isDragging)
    }

    /// Where a block sits, including any drag in progress.
    private func draggedOffsetY(for position: PositionedEvent) -> CGFloat {
        let base = position.top * gridHeight
        guard case .moving(let id, _, let hourOffset) = drag, id == position.event.id else { return base }
        return base + hourOffset * hourHeight
    }

    /// How far a block has been dragged sideways, in points.
    ///
    /// Only ever non-zero in a week view: a day view has one column, and letting a block drift out
    /// of it would be a drag with nowhere to land.
    private func draggedOffsetX(for position: PositionedEvent, columnWidth: CGFloat) -> CGFloat {
        guard days.count > 1 else { return 0 }
        guard case .moving(let id, let dayOffset, _) = drag, id == position.event.id else { return 0 }
        return CGFloat(dayOffset) * columnWidth
    }

    private func draggedHeight(for position: PositionedEvent) -> CGFloat {
        let base = position.height * gridHeight
        guard case .resizing(let id, let endHour) = drag, id == position.event.id else { return base }

        let startHour = position.top * 24
        return max(Theme.CalendarMetrics.minimumBlockHeight, CGFloat(endHour - startHour) * hourHeight)
    }

    private func resizeHandle(_ event: CalendarEventSummary, day: Date) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(.rect)
            .frame(height: Theme.CalendarMetrics.resizeHandleHeight)
            .gesture(resizeGesture(event, day: day))
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .accessibilityHidden(true)
    }

    private func select(_ event: CalendarEventSummary) {
        selectedEventID = event.id
    }

    // MARK: - Gestures

    /// Sweeping out a new event on empty space.
    private func creationGesture(day: Date) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let from = snappedHour(at: value.startLocation.y)
                let to = snappedHour(at: value.location.y)
                drag = .creating(day: day, from: from, to: to)
            }
            .onEnded { value in
                defer { drag = nil }

                let from = snappedHour(at: value.startLocation.y)
                let to = snappedHour(at: value.location.y)
                let lower = min(from, to)
                // A flick rather than a sweep still means "an event here", and the default length is
                // more useful than a five-minute sliver nobody wanted.
                let upper = max(to, from) - lower < 0.25 ? lower + 1 : max(from, to)

                guard let start = date(day: day, hour: lower), let end = date(day: day, hour: upper) else {
                    return
                }
                onCreate(start, end)
            }
    }

    /// Dragging a block to another time, and in a week view to another day.
    ///
    /// Both axes at once, because that is how somebody moves "Tuesday at ten" to "Thursday at two" —
    /// one gesture, not two. The day is worked out from the column width rather than from a drop
    /// target, so the block follows the pointer continuously instead of jumping between columns.
    private func moveGesture(_ event: CalendarEventSummary, day: Date, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard event.isEditable else { return }
                drag = .moving(
                    id: event.id,
                    dayOffset: dayDelta(value.translation.width, columnWidth: columnWidth),
                    hourOffset: snappedDelta(value.translation.height)
                )
            }
            .onEnded { value in
                defer { drag = nil }
                guard event.isEditable else { return }

                let hourDelta = snappedDelta(value.translation.height)
                let dayDelta = dayDelta(value.translation.width, columnWidth: columnWidth)
                guard hourDelta != 0 || dayDelta != 0 else { return }

                // Days first, through `Calendar`, so a drag across a clock change keeps the event at
                // the same time of day rather than sliding it by an hour. Adding 86,400 seconds
                // would be wrong twice a year, on exactly the days somebody is most confused.
                let shifted = calendar.date(byAdding: .day, value: dayDelta, to: event.startAt)
                    ?? event.startAt
                onMove(event, shifted.addingTimeInterval(hourDelta * 3_600))
            }
    }

    /// How many columns a sideways drag has crossed.
    ///
    /// Clamped to the visible week, so dragging off the edge lands on the last day rather than
    /// producing an event three weeks away that nobody can see to correct.
    private func dayDelta(_ width: CGFloat, columnWidth: CGFloat) -> Int {
        guard days.count > 1, columnWidth > 0 else { return 0 }
        let raw = Int((width / columnWidth).rounded())
        return min(max(raw, -(days.count - 1)), days.count - 1)
    }

    private func resizeGesture(_ event: CalendarEventSummary, day: Date) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let dayStart = calendar.startOfDay(for: day)
                let currentEnd = event.endAt.timeIntervalSince(dayStart) / 3_600
                let proposed = currentEnd + snappedDelta(value.translation.height)
                drag = .resizing(id: event.id, endHour: proposed)
            }
            .onEnded { value in
                defer { drag = nil }

                let delta = snappedDelta(value.translation.height)
                guard delta != 0 else { return }

                let newEnd = event.endAt.addingTimeInterval(delta * 3_600)
                guard newEnd > event.startAt else { return }
                onResize(event, newEnd)
            }
    }

    /// Snaps a vertical position to the nearest quarter hour.
    private func snappedHour(at y: CGFloat) -> Double {
        let raw = Double(max(0, min(y, gridHeight)) / hourHeight)
        let step = Double(Theme.CalendarMetrics.dragSnapMinutes) / 60
        return (raw / step).rounded() * step
    }

    /// Snaps a drag *distance* to the nearest quarter hour.
    private func snappedDelta(_ height: CGFloat) -> Double {
        let raw = Double(height / hourHeight)
        let step = Double(Theme.CalendarMetrics.dragSnapMinutes) / 60
        return (raw / step).rounded() * step
    }

    /// An instant on a day, from an hour offset.
    ///
    /// Built by adding minutes to the start of the day rather than by setting an hour, so a day on
    /// which the clocks change still produces a real instant.
    private func date(day: Date, hour: Double) -> Date? {
        let minutes = Int((hour * 60).rounded())
        return calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day))
    }
}

// MARK: - The ruler

/// The hour column, in one zone or two.
private struct HourRuler: View {
    let hourHeight: CGFloat
    let display: TimeZoneDisplay
    let referenceDay: Date
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: Theme.Spacing.tight) {
                    Spacer(minLength: 0)
                    Text(label(hour: hour, in: display.displayZone))
                        .font(Theme.Text.keyHint)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if let secondary = display.secondaryZone {
                        Text(label(hour: hour, in: secondary))
                            .font(Theme.Text.keyHint)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.7))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.trailing, Theme.Spacing.small)
                // Nudged up so the label sits beside the line rather than below it.
                .offset(y: -6)
                .frame(height: hourHeight, alignment: .top)
            }
        }
        .accessibilityHidden(true)
    }

    /// The wall-clock hour in a zone, read at the day being shown.
    ///
    /// Read at the day rather than computed from a fixed offset, because the gap between two zones
    /// is not constant — it changes for a fortnight each spring, which is exactly when somebody
    /// looking at a dual ruler most needs it to be right.
    ///
    /// ### Why the hour and not the time
    /// This used to ask for `.shortened`, which is "10:00 AM" — eight characters in a column 56
    /// points wide. Everything up to "9:00 AM" fitted and everything after it wrapped, so the ruler
    /// read 8:00 AM, 9:00 AM, "10:00 A / M", "11:00 A / M", "12:00 P / M" down the side of the week.
    ///
    /// The fix is not a wider column. A ruler of whole hours has no minutes to report, and printing
    /// ":00" twenty-four times says nothing while taking the room that made it wrap. `.hour()` gives
    /// "10 AM" here and "10" in a twenty-four-hour locale, which is what Calendar itself shows.
    private func label(hour: Int, in zone: TimeZone) -> String {
        let dayStart = calendar.startOfDay(for: referenceDay)
        guard let instant = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { return "" }

        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = zone
        return instant.formatted(style)
    }
}

/// The horizontal hour lines, and the shading outside working hours.
private struct HourLines: View {
    let hourHeight: CGFloat
    let workingHours: WorkingHours
    let day: Date
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(isWorking(hour: hour) ? Color.clear : Theme.Colors.outsideWorkingHours)
                    Rectangle()
                        .fill(Theme.Colors.separator.opacity(0.5))
                        .frame(height: 1)
                }
                .frame(height: hourHeight)
            }
        }
        .accessibilityHidden(true)
    }

    private func isWorking(hour: Int) -> Bool {
        guard workingHours.includes(weekday: calendar.component(.weekday, from: day)) else { return false }
        let minutes = hour * 60
        return minutes >= workingHours.startMinutes && minutes < workingHours.endMinutes
    }
}

/// The line across the grid marking the present moment.
private struct CurrentTimeIndicator: View {
    let now: Date
    let day: Date
    let hourHeight: CGFloat
    let calendar: Calendar

    var body: some View {
        let hours = now.timeIntervalSince(calendar.startOfDay(for: day)) / 3_600

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.currentTime)
                .frame(height: 1.5)

            Circle()
                .fill(Theme.Colors.currentTime)
                .frame(width: 7, height: 7)
                .offset(x: -3)
        }
        .offset(y: CGFloat(hours) * hourHeight)
        .allowsHitTesting(false)
        .accessibilityLabel("Now")
    }
}

/// The block being swept out by a drag.
private struct DraftBlock: View {
    let from: Double
    let to: Double
    let hourHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.Colors.draftEvent.opacity(0.25))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.Colors.draftEvent, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(height: max(Theme.CalendarMetrics.minimumBlockHeight, CGFloat(to - from) * hourHeight))
            .offset(y: CGFloat(from) * hourHeight)
            .allowsHitTesting(false)
    }
}

// MARK: - Blocks

/// One event in a time grid.
struct EventBlockView: View {
    let event: CalendarEventSummary
    let isSelected: Bool
    let isAnnotated: Bool
    let timeZoneDisplay: TimeZoneDisplay
    let calendar: Calendar

    /// Whether the block is tall enough for a second line.
    let showsDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.hairline) {
                Text(event.displayTitle)
                    .font(Theme.Text.keyHint)
                    .fontWeight(.medium)
                    .strikethrough(event.isCancelled)
                    .lineLimit(showsDetail ? 2 : 1)

                if event.isRecurring {
                    Image(systemName: "repeat")
                        .font(.system(size: 7))
                        .accessibilityHidden(true)
                }
                if isAnnotated {
                    Image(systemName: "text.append")
                        .font(.system(size: 7))
                        .accessibilityHidden(true)
                }
            }

            if showsDetail, let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.EventStyle.fill(colorName: event.calendarColorName, isCancelled: event.isCancelled))
        }
        .overlay(alignment: .leading) {
            // The saturated edge, which is what makes a calendar identifiable at a glance without
            // the whole block being a solid colour that titles cannot be read off.
            Rectangle()
                .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                .frame(width: 2.5)
                .clipShape(.rect(topLeadingRadius: Theme.Radius.small, bottomLeadingRadius: Theme.Radius.small))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Theme.Colors.selection
                        : Theme.EventStyle.border(colorName: event.calendarColorName),
                    lineWidth: isSelected ? 2 : 0.5
                )
        }
        .opacity(event.isCancelled ? 0.65 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(AccessibilityID.Calendar.eventRow(id: event.id))
        .help(tooltip)
    }

    private var detail: String? {
        if let location = event.locationName, !location.isEmpty { return location }
        return event.timeSummary(in: timeZoneDisplay.displayZone, calendar: calendar)
    }

    private var tooltip: String {
        var lines = [event.displayTitle, event.timeSummary(in: timeZoneDisplay.displayZone, calendar: calendar)]
        if let location = event.locationName, !location.isEmpty { lines.append(location) }
        if let name = event.calendarName { lines.append(name) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityDescription: String {
        var parts = [event.displayTitle]
        parts.append(event.timeSummary(in: timeZoneDisplay.displayZone, calendar: calendar))
        if event.isRecurring { parts.append("repeating") }
        if event.isCancelled { parts.append("canceled") }
        if let location = event.locationName, !location.isEmpty { parts.append("at \(location)") }
        if let name = event.calendarName { parts.append("on \(name)") }
        if isAnnotated { parts.append("has notes") }
        if !event.isEditable { parts.append("read only") }
        return parts.joined(separator: ", ")
    }
}

/// One all-day or multi-day event, as a bar.
struct EventBarView: View {
    let bar: EventBar
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if bar.continuesBefore {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 8))
                    .accessibilityHidden(true)
            }

            Text(bar.event.displayTitle)
                .font(Theme.Text.keyHint)
                .lineLimit(1)

            Spacer(minLength: 0)

            if bar.continuesAfter {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.EventStyle.fill(colorName: bar.event.calendarColorName))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.Colors.selection : Theme.EventStyle.border(colorName: bar.event.calendarColorName),
                    lineWidth: isSelected ? 2 : 0.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityDescription: String {
        var parts = [bar.event.displayTitle, "all day"]
        if bar.columnSpan > 1 { parts.append("\(bar.columnSpan) days") }
        if bar.continuesBefore { parts.append("started earlier") }
        if bar.continuesAfter { parts.append("continues") }
        return parts.joined(separator: ", ")
    }
}

/// The date above a day column.
private struct DayColumnHeader: View {
    let day: Date
    let calendar: Calendar
    let isToday: Bool
    let isWorkingDay: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(weekdayName)
                .font(Theme.Text.keyHint)
                .textCase(.uppercase)
                .foregroundStyle(isWorkingDay ? Theme.Colors.secondaryText : Theme.Colors.tertiaryText)

            Text(dayNumber)
                .font(.system(.title3, design: .default, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.white : Theme.Colors.primaryText)
                .frame(width: 26, height: 26)
                .background {
                    if isToday {
                        Circle().fill(Theme.Colors.currentTime)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var weekdayName: String {
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    private var dayNumber: String {
        var style = Date.FormatStyle().day()
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    private var accessibilityDescription: String {
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.timeZone = calendar.timeZone
        return isToday ? "Today, \(day.formatted(style))" : day.formatted(style)
    }
}

import AppKit
