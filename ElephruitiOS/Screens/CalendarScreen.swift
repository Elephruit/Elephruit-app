import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The calendar, phone-sized: a month to orient by, an agenda to read, sets to switch.
///
/// Agenda-first deliberately. The Mac's week and quarter grids trade on width; a phone
/// trades on scrolling, and an agenda under a compact month is the arrangement every
/// usable phone calendar has converged on. Same `CalendarService`, same sets, same
/// time-zone rules underneath.
struct CalendarScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var anchor = Date()
    @State private var isCreatingEvent = false

    var body: some View {
        Group {
            if let services {
                content(services)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ services: AppServices) -> some View {
        let calendar = services.calendar

        if !calendar.isEnabled {
            enableState(calendar)
        } else {
            switch calendar.authorization {
            case .authorized:
                agendaView(services)
            case .notRequested:
                requestState(calendar)
            case .denied, .restricted, .unavailable:
                deniedState
            }
        }
    }

    // MARK: - Permission states

    private func enableState(_ calendar: CalendarService) -> some View {
        EmptyStateView(
            symbolName: "calendar.badge.plus",
            headline: "Your calendar, alongside your work",
            message: "Elephruit shows your events and lets you create and change them. Your notes about a meeting stay here and are never written into an event.",
            actionTitle: "Turn On Calendar"
        ) {
            Task { _ = await calendar.enable() }
        }
        .padding(Theme.Spacing.generous)
    }

    private func requestState(_ calendar: CalendarService) -> some View {
        EmptyStateView(
            symbolName: "calendar",
            headline: "Allow calendar access",
            message: "iOS will ask for permission. Elephruit reads and writes only what you see and do here.",
            actionTitle: "Continue"
        ) {
            Task { _ = await calendar.enable() }
        }
        .padding(Theme.Spacing.generous)
    }

    private var deniedState: some View {
        EmptyStateView(
            symbolName: "calendar.badge.exclamationmark",
            headline: "Calendar access is off",
            message: "Allow access in Settings › Privacy & Security › Calendars, then come back."
        )
        .padding(Theme.Spacing.generous)
    }

    // MARK: - Agenda

    private func agendaView(_ services: AppServices) -> some View {
        let calendar = services.calendar
        let displayCalendar = calendar.displayCalendar

        return List {
            monthSection(calendar: calendar, displayCalendar: displayCalendar)
            agendaSections(calendar: calendar, displayCalendar: displayCalendar)
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await calendar.load(range: visibleRange(displayCalendar))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !displayCalendar.isDate(anchor, inSameDayAs: services.dateProvider.now) {
                    Button("Today") {
                        withCalmAnimation(Theme.Motion.standard) { anchor = services.dateProvider.now }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                setsMenu(calendar)
                Button {
                    isCreatingEvent = true
                } label: {
                    Label("New Event", systemImage: "plus")
                }
            }
        }
        .task(id: anchorMonthKey(displayCalendar)) {
            await calendar.load(range: visibleRange(displayCalendar))
        }
        .task {
            await calendar.start()
        }
        .sheet(isPresented: $isCreatingEvent) {
            EventEditorSheet(existing: nil, defaultDay: anchor)
        }
    }

    @ViewBuilder
    private func setsMenu(_ calendar: CalendarService) -> some View {
        if !calendar.sets.isEmpty {
            Menu {
                Picker("Calendar set", selection: Binding(
                    get: { calendar.activeSet?.id },
                    set: { id in Task { await calendar.activate(setID: id) } }
                )) {
                    Text("Everything").tag(UUID?.none)
                    ForEach(calendar.sets) { set in
                        Label(set.name, systemImage: set.symbolName).tag(UUID?.some(set.id))
                    }
                }
            } label: {
                Label("Calendar Sets", systemImage: "square.stack")
            }
        }
    }

    private func monthSection(calendar: CalendarService, displayCalendar: Calendar) -> some View {
        Section {
            MonthGrid(
                month: anchor,
                calendar: displayCalendar,
                cellSize: CGSize(width: 40, height: 40),
                spacing: 2,
                showsWeekdayHeader: true
            ) { day in
                let hasEvents = !calendar.events(on: day).isEmpty
                let isSelected = displayCalendar.isDate(day, inSameDayAs: anchor)
                let isToday = displayCalendar.isDateInToday(day)

                Button {
                    withCalmAnimation(Theme.Motion.standard) { anchor = day }
                } label: {
                    VStack(spacing: 2) {
                        Text("\(displayCalendar.component(.day, from: day))")
                            .font(Theme.Text.rowSubtitle)
                            .monospacedDigit()
                            .fontWeight(isToday ? .bold : .regular)
                            .foregroundStyle(
                                isSelected
                                    ? Theme.Colors.onAccent
                                    : isToday ? Theme.Colors.selection : Theme.Colors.primaryText
                            )
                        Circle()
                            .fill(hasEvents ? Theme.Colors.selection : Color.clear)
                            .frame(width: 4, height: 4)
                            .opacity(isSelected ? 0 : 1)
                    }
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(isSelected ? Theme.Colors.selection : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .gesture(
                DragGesture(minimumDistance: 40).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    withCalmAnimation(Theme.Motion.standard) {
                        anchor = displayCalendar.date(
                            byAdding: .month,
                            value: value.translation.width < 0 ? 1 : -1,
                            to: anchor
                        ) ?? anchor
                    }
                }
            )
        } header: {
            Text(anchor.formatted(.dateTime.month(.wide).year()))
                .font(Theme.Text.sectionHeader)
        }
    }

    @ViewBuilder
    private func agendaSections(calendar: CalendarService, displayCalendar: Calendar) -> some View {
        let days = agendaDays(displayCalendar)
        ForEach(days, id: \.self) { day in
            let events = calendar.events(on: day)
            if !events.isEmpty {
                Section {
                    ForEach(events) { event in
                        AgendaEventRow(event: event)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                shell.push(.event(event.identity.storageKey))
                            }
                    }
                } header: {
                    Text(dayHeader(day, displayCalendar: displayCalendar))
                }
            }
        }

        if days.allSatisfy({ calendar.events(on: $0).isEmpty }) {
            Section {
                if calendar.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    EmptyStateView(
                        symbolName: "calendar",
                        headline: "Nothing scheduled",
                        message: "The week from \(anchor.formatted(.dateTime.day().month())) is clear."
                    )
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Windows

    private func agendaDays(_ displayCalendar: Calendar) -> [Date] {
        let start = displayCalendar.startOfDay(for: anchor)
        return (0..<14).compactMap { displayCalendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func visibleRange(_ displayCalendar: Calendar) -> Range<Date> {
        let gridStart = CalendarWorkspaceModel.monthGridRange(
            containing: anchor, calendar: displayCalendar
        )
        let agendaEnd = displayCalendar.date(byAdding: .day, value: 15, to: displayCalendar.startOfDay(for: anchor))
            ?? anchor
        return min(gridStart.lowerBound, anchor)..<max(gridStart.upperBound, agendaEnd)
    }

    private func anchorMonthKey(_ displayCalendar: Calendar) -> String {
        let components = displayCalendar.dateComponents([.year, .month, .day], from: anchor)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func dayHeader(_ day: Date, displayCalendar: Calendar) -> String {
        if displayCalendar.isDateInToday(day) { return "Today" }
        if displayCalendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// One agenda row: times, colour, title, place, and whether you have declined it.
struct AgendaEventRow: View {
    let event: CalendarEventSummary

    /// Scales with the text it holds, so an accessibility size widens the column
    /// rather than wrapping a time mid-digit.
    @ScaledMetric(relativeTo: .caption) private var timeColumnWidth: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            VStack(alignment: .trailing, spacing: 0) {
                if event.isAllDay {
                    Text("All day")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                } else {
                    Text(event.startAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                    Text(event.endAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .frame(width: timeColumnWidth, alignment: .trailing)

            Capsule()
                .fill(Theme.Palette.color(named: event.calendarColorName))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(event.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(event.isCancelled)
                    .lineLimit(2)
                if let location = event.locationName, !location.isEmpty {
                    Text(location)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
                if event.participation == .declined {
                    Text("Declined")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .opacity(event.isCancelled || event.participation == .declined ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
