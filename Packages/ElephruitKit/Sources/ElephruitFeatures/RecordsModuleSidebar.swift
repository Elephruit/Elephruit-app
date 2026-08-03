import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Records' entire navigation in one column: filters, search, and the records themselves.
/// `ModuleHeader` supplies the back button immediately above this view.
struct RecordsModuleSidebar: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var records: [Item] = []
    @State private var searchText = ""
    @State private var isShowingNewRecord = false
    @State private var isShowingContactImport = false
    @State private var loadError: AppError?

    private var scope: RecordsScope {
        if case .records(let scope) = navigation.selection { return scope }
        return .all
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack {
                    TextField("Search records", text: $searchText)
                        .textFieldStyle(.roundedBorder)
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
                List(filteredRecords, selection: selectionBinding) { record in
                    row(record).tag(record.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
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
        .sheet(isPresented: $isShowingNewRecord) {
            NewRecordSheet { draft in
                guard let services else { return }
                do {
                    let record = try services.records.create(draft)
                    refresh(selecting: record.id)
                } catch { loadError = appError(error) }
            }
        }
        .sheet(isPresented: $isShowingContactImport, onDismiss: { refresh() }) {
            ContactOnboardingView(
                navigation: navigation,
                completionSelection: .records(.unsorted)
            )
        }
        .task(id: scope) { refresh() }
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
        .accessibilityIdentifier("sidebar.module.records.browser")
    }

    private var scopeFilter: some View {
        HStack(spacing: Theme.Spacing.tight) {
            ForEach(RecordsScope.allCases) { candidate in
                let selected = candidate == scope
                Button {
                    navigation.select(.records(candidate))
                } label: {
                    Image(systemName: candidate.symbolName)
                        .frame(width: 26, height: 24)
                        .background(selected ? Theme.Colors.selection : Theme.Colors.subtleFill)
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.secondaryText)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }
                .buttonStyle(.plain)
                .help(candidate.title)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("records.filter.\(candidate.rawValue)")
            }
        }
    }

    private func row(_ record: Item) -> some View {
        let type = services?.records.type(of: record) ?? .other
        return HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: type.symbolName)
                .frame(width: 30, height: 30)
                .background(Theme.Colors.subtleFill)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(record.displayTitle).font(Theme.Text.rowTitleEmphasised).lineLimit(1)
                Text(subtitle(for: record, type: type))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if services?.records.isUnsorted(record) == true {
                Image(systemName: "tray").foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

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

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { navigation.selectedItemID },
            set: { navigation.selectItem($0) }
        )
    }

    private func refresh(selecting id: UUID? = nil) {
        guard let services else { return }
        do {
            records = try services.records.allRecords()
            loadError = nil
            if let id { navigation.selectItem(id) }
            if navigation.selectedItemID == nil
                || filteredRecords.contains(where: { $0.id == navigation.selectedItemID }) == false
            {
                navigation.selectItem(filteredRecords.first?.id)
            }
        } catch { loadError = error }
    }

    private func subtitle(for record: Item, type: RecordType) -> String {
        if let summary = record.recordProfile?.details["summary"], !summary.isEmpty { return summary }
        if type == .person {
            let value = [record.personProfile?.roleTitle, record.personProfile?.organizationName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return value.isEmpty ? "Person" : value
        }
        return type.displayName
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
