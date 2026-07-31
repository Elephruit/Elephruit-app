import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Which slice of People the middle column is showing.
///
/// A value type for the same reason ``SidebarSelection`` is one: it survives scene restoration, it
/// compares for equality, and "what does Needs follow-up mean" is answered by a pure function rather
/// than inside a view.
public enum PeopleScope: Hashable, Sendable, Codable {
    case all
    case recentlyViewed
    case favorites
    case celebrations
    case needsFollowUp
    case group(id: UUID)
    case duplicates

    /// People whose standard details come from the address book.
    ///
    /// A scope rather than a separate list, because the point of the module is that there is **one**
    /// person record — not an iCloud version and a CRM version. This filters the same list.
    case fromContacts

    public var title: String {
        switch self {
        case .all: "All People"
        case .recentlyViewed: "Recently Viewed"
        case .favorites: "Favourites"
        case .celebrations: "Celebrations"
        case .needsFollowUp: "Needs Follow-up"
        case .group: "Group"
        case .duplicates: "Possible Duplicates"
        case .fromContacts: "From Contacts"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: "person.2"
        case .recentlyViewed: "clock.arrow.circlepath"
        case .favorites: "star"
        case .celebrations: "birthday.cake"
        case .needsFollowUp: "hand.wave"
        case .group: "person.2.circle"
        case .duplicates: "person.crop.circle.badge.questionmark"
        case .fromContacts: "person.crop.rectangle.stack"
        }
    }

    /// The empty state, which differs per scope because "you have nobody" and "nobody is overdue"
    /// are entirely different pieces of news.
    public var emptyMessage: String {
        switch self {
        case .all: "Add somebody with ⌘⇧K, or link a contact from Settings."
        case .recentlyViewed: "People you open appear here for this session."
        case .favorites: "Star somebody to keep them close."
        case .celebrations: "Record a birthday or an anniversary and it will appear here."
        case .needsFollowUp: "Nobody is overdue. Follow-up suggestions are off until you turn them on."
        case .group: "Nobody in this group yet."
        case .duplicates: "No likely duplicates. Contacts from several accounts are matched automatically."
        case .fromContacts: "Nobody is linked to your address book yet. Import contacts from People settings."
        }
    }
}

