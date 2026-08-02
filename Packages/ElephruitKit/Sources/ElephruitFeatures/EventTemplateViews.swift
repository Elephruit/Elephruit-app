import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The menu that applies a saved event shape.
///
/// Ranked by what somebody actually reaches for rather than left in creation order: a list of
/// fifteen templates in the order they happened to be made is a list nobody reads to the bottom of.
struct EventTemplateMenu: View {
    @Environment(\.services) private var services

    /// When the created event should start.
    let start: Date

    var onCreated: (CalendarEventSummary) -> Void
    var onManage: () -> Void

    @State private var templates: [EventTemplate] = []

    var body: some View {
        Menu {
            if templates.isEmpty {
                Text("No templates yet")
            } else {
                ForEach(templates) { template in
                    Button {
                        Task { await apply(template) }
                    } label: {
                        Label(template.name, systemImage: template.symbolName)
                    }
                    .help(template.summary)
                }
                Divider()
            }

            Button("Manage Templates…", action: onManage)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { reload() }
        .help("Create an event from a template")
        .accessibilityLabel("Templates")
        .accessibilityIdentifier(AccessibilityID.Calendar.templateMenu)
    }

    private func reload() {
        templates = (try? services?.eventTemplates.mostUsed(limit: 8)) ?? []
    }

    private func apply(_ template: EventTemplate) async {
        guard let services else { return }

        let draft = template.draft(
            startingAt: start,
            fallbackCalendar: services.calendar.defaultCalendarIdentifier ?? "",
            available: services.calendar.calendars,
            currentZone: services.calendar.timeZoneDisplay.deviceZone
        )

        switch await services.calendar.create(draft) {
        case .success(let event):
            services.perform { try services.eventTemplates.noteUse(of: template.id) }

            // The template's local links are applied to the app's own annotation rather than to the
            // event, which is what keeps a project name out of a work calendar other people read.
            applyLocalLinks(of: template, to: event, services: services)
            onCreated(event)
            reload()

        case .failure(let failure):
            services.calendar.lastWriteFailure = failure
        }
    }

    private func applyLocalLinks(
        of template: EventTemplate,
        to event: CalendarEventSummary,
        services: AppServices
    ) {
        guard template.linkedProjectID != nil || !template.linkedPersonIDs.isEmpty else { return }

        services.perform {
            if let projectID = template.linkedProjectID,
               let project = try services.items.item(id: projectID) {
                try services.eventLinks.file(event, under: project)
            }
            for personID in template.linkedPersonIDs {
                guard let person = try services.items.item(id: personID) else { continue }
                try services.eventLinks.link(person: person, to: event)
            }
        }
    }
}

/// Managing saved templates.
struct EventTemplateListView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [EventTemplate] = []
    @State private var editing: EventTemplate?
    @State private var pendingDeletion: EventTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Event Templates")
                    .font(Theme.Text.title)
                Spacer()
                Button {
                    editing = EventTemplate(name: "New Template")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New template")
                .accessibilityLabel("New template")
            }
            .padding(Theme.Spacing.medium)

            Divider()

