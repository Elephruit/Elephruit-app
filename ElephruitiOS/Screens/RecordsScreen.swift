import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Records tab: everyone and everything tracked, people first.
///
/// The Mac gives records a workspace with a browser, a detail pane, and tabs; a phone
/// gets the browser, and each record is a push. The scope vocabulary is the Mac's own
/// `RecordsScope` — same titles, same symbols, same hints — so the two apps never
/// disagree about what "Unsorted" means. Search runs the ranked person-graph search the
/// Mac's command bar uses, so "maya's manager" finds her here too.
struct RecordsScreen: View {
    /// People first: the tab inherits the donor People tab's job. The full type menu is
    /// one tap away, which is a hierarchy, not a hiding place.
    @State private var scope: RecordsScope = .people

    var body: some View {
        RecordsListBody(scope: scope) {
            scopeMenu
        }
        .navigationTitle(scope == .people ? "Records" : scope.title)
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: $scope) {
                ForEach(RecordsScope.typeFilters) { filter in
                    Label(filter.title, systemImage: filter.symbolName).tag(filter)
                }
                Label(RecordsScope.favorites.title, systemImage: RecordsScope.favorites.symbolName)
                    .tag(RecordsScope.favorites)
            }
        } label: {
            Label("Scope", systemImage: scope.symbolName)
        }
        .accessibilityIdentifier("records.scope")
    }
}

/// A routed, fixed-scope slice of the same list — pushed from Library or a link.
struct RecordsListScreen: View {
    let scope: RecordsScope

    var body: some View {
        RecordsListBody(scope: scope) { EmptyView() }
            .navigationTitle(scope.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The shared list: scoped records, ranked search on top.
private struct RecordsListBody<TrailingItem: View>: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let scope: RecordsScope
    @ViewBuilder let trailingItem: TrailingItem

    @State private var records: [Item] = []
    @State private var results: [RankedPerson] = []
    @State private var searchText = ""
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            if isSearching {
                ForEach(results) { person in
                    Button {
                        shell.push(.person(person.id))
                    } label: {
                        rankedRow(person)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(records) { record in
                    Button {
                        shell.push(.person(record.id))
                    } label: {
                        MobileItemRow(item: record)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isSearching, records.isEmpty, loadError == nil {
                EmptyStateView(
                    symbolName: scope.symbolName,
                    headline: "Nothing here yet",
                    message: scope.hint
                )
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { trailingItem }
        }
        .task(id: reloadKey) { reload() }
        .onChange(of: searchText) { _, _ in runSearch() }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One key so the list follows both the library and the scope.
    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(scope.id)"
    }

    private func rankedRow(_ person: RankedPerson) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text(person.name)
                .font(Theme.Text.rowTitle)
            if let reason = person.reasons.first {
                Text(reason.text)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func reload() {
        guard let services else { return }
        do {
            let all = try services.records.allRecords()
            records = all.filter { record in
                switch scope {
                case .all: true
                case .unsorted: services.records.isUnsorted(record)
                case .favorites: record.isFavorite
                default:
                    scope.recordType.map { services.records.type(of: record) == $0 } ?? true
                }
            }
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }

    private func runSearch() {
        guard let services, isSearching else {
            results = []
            return
        }
        results = (try? services.personSearch.search(searchText, limit: 50)) ?? []
    }
}
