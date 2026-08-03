import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The production Records workspace. It reads and writes the shared Item graph; People remains in
/// place as a richer, focused view over person records.
struct RecordsWorkspaceView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel
    let scope: RecordsScope

    @State private var records: [Item] = []
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var tab = RecordsTab.overview
    @State private var isShowingNewRecord = false
    @State private var isShowingContactImport = false
    @State private var loadError: AppError?

    var body: some View {
        detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.contentBackground)
        .sheet(isPresented: $isShowingNewRecord) {
            NewRecordSheet { draft in
                guard let services else { return }
                do {
                    let record = try services.records.create(draft)
                    refresh(selecting: record.id)
                } catch {
                    loadError = appError(error)
                }
            }
        }
        .sheet(isPresented: $isShowingContactImport, onDismiss: { refresh() }) {
            ContactOnboardingView(
                navigation: navigation,
                completionSelection: .records(.unsorted)
            )
        }
        .task(id: navigation.selectedItemID) { refresh() }
        .onChange(of: services?.context.hasChanges) { _, _ in refresh() }
        .alert(
            "Records could not be updated",
            isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } }),
            presenting: loadError
        ) { _ in
            Button("OK") { loadError = nil }
        } message: { error in
            Text(error.summary)
        }
        .accessibilityIdentifier("records.workspace")
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text("Records").font(Theme.Text.title)
                        Text(browserSubtitle)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    Spacer()
                    Menu {
                        Button("New Record", systemImage: "plus") { isShowingNewRecord = true }
                        Divider()
                        Button("Import from Contacts…", systemImage: "person.crop.rectangle.stack") {
                            isShowingContactImport = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add a record or import contacts")
                }

                TextField("Search records", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                scopeFilter
            }
            .padding(Theme.Spacing.large)

            Divider()

            if filteredRecords.isEmpty {
                EmptyStateView(
                    symbolName: scope.symbolName,
                    headline: searchText.isEmpty ? emptyHeadline : "No records match",
                    message: searchText.isEmpty ? emptyMessage : "Try another name, type, or detail.",
                    actionTitle: searchText.isEmpty ? "New Record" : "Clear Search",
                    action: searchText.isEmpty
                        ? { isShowingNewRecord = true }
                        : { searchText = "" }
                )
            } else {
                List(filteredRecords, selection: $selection) { record in
                    recordRow(record)
                        .tag(record.id)
                }
                .listStyle(.inset)
            }

            Divider()

            Button("Import from Contacts…", systemImage: "person.crop.rectangle.stack") {
                isShowingContactImport = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(.regularMaterial)
    }

    /// Records already owns the browser column. Keeping its scopes here turns that column into the
    /// whole Records navigator instead of placing a second navigation sidebar beside it.
    private var scopeFilter: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(RecordsScope.allCases) { candidate in
                let isSelected = candidate == scope
                Button {
                    navigation.select(.records(candidate))
                } label: {
                    Image(systemName: candidate.symbolName)
                        .frame(width: 28, height: 24)
                        .background(isSelected ? Theme.Colors.selection : Theme.Colors.subtleFill)
                        .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.secondaryText)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }
                .buttonStyle(.plain)
                .help(candidate.title)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("records.filter.\(candidate.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordRow(_ record: Item) -> some View {
        let type = services?.records.type(of: record) ?? .other
        let selected = selection == record.id
        return HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: type.symbolName)
                .frame(width: 32, height: 32)
                .background(Theme.Colors.subtleFill)
                .clipShape(.circle)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(record.displayTitle)
                    .font(Theme.Text.rowTitleEmphasised)
                    .lineLimit(1)
                Text(rowSubtitle(for: record, type: type))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.82) : Theme.Colors.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if services?.records.isUnsorted(record) == true {
                Image(systemName: "tray")
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.8) : Theme.Colors.tertiaryText)
                    .help("Unsorted import")
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityLabel("\(record.displayTitle), \(type.displayName)")
    }

    @ViewBuilder
    private var detail: some View {
        if let record = selectedRecord {
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
                symbolName: "circle.grid.2x2",
                headline: "No record selected",
                message: "Choose a person or thing to see its details, notes, history, relationships, and shared work."
            )
        }
    }

    private var selectedRecord: Item? { records.first { $0.id == navigation.selectedItemID } }

    private var filteredRecords: [Item] {
        guard let services else { return [] }
        return records.filter { record in
            if scope == .unsorted, !services.records.isUnsorted(record) { return false }
            if let required = scope.recordType, services.records.type(of: record) != required { return false }
            guard !searchText.isEmpty else { return true }
            let details = record.recordProfile?.details.values.joined(separator: " ") ?? ""
            return "\(record.displayTitle) \(record.body) \(details)"
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    private func refresh(selecting id: UUID? = nil) {
        guard let services else { return }
        do {
            records = try services.records.allRecords()
            loadError = nil
            if let id { navigation.selectItem(id) }
            if navigation.selectedItemID == nil
                || records.contains(where: { $0.id == navigation.selectedItemID }) == false
            {
                navigation.selectItem(filteredRecords.first?.id)
            }
        } catch { loadError = error }
    }

    private func rowSubtitle(for record: Item, type: RecordType) -> String {
        if let summary = record.recordProfile?.details["summary"], !summary.isEmpty { return summary }
        if type == .person {
            return [record.personProfile?.roleTitle, record.personProfile?.organizationName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "Person"
        }
        return type.displayName
    }

    private var browserSubtitle: String {
        scope == .unsorted ? "Contacts waiting to be filed" : "People and things you keep track of"
    }

    private var emptyHeadline: String { scope == .unsorted ? "Nothing to sort" : "No records yet" }
    private var emptyMessage: String {
        scope == .unsorted
            ? "New contact imports wait here until you file them."
            : "Add a person, pet, vehicle, organization, or anything else you track."
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

    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            detailCard(title: "At a glance", symbol: "info.circle") {
                if isEditing {
                    TextField("Short description", text: $summary)
                } else {
                    Text(summary.isEmpty ? "No description yet." : summary)
                        .foregroundStyle(summary.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.primaryText)
                }
                ForEach(details.keys.filter { $0 != "summary" }.sorted(), id: \.self) { key in
                    LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                        if isEditing {
                            TextField(key.capitalized, text: detailBinding(key))
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text(details[key] ?? "")
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

    private var history: some View {
        detailCard(title: "History", symbol: "clock.arrow.circlepath") {
            if record.activities.isEmpty {
                Text("Interactions, appointments, maintenance, medication changes, and other events will build a timeline here.")
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(record.activities.sorted { $0.at > $1.at }) { activity in
                    LabeledContent(activity.sentence) { Text(activity.at, style: .date) }
                    Divider()
                }
            }
        }
    }

    private var relationships: some View {
        detailCard(title: "Relationships", symbol: "point.3.connected.trianglepath.dotted") {
            let links = record.outgoingLinks + record.incomingLinks
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
                return other?.kind == .task ? other : nil
            }
            if tasks.isEmpty {
                Text("Tasks linked to this record appear here, including work assigned to them and things you owe them.")
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
}

struct NewRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (RecordDraft) -> Void

    @State private var name = ""
    @State private var type = RecordType.person
    @State private var summary = ""
    @State private var notes = ""
    @State private var details: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text("New Record").font(Theme.Text.title)
                    Text("People and things share one workspace; the type controls the useful details.")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                Spacer()
            }
            .padding(Theme.Spacing.section)
            Divider()

            Form {
                Picker("Type", selection: $type) {
                    ForEach(RecordType.allCases) { Label($0.displayName, systemImage: $0.symbolName).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField(namePrompt, text: $name)
                TextField("Short description", text: $summary)

                Section("Useful details") {
                    ForEach(detailFields, id: \.key) { field in
                        TextField(field.label, text: binding(field.key))
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 100)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Record") {
                    onCreate(RecordDraft(name: name, type: type, summary: summary, notes: notes, details: details))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Theme.Spacing.large)
        }
        .frame(width: 620, height: 620)
        .onChange(of: type) { _, _ in details = [:] }
    }

    private var namePrompt: String { type == .person ? "Full name" : type == .vehicle ? "Vehicle name" : "Name" }

    private var detailFields: [(key: String, label: String)] {
        switch type {
        case .person: [("role", "Role"), ("organization", "Organization"), ("email", "Email"), ("phone", "Phone")]
        case .pet: [("species", "Species"), ("breed", "Breed"), ("birth_date", "Birth date"), ("vet", "Veterinarian"), ("medications", "Medications")]
        case .vehicle: [("year", "Year"), ("make", "Make"), ("model", "Model"), ("vin", "VIN"), ("license_plate", "License plate")]
        case .organization: [("role", "Your role"), ("website", "Website"), ("phone", "Phone"), ("address", "Address")]
        case .other: [("category", "Category"), ("identifier", "Identifier"), ("location", "Location")]
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { details[key] ?? "" }, set: { details[key] = $0 })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
