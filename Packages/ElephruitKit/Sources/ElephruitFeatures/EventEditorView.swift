import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Creating or changing an event.
///
/// ### Progressive disclosure, and what that actually means here
/// Not "hide the hard things". A simple event needs a title and a time, so those are the only two
/// fields that are ever visible without asking — everything else is behind a disclosure that
/// **shows a summary of what it contains**, so somebody can see at a glance that an event has three
/// alarms and repeats weekly without opening anything. A collapsed section that says nothing about
/// its contents is not disclosure, it is concealment, and it is why people end up saving events with
/// the wrong reminder still attached.
struct EventEditorView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The event being changed, or `nil` when this is a new one.
    let existing: CalendarEventSummary?

    @State private var draft: EventDraft
    @State private var isShowingDetails: Bool
    @State private var isSaving = false
    @State private var scopeRequest: ScopeRequest?
    @State private var failure: CalendarWriteFailure?

    /// Which fields the user has touched by hand.
    ///
    /// Kept so that a re-parse from the natural-language field cannot overwrite a decision somebody
    /// made in this sheet — the same separation of raw and derived state that the entry field keeps.
    @State private var editedFields: Set<String> = []

    @FocusState private var isTitleFocused: Bool

    var onSaved: (CalendarEventSummary) -> Void

    init(
        existing: CalendarEventSummary? = nil,
        draft: EventDraft,
        onSaved: @escaping (CalendarEventSummary) -> Void
    ) {
        self.existing = existing
        self._draft = State(initialValue: draft)
        self.onSaved = onSaved
        // Opened expanded when there is already something in the advanced half to see, so editing an
        // event with alarms does not hide them behind a triangle.
        self._isShowingDetails = State(
            initialValue: !draft.alarms.isEmpty || draft.recurrence != nil
                || !draft.location.isEmpty || !draft.notes.isEmpty
        )
    }

    private var calendars: [CalendarInfo] {
        services?.calendar.calendars.filter { $0.allowsModification } ?? []
    }

    private var targetCalendar: CalendarInfo? {
        calendars.first { $0.id == draft.calendarIdentifier }
    }

    private var problems: [EventDraftProblem] {
        draft.problems(savingTo: targetCalendar)
    }

    private var warnings: [TimeZoneWarning] {
        guard let services else { return [] }
        return TimeZoneInspector.warnings(
            for: draft,
            display: services.calendar.timeZoneDisplay,
            calendar: services.calendar.displayCalendar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    essentials
                    Divider()
                    disclosure
                    if isShowingDetails { details }
                    messages
                }
                .padding(Theme.Spacing.large)
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 620)
        .onAppear { isTitleFocused = true }
        .sheet(item: $scopeRequest) { request in
            EventScopeSheet(
                confirmation: request.confirmation,
                isDeletion: false,
                onChoose: { scope in
                    scopeRequest = nil
                    Task { await save(scope: scope) }
                },
                onCancel: { scopeRequest = nil }
            )
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.editor)
    }

    // MARK: The two fields a simple event needs

    private var essentials: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(Theme.Text.title)
                .focused($isTitleFocused)
                .onSubmit { Task { await attemptSave() } }
                .accessibilityIdentifier(AccessibilityID.Calendar.editorTitle)

            Toggle("All day", isOn: allDayBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack(spacing: Theme.Spacing.small) {
                DatePicker(
                    "Starts",
                    selection: startBinding,
                    displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
            }

            HStack(spacing: Theme.Spacing.small) {
                DatePicker(
                    "Ends",
                    selection: endBinding,
                    in: draft.startAt...,
                    displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)

                if !draft.isAllDay {
                    Text(EventAlarm.durationPhrase(Int(draft.duration / 60)))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .monospacedDigit()
                }
            }

            Picker("Calendar", selection: calendarBinding) {
                ForEach(calendars) { calendar in
                    Label {
                        Text(calendar.title)
                    } icon: {
                        Circle()
                            .fill(Theme.EventStyle.accent(colorName: calendar.colorName))
                            .frame(width: 8, height: 8)
                    }
                    .tag(calendar.id)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Calendar.editorCalendar)
        }
    }

    // MARK: Everything else

    /// The disclosure control, which says what it is hiding.
    private var disclosure: some View {
        Button {
            withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.standard, reduceMotion: reduceMotion)) { isShowingDetails.toggle() }
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: isShowingDetails ? "chevron.down" : "chevron.right")
                    .font(Theme.Text.metadata)
                Text("Details")
                    .font(Theme.Text.sectionHeader)
                    .textCase(.uppercase)

                if !isShowingDetails, let summary = detailSummary {
                    Text(summary)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowingDetails ? "Hide details" : "Show details. \(detailSummary ?? "Nothing set")")
    }

    /// What is inside the collapsed section, in one line.
    private var detailSummary: String? {
        var parts: [String] = []
        if !draft.location.isEmpty { parts.append(draft.location) }
        if let recurrence = draft.recurrence { parts.append(recurrence.summary) }
        if !draft.alarms.isEmpty {
            parts.append(draft.alarms.count == 1 ? "1 alert" : "\(draft.alarms.count) alerts")
        }
        if draft.availability != .busy { parts.append(draft.availability.displayName) }
        if !draft.notes.isEmpty { parts.append("notes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("Location", text: $draft.location)
                .textFieldStyle(.roundedBorder)

            TextField("URL", text: urlBinding)
                .textFieldStyle(.roundedBorder)

            Picker("Shows as", selection: $draft.availability) {
                ForEach(EventAvailability.selectable, id: \.self) { availability in
                    Text(availability.displayName).tag(availability)
                }
            }

            if !draft.isAllDay {
                Picker("Time zone", selection: timeZoneBinding) {
                    Text("Wherever I am").tag("")
                    ForEach(zoneChoices, id: \.self) { identifier in
                        Text(EventPhraseParser.shortZoneName(identifier)).tag(identifier)
                    }
                }
            }

            RecurrenceEditor(recurrence: $draft.recurrence, start: draft.startAt, calendar: displayCalendar)

            AlarmEditor(alarms: $draft.alarms)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Notes")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)

                TextEditor(text: $draft.notes)
                    .font(Theme.Text.rowSubtitle)
                    .frame(height: 72)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Colors.separator)
                    }
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        let visible = problems.filter { $0 != .titleMissing || !draft.title.isEmpty }

        if !visible.isEmpty || !warnings.isEmpty || failure != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(visible) { problem in
                    MessageRow(
                        symbol: problem.blocksSaving ? "exclamationmark.triangle" : "info.circle",
                        text: problem.message,
                        tint: problem.blocksSaving ? Theme.Colors.destructive : Theme.Colors.warning
                    )
                }

                ForEach(warnings) { warning in
                    MessageRow(
                        symbol: warning.isProminent ? "exclamationmark.triangle" : "clock.badge.questionmark",
                        text: warning.message,
                        tint: warning.isProminent ? Theme.Colors.warning : Theme.Colors.secondaryText
                    )
                }

                if let failure {
                    MessageRow(
                        symbol: "xmark.octagon",
                        text: failure.message,
                        tint: Theme.Colors.destructive
                    )
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(existing == nil ? "Add" : "Save") {
                Task { await attemptSave() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || !draft.canSave(to: targetCalendar))
        }
        .padding(Theme.Spacing.medium)
    }

    // MARK: Saving

    /// Asks whatever has to be asked, then saves.
    private func attemptSave() async {
        guard let services, draft.canSave(to: targetCalendar) else { return }
        failure = nil

        guard let existing else {
            await save(scope: .thisEvent)
            return
        }

        let required = services.calendar.confirmations(for: draft, replacing: existing)

        // The recurrence question has to be answered before anything is written; a calendar move is
        // asked about in the same sheet when both apply.
        if let recurring = required.first(where: \.needsScopeChoice) {
            scopeRequest = ScopeRequest(confirmation: recurring)
            return
        }
        if let move = required.first {
            scopeRequest = ScopeRequest(confirmation: move)
            return
        }

        await save(scope: .thisEvent)
    }

    private func save(scope: EventEditScope) async {
        guard let services else { return }
        isSaving = true
        defer { isSaving = false }

        let outcome: Result<CalendarEventSummary, CalendarWriteFailure>
        if let existing {
            outcome = await services.calendar.update(existing.identity, with: draft, scope: scope)
        } else {
            outcome = await services.calendar.create(draft)
        }

        switch outcome {
        case .success(let event):
            onSaved(event)
            dismiss()
        case .failure(let error):
            failure = error
        }
    }

    // MARK: Bindings

    private var displayCalendar: Calendar {
        services?.calendar.displayCalendar ?? Calendar.current
    }

    private var zoneChoices: [String] {
        var choices = services?.calendar.timeZoneDisplay.favouriteZoneIdentifiers ?? []
        let device = services?.calendar.timeZoneDisplay.deviceZoneIdentifier
        if let device, !choices.contains(device) { choices.insert(device, at: 0) }
        if let current = draft.timeZoneIdentifier, !choices.contains(current) { choices.append(current) }
        return choices
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { draft.isAllDay },
            set: { isAllDay in
                draft.isAllDay = isAllDay
                editedFields.insert("isAllDay")

                if isAllDay {
                    // Snapped to whole days, because an all-day event that starts at 09:00 is a
                    // half-day event wearing a hat, and EventKit stores it wrongly.
                    draft.startAt = displayCalendar.startOfDay(for: draft.startAt)
                    draft.endAt = displayCalendar.date(byAdding: .day, value: 1, to: draft.startAt)
                        ?? draft.startAt
                    draft.timeZoneIdentifier = nil
                } else {
                    let hour = displayCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.startAt)
                    draft.startAt = hour ?? draft.startAt
                    draft.endAt = draft.startAt.addingTimeInterval(3_600)
                }
            }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { draft.startAt },
            set: { newStart in
                // Moving the start moves the whole event, which is what every calendar does and what
                // anybody dragging a start expects. Changing the length is what the end field is for.
                draft.move(to: newStart)
                editedFields.insert("start")
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { draft.endAt },
            set: { newEnd in
                draft.endAt = max(newEnd, draft.startAt.addingTimeInterval(60))
                editedFields.insert("end")
            }
        )
    }

    private var calendarBinding: Binding<String> {
        Binding(
            get: { draft.calendarIdentifier },
            set: {
                draft.calendarIdentifier = $0
                editedFields.insert("calendar")
            }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { draft.url?.absoluteString ?? "" },
            set: { draft.url = $0.isEmpty ? nil : URL(string: $0) }
        )
    }

    private var timeZoneBinding: Binding<String> {
        Binding(
            get: { draft.timeZoneIdentifier ?? "" },
            set: { draft.timeZoneIdentifier = $0.isEmpty ? nil : $0 }
        )
    }
}

