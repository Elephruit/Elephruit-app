import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The People band in the sidebar.
///
/// ### Why a band rather than one row
/// The existing "People" row was a flat `.kind(.person)` list. That answers "who do I know" and
/// nothing else, whereas the questions people actually arrive with are "who is having a birthday",
/// "who have I not spoken to", and "who is in my family" — each of which is a different query and
/// deserves a row rather than a filter somebody has to remember to apply.
///
/// Groups are listed underneath, fixed ones before smart ones, because a group whose membership the
/// user chose is a more stable thing to navigate by than one that changes underneath them.
struct PeopleSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @State private var groups: [PersonGroupSummary] = []
    @State private var duplicateCount = 0
    @State private var linkedCount = 0
    @State private var scopeCounts: [PeopleScope: Int] = [:]
    @State private var isExpanded = true
    @State private var isShowingContactImport = false

    private struct GroupDeletion {
        let id: UUID
        let name: String
    }

    @State private var pendingGroupDeletion: GroupDeletion?

    var body: some View {
        Section {
            ForEach(Self.scopes, id: \.self) { scope in
                row(for: scope, count: count(for: scope))
            }

            ForEach(contactScopes, id: \.self) { scope in
                row(for: scope, count: linkedCount)
            }

            // Only when there is something to reconcile. A permanently visible "0 duplicates" row is
            // a chore the interface invented for itself.
            if duplicateCount > 0 {
                row(for: .duplicates, count: duplicateCount)
            }
        }
        .task { reload() }
        .onChange(of: services?.changeToken) { _, _ in reload() }
        .sheet(isPresented: $isShowingContactImport) {
            ContactOnboardingView(navigation: navigation)
        }

        // Groups earn a header now that People has the sidebar to itself: a group is somebody's own
        // organisation and belongs under a heading that says so, rather than trailing the fixed
        // scopes as though it were another one.
        Section(isExpanded: $isExpanded) {
            ForEach(groups) { group in
                row(
                    for: .group(id: group.id),
                    title: group.name,
                    symbolName: group.symbolName,
                    count: nil
                )
            }

            Button("Import from Contacts…", systemImage: "person.crop.rectangle.stack") {
                isShowingContactImport = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .frame(minHeight: Theme.Size.rowHeight)
            .hoverHighlight(
                cornerRadius: SidebarMetrics.selectionRadius,
                extending: SidebarMetrics.selectionInset
            )
            .help("Bring people in from your address book. Elephruit reads it and never writes to it.")
            .accessibilityIdentifier("sidebar.people.import")
        } header: {
            HStack {
                Text("Groups")
                Spacer()

                Button {
                    navigation.isNewPersonVisible = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Add a person")
                .accessibilityLabel("Add a person")
                .accessibilityIdentifier("sidebar.people.add")
            }
        }
    }

    /// The fixed scopes, in the order they are shown.
    static let scopes: [PeopleScope] = [
        .recordsDemo, .all, .recentlyViewed, .favorites, .celebrations, .needsFollowUp,
    ]

    /// Shown only once something is actually linked, so an unused integration adds no row.
    var contactScopes: [PeopleScope] {
        linkedCount > 0 ? [.fromContacts] : []
    }

    @ViewBuilder
    private func row(
        for scope: PeopleScope,
        title: String? = nil,
        symbolName: String? = nil,
        count: Int? = nil
    ) -> some View {
        let selection = SidebarSelection.people(scope)

        Button {
            navigation.select(selection)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: symbolName ?? scope.symbolName)
                    .frame(width: Theme.Size.rowGlyph)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Text(title ?? scope.title)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.tight)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            isEnabled: navigation.selection != selection,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(selection)
        // A group carries its own name on the row, so the hint explains the *kind* of row it is;
        // the fixed scopes each explain the rule that decides who appears in them.
        .help(scope.hint)
        .accessibilityIdentifier(selection.accessibilityIdentifier)
        .accessibilityLabel(count.map { "\(title ?? scope.title), \($0)" } ?? (title ?? scope.title))
        .accessibilityHint(scope.hint)
        .contextMenu {
            if case .group(let id) = scope {
                Button("Delete Group…", role: .destructive) {
                    pendingGroupDeletion = GroupDeletion(id: id, name: title ?? scope.title)
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingGroupDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingGroupDeletion != nil },
                set: { if !$0 { pendingGroupDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) { confirmGroupDeletion() }
            Button("Cancel", role: .cancel) { pendingGroupDeletion = nil }
        } message: {
            Text("The group is only a grouping. The people in it are not affected.")
        }
    }

    private func count(for scope: PeopleScope) -> Int? {
        scopeCounts[scope]
    }

    private func reload() {
        guard let services else { return }
        groups = (try? services.personGroups.allGroupSummaries()) ?? []
        duplicateCount = ((try? services.personIdentity.duplicates()) ?? []).count
        linkedCount = (try? services.contactImports.linkedCount()) ?? 0

        var counts: [PeopleScope: Int] = [:]
        counts[.all] = try? services.persons.allPeople(includingPlaceholders: false).count
        counts[.favorites] = try? services.persons.allPeople(includingPlaceholders: true).count(where: \.isFavorite)
        if let celebrations = try? services.persons.allCelebrations() {
            counts[.celebrations] = CelebrationCalendar.upcoming(
                from: celebrations,
                within: 30,
                asOf: services.dateProvider.now,
                calendar: services.dateProvider.calendar
            ).count
        }
        if services.showsFollowUpSuggestions {
            counts[.needsFollowUp] = try? services.people.followUpSuggestions(thresholdDays: services.followUpThresholdDays).count
        }
        counts[.fromContacts] = linkedCount
        scopeCounts = counts
    }

    private func confirmGroupDeletion() {
        defer { pendingGroupDeletion = nil }
        guard let services, let pending = pendingGroupDeletion else { return }
        services.perform { try services.personGroups.deleteGroup(id: pending.id) }
        if navigation.selection == .people(.group(id: pending.id)) {
            navigation.select(.people(.all))
        }
        reload()
    }
}

// MARK: - Context sidebar

/// The trailing pane, for a person.
///
/// Everything here is *about* the person on screen rather than a peer of them, which is why it lives
/// in the inspector rather than becoming a fourth column.
///
/// ### What it stopped repeating, and why that is what made it worth keeping
/// It held eight sections and three of them were already on the profile a few hundred points to its
/// left. *Related people* is the Relationships section; *Reach them* is the Contact section, minus
/// the ability to do anything with a number; *Places* is one line of the same. A pane that opens
/// itself whenever you click a name and then shows you a narrower copy of what you are looking at is
/// not an inspector — it is a column the layout has to keep finding room for, in a module whose
/// complaint was that the profile was cramped.
///
/// What is left is only what the profile does not say: what is **coming**, what is **open**, and
/// what has not been confirmed in a while. Those are questions about the state of the record and of
/// the relationship rather than about its contents, and none of them is answerable by scrolling the
/// page. The pane is worth opening for them and is no longer opened on your behalf — see
/// `AppModule.shellLayout`, where People stopped saying `opensAfterSelection`.
struct PersonContextSidebar: View {
    @Environment(\.services) private var services

    let person: Item
    let navigation: NavigationModel

    @State private var context: PersonSidebarContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if let context, !context.isEmpty {
                    if !context.celebrations.isEmpty {
                        InspectorSection("Coming up") {
                            ForEach(context.celebrations) { entry in
                                Text(entry.summary)
                                    .font(Theme.Text.rowSubtitle)
                            }
                        }
                    }

                    if !context.upcoming.isEmpty {
                        InspectorSection("Scheduled") {
                            ForEach(context.upcoming.prefix(5)) { entry in
                                linkRow(entry.title, systemImage: entry.kind.symbolName) {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.openItems.isEmpty {
                        InspectorSection("Tasks") {
                            ForEach(context.openItems.prefix(6)) { entry in
                                linkRow(entry.title, systemImage: entry.kind.symbolName) {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.sharedProjects.isEmpty {
                        InspectorSection("Shared projects") {
                            ForEach(context.sharedProjects) { project in
                                linkRow(project.name, systemImage: "square.stack.3d.up") {
                                    navigation.selectItem(project.id)
                                }
                            }
                        }
                    }

                    if !context.staleFacts.isEmpty {
                        InspectorSection("Worth checking") {
                            ForEach(context.staleFacts, id: \.id) { fact in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(fact.attribute.displayName): \(fact.value)")
                                        .font(Theme.Text.rowSubtitle)
                                    Text("Last confirmed \(fact.lastConfirmedOn.formatted(date: .abbreviated, time: .omitted))")
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                            }
                        }
                    }

                } else {
                    EmptyStateView(
                        symbolName: "sidebar.trailing",
                        headline: "Nothing outstanding",
                        message: "What is scheduled, what is open, and what is worth checking "
                            + "appear here. Everything you know about this person is on the page."
                    )
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .accessibilityIdentifier(AccessibilityID.People.contextSidebar)
        .task(id: person.id) { reload() }
        // Tasks are other items pointing here, so a new task about
        // this person has to arrive without a navigation — see ``AppServices/changeToken``.
        .onChange(of: services?.changeToken) { _, _ in reload() }
    }

    private func reload() {
        context = try? services?.personWorkspace.sidebar(for: person)
    }

    @ViewBuilder
    private func linkRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Text.rowSubtitle)
                .lineLimit(1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func openInMaps(_ place: String) {
        guard let url = ContactActionURL.mapsURL(address: place) else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
