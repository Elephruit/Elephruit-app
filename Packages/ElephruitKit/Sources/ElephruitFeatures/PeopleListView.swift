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

    /// The tooltip on the sidebar row, shown once the pointer has rested there.
    ///
    /// Each of these is a *rule*, not a restatement of the title: what "Needs follow-up" counts as
    /// overdue, and how far ahead "Celebrations" looks, are the two things somebody cannot work out
    /// from the row and the two they ask about first.
    public var hint: String {
        switch self {
        case .all: "Everybody you have a record for."
        case .recentlyViewed: "People you opened this session. Cleared when you quit."
        case .favorites: "The people you starred."
        case .celebrations: "Birthdays and anniversaries in the next month."
        case .needsFollowUp: "People you have not spoken to in a while. Off until you turn suggestions on."
        case .group: "Everybody in this group."
        case .duplicates: "Records that may be the same person, waiting to be reconciled."
        case .fromContacts: "People whose standard details come from your address book."
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
///
/// ### Searching narrows the list; it does not replace it
/// Results used to be their own list of plain buttons, which meant that typing into the search field
/// silently took away selection, the highlight, the context menu, the batch bar, and the delete key —
/// every way of *doing* something to a person, at exactly the moment they had just been found. The
/// search now changes which people the list holds and why each one is there, and nothing else.
struct PeopleListView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel
    let scope: PeopleScope

    @State private var people: [Item] = []
    @State private var selection: Set<UUID> = []
    @State private var searchText = ""
    @State private var searchMatches: [PersonMatch] = []
    @State private var isShowingBatchEmail = false
    @State private var loadFailure: AppError?

    var body: some View {
        VStack(spacing: 0) {
            if let loadFailure {
                FailureStateView(error: loadFailure) { _ in refresh() }
            } else if rows.isEmpty {
                EmptyStateView(
                    symbolName: isSearching ? "magnifyingglass" : scope.symbolName,
                    headline: isSearching ? "Nobody matches" : scope.title,
                    message: isSearching
                        ? "Try “\(PersonQueryParser.examples.randomElement() ?? "people in Austin")”."
                        : scope.emptyMessage
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

    /// What the list is showing: the scope's people, or — while searching — the matches in rank
    /// order, each carrying the reason it earned its place.
    private var rows: [PersonMatch] {
        isSearching ? searchMatches : people.map { PersonMatch(person: $0, reason: nil) }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                PersonRow(
                    person: row.person,
                    dateProvider: services?.dateProvider ?? SystemDateProvider(),
                    isSelected: selection.contains(row.id),
                    matchReason: row.reason
                )
                    .tag(row.id)
                    .contextMenu {
                        Button("Open") { navigation.selectItem(row.id) }
                        Button(row.person.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                            toggleFavorite(row.person)
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) { trash(contextTargets(for: row)) }
                    }
            }
        }
        .listStyle(.inset)
        // The list has always had a Move to Trash in its context menu and no way to reach it from
        // the keyboard, which reads as "people cannot be deleted" to anybody who tries ⌫ first.
        .onDeleteCommand { trash(selectedPeople) }
        .onChange(of: selection) { _, newValue in
            // The list's own selection drives the detail pane, so clicking a row opens somebody
            // without a second gesture.
            navigation.selectedItemIDs = newValue
        }
    }

    /// A right-click acts on the whole selection when the clicked row is part of it, and on that row
    /// alone otherwise — the rule every macOS list follows, and the one that stops a context menu
    /// from quietly trashing four people when the user meant the one under the pointer.
    private func contextTargets(for row: PersonMatch) -> [Item] {
        selection.contains(row.id) ? selectedPeople : [row.person]
    }

    private var selectedPeople: [Item] {
        rows.filter { selection.contains($0.id) }.map(\.person)
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

    /// Resolves the ranked results to the person records the rows are built from.
    ///
    /// The search index answers with ids and names; a row needs the item itself for its details, its
    /// star, and its address-book badge. A result whose record has since gone is dropped rather than
    /// drawn as a name with nothing behind it.
    private func runSearch(_ query: String) {
        guard let services, isSearching else {
            searchMatches = []
            return
        }

        let ranked = (try? services.personSearch.search(query)) ?? []
        searchMatches = ranked.compactMap { result in
            guard let person = try? services.persons.person(id: result.id) else { return nil }
            return PersonMatch(person: person, reason: result.bestReason?.text)
        }
    }

    /// Reloads the scope and re-runs any live search, so a change is reflected in whichever of the
    /// two the user is looking at.
    private func refresh() {
        reload()
        runSearch(searchText)
    }

    private func toggleFavorite(_ person: Item) {
        guard let services else { return }
        services.perform { try services.items.update(person) { $0.isFavorite.toggle() } }
        refresh()
    }

    private func trash(_ people: [Item]) {
        guard let services, !people.isEmpty else { return }

        for person in people {
            services.perform { try services.items.moveToTrash(person) }
            services.noteRemoval(of: person.id)
        }

        // The rows are gone, so a selection still naming them would leave the detail pane showing
        // somebody who is no longer in the list.
        selection.subtract(people.map(\.id))
        navigation.selectedItemIDs = selection
        refresh()
    }
}

/// A person as the list draws them, and — when the list is a search result — why they are in it.
struct PersonMatch: Identifiable {
    let person: Item
    let reason: String?

    var id: UUID { person.id }
}

/// One compact row.
///
/// ### Three lines, and only the ones that have something to say
/// Who they are, then how to reach them. The middle line used to be role-and-organisation with a
/// relationship summary behind it, which produced rows reading "Caroline Howe / Caroline Howe" for
/// every record whose company field holds the person's own name — a thing address books imported
/// from elsewhere do constantly. ``ContactCard/identityLine(name:role:organization:location:)``
/// drops anything that merely repeats the name, so that line is now either informative or absent.
///
/// The contact line is the answer to what the list is usually open for: an address and a number,
/// each carrying the label the user gave it, so which one is work and which is home is visible
/// without opening anybody.
struct PersonRow: View {
    @Environment(\.services) private var services

    let person: Item
    let dateProvider: any DateProvider

    /// Suppresses the hover fill on a row that already carries the selection fill.
    var isSelected: Bool = false

    /// Why this person matched the search, when the list is answering one.
    var matchReason: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            PersonAvatar(name: person.displayTitle, colorName: person.colorName, size: 28)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(person.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .rowForeground(.primary)
                        .lineLimit(1)

                    if person.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .rowTint(Theme.Colors.dueToday)
                    }

                    if let state = linkState {
                        ContactSourceBadge(state: state)
                    }
                }

                if let identityLine {
                    Text(identityLine)
                        .font(Theme.Text.metadata)
                        .rowForeground(.secondary)
                        .lineLimit(1)
                }

                if !rowDetails.isEmpty {
                    // Wrapped rather than truncated: two details on a narrow list column are worth a
                    // second line, and a middle-truncated email address is worth nothing.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Spacing.medium) { detailLabels }
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) { detailLabels }
                    }
                } else if let relationshipLine {
                    Text(relationshipLine)
                        .font(Theme.Text.metadata)
                        .rowForeground(.tertiary)
                        .lineLimit(1)
                }

                // Below the details rather than instead of them: "likes natural wine" explains the
                // row's presence, and the row still has to answer the question the list is for.
                if let matchReason {
                    Label(matchReason, systemImage: "sparkle.magnifyingglass")
                        .font(Theme.Text.metadata)
                        .rowForeground(.tertiary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeightExpanded)
        .hoverHighlight(isEnabled: !isSelected, extending: Theme.Spacing.small)
        // Everything the row shows, at full length — a work address and a mobile number are exactly
        // the things a narrow list column truncates, and exactly the things somebody hovers for.
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var detailLabels: some View {
        ForEach(rowDetails) { detail in
            ContactDetailLabel(detail)
        }
    }

    /// The whole row, untruncated, one line each.
    ///
    /// The row truncates the identity line and fits the contact details to the column width; the
    /// tooltip is where a long address or a role that ran out of room can be read in full.
    private var tooltip: String {
        var lines = [person.displayTitle]
        if let identityLine { lines.append(identityLine) }
        if rowDetails.isEmpty {
            if let relationshipLine { lines.append(relationshipLine) }
        } else {
            lines.append(contentsOf: rowDetails.map { "\($0.displayLabel): \($0.value)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Whether this person's details come from the address book, and whether that still works.
    private var linkState: ContactSyncState? {
        guard let services else { return nil }
        return (try? services.contactImports.link(for: person))?.state
    }

    /// Role, organisation, and place — never a second copy of the name.
    private var identityLine: String? {
        ContactCard.identityLine(
            name: person.displayTitle,
            role: person.personProfile?.roleTitle,
            organization: person.personProfile?.organizationName,
            location: person.personProfile?.locationText
        )
    }

    /// The email and the number, or whichever two details exist.
    private var rowDetails: [ContactDetail] {
        guard let profile = person.personProfile else { return [] }
        return ContactCard.rowDetails(from: profile.contactDetails())
    }

    /// Where the relationship stands, shown only when there is nothing to reach them by — a row with
    /// an address and "Nothing recorded yet" would spend its last line on the less useful of the two.
    private var relationshipLine: String? {
        guard let services else { return nil }
        return services.people.context(for: person).summary(using: dateProvider)
    }

    private var accessibilityDescription: String {
        var parts = [person.displayTitle]
        if let matchReason { parts.append(matchReason) }
        if let identityLine { parts.append(identityLine) }
        if rowDetails.isEmpty {
            if let relationshipLine { parts.append(relationshipLine) }
        } else {
            parts.append(
                contentsOf: rowDetails.map {
                    "\($0.displayLabel) \($0.kind.displayName.lowercased()), \($0.value)"
                }
            )
        }
        return parts.joined(separator: ", ")
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
