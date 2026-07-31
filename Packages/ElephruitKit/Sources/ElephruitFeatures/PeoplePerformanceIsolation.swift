import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A temporary switch for finding the People module's remaining load-time cost empirically.
///
/// The production People list and the sidebar's fixed destinations, groups, and linked-contact scope
/// are enabled now. Counts, duplicate detection, and celebration derivation remain isolated. Contact
/// source badges are deliberately absent from rows: they added store work without useful information.
enum PeoplePerformanceIsolation {
    static let usesIsolatedSidebar = true
    static let usesIsolatedList = false
}

/// The fixed People destinations, without any store-derived sidebar content.
struct IsolatedPeopleSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var groups: [PersonGroupSummary] = []
    @State private var hasLinkedPeople = false

    var body: some View {
        Section {
            ForEach(PeopleSidebarSection.scopes, id: \.self) { scope in
                Button {
                    navigation.select(.people(scope))
                } label: {
                    Label(scope.title, systemImage: scope.symbolName)
                }
                .buttonStyle(.plain)
                .tag(SidebarSelection.people(scope))
                .help(scope.hint)
                .accessibilityIdentifier(SidebarSelection.people(scope).accessibilityIdentifier)
            }

            if hasLinkedPeople {
                let scope = PeopleScope.fromContacts
                Button {
                    navigation.select(.people(scope))
                } label: {
                    Label(scope.title, systemImage: scope.symbolName)
                }
                .buttonStyle(.plain)
                .tag(SidebarSelection.people(scope))
                .help(scope.hint)
                .accessibilityIdentifier(SidebarSelection.people(scope).accessibilityIdentifier)
            }
        }

        Section("Groups") {
            ForEach(groups) { group in
                let scope = PeopleScope.group(id: group.id)
                Button {
                    navigation.select(.people(scope))
                } label: {
                    Label(group.name, systemImage: group.symbolName)
                }
                .buttonStyle(.plain)
                .tag(SidebarSelection.people(scope))
                .help(scope.hint)
                .accessibilityIdentifier(SidebarSelection.people(scope).accessibilityIdentifier)
            }
        }
        .task { loadSidebar() }
    }

    private func loadSidebar() {
        guard let services else { return }
        groups = (try? services.personGroups.allGroupSummaries()) ?? []
        hasLinkedPeople = (try? services.contactImports.hasLinkedPeople()) ?? false
    }
}

/// Production People loading, sectioning, and rows.
struct IsolatedPeopleListView: View {
    @Environment(\.services) private var services

    @State private var model = PeopleListModel()

    var body: some View {
        Group {
            if let failure = model.loadFailure {
                FailureStateView(error: failure) { _ in load() }
            } else {
                List {
                    ForEach(model.sections) { section in
                        Section(section.title) {
                            ForEach(section.entries) { entry in
                                if let person = model.person(id: entry.id) {
                                    PersonRow(person: person)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("People — contact badges enabled")
        .task { load() }
    }

    private func load() {
        guard let services else { return }

        do {
            model.setPeople(try services.persons.allPeople(includingPlaceholders: false))
        } catch {
            model.setPeople([], failure: error)
        }
    }
}
