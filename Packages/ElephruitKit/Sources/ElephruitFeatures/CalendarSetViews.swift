import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Managing saved ways of looking at the calendar.
struct CalendarSetListView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var sets: [CalendarSetDefinition] = []
    @State private var editing: CalendarSetDefinition?
    @State private var isOfferingSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calendar Sets")
                    .font(Theme.Text.title)
                Spacer()
                Button {
                    editing = CalendarSetDefinition(name: "New Set")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Calendar Set")
                .accessibilityLabel("New Calendar Set")
            }
            .padding(Theme.Spacing.medium)

            Divider()

            if sets.isEmpty {
                EmptyStateView(
                    symbolName: "square.stack.3d.up",
                    headline: "No sets yet",
                    message: """
                        A set saves which calendars are showing, where new events land, which view \
                        you prefer, and what counts as working hours — so switching context is one \
                        action rather than five.
                        """,
                    actionTitle: "Start From a Suggestion",
                    action: { isOfferingSuggestions = true }
                )
                .frame(height: 260)
            } else {
                List {
                    ForEach(sets) { set in
                        CalendarSetRow(definition: set, calendars: services?.calendar.calendars ?? [])
                            .contentShape(.rect)
                            .onTapGesture { editing = set }
                            .contextMenu {
                                Button("Edit…") { editing = set }
                                Button("Delete", role: .destructive) { delete(set) }
                            }
                    }
                    .onMove(perform: move)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                if !sets.isEmpty {
                    Button("Add a Suggested Set…") { isOfferingSuggestions = true }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 480, height: 460)
        .task { reload() }
        .sheet(item: $editing) { set in
            CalendarSetEditorView(definition: set) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .sheet(isPresented: $isOfferingSuggestions) {
            CalendarSetSuggestionsView { chosen in
                services?.perform { try services?.calendarSets.acceptSuggestions(chosen) }
                isOfferingSuggestions = false
                reload()
            } onCancel: {
                isOfferingSuggestions = false
            }
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.setEditor)
    }

    private func reload() {
        sets = (try? services?.calendarSets.sets()) ?? []
    }

    private func save(_ set: CalendarSetDefinition) {
        guard let services else { return }
        services.perform {
            if sets.contains(where: { $0.id == set.id }) {
                try services.calendarSets.update(set)
            } else {
                try services.calendarSets.create(set)
            }
        }
        reload()
        Task { await services.calendar.refreshSets() }
    }

    private func delete(_ set: CalendarSetDefinition) {
        guard let services else { return }
        services.perform { try services.calendarSets.delete(id: set.id) }
        reload()
        Task { await services.calendar.refreshSets() }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let services else { return }
        var reordered = sets
        reordered.move(fromOffsets: source, toOffset: destination)
        services.perform { try services.calendarSets.reorder(reordered.map(\.id)) }
        reload()
    }
}

/// One set, in the list.
private struct CalendarSetRow: View {
    let definition: CalendarSetDefinition
    let calendars: [CalendarInfo]

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: definition.symbolName)
                .foregroundStyle(Theme.Palette.color(named: definition.colorName))
                .frame(width: Theme.Size.rowGlyph)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(definition.name)
                    .font(Theme.Text.rowTitle)
                Text(summary)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !unavailable.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
                    .help(unavailableMessage)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(definition.name). \(summary)")
    }

    private var unavailable: [CalendarReference] {
        definition.unavailableCalendars(among: calendars)
    }

    private var unavailableMessage: String {
        let names = unavailable.map(\.title).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "Some calendars in this set are not available." }
        return "Not available right now: \(names.joined(separator: ", "))"
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(definition.showsEveryCalendar ? "Every calendar" : "\(definition.calendars.count) calendars")
        parts.append(definition.preferredView.displayName)
        parts.append(definition.workingHours.summary)
        if let zone = definition.displayTimeZoneIdentifier {
            parts.append(EventPhraseParser.shortZoneName(zone))
        }
        return parts.joined(separator: " · ")
    }
}

/// Editing one set.
struct CalendarSetEditorView: View {
    @Environment(\.services) private var services

    @State var definition: CalendarSetDefinition
    var onSave: (CalendarSetDefinition) -> Void
    var onCancel: () -> Void

    private var calendars: [CalendarInfo] {
        services?.calendar.calendars ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $definition.name)

