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

    @State private var groups: [PersonGroup] = []
    @State private var duplicateCount = 0
    @State private var linkedCount = 0
    @State private var isExpanded = true
    @State private var isShowingContactImport = false

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(Self.scopes, id: \.self) { scope in
                row(for: scope, count: count(for: scope))
            }

            ForEach(contactScopes, id: \.self) { scope in
                row(for: scope, count: linkedCount)
            }

            if !groups.isEmpty {
                ForEach(groups) { group in
                    row(
                        for: .group(id: group.id),
                        title: group.name,
                        symbolName: group.symbolName,
                        count: group.memberCount
                    )
                }
            }

            // Only when there is something to reconcile. A permanently visible "0 duplicates" row is
            // a chore the interface invented for itself.
            if duplicateCount > 0 {
                row(for: .duplicates, count: duplicateCount)
            }
        } header: {
            HStack {
                Text("People")
                Spacer()

                Menu {
                    Button("Add a Person…") { navigation.isPeopleCommandBarVisible = true }
                    Divider()
                    Button("Import from Contacts…") { isShowingContactImport = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a person, or bring in your contacts")
                .accessibilityLabel("Add people")
            }
        }
        .task { reload() }
        .sheet(isPresented: $isShowingContactImport) {
            ContactOnboardingView(navigation: navigation)
        }
    }

    /// The fixed scopes, in the order they are shown.
    static let scopes: [PeopleScope] = [
        .all, .recentlyViewed, .favorites, .celebrations, .needsFollowUp,
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

                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .monospacedDigit()
                }
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
                Button("Delete group", role: .destructive) { deleteGroup(id) }
            }
        }
    }

    private func count(for scope: PeopleScope) -> Int? {
        guard let services else { return nil }

        switch scope {
        case .all:
            return (try? services.persons.allPeople(includingPlaceholders: false).count)

        case .favorites:
            return (try? services.persons.allPeople(includingPlaceholders: true).count(where: \.isFavorite))

        case .celebrations:
            let all = (try? services.persons.allCelebrations()) ?? []
            return CelebrationCalendar.upcoming(
                from: all, within: 30, asOf: services.dateProvider.now, calendar: services.dateProvider.calendar
            ).count

        case .needsFollowUp:
            // Nothing is counted unless the user asked for suggestions. A badge that appears
            // unbidden is the app starting a conversation about who has been neglected.
            guard services.showsFollowUpSuggestions else { return nil }
            return (try? services.people.followUpSuggestions(thresholdDays: services.followUpThresholdDays).count)

        case .fromContacts:
            return (try? services.contactImports.linkedCount())

        case .recentlyViewed, .group, .duplicates:
            return nil
        }
    }

    private func reload() {
        guard let services else { return }
        groups = (try? services.personGroups.allGroups()) ?? []
        duplicateCount = ((try? services.personIdentity.duplicates()) ?? []).count
        linkedCount = (try? services.contactImports.linkedCount()) ?? 0
    }

    private func deleteGroup(_ id: UUID) {
        guard let services else { return }
        services.perform { try services.personGroups.deleteGroup(id: id) }
        reload()
    }
}

// MARK: - Context sidebar

/// The trailing pane, for a person.
///
/// Everything here is *about* the person on screen rather than a peer of them, which is why it lives
/// in the inspector rather than becoming a fourth column.
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

                    if !context.promises.isEmpty {
                        InspectorSection("You promised") {
                            ForEach(context.promises) { entry in
                                linkRow(entry.title, systemImage: "hand.raised") {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.openItems.isEmpty {
                        InspectorSection("Open") {
                            ForEach(context.openItems.prefix(6)) { entry in
                                linkRow(entry.title, systemImage: entry.kind.symbolName) {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.relatedPeople.isEmpty {
                        InspectorSection("Related people") {
                            ForEach(context.relatedPeople) { related in
                                linkRow("\(related.name) · \(related.label)", systemImage: related.kind.symbolName) {
                                    navigation.selectItem(related.id)
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

                    if !context.places.isEmpty {
                        InspectorSection("Places") {
                            ForEach(context.places, id: \.self) { place in
                                Button {
                                    openInMaps(place)
                                } label: {
                                    Label(place, systemImage: "map")
                                        .font(Theme.Text.rowSubtitle)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.Colors.link)
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

                    if !context.destinations.isEmpty {
                        InspectorSection("Reach them") {
                            ForEach(context.destinations) { destination in
                                Text(destination.displayText)
                                    .font(Theme.Text.rowSubtitle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    EmptyStateView(
                        symbolName: "sidebar.trailing",
                        headline: "Nothing yet",
                        message: "Meetings, promises, and related people appear here as they accumulate."
                    )
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .accessibilityIdentifier(AccessibilityID.People.contextSidebar)
        .task(id: person.id) { reload() }
        // "Open" and "You promised" are lists of other items pointing here, so a new task about
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