            if templates.isEmpty {
                EmptyStateView(
                    symbolName: "doc.on.doc",
                    headline: "No templates yet",
                    message: """
                        A template is a shape you apply when you decide to — a one-to-one, a review, \
                        a standing call — with its length, calendar, alarms, and links already set. \
                        It is not a repeating event: it appears only when you use it.
                        """,
                    actionTitle: "New Template",
                    action: { editing = EventTemplate(name: "New Template") }
                )
                .frame(height: 240)
            } else {
                List {
                    ForEach(templates) { template in
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: template.symbolName)
                                .foregroundStyle(Theme.Palette.color(named: template.colorName))
                                .frame(width: Theme.Size.rowGlyph)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.name)
                                    .font(Theme.Text.rowTitle)
                                Text(template.summary)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if template.useCount > 0 {
                                Text("\(template.useCount)×")
                                    .font(Theme.Text.keyHint)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .help("Used \(template.useCount) times")
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { editing = template }
                        .contextMenu {
                            Button("Edit…") { editing = template }
                            Button("Delete…", role: .destructive) { pendingDeletion = template }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 460, height: 420)
        .task { reload() }
        // Configuration, not content, so the structural rule applies: confirm, and say what goes.
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Template", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Events already created from it are not affected.")
        }
        .sheet(item: $editing) { template in
            EventTemplateEditorView(template: template) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.templateEditor)
    }

    private func reload() {
        templates = (try? services?.eventTemplates.templates()) ?? []
    }

    private func save(_ template: EventTemplate) {
        guard let services else { return }
        services.perform {
            if templates.contains(where: { $0.id == template.id }) {
                try services.eventTemplates.update(template)
            } else {
                try services.eventTemplates.create(template)
            }
        }
        reload()
    }

    private func confirmDeletion() {
        defer { pendingDeletion = nil }
        guard let services, let template = pendingDeletion else { return }
        services.perform { try services.eventTemplates.delete(id: template.id) }
        reload()
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let services else { return }
        var reordered = templates
        reordered.move(fromOffsets: source, toOffset: destination)
        services.perform { try services.eventTemplates.reorder(reordered.map(\.id)) }
        reload()
    }
}

/// Editing one template.
struct EventTemplateEditorView: View {
    @Environment(\.services) private var services

    @State var template: EventTemplate
    var onSave: (EventTemplate) -> Void
    var onCancel: () -> Void

    private var calendars: [CalendarInfo] {
        services?.calendar.calendars.filter(\.allowsModification) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Template name", text: $template.name)
                    TextField("Event title", text: $template.title)

                    Stepper(value: $template.durationMinutes, in: 5...(60 * 24), step: 5) {
                        Text(EventAlarm.durationPhrase(template.durationMinutes))
                            .monospacedDigit()
                    }

                    Picker("Calendar", selection: calendarBinding) {
                        Text("The set's default").tag("")
                        ForEach(calendars) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                }

                Section("Details") {
                    TextField("Location", text: $template.location)

                    Picker("Shows as", selection: $template.availability) {
                        ForEach(EventAvailability.selectable, id: \.self) { availability in
                            Text(availability.displayName).tag(availability)
                        }
                    }

                    Picker("Time zone", selection: timeZoneBinding) {
                        Text("Wherever I am").tag("current")
                        Text("The same time everywhere").tag("floating")
                        ForEach(zoneChoices, id: \.self) { identifier in
                            Text(EventPhraseParser.shortZoneName(identifier)).tag(identifier)
                        }
                    }

                    AlarmEditor(alarms: $template.alarms)
                }

                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text("Notes")
                            .font(Theme.Text.sectionHeader)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        TextEditor(text: $template.notes)
                            .font(Theme.Text.rowSubtitle)
                            .frame(height: 60)
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                    .strokeBorder(Theme.Colors.separator)
                            }
                    }
                } footer: {
                    Text("""
                        Notes here are written into the calendar event, so anybody who can see the \
                        event can read them. Anything private belongs in the event's own panel, which \
                        stays in Elephruit.
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
                Button("Save") { onSave(template) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 440, height: 520)
    }

    private var zoneChoices: [String] {
        services?.calendar.timeZoneDisplay.favouriteZoneIdentifiers ?? []
    }

    private var calendarBinding: Binding<String> {
        Binding(
            get: { template.calendar?.identifier ?? "" },
            set: { identifier in
                template.calendar = calendars.first { $0.id == identifier }?.reference
            }
        )
    }

    private var timeZoneBinding: Binding<String> {
        Binding(
            get: {
                switch template.timeZoneBehaviour {
                case .currentZone: "current"
                case .floating: "floating"
                case .fixedZone(let identifier): identifier
                }
            },
            set: { choice in
                switch choice {
                case "current": template.timeZoneBehaviour = .currentZone
                case "floating": template.timeZoneBehaviour = .floating
                default: template.timeZoneBehaviour = .fixedZone(identifier: choice)
                }
            }
        )
    }
}