                    Picker("Symbol", selection: $definition.symbolName) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }

                    Picker("Color", selection: colorBinding) {
                        ForEach(Theme.Palette.allCases, id: \.rawValue) { entry in
                            Text(entry.displayName).tag(entry.rawValue)
                        }
                    }
                }

                Section("Calendars") {
                    Toggle("Show every calendar", isOn: $definition.showsEveryCalendar)

                    if !definition.showsEveryCalendar {
                        ForEach(services?.calendar.calendarsByAccount ?? [], id: \.account) { group in
                            DisclosureGroup(group.account) {
                                ForEach(group.calendars) { calendar in
                                    Toggle(isOn: binding(for: calendar)) {
                                        HStack(spacing: Theme.Spacing.tight) {
                                            Circle()
                                                .fill(Theme.EventStyle.accent(colorName: calendar.colorName))
                                                .frame(width: 8, height: 8)
                                            Text(calendar.title)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("When this set is active") {
                    Picker("Default calendar", selection: defaultCalendarBinding) {
                        Text("System default").tag("")
                        ForEach(calendars.filter(\.allowsModification)) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }

                    Picker("Preferred view", selection: $definition.preferredView) {
                        ForEach(CalendarViewKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    Picker("Density", selection: $definition.density) {
                        ForEach(CalendarDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }

                    Picker("Show times in", selection: displayZoneBinding) {
                        Text("Wherever I am").tag("")
                        ForEach(zoneChoices, id: \.self) { identifier in
                            Text(EventPhraseParser.shortZoneName(identifier)).tag(identifier)
                        }
                    }
                }

                Section("Working hours") {
                    HStack {
                        Stepper(value: startHourBinding, in: 0...23) {
                            Text("From \(WorkingHours.timeLabel(definition.workingHours.startMinutes))")
                                .monospacedDigit()
                        }
                        Stepper(value: endHourBinding, in: 1...24) {
                            Text("to \(WorkingHours.timeLabel(definition.workingHours.endMinutes))")
                                .monospacedDigit()
                        }
                    }

                    HStack(spacing: Theme.Spacing.tight) {
                        ForEach(1...7, id: \.self) { weekday in
                            let isOn = definition.workingHours.weekdays.contains(weekday)
                            Button {
                                toggleWorkingDay(weekday)
                            } label: {
                                Text(shortWeekday(weekday))
                                    .font(Theme.Text.keyHint)
                                    .frame(width: 26, height: 22)
                            }
                            .buttonStyle(.bordered)
                            .tint(isOn ? Theme.Colors.selection : Theme.Colors.secondaryText)
                            .accessibilityLabel(shortWeekday(weekday))
                            .accessibilityAddTraits(isOn ? [.isSelected] : [])
                        }
                    }
                }

                Section {
                    Toggle("Show people and CRM context", isOn: $definition.showsPersonContext)
                    Toggle("Hide events I declined", isOn: $definition.hidesDeclinedEvents)
                } footer: {
                    Text("""
                        Turning off CRM context hides linked people, meeting briefs, and your own \
                        notes while this set is active. Nothing is deleted — it is a set you can \
                        share a screen from.
                        """)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(definition) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(definition.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 460, height: 560)
    }

    private static let symbols = [
        "calendar", "briefcase", "house", "figure.2.and.child.holdinghands",
        "airplane", "person.2", "square.stack", "star", "flag", "heart",
    ]

    private var zoneChoices: [String] {
        var choices = services?.calendar.timeZoneDisplay.favouriteZoneIdentifiers ?? []
        if let current = definition.displayTimeZoneIdentifier, !choices.contains(current) {
            choices.append(current)
        }
        return choices
    }

    private func binding(for calendar: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { definition.calendars.contains { $0.identifier == calendar.id } },
            set: { isOn in
                if isOn {
                    definition.calendars.append(calendar.reference)
                } else {
                    definition.calendars.removeAll { $0.identifier == calendar.id }
                }
            }
        )
    }

    private var colorBinding: Binding<String> {
        Binding(get: { definition.colorName ?? "blue" }, set: { definition.colorName = $0 })
    }

    private var defaultCalendarBinding: Binding<String> {
        Binding(
            get: { definition.defaultCalendar?.identifier ?? "" },
            set: { identifier in
                definition.defaultCalendar = calendars.first { $0.id == identifier }?.reference
            }
        )
    }

    private var displayZoneBinding: Binding<String> {
        Binding(
            get: { definition.displayTimeZoneIdentifier ?? "" },
            set: { definition.displayTimeZoneIdentifier = $0.isEmpty ? nil : $0 }
        )
    }

    private var startHourBinding: Binding<Int> {
        Binding(
            get: { definition.workingHours.startMinutes / 60 },
            set: { hour in
                definition.workingHours = WorkingHours(
                    startMinutes: hour * 60,
                    endMinutes: max((hour + 1) * 60, definition.workingHours.endMinutes),
                    weekdays: definition.workingHours.weekdays
                )
            }
        )
    }

    private var endHourBinding: Binding<Int> {
        Binding(
            get: { definition.workingHours.endMinutes / 60 },
            set: { hour in
                definition.workingHours = WorkingHours(
                    startMinutes: min(definition.workingHours.startMinutes, (hour - 1) * 60),
                    endMinutes: hour * 60,
                    weekdays: definition.workingHours.weekdays
                )
            }
        )
    }

    private func toggleWorkingDay(_ weekday: Int) {
        var weekdays = definition.workingHours.weekdays
        if weekdays.contains(weekday) { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
        definition.workingHours = WorkingHours(
            startMinutes: definition.workingHours.startMinutes,
            endMinutes: definition.workingHours.endMinutes,
            weekdays: weekdays
        )
    }

    private func shortWeekday(_ weekday: Int) -> String {
        let symbols = (services?.calendar.displayCalendar ?? .current).veryShortWeekdaySymbols
        guard weekday - 1 < symbols.count else { return "" }
        return symbols[weekday - 1]
    }
}

/// The starter sets, offered once and never created unasked.
struct CalendarSetSuggestionsView: View {
    var onAccept: ([CalendarSetDefinition]) -> Void
    var onCancel: () -> Void

    @State private var chosen: Set<UUID> = []
    @State private var suggestions = CalendarSetDefinition.suggestions()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Suggested sets")
                .font(Theme.Text.title)

            Text("""
                Each one starts with every calendar showing. Choose which calendars belong in it \
                afterwards — these are a starting point, not a guess about how you work.
                """)
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(suggestions) { suggestion in
                Toggle(isOn: binding(for: suggestion)) {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: suggestion.symbolName)
                            .foregroundStyle(Theme.Palette.color(named: suggestion.colorName))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(suggestion.name)
                            Text("\(suggestion.preferredView.displayName) · \(suggestion.workingHours.summary)")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Not Now", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onAccept(suggestions.filter { chosen.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
    }

    private func binding(for suggestion: CalendarSetDefinition) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(suggestion.id) },
            set: { isOn in
                if isOn { chosen.insert(suggestion.id) } else { chosen.remove(suggestion.id) }
            }
        )
    }
}
