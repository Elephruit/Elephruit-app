import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One calendar event, with the Elephruit context EventKit knows nothing about:
/// linked people, meeting notes, and preparation.
struct EventScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let identityKey: String

    @State private var event: CalendarEventSummary?
    @State private var hasLoaded = false
    @State private var isEditing = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let event {
                content(event)
            } else if hasLoaded {
                EmptyStateView(
                    symbolName: "calendar.badge.exclamationmark",
                    headline: "This event is gone",
                    message: "It may have been deleted from the calendar."
                )
            } else {
                Color.clear
            }
        }
        .task(id: services?.calendar.revision) { await load() }
    }

    private func content(_ event: CalendarEventSummary) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(event.displayTitle)
                        .font(Theme.Text.title)
                        .strikethrough(event.isCancelled)

                    if let services {
                        Text(event.timeSummary(
                            in: .current,
                            calendar: services.calendar.displayCalendar
                        ))
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    if let calendarName = event.calendarName {
                        Label(calendarName, systemImage: "circle.fill")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Palette.color(named: event.calendarColorName))
                    }

                    if let location = event.locationName, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .padding(.vertical, Theme.Spacing.tight)
            }

            attendeesSection(event)
            meetingContextSection(event)

            if let notes = event.notes, !notes.isEmpty {
                Section("Event notes") {
                    Text(notes)
                        .font(Theme.Text.rowSubtitle)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if event.isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { isEditing = true }
                        Button("Delete Event", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            EventEditorSheet(existing: event, defaultDay: event.startAt)
        }
        .confirmationDialog(
            "Delete “\(event.displayTitle)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            if event.isRecurring {
                Button("Delete This Occurrence", role: .destructive) {
                    delete(event, scope: .thisEvent)
                }
                Button("Delete This and Future", role: .destructive) {
                    delete(event, scope: .thisAndFuture)
                }
            } else {
                Button("Delete Event", role: .destructive) {
                    delete(event, scope: .thisEvent)
                }
            }
        }
    }

    @ViewBuilder
    private func attendeesSection(_ event: CalendarEventSummary) -> some View {
        if !event.attendees.isEmpty {
            Section("Attendees") {
                ForEach(event.attendees) { attendee in
                    HStack {
                        Text(attendee.displayName)
                            .font(Theme.Text.rowSubtitle)
                        if attendee.isOrganizer {
                            Text("Organizer")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        Spacer()
                        participationMark(attendee.participation)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func participationMark(_ participation: EventParticipation) -> some View {
        switch participation {
        case .accepted:
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Colors.completed)
        case .declined:
            Label("Declined", systemImage: "xmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Colors.destructive)
        case .tentative:
            Label("Maybe", systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Colors.warning)
        case .pending, .unknown:
            EmptyView()
        }
    }

    /// What Elephruit knows about this meeting: notes, preparation, linked people.
    @ViewBuilder
    private func meetingContextSection(_ event: CalendarEventSummary) -> some View {
        if let services {
            Section("In Elephruit") {
                Button {
                    openMeetingNotes(event)
                } label: {
                    Label("Meeting Notes", systemImage: "note.text")
                }

                if let annotation = try? services.eventLinks.annotation(for: event.identity) {
                    ForEach(annotation.personIDs, id: \.self) { personID in
                        if let person = try? services.items.item(id: personID) {
                            Button {
                                shell.push(.person(personID))
                            } label: {
                                Label(person.displayTitle, systemImage: "person")
                            }
                        }
                    }
                }
            }
        }
    }

    private func openMeetingNotes(_ event: CalendarEventSummary) {
        guard let services else { return }
        services.perform {
            guard let meeting = try services.eventLinks.meetingItem(for: event) else { return }
            services.noteChange(to: meeting)
            shell.push(.item(meeting.id))
        }
    }

    private func delete(_ event: CalendarEventSummary, scope: EventEditScope) {
        guard let services else { return }
        Task {
            _ = await services.calendar.delete(event.identity, scope: scope)
        }
    }

    private func load() async {
        guard let services,
            let identity = EventIdentity.fromStorageKey(identityKey)
        else {
            hasLoaded = true
            return
        }
        event = await services.calendar.event(matching: identity)
        hasLoaded = true
    }
}

/// Creating or editing an event: the fields that matter, the problems said before saving.
struct EventEditorSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let existing: CalendarEventSummary?
    let defaultDay: Date

    @State private var title = ""
    @State private var isAllDay = false
    @State private var startAt = Date()
    @State private var endAt = Date()
    @State private var location = ""
    @State private var notes = ""
    @State private var calendarIdentifier = ""
    @State private var writeFailure: CalendarWriteFailure?
    @State private var hasPrepared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Location", text: $location)
                }

                Section {
                    Toggle("All day", isOn: $isAllDay)
                    DatePicker(
                        "Starts",
                        selection: $startAt,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "Ends",
                        selection: $endAt,
                        in: startAt...,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                }

                if let services, existing == nil {
                    let writable = services.calendar.calendars.filter(\.allowsModification)
                    if !writable.isEmpty {
                        Section {
                            Picker("Calendar", selection: $calendarIdentifier) {
                                ForEach(writable) { info in
                                    Label(info.title, systemImage: "circle.fill")
                                        .tint(Theme.Palette.color(named: info.colorName))
                                        .tag(info.id)
                                }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let failure = writeFailure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { prepare() }
        }
    }

    private func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true

        if let existing {
            title = existing.title
            isAllDay = existing.isAllDay
            startAt = existing.startAt
            endAt = existing.endAt
            location = existing.locationName ?? ""
            notes = existing.notes ?? ""
            calendarIdentifier = existing.calendarIdentifier ?? ""
        } else {
            let calendar = Calendar.current
            var start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDay) ?? defaultDay
            if calendar.isDateInToday(defaultDay) {
                // Next round hour, not nine in the morning of a day that is half over.
                let now = Date()
                let hour = calendar.component(.hour, from: now)
                start = calendar.date(bySettingHour: min(hour + 1, 23), minute: 0, second: 0, of: now) ?? now
            }
            startAt = start
            endAt = start.addingTimeInterval(3600)
            calendarIdentifier = services?.calendar.defaultCalendarIdentifier ?? ""
        }
    }

    private func save() {
        guard let services else { return }
        var draft: EventDraft
        if let existing {
            draft = EventDraft(
                editing: existing,
                calendarIdentifier: existing.calendarIdentifier ?? calendarIdentifier
            )
        } else {
            draft = EventDraft(
                calendarIdentifier: calendarIdentifier,
                title: "",
                startAt: startAt,
                endAt: endAt
            )
        }
        draft.title = title.trimmingCharacters(in: .whitespaces)
        draft.isAllDay = isAllDay
        draft.startAt = startAt
        draft.endAt = endAt
        draft.location = location
        draft.notes = notes

        Task {
            let result: Result<CalendarEventSummary, CalendarWriteFailure>
            if let existing {
                result = await services.calendar.update(existing.identity, with: draft, scope: .thisEvent)
            } else {
                result = await services.calendar.create(draft)
            }
            switch result {
            case .success:
                dismiss()
            case .failure(let failure):
                // The draft stays exactly as typed — a failed save must never eat the form.
                writeFailure = failure
            }
        }
    }
}