/// The middle column when People is selected.
///
/// Compact rows: name, the one line that answers "where are we with this person", and a hint of what
/// is open. Multi-selection and a batch bar, the same shape `ItemListView` already uses, so nothing
/// about selecting people is a special case the user has to learn separately.
struct PeopleListView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel
    let scope: PeopleScope

    @State private var people: [Item] = []
    @State private var selection: Set<UUID> = []
    @State private var searchText = ""
    @State private var searchResults: [RankedPerson] = []
    @State private var isShowingBatchEmail = false
    @State private var loadFailure: AppError?

    var body: some View {
        VStack(spacing: 0) {
            if let loadFailure {
                FailureStateView(error: loadFailure) { _ in reload() }
            } else if isSearching {
                searchList
            } else if people.isEmpty {
                EmptyStateView(
                    symbolName: scope.symbolName,
                    headline: scope.title,
                    message: scope.emptyMessage
                )
            } else {
                list
            }

            if selection.count > 1 {
                Divider()
                PeopleBatchBar(
                    count: selection.count,
                    onEmail: { isShowingBatchEmail = true },
                    onClear: { selection = [] }
                )
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "people in Austin · likes natural wine")
        .onChange(of: searchText) { _, query in runSearch(query) }
        .navigationTitle(scope.title)
        .accessibilityIdentifier(AccessibilityID.People.list)
        .task(id: scope) { reload() }
        .sheet(isPresented: $isShowingBatchEmail) {
            AdHocGroupActionSheet(personIDs: Array(selection)) { isShowingBatchEmail = false }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(people, id: \.id) { person in
                PersonRow(person: person, dateProvider: services?.dateProvider ?? SystemDateProvider())
                    .tag(person.id)
                    .contextMenu {
                        Button("Open") { navigation.selectItem(person.id) }
                        Button(person.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                            toggleFavorite(person)
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) { trash(person) }
                    }
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, newValue in
            // The list's own selection drives the detail pane, so clicking a row opens somebody
            // without a second gesture.
            navigation.selectedItemIDs = newValue
        }
    }

    private var searchList: some View {
        List {
            if searchResults.isEmpty {
                EmptyStateView(
                    symbolName: "magnifyingglass",
                    headline: "Nobody matches",
                    message: "Try “\(PersonQueryParser.examples.randomElement() ?? "people in Austin")”."
                )
            } else {
                ForEach(searchResults) { result in
                    Button {
                        navigation.selectItem(result.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.name)
                                .font(Theme.Text.rowTitle)
                            if let reason = result.bestReason {
                                Text(reason.text)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }

        do {
            switch scope {
            case .all:
                people = try services.persons.allPeople(includingPlaceholders: false)

            case .recentlyViewed:
                var seen: [Item] = []
                for id in services.recentlyViewedPeople {
                    if let person = try services.persons.person(id: id) { seen.append(person) }
                }
                people = seen

            case .favorites:
                people = try services.persons.allPeople(includingPlaceholders: true).filter(\.isFavorite)

            case .celebrations, .duplicates:
                // These have their own views; the list is not the right shape for either.
                people = []

            case .fromContacts:
                let linkedIDs = Set(
                    try services.contactImports.allLinks().compactMap { $0.person?.id }
                )
                people = try services.persons
                    .allPeople(includingPlaceholders: false)
                    .filter { linkedIDs.contains($0.id) }

            case .needsFollowUp:
                // Off by default, and it stays off: the suggestion machinery answers when asked and
                // never starts telling the user who they have neglected.
                guard services.showsFollowUpSuggestions else {
                    people = []
                    break
                }
                let suggestions = try services.people.followUpSuggestions(
                    thresholdDays: services.followUpThresholdDays
                )
                var found: [Item] = []
                for suggestion in suggestions {
                    if let person = try services.persons.person(id: suggestion.personID) { found.append(person) }
                }
                people = found

            case .group(let id):
                guard let group = try services.personGroups.group(id: id) else {
                    people = []
                    break
                }
                people = try services.personGroups.members(of: group)
            }
            loadFailure = nil
        } catch {
            loadFailure = error
            people = []
        }
    }

    private func runSearch(_ query: String) {
        guard let services, isSearching else {
            searchResults = []
            return
        }
        searchResults = (try? services.personSearch.search(query)) ?? []
    }

    private func toggleFavorite(_ person: Item) {
        guard let services else { return }
        services.perform { try services.items.update(person) { $0.isFavorite.toggle() } }
        reload()
    }

    private func trash(_ person: Item) {
        guard let services else { return }
        services.perform { try services.items.moveToTrash(person) }
        services.noteRemoval(of: person.id)
        reload()
    }
}

/// One compact row.
struct PersonRow: View {
    @Environment(\.services) private var services

    let person: Item
    let dateProvider: any DateProvider

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 28)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(person.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)

                    if person.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.dueToday)
                    }

                    if let state = linkState {
                        ContactSourceBadge(state: state)
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Size.rowHeightExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(person.displayTitle), \($0)" } ?? person.displayTitle)
    }

    /// Whether this person's details come from the address book, and whether that still works.
    private var linkState: ContactSyncState? {
        guard let services else { return nil }
        return (try? services.contactImports.link(for: person))?.state
    }

    /// Role and organisation if known, otherwise where the relationship stands.
    private var subtitle: String? {
        let role = [person.personProfile?.roleTitle, person.personProfile?.organizationName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !role.isEmpty { return role.joined(separator: " · ") }

        guard let services else { return nil }
        return services.people.context(for: person).summary(using: dateProvider)
    }
}

/// The bar that appears when several people are selected.
struct PeopleBatchBar: View {
    let count: Int
    let onEmail: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text("\(count) selected")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer()

            Button("Email…", action: onEmail)
                .controlSize(.small)

            Button("Clear", action: onClear)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) people selected")
    }
}

/// A batch action over a selection that is not a saved group.
///
/// The same preview, the same blind-copy default, and the same list of who is being skipped — a
/// selection made by shift-clicking deserves no less care than one that has a name.
struct AdHocGroupActionSheet: View {
    @Environment(\.services) private var services

    let personIDs: [UUID]
    let onFinish: () -> Void

    @State private var preview: GroupActionPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label("Email these people", systemImage: "envelope")
                .font(Theme.Text.title)

            if let preview {
                GroupRecipientList(preview: preview)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onFinish)
                    .keyboardShortcut(.cancelAction)
                Button("Open a draft") {
                    if let url = preview?.url { NSWorkspace.shared.open(url) }
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview?.isRunnable != true)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 460)
        .accessibilityIdentifier(AccessibilityID.People.groupActionPreview)
        .task { build() }
    }

    private func build() {
        guard let services else { return }
        // An ad-hoc selection is described as a group without becoming one, so the preview,
        // exclusions, and blind-copy rule are the same code rather than a second implementation.
        let group = PersonGroup(
            id: UUID(), name: "Selected people", symbolName: "person.2",
            definition: .fixed, memberIDs: personIDs
        )
        preview = try? services.personGroups.preview(.email, for: group)
    }
}

import AppKit
