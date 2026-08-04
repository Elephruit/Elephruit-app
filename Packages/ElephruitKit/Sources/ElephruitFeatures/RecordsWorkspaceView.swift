import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The detail canvas for the record selected in Records' single browser column.
struct RecordsWorkspaceView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel
    let scope: RecordsScope

    @State private var records: [Item] = []
    @State private var tab = RecordsTab.overview
    @State private var loadError: AppError?
    @State private var contactMessage: String?

    var body: some View {
        detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.contentBackground)
        .task(id: navigation.selectedItemID) { refresh() }
        .onChange(of: services?.context.hasChanges) { _, _ in refresh() }
        .onDisappear { navigation.isNewRecordVisible = false }
        .alert(
            "Records could not be updated",
            isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } }),
            presenting: loadError
        ) { _ in
            Button("OK") { loadError = nil }
        } message: { error in
            Text(error.summary)
        }
        .alert(
            "Person saved",
            isPresented: Binding(get: { contactMessage != nil }, set: { if !$0 { contactMessage = nil } })
        ) {
            Button("OK") { contactMessage = nil }
        } message: {
            Text(contactMessage ?? "")
        }
        .accessibilityIdentifier("records.workspace")
    }

    @ViewBuilder
    private var detail: some View {
        if navigation.isNewRecordVisible {
            NewRecordEditor(
                onCancel: cancelNewRecord,
                onCreate: createRecord
            )
        } else if scope == .celebrations {
            CelebrationsView(navigation: navigation)
        } else if scope == .duplicates {
            DuplicatesView(navigation: navigation)
        } else if let record = selectedRecord {
            if record.kind == .person {
                // Person records keep the full CRM portrait, timeline, contact actions, meeting
                // brief, facts, and relationship charts that previously required leaving Records.
                ItemDetailView(navigation: navigation)
            } else {
                RecordDetail(record: record, tab: $tab) {
                    do {
                        try services?.records.file(record)
                        refresh(selecting: record.id)
                    } catch { loadError = appError(error) }
                } onSave: { summary, notes, details in
                    do {
                        try services?.records.update(record, summary: summary, notes: notes, details: details)
                        refresh(selecting: record.id)
                    } catch { loadError = appError(error) }
                }
            }
        } else {
            EmptyStateView(
                symbolName: "person.text.rectangle",
                headline: "No record selected",
                message: "Choose a person or thing to see its details, notes, history, relationships, and shared work."
            )
        }
    }

    private var selectedRecord: Item? { records.first { $0.id == navigation.selectedItemID } }

    private func cancelNewRecord() {
        navigation.isNewRecordVisible = false
    }

    private func createRecord(_ draft: RecordDraft) {
        guard let services else { return }
        do {
            let record = try services.records.create(draft)
            navigation.isNewRecordVisible = false
            refresh(selecting: record.id)
            if draft.addToContacts {
                addToAppleContacts(draft, person: record, services: services)
            }
        } catch {
            loadError = appError(error)
        }
    }

    private func addToAppleContacts(_ draft: RecordDraft, person: Item, services: AppServices) {
        Task {
            if !services.contacts.isEnabled {
                _ = await services.contacts.enable()
            }

            let value: (String) -> String = { key in
                draft.details[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let labelled: (String, String) -> [ContactLabelledValue] = { label, raw in
                raw.isEmpty ? [] : [ContactLabelledValue(label: label, value: raw)]
            }
            let contact = ContactCreate(
                givenName: value("given_name"),
                middleName: value("middle_name"),
                familyName: value("family_name"),
                namePrefix: value("name_prefix"),
                nameSuffix: value("name_suffix"),
                nickname: value("nickname"),
                jobTitle: value("role"),
                departmentName: value("department"),
                organizationName: value("organization"),
                emailAddresses: labelled("email", value("email")),
                phoneNumbers: labelled("phone", value("phone")),
                urlAddresses: labelled("website", value("website"))
            )

            switch await services.contacts.create(contact) {
            case .created(let systemContact):
                do {
                    try services.contactImports.attachCreatedContact(systemContact, to: person)
                    refresh(selecting: person.id)
                } catch {
                    contactMessage = "The Apple contact was created, but Elephruit could not link it back to this record."
                }
            case .notPermitted:
                contactMessage = ContactCreateOutcome.notPermitted.explanation
            case .failed(let reason):
                contactMessage = ContactCreateOutcome.failed(reason).explanation
            }
        }
    }

    private func refresh(selecting id: UUID? = nil) {
        guard let services else { return }
        do {
            records = try services.records.allRecords()
            loadError = nil
            if let id { navigation.selectItem(id) }
        } catch { loadError = error }
    }

    private func appError(_ error: any Error) -> AppError {
        (error as? AppError) ?? .storeUnavailable(underlying: error.localizedDescription)
    }
}

private enum RecordsTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case history = "History"
    case relationships = "Relationships"
    case work = "Shared Work"
    var id: String { rawValue }
}

