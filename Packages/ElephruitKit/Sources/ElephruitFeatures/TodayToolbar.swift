import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Moving between days, and choosing what a day shows — as the window toolbar's own items.
///
/// This was an in-content bar on the argument that these controls are about the page. So they
/// are — and so are every native calendar's, which still puts them in the one toolbar, because
/// two stacked rows of chrome above a day is chrome spending the day's room. The filter chips
/// that used to appear at width live in the options menu permanently: the bar already folded
/// them there below 620 points, so the menu was always their other home.
struct TodayToolbarItems: ToolbarContent {
    @Environment(\.services) private var services

    let model: TodayModel
    let preferences: TodayPreferences?
    let calendars: CalendarService?

    @Binding var isDatePickerPresented: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.step(days: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .help("The day before")
            .accessibilityLabel("Previous day")
            .accessibilityIdentifier(AccessibilityID.Today.previousDay)

            Button { model.step(days: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .help("The day after")
            .accessibilityLabel("Next day")
            .accessibilityIdentifier(AccessibilityID.Today.nextDay)

            Button {
                isDatePickerPresented = true
            } label: {
                Text(dateLabel)
                    .font(Theme.Text.rowTitleEmphasised)
            }
            .help("Go to a date")
            .accessibilityIdentifier(AccessibilityID.Today.datePicker)
            .popover(isPresented: $isDatePickerPresented, arrowEdge: .bottom) {
                datePicker
            }

            // Only when it would do something. A "Today" button while standing on today is a
            // control that looks pressable and is not. ⌘0 is the keyboard way back.
            if !model.isOnToday {
                Button("Today") { model.returnToToday() }
                    .help("Back to today")
                    .accessibilityIdentifier(AccessibilityID.Today.returnToToday)
            }
        }

        ToolbarItem {
            overflowMenu
        }
    }

    private var dateLabel: String {
        if model.isOnToday { return "Today" }
        let clock = services?.dateProvider ?? SystemDateProvider()
        let calendar = clock.calendar
        if calendar.isDate(model.selectedDate, inSameDayAs: clock.startOfTomorrow) { return "Tomorrow" }
        return model.selectedDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var datePicker: some View {
        DatePicker(
            "Go to",
            selection: Binding(
                get: { model.selectedDate },
                set: { model.select($0) }
            ),
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .padding(Theme.Spacing.medium)
        .frame(width: 300)
    }

    // MARK: - What it shows

    private var filters: TodayFilters { preferences?.filters ?? .standard }

    private var overflowMenu: some View {
        Menu {
            Section("Show") {
                toggle("Reminders", isOn: filters.showsTasks) { preferences?.toggleTasks() }
                toggle("Meetings", isOn: filters.showsMeetings) { preferences?.toggleMeetings() }
                toggle("People", isOn: filters.showsPeople) { preferences?.togglePeople() }
                toggle("Daily Note", isOn: filters.showsDailyNote) { preferences?.toggleDailyNote() }
                toggle("Completed Work", isOn: filters.showsCompleted) { preferences?.toggleCompleted() }
            }

            Section("Arrangement") {
                Picker("Arrangement", selection: agendaBinding) {
                    Text("One timeline").tag(true)
                    Text("Grouped sections").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            calendarSection
            projectSection

            if filters.isFiltering {
                Divider()
                Button("Show Everything") { preferences?.reset() }
            }
        } label: {
            Image(systemName: filters.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help(filters.summary ?? "What this page shows")
        .accessibilityLabel("Page options")
        .accessibilityValue(filters.summary ?? "Showing everything")
        .accessibilityIdentifier(AccessibilityID.Today.filters)
    }

    private var agendaBinding: Binding<Bool> {
        Binding(
            get: { filters.usesIntegratedAgenda },
            set: { preferences?.setIntegratedAgenda($0) }
        )
    }

    @ViewBuilder
    private var calendarSection: some View {
        // Only when there is more than one calendar to choose between. A menu offering to hide the
        // only calendar somebody has is a menu offering to empty the page.
        if let calendars, calendars.isEnabled, calendars.calendarNames.count > 1 {
            Section("Calendars") {
                ForEach(calendars.calendarsByAccount, id: \.account) { group in
                    ForEach(group.calendars) { calendar in
                        toggle(
                            calendar.title,
                            isOn: preferences?.isCalendarShown(calendar.id) ?? true
                        ) {
                            preferences?.toggleCalendar(calendar.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        // Computed on reload rather than here — see ``TodayModel/activeContainers``.
        let projects = model.activeContainers
        if !projects.isEmpty {
            Section("Projects") {
                ForEach(projects, id: \.id) { project in
                    toggle(
                        project.displayTitle,
                        isOn: preferences?.isContainerShown(project.id) ?? true
                    ) {
                        preferences?.toggleContainer(project.id)
                    }
                }
            }
        }
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark" : "")
        }
    }
}
