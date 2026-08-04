import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Moving between days, and choosing what a day shows.
///
/// ### Why this is a bar and not a toolbar
/// The window's toolbar belongs to the window and is shared with search, the module switcher and
/// everything else. These controls are about *this page* and change what is directly beneath them —
/// the date they move, the sections they hide — so they sit against the content they act on. It also
/// means they survive the page being narrow, where a window toolbar starts collapsing controls into
/// an overflow the user cannot predict.
struct TodayToolbar: View {
    @Environment(\.services) private var services

    let model: TodayModel
    let preferences: TodayPreferences?
    let calendars: CalendarService?

    @Binding var isDatePickerPresented: Bool

    /// Below this the named filter chips fold into the overflow menu.
    ///
    /// A measured width rather than a size class: the page is a column inside a resizable window,
    /// and the thing that decides whether three chips fit is how wide the column is, not how wide
    /// the display is.
    @State private var availableWidth: CGFloat = 0

    private var showsChips: Bool { availableWidth >= 620 }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            dateControls

            Spacer(minLength: Theme.Spacing.medium)

            if showsChips {
                filterChips
            }

            overflowMenu
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityIdentifier(AccessibilityID.Today.filters)
    }

    // MARK: - Where you are

    private var dateControls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button { model.step(days: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("The day before")
            .accessibilityLabel("Previous day")
            .accessibilityIdentifier(AccessibilityID.Today.previousDay)

            Button { model.step(days: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("The day after")
            .accessibilityLabel("Next day")
            .accessibilityIdentifier(AccessibilityID.Today.nextDay)

            Button {
                isDatePickerPresented = true
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(dateLabel)
                        .font(Theme.Text.rowTitleEmphasised)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.primaryText)
            .help("Go to a date")
            .accessibilityIdentifier(AccessibilityID.Today.datePicker)
            .popover(isPresented: $isDatePickerPresented, arrowEdge: .bottom) {
                datePicker
            }

            // Only when it would do something. A "Today" button while standing on today is a control
            // that looks pressable and is not.
            if !model.isOnToday {
                Button("Today") { model.returnToToday() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .help("Back to today")
                    .accessibilityIdentifier(AccessibilityID.Today.returnToToday)
            }
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

    private var filterChips: some View {
        HStack(spacing: Theme.Spacing.tight) {
            chip("Reminders", systemImage: "bell", isOn: filters.showsTasks) {
                preferences?.toggleTasks()
            }
            chip("Meetings", systemImage: "person.2", isOn: filters.showsMeetings) {
                preferences?.toggleMeetings()
            }
            chip("People", systemImage: "person.crop.circle", isOn: filters.showsPeople) {
                preferences?.togglePeople()
            }
        }
    }

    private var filters: TodayFilters { preferences?.filters ?? .standard }

    /// A switch that reads as a switch whether or not colour is available.
    ///
    /// On is a filled background and a filled glyph; off is neither and a dimmed label. Two channels
    /// rather than one, so the state survives greyscale, and the label is always the noun rather
    /// than "Show tasks" — the chip says what it is and its appearance says whether it is on.
    private func chip(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: isOn ? "\(systemImage).fill" : systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(Theme.Text.chip)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(isOn ? Theme.Colors.subtleFill : .clear)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: isOn ? 0 : 1)
            }
            .foregroundStyle(isOn ? Theme.Colors.primaryText : Theme.Colors.secondaryText)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - Everything else

    private var overflowMenu: some View {
        Menu {
            if !showsChips {
                Section("Show") {
                    toggle("Reminders", isOn: filters.showsTasks) { preferences?.toggleTasks() }
                    toggle("Meetings", isOn: filters.showsMeetings) { preferences?.toggleMeetings() }
                    toggle("People", isOn: filters.showsPeople) { preferences?.togglePeople() }
                }
            }

            Section {
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filters.summary ?? "What this page shows")
        .accessibilityLabel("Page options")
        .accessibilityValue(filters.summary ?? "Showing everything")
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