private struct RecordDetail: View {
    @Environment(\.services) private var services
    let record: Item
    @Binding var tab: RecordsTab
    let onFile: () -> Void
    let onSave: (String, String, [String: String]) -> Void

    @State private var summary = ""
    @State private var notes = ""
    @State private var details: [String: String] = [:]
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $tab) {
                ForEach(RecordsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .padding(Theme.Spacing.large)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .overview: overview
                    case .history: history
                    case .relationships: relationships
                    case .work: sharedWork
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(Theme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .id(record.id)
        .onAppear(perform: loadDraft)
    }

    private var type: RecordType { services?.records.type(of: record) ?? .other }

    private var header: some View {
        HStack(spacing: Theme.Spacing.large) {
            Image(systemName: type.symbolName)
                .font(.system(.title, weight: .medium))
                .frame(width: 58, height: 58)
                .background(Theme.Colors.subtleFill)
                .clipShape(.rect(cornerRadius: Theme.Radius.large))

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack {
                    Text(record.displayTitle).font(.system(.title, weight: .semibold))
                    Text(type.displayName)
                        .font(Theme.Text.chip)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.hairline)
                        .background(Theme.Colors.subtleFill)
                        .clipShape(.capsule)
                }
                if !summary.isEmpty {
                    Text(summary).foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            Spacer()
            if services?.records.isUnsorted(record) == true {
                Button("File Record", systemImage: "tray.and.arrow.down", action: onFile)
            }
            Button(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil") {
                if isEditing { onSave(summary, notes, details) }
                isEditing.toggle()
            }
        }
        .padding(Theme.Spacing.section)
    }

    @ViewBuilder
    private var overview: some View {
        if type == .pet && !isEditing {
            petOverview
        } else {
            genericOverview
        }
    }

    private var genericOverview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            detailCard(title: "At a glance", symbol: "info.circle") {
                if isEditing {
                    TextField("Short description", text: $summary)
                } else {
                    Text(summary.isEmpty ? "No description yet." : summary)
                        .foregroundStyle(summary.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.primaryText)
                }
                ForEach(visibleDetailKeys, id: \.self) { key in
                    LabeledContent(detailDisplayName(key)) {
                        if isEditing {
                            TextField(key.capitalized, text: detailBinding(key))
                                .multilineTextAlignment(.trailing)
                        } else {
                            detailValue(key)
                        }
                    }
                }
            }

            detailCard(title: "Notes", symbol: "note.text") {
                if isEditing {
                    TextEditor(text: $notes).frame(minHeight: 140)
                } else {
                    Text(notes.isEmpty ? "Add background, care instructions, preferences, or anything worth remembering." : notes)
                        .foregroundStyle(notes.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.primaryText)
                        .textSelection(.enabled)
                }
            }

            if type == .person {
                detailCard(title: "Contact details", symbol: "person.text.rectangle") {
                    let profile = record.personProfile
                    contactRows(profile)
                }
            }
        }
    }

    private var petOverview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(.title3, weight: .medium))
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Theme.Spacing.section), GridItem(.flexible())],
                alignment: .leading,
                spacing: Theme.Spacing.section
            ) {
                petInfoCard(
                    title: "Profile",
                    symbol: "pawprint",
                    fields: [
                        ("Species", "species"),
                        ("Breed", "breed"),
                        ("Birth date", "birth_date"),
                    ],
                    emptyMessage: "Add species, breed, or birthday."
                )
                petCareCard
            }

            detailCard(title: "Notes", symbol: "note.text") {
                Text(notes.isEmpty ? "Add care instructions, temperament, dietary notes, or anything useful to remember." : notes)
                    .foregroundStyle(notes.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.primaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private func petInfoCard(
        title: String,
        symbol: String,
        fields: [(label: String, key: String)],
        emptyMessage: String
    ) -> some View {
        let populated = fields.filter { !(details[$0.key] ?? "").isEmpty }
        return VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Label(title, systemImage: symbol)
                .font(Theme.Text.rowTitleEmphasised)

            if populated.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(populated, id: \.key) { field in
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(field.label)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(details[field.key] ?? "")
                            .font(Theme.Text.rowTitleEmphasised)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Theme.Colors.subtleFill)
        .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }

    private var petCareCard: some View {
        let vet = details["vet"] ?? ""
        let medications = details["medications"] ?? ""
        let hasContactDetails = ["vet_address", "vet_phone", "vet_website", "vet_maps_url"]
            .contains { !(details[$0] ?? "").isEmpty }

        return VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Label("Care", systemImage: "cross.case")
                .font(Theme.Text.rowTitleEmphasised)

            if vet.isEmpty && medications.isEmpty && !hasContactDetails {
                Text("Add a veterinarian or medication details.")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                if !vet.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Veterinarian")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(vet)
                            .font(Theme.Text.rowTitleEmphasised)
                            .textSelection(.enabled)
                        placeContactRows(prefix: "vet")
                    }
                }
                if !medications.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text("Medications")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(medications)
                            .font(Theme.Text.rowTitleEmphasised)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Theme.Colors.subtleFill)
        .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }

    @ViewBuilder
    private func placeContactRows(prefix: String) -> some View {
        let value: (String) -> String = { details["\(prefix)_\($0)"] ?? "" }
        if !value("address").isEmpty {
            Label(value("address"), systemImage: "mappin")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .textSelection(.enabled)
        }
        if let phoneURL = URL(string: "tel:\(value("phone"))"), !value("phone").isEmpty {
            Link(destination: phoneURL) {
                Label(value("phone"), systemImage: "phone")
            }
            .font(Theme.Text.rowSubtitle)
        }
        if let websiteURL = URL(string: value("website")), !value("website").isEmpty {
            Link(destination: websiteURL) {
                Label("Website", systemImage: "safari")
            }
            .font(Theme.Text.rowSubtitle)
        }
        if let mapsURL = URL(string: value("maps_url")), !value("maps_url").isEmpty {
            Link(destination: mapsURL) {
                Label("Open in Maps", systemImage: "map")
            }
            .font(Theme.Text.rowSubtitle)
        }
    }

    private var history: some View {
        detailCard(title: "History", symbol: "clock.arrow.circlepath") {
            if historyEntries.isEmpty {
                Text("Interactions, appointments, maintenance, medication changes, and other events will build a timeline here.")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(historyEntries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Image(systemName: entry.symbolName)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: Theme.Size.rowGlyph)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.small)
                        Text(entry.date, style: .date)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Divider()
                }
            }
        }
    }

    /// Calendar tags are participant links to a lazily-created meeting item. Reading those links
    /// here makes the tag an interaction on the record as well as preparation context on the event.
    private var historyEntries: [RecordHistoryEntry] {
        let activities = record.activities.map { activity in
            RecordHistoryEntry(
                id: "activity-\(activity.id.uuidString)",
                date: activity.at,
                title: activity.sentence,
                detail: nil,
                symbolName: "clock.arrow.circlepath"
            )
        }

        let meetings = (record.incomingLinks + record.outgoingLinks).compactMap { link -> Item? in
            guard link.kind == .participant else { return nil }
            let other = link.source?.id == record.id ? link.target : link.source
            return other?.kind == .meeting ? other : nil
        }.map { meeting in
            RecordHistoryEntry(
                id: "meeting-\(meeting.id.uuidString)",
                date: meeting.eventReference?.startAt ?? meeting.startAt ?? meeting.createdAt,
                title: meeting.displayTitle,
                detail: "Calendar interaction",
                symbolName: "calendar"
            )
        }

        return (activities + meetings).sorted { $0.date > $1.date }
    }

    private struct RecordHistoryEntry: Identifiable {
        let id: String
        let date: Date
        let title: String
        let detail: String?
        let symbolName: String
    }

    private var relationships: some View {
        detailCard(title: "Relationships", symbol: "point.3.connected.trianglepath.dotted") {
            let links = (record.outgoingLinks + record.incomingLinks).filter { link in
                let related = link.source?.id == record.id ? link.target : link.source
                return link.kind != .participant || related?.kind != .meeting
            }
            if links.isEmpty {
                Text("Connect this record to people, households, organizations, vehicles, pets, projects, and notes.")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(links) { link in
                    let related = link.source?.id == record.id ? link.target : link.source
                    Label(related?.displayTitle ?? "Related record", systemImage: related?.kind.symbolName ?? "link")
                }
            }
        }
    }

    private var sharedWork: some View {
        detailCard(title: "Assigned and owed", symbol: "checklist") {
            let tasks = (record.outgoingLinks + record.incomingLinks).compactMap { link in
                let other = link.source?.id == record.id ? link.target : link.source
                return other?.kind == .reminder ? other : nil
            }
            if tasks.isEmpty {
                Text("Reminders linked to this record appear here, including things assigned to them and things you owe them.")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(tasks) { task in Label(task.displayTitle, systemImage: "circle") }
            }
        }
    }

    @ViewBuilder
    private func contactRows(_ profile: PersonProfile?) -> some View {
        if let profile {
            if let role = profile.roleTitle, !role.isEmpty { LabeledContent("Role", value: role) }
            if let org = profile.organizationName, !org.isEmpty { LabeledContent("Organization", value: org) }
            ForEach(profile.emails, id: \.self) { LabeledContent($0.label, value: $0.value) }
            ForEach(profile.phones, id: \.self) { LabeledContent($0.label, value: $0.value) }
            if profile.emails.isEmpty && profile.phones.isEmpty {
                Text("No contact details yet.").foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private func detailCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: symbol).font(Theme.Text.rowTitleEmphasised)
            content()
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.subtleFill)
        .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }

    private func loadDraft() {
        let stored = record.recordProfile?.details ?? [:]
        summary = stored["summary"] ?? ""
        details = stored.filter { $0.key != "summary" }
        notes = record.body
    }

    private func detailBinding(_ key: String) -> Binding<String> {
        Binding(get: { details[key] ?? "" }, set: { details[key] = $0 })
    }

    private var visibleDetailKeys: [String] {
        details.keys.filter { key in
            key != "summary"
                && !key.hasSuffix("map_item_id")
                && !key.hasSuffix("latitude")
                && !key.hasSuffix("longitude")
        }.sorted()
    }

    private func detailDisplayName(_ key: String) -> String {
        if key.hasSuffix("maps_url") { return "Apple Maps" }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @ViewBuilder
    private func detailValue(_ key: String) -> some View {
        let value = details[key] ?? ""
        if key.hasSuffix("maps_url"), let url = URL(string: value) {
            Link("Open in Maps", destination: url)
        } else if key.hasSuffix("website"), let url = URL(string: value) {
            Link("Website", destination: url)
        } else if key.hasSuffix("phone"), let url = URL(string: "tel:\(value)") {
            Link(value, destination: url)
        } else {
            Text(value).textSelection(.enabled)
        }
    }
}