/// A pending question about which occurrences a change reaches.
private struct ScopeRequest: Identifiable {
    let confirmation: EventChangeConfirmation
    var id: String { confirmation.id }
}

/// One line of explanation under the editor's fields.
private struct MessageRow: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .font(Theme.Text.metadata)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(text)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scope

/// The sheet that asks which occurrences a change reaches.
///
/// Offered rather than inferred, and offered *before* anything is written. Guessing here is how
/// somebody loses a year of a series they meant to change one instance of, and the guess is never
/// recoverable because the edit has already gone to a server.
struct EventScopeSheet: View {
    let confirmation: EventChangeConfirmation
    let isDeletion: Bool

    var onChoose: (EventEditScope) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(confirmation.title)
                .font(Theme.Text.title)

            Text(confirmation.message)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if confirmation.needsScopeChoice {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(EventEditScope.offered) { scope in
                        Button {
                            onChoose(scope)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scope.displayName)
                                    .font(Theme.Text.rowTitle)
                                Text(scope.explanation(deleting: isDeletion))
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(scope.explanation(deleting: isDeletion))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if !confirmation.needsScopeChoice {
                    Button(isDeletion ? "Delete" : "Move") { onChoose(.thisEvent) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
        .accessibilityIdentifier(AccessibilityID.Calendar.scopeSheet)
    }
}

// MARK: - Recurrence

/// Choosing how an event repeats.
///
/// The presets come first and cover almost everything; "Custom…" opens the rest. A picker that leads
/// with `BYSETPOS` is one nobody uses.
struct RecurrenceEditor: View {
    @Binding var recurrence: EventRecurrence?
    let start: Date
    let calendar: Calendar

    @State private var isShowingCustom = false

    private var presets: [(label: String, rule: EventRecurrence)] {
        EventRecurrence.presets(for: start, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Picker("Repeat", selection: selection) {
                Text("Never").tag("none")
                ForEach(presets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
                if let recurrence, !presets.contains(where: { $0.rule == recurrence }) {
                    Text(recurrence.summary).tag("custom-current")
                }
                Text("Custom…").tag("custom")
            }

            if let recurrence {
                HStack(spacing: Theme.Spacing.small) {
                    Text(recurrence.summary)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Button("Edit…") { isShowingCustom = true }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                }
            }
        }
        .sheet(isPresented: $isShowingCustom) {
            CustomRecurrenceSheet(
                recurrence: recurrence ?? EventRecurrence(frequency: .weekly),
                start: start,
                calendar: calendar,
                onSave: { rule in
                    recurrence = rule
                    isShowingCustom = false
                },
                onCancel: { isShowingCustom = false }
            )
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.recurrenceEditor)
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                guard let recurrence else { return "none" }
                return presets.first { $0.rule == recurrence }?.label ?? "custom-current"
            },
            set: { choice in
                switch choice {
                case "none": recurrence = nil
                case "custom": isShowingCustom = true
                case "custom-current": break
                default: recurrence = presets.first { $0.label == choice }?.rule
                }
            }
        )
    }
}

/// The full recurrence editor, with a preview of what it will actually do.
struct CustomRecurrenceSheet: View {
    @State var recurrence: EventRecurrence
    let start: Date
    let calendar: Calendar

    var onSave: (EventRecurrence) -> Void
    var onCancel: () -> Void

    @State private var endChoice = "never"
    @State private var endDate = Date()
    @State private var occurrenceCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Repeat")
                .font(Theme.Text.title)

            HStack(spacing: Theme.Spacing.small) {
                Text("Every")
                Stepper(value: intervalBinding, in: 1...52) {
                    Text("\(recurrence.interval)")
                        .monospacedDigit()
                        .frame(minWidth: 20)
                }
                Picker("", selection: frequencyBinding) {
                    ForEach(EventRecurrence.Frequency.allCases, id: \.self) { frequency in
                        Text(recurrence.interval == 1 ? frequency.unitName : frequency.unitName + "s")
                            .tag(frequency)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            if recurrence.frequency == .weekly {
                weekdayPicker
            }

            if recurrence.frequency == .monthly {
                monthlyPicker
            }

            Divider()

            endPicker

            Divider()

            preview

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onSave(applyingEnd()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
        .onAppear { readEnd() }
    }

    private var weekdayPicker: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(1...7, id: \.self) { weekday in
                let isOn = recurrence.daysOfWeek.contains { $0.weekday == weekday }

                Button {
                    toggle(weekday: weekday)
                } label: {
                    Text(shortWeekday(weekday))
                        .font(Theme.Text.keyHint)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .tint(isOn ? Theme.Colors.selection : Theme.Colors.secondaryText)
                .accessibilityLabel(shortWeekday(weekday))
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private var monthlyPicker: some View {
        Picker("On", selection: monthlyModeBinding) {
            Text("Day \(calendar.component(.day, from: start))").tag("day")
            if let ordinal = EventRecurrence.ordinalPosition(of: start, calendar: calendar) {
                Text("The \(EventRecurrence.DayOfWeek.ordinalName(ordinal)) \(weekdayName)").tag("ordinal")
            }
        }
    }

    private var endPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Picker("Ends", selection: $endChoice) {
                Text("Never").tag("never")
                Text("On a date").tag("date")
                Text("After a number of times").tag("count")
            }

            switch endChoice {
            case "date":
                DatePicker("On", selection: $endDate, in: start..., displayedComponents: [.date])
                    .datePickerStyle(.compact)
            case "count":
                Stepper(value: $occurrenceCount, in: 1...999) {
                    Text("\(occurrenceCount) times").monospacedDigit()
                }
            default:
                EmptyView()
            }
        }
    }

    /// The next few occurrences, so a rule can be checked before it is saved.
    ///
    /// This is what makes an ordinal rule usable at all: "the last Friday of every month" is a
    /// sentence somebody has to trust, and three dates turn it into something they can verify.
    private var preview: some View {
        let dates = applyingEnd().occurrences(startingAt: start, calendar: calendar, limit: 4)

        return VStack(alignment: .leading, spacing: 2) {
            Text("Next")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            if dates.isEmpty {
                Text("This rule produces no occurrences.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            } else {
                ForEach(dates, id: \.self) { date in
                    Text(label(for: date))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The next occurrences of this rule")
    }

    private func label(for date: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private func shortWeekday(_ weekday: Int) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        guard weekday - 1 < symbols.count else { return "" }
        return symbols[weekday - 1]
    }

    private var weekdayName: String {
        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = calendar.timeZone
        return start.formatted(style)
    }

    private func toggle(weekday: Int) {
        if let index = recurrence.daysOfWeek.firstIndex(where: { $0.weekday == weekday }) {
            recurrence.daysOfWeek.remove(at: index)
        } else {
            recurrence.daysOfWeek.append(.init(weekday))
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { recurrence.interval }, set: { recurrence.interval = max(1, $0) })
    }

    private var frequencyBinding: Binding<EventRecurrence.Frequency> {
        Binding(
            get: { recurrence.frequency },
            set: { frequency in
                recurrence.frequency = frequency
                // The qualifiers belong to a frequency, and carrying them across produces rules
                // nobody meant — a yearly event "on the third Thursday" of every month.
                if frequency != .weekly, frequency != .monthly { recurrence.daysOfWeek = [] }
                if frequency != .monthly { recurrence.daysOfMonth = [] }
            }
        )
    }

    private var monthlyModeBinding: Binding<String> {
        Binding(
            get: { recurrence.daysOfWeek.isEmpty ? "day" : "ordinal" },
            set: { mode in
                if mode == "day" {
                    recurrence.daysOfWeek = []
                    recurrence.daysOfMonth = [calendar.component(.day, from: start)]
                } else {
                    recurrence.daysOfMonth = []
                    let weekday = calendar.component(.weekday, from: start)
                    let ordinal = EventRecurrence.ordinalPosition(of: start, calendar: calendar) ?? 1
                    recurrence.daysOfWeek = [.init(weekday, weekNumber: ordinal)]
                }
            }
        )
    }

    private func readEnd() {
        switch recurrence.end {
        case .never:
            endChoice = "never"
        case .onDate(let date):
            endChoice = "date"
            endDate = date
        case .afterOccurrences(let count):
            endChoice = "count"
            occurrenceCount = count
        }
    }

    private func applyingEnd() -> EventRecurrence {
        var rule = recurrence
        switch endChoice {
        case "date": rule.end = .onDate(endDate)
        case "count": rule.end = .afterOccurrences(occurrenceCount)
        default: rule.end = .never
        }
        return rule
    }
}

// MARK: - Alarms

/// Adding and removing an event's alerts.
struct AlarmEditor: View {
    @Binding var alarms: [EventAlarm]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack {
                Text("Alerts")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                Menu {
                    ForEach(EventAlarm.commonOffsets, id: \.self) { minutes in
                        Button(EventAlarm.minutesBefore(minutes).displayName) {
                            add(minutes: minutes)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add an alert")
                .accessibilityLabel("Add an alert")
            }

            if alarms.isEmpty {
                Text("None")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(alarms) { alarm in
                    HStack {
                        Image(systemName: "bell")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .accessibilityHidden(true)

                        Text(alarm.displayName)
                            .font(Theme.Text.metadata)

                        Spacer()

                        Button {
                            alarms.removeAll { $0.id == alarm.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .accessibilityLabel("Remove \(alarm.displayName)")
                    }
                }
            }
        }
    }

    /// Adds an alert, unless the same one is already there.
    ///
    /// Two identical alarms fire twice, which reads as a bug in the app rather than as a duplicate
    /// somebody added.
    private func add(minutes: Int) {
        let alarm = EventAlarm.minutesBefore(minutes)
        guard !alarms.contains(where: { $0.relativeOffset == alarm.relativeOffset }) else { return }
        alarms.append(alarm)
        alarms.sort { ($0.relativeOffset ?? 0) < ($1.relativeOffset ?? 0) }
    }
}