struct NewRecordEditor: View {
    let onCancel: () -> Void
    let onCreate: (RecordDraft) -> Void

    @State private var name = ""
    @State private var type = RecordType.person
    @State private var summary = ""
    @State private var notes = ""
    @State private var details: [String: String] = [:]
    @State private var addToContacts = false
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    typeChooser
                    identityCard
                    detailsCard
                    if type == .person { contactsCard }
                    notesCard
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.section)
                .padding(.vertical, Theme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Theme.Colors.contentBackground)
        .onAppear { focusedField = "name" }
        .onChange(of: type) { _, _ in
            details = [:]
            addToContacts = false
            focusedField = "name"
        }
        .accessibilityIdentifier("records.new.editor")
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button(action: onCancel) {
                Label("Back to Records", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .keyboardShortcut(.cancelAction)

            Divider().frame(height: 20)

            Text("New Record")
                .font(Theme.Text.title)

            Spacer()

            Button("Add Record", systemImage: "plus", action: create)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .frame(height: 68)
    }

    private var typeChooser: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Record type")
                .font(Theme.Text.rowTitleEmphasised)

            HStack(spacing: Theme.Spacing.medium) {
                ForEach(RecordType.allCases) { candidate in
                    typeButton(candidate)
                }
            }
        }
    }

    private func typeButton(_ candidate: RecordType) -> some View {
        let selected = type == candidate
        return Button {
            type = candidate
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: candidate.symbolName)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.secondaryText)

                Text(candidate.displayName)
                    .font(Theme.Text.rowTitleEmphasised)
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.primaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
            .padding(.horizontal, Theme.Spacing.medium)
            .background(selected ? Theme.Colors.selection : Theme.Colors.subtleFill)
            .clipShape(.rect(cornerRadius: Theme.Radius.large))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .stroke(selected ? Color.clear : Theme.Colors.separator.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var identityCard: some View {
        editorCard {
            if type == .person {
                editorField(label: "Prefix", text: binding("name_prefix"), focusID: "name_prefix")
                Divider()
                editorField(label: "First name", text: binding("given_name"), focusID: "name")
                Divider()
                editorField(label: "Middle name", text: binding("middle_name"), focusID: "middle_name")
                Divider()
                editorField(label: "Last name", text: binding("family_name"), focusID: "family_name")
                Divider()
                editorField(label: "Suffix", text: binding("name_suffix"), focusID: "name_suffix")
                Divider()
                editorField(label: "Nickname", text: binding("nickname"), focusID: "nickname")
            } else if type == .organization {
                MapPlaceSearchField(
                    label: "Organization name",
                    text: $name,
                    onSelect: { applyMapListing($0, prefix: nil) },
                    onClear: { clearMapListing(prefix: nil) }
                )
            } else {
                editorField(label: namePrompt, text: $name, focusID: "name")
            }
            Divider()
            editorField(label: "Short description", text: $summary, focusID: "summary")
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            sectionTitle("Useful details", symbol: "list.bullet.rectangle")

            editorCard {
                ForEach(Array(detailFields.enumerated()), id: \.element.key) { index, field in
                    if let prefix = mapPrefix(for: field.key) {
                        MapPlaceSearchField(
                            label: field.label,
                            text: binding(field.key),
                            onSelect: { applyMapListing($0, prefix: prefix) },
                            onClear: { clearMapListing(prefix: prefix) }
                        )
                    } else {
                        editorField(label: field.label, text: binding(field.key), focusID: field.key)
                    }
                    if index < detailFields.count - 1 { Divider() }
                }
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            sectionTitle("Notes", symbol: "note.text")

            TextEditor(text: $notes)
                .font(Theme.Text.editorBody)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.medium)
                .frame(minHeight: 170)
                .background(Theme.Colors.subtleFill)
                .clipShape(.rect(cornerRadius: Theme.Radius.large))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text(notesPrompt)
                            .font(Theme.Text.editorBody)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.horizontal, Theme.Spacing.large)
                            .padding(.vertical, Theme.Spacing.large)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var contactsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            sectionTitle("Apple Contacts", symbol: "person.crop.circle.badge.plus")

            HStack(spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text("Add this person to Apple Contacts")
                        .font(Theme.Text.rowTitleEmphasised)
                    Text("The structured name and contact details above will be used. You may be asked for Contacts access.")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $addToContacts)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(Theme.Spacing.large)
            .background(Theme.Colors.subtleFill)
            .clipShape(.rect(cornerRadius: Theme.Radius.large))
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(Theme.Text.rowTitleEmphasised)
    }

    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, Theme.Spacing.large)
            .background(Theme.Colors.subtleFill)
            .clipShape(.rect(cornerRadius: Theme.Radius.large))
    }

    private func editorField(
        label: String,
        text: Binding<String>,
        focusID: String
    ) -> some View {
        HStack(spacing: Theme.Spacing.large) {
            Text(label)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 150, alignment: .leading)

            TextField(label, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: focusID)

            Spacer()
        }
        .frame(minHeight: 54)
    }

    private var namePrompt: String { type == .person ? "Full name" : type == .vehicle ? "Vehicle name" : "Name" }

    private var notesPrompt: String {
        switch type {
        case .person: "Background, interests, context, or anything useful to remember."
        case .pet: "Care instructions, temperament, dietary notes, or health context."
        case .vehicle: "Maintenance context, quirks, service preferences, or history."
        case .organization: "Background, key contacts, working context, or useful details."
        case .other: "Anything useful to remember about this record."
        }
    }

    private var trimmedName: String {
        if type == .person {
            let structured = ["name_prefix", "given_name", "middle_name", "family_name", "name_suffix"]
                .compactMap { details[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !structured.isEmpty { return structured }
            return details["nickname"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(
            RecordDraft(
                name: trimmedName,
                type: type,
                summary: summary,
                notes: notes,
                details: details,
                addToContacts: type == .person && addToContacts
            )
        )
    }

    private var detailFields: [(key: String, label: String)] {
        switch type {
        case .person: [
            ("role", "Role"),
            ("department", "Department"),
            ("organization", "Organization"),
            ("email", "Email"),
            ("phone", "Phone"),
            ("website", "Website"),
        ]
        case .pet: [("species", "Species"), ("breed", "Breed"), ("birth_date", "Birth date"), ("vet", "Veterinarian"), ("medications", "Medications")]
        case .vehicle: [("year", "Year"), ("make", "Make"), ("model", "Model"), ("vin", "VIN"), ("license_plate", "License plate")]
        case .organization: [("role", "Your role"), ("website", "Website"), ("phone", "Phone"), ("address", "Address")]
        case .other: [("category", "Category"), ("identifier", "Identifier"), ("location", "Location")]
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { details[key] ?? "" }, set: { details[key] = $0 })
    }

    private func mapPrefix(for key: String) -> String? {
        switch (type, key) {
        case (.pet, "vet"): "vet"
        case (.person, "organization"): "organization"
        default: nil
        }
    }

    private func applyMapListing(_ listing: MapPlaceListing, prefix: String?) {
        let key: (String) -> String = { suffix in
            prefix.map { "\($0)_\(suffix)" } ?? suffix
        }
        if let prefix {
            details[prefix] = listing.name
        } else {
            name = listing.name
        }
        details[key("address")] = listing.address
        details[key("phone")] = listing.phone
        details[key("website")] = listing.website
        details[key("maps_url")] = listing.mapsURL
        details[key("map_item_id")] = listing.mapItemIdentifier ?? ""
        details[key("latitude")] = listing.latitude
        details[key("longitude")] = listing.longitude
    }

    private func clearMapListing(prefix: String?) {
        let key: (String) -> String = { suffix in
            prefix.map { "\($0)_\(suffix)" } ?? suffix
        }
        for suffix in ["address", "phone", "website", "maps_url", "map_item_id", "latitude", "longitude"] {
            details[key(suffix)] = nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
