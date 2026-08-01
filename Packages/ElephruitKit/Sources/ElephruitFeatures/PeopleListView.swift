import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import AppKit
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
        case .favorites: "Favorites"
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

    /// Owns the sorting and the sectioning, so neither happens in `body`. See ``PeopleListModel``.
    @State private var model = PeopleListModel()

    @State private var selection: Set<UUID> = []
    @State private var searchText = ""
    @State private var isShowingBatchEmail = false

    /// Letters typed into the focused list, until the user pauses.
    @State private var typeAhead = TypeToSelectBuffer()
    @State private var typedPreview: String?

    /// The heading under the pointer while the jump strip is being dragged.
    @State private var scrubbedTitle: String?

    /// What to scroll to next. Cleared once it has been done, so a later render does not scroll
    /// somebody back to where they were three actions ago.
    @State private var pendingScroll: ScrollTarget?

    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    /// Where the list was before a search took it over, so cancelling puts it back.
    @State private var selectionBeforeSearch: Set<UUID> = []

    /// The query in flight, so the next keystroke can abandon it.
    @State private var searchTask: Task<Void, Never>?

    private enum ScrollTarget: Equatable {
        case section(String)
        case person(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = model.loadFailure {
                FailureStateView(error: failure) { _ in refresh() }
            } else if model.isEmpty {
                EmptyStateView(
                    symbolName: model.isSearching ? "magnifyingglass" : scope.symbolName,
                    headline: model.isSearching ? "Nobody matches" : scope.title,
                    message: model.isSearching
                        ? "Try “\(PersonQueryParser.examples.randomElement() ?? "people in Austin")”."
                        : scope.emptyMessage,
                    actionTitle: model.isSearching ? "Clear Search" : nil,
                    action: model.isSearching ? { clearSearch() } : nil
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
        // "Search People", not a worked example. The prompt used to read "people in Austin · likes
        // natural wine", which is a sentence about somebody who does not exist, sitting in the place
        // where the user's own text goes. It reads as content rather than as a prompt, and there is
        // no Austin and no wine in an empty library. What the field *accepts* is worth teaching, but
        // the empty-search view below has room to teach it and a prompt does not.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search People")
        .searchFocused($isSearchFocused)
        .onKeyPress(.downArrow) { moveSearchSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSearchSelection(by: -1) }
        .onSubmit(of: .search) { openSearchSelection() }
        .toolbar { sortMenu }
        .onChange(of: searchText) { _, query in beginSearch(query) }
        // ⌘F belongs to the list it is looking at. Without this it opened the app-wide search field
        // while the contact list — the thing on screen, the thing with two thousand rows in it —
        // stayed exactly as it was.
        .onChange(of: navigation.isSearchActive) { _, isActive in
            guard isActive, navigation.selection.isPeopleDestination else { return }
            focusSearchField(selectingContents: !searchText.isEmpty)
        }
        .onChange(of: navigation.searchFocusRequest) { _, _ in
            guard navigation.isSearchActive, navigation.selection.isPeopleDestination else { return }
            focusSearchField(selectingContents: !searchText.isEmpty)
        }
        .navigationTitle(navigation.windowTitle)
        .accessibilityIdentifier(AccessibilityID.People.list)
        .task(id: scope) { reload() }
        .sheet(isPresented: $isShowingBatchEmail) {
            AdHocGroupActionSheet(personIDs: Array(selection)) { isShowingBatchEmail = false }
        }
    }

    // MARK: - The list

    private var list: some View {
        ScrollViewReader { proxy in
            // ### Why an HStack and not a ZStack
            // It was a `ZStack(alignment: .topTrailing)`, which is to say the rail was drawn *on
            // top of* the list. Every row was laid out as though the rail were not there, so names
            // ran under the letters and — much worse — so did the separators and the selection
            // fill: choosing somebody painted the accent colour straight through the alphabet, and
            // the rail read as the table's last column rather than as a control beside it.
            //
            // Side by side, the list simply ends where the rail begins. Nothing of the list's can
            // reach the rail because there is no overlap to reach across, and the rail keeps its
            // width whether or not it can be used — see `isEnabled` below — so nothing shifts
            // sideways when a search starts.
            HStack(spacing: 0) {
                sectionedList

                // Beside the scrollbar rather than instead of it: clicking the scrollbar track and
                // dragging its knob are still how somebody moves *through* the list, and this is how
                // they move *to* a letter. Two different questions, two controls.
                SectionIndexBar(
                    titles: model.sectionTitles,
                    activeTitle: activeSectionTitle,
                    // Search results are ranked by how well they match, not alphabetised, so there
                    // are no sections to jump to. Dimmed and inert rather than gone, because a rail
                    // that vanishes as somebody types takes its width with it and moves every row
                    // they were reading.
                    isEnabled: !model.isSearching,
                    label: model.sort.jumpLabel,
                    unavailableReason: "Search results are ranked by relevance, so there is nothing to jump to."
                ) { title in
                    jump(to: title, using: proxy)
                }
            }
            .overlay {
                if let scrubbedTitle {
                    SectionScrubIndicator(title: scrubbedTitle)
                } else if let typedPreview {
                    SectionScrubIndicator(title: typedPreview)
                }
            }
            .onChange(of: pendingScroll) { _, target in
                guard let target else { return }
                switch target {
                case .section(let title): proxy.scrollTo(title, anchor: .top)
                case .person(let id): proxy.scrollTo(id, anchor: .center)
                }
                pendingScroll = nil
            }
        }
    }

    private var sectionedList: some View {
        List(selection: $selection) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        if let person = model.person(id: entry.id) {
                            row(for: person, reason: model.matchReasons[entry.id])
                                .id(entry.id)
                        }
                    }
                } header: {
                    // The heading carries the section's identity for `scrollTo`, so a jump lands on
                    // the header rather than on the first name under it — which is what makes the
                    // letter you asked for the thing at the top of the pane.
                    SectionHeader(section.title, count: section.entries.count)
                        .id(section.title)
                }
            }
        }
        .listStyle(.inset)
        .focused($isListFocused)
        .onDeleteCommand { trash(selectedPeople) }
        .focusedSceneValue(
            \.rowActions,
            RowActions(isEnabled: !selection.isEmpty) { trash(selectedPeople) }
        )
        .onChange(of: selection) { _, newValue in
            // The list's own selection drives the detail pane, so clicking a row opens somebody
            // without a second gesture.
            navigation.selectedItemIDs = newValue
        }
        // Home, End, Page Up and Page Down. `List` gives arrow keys and nothing else, so a list of
        // two thousand people could be walked only one row at a time.
        .onKeyPress(.home) { move(to: .first); return .handled }
        .onKeyPress(.end) { move(to: .last); return .handled }
        .onKeyPress(.pageUp) { move(to: .page(-1)); return .handled }
        .onKeyPress(.pageDown) { move(to: .page(1)); return .handled }
        .onKeyPress(.escape) {
            guard typeAhead.text.isEmpty else { clearTypeAhead(); return .handled }
            return .ignored
        }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            // Modifier combinations belong to the menus. Only a bare letter is somebody typing a
            // name at a list.
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            return type(press.characters)
        }
    }

    private func row(for person: Item, reason: String?) -> some View {
        PersonRow(
            person: person,
            isSelected: selection.contains(person.id),
            matchReason: reason
        )
        .tag(person.id)
        .contextMenu {
            Button("Open") { navigation.selectItem(person.id) }
            Button(person.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite(person)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(contextTargets(for: person)) }
        }
        .rowSwipeActions(
            id: person.id,
            leading: RowSwipeActions.personLeading(person, services: services, onChange: reload),
            trailing: RowSwipeActions.personTrailing(person, services: services, onChange: reload)
        )
    }

    // MARK: - Sorting

    /// One menu rather than four controls on the toolbar.
    ///
    /// Progressive disclosure in the sense the brief means it: the order somebody wants is a decision
    /// they make rarely and then live with, so it costs a click and no permanent width. Recently
    /// Viewed, Favourites and the groups are already in the sidebar, which is where a *filter*
    /// belongs; this is only the order.
    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: sortBinding) {
                    ForEach(PersonListSort.allCases) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by \(model.sort.displayName.lowercased())")
            .accessibilityLabel("Sort")
            .accessibilityValue(model.sort.displayName)
            .accessibilityIdentifier(AccessibilityID.People.sortMenu)
        }
    }

    private var sortBinding: Binding<PersonListSort> {
        Binding(
            get: { model.sort },
            set: { newSort in
                model.sort = newSort
                // Ordering by when you last spoke to somebody needs a date the list does not
                // otherwise pay for; it is fetched when it is asked for and not before.
                if newSort == .recentInteraction { reload() }
                // The selection is the one thing that should survive a reorder — a list that
                // reorders and then loses your place has done the opposite of helping.
                if let id = selection.first { pendingScroll = .person(id) }
            }
        )
    }

    // MARK: - Jumping and typing

    /// Which section the rail should mark as the one you are in.
    ///
    /// The selected person's section, or the letter last scrubbed to. Derived rather than tracked
    /// from the scroll position: the question the mark answers is "where am I in this list", and in
    /// a list you navigate by selecting somebody, that is the selection — not whatever happens to be
    /// under the top edge after an inertial flick.
    private var activeSectionTitle: String? {
        if let scrubbedTitle { return scrubbedTitle }
        guard let id = selection.first else { return nil }
        return model.sectionTitle(containing: id)
    }

    private func jump(to title: String, using proxy: ScrollViewProxy) {
        guard let landing = model.section(nearest: title) else { return }
        scrubbedTitle = landing
        proxy.scrollTo(landing, anchor: .top)

        // The label follows the pointer and then goes, rather than being dismissed by the gesture
        // ending — which would make a single click flash it for one frame.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if scrubbedTitle == landing { scrubbedTitle = nil }
        }
    }

    private func type(_ characters: String) -> KeyPress.Result {
        guard let character = characters.first else { return .ignored }

        let typed = typeAhead.append(character, at: services?.dateProvider.now ?? Date())
        typedPreview = typed

        guard let id = model.entry(matching: typed) else { return .handled }
        selection = [id]
        navigation.selectedItemIDs = selection
        pendingScroll = .person(id)

        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard typeAhead.hasExpired(at: services?.dateProvider.now ?? Date()) else { return }
            clearTypeAhead()
        }

        return .handled
    }

    private func clearTypeAhead() {
        typeAhead.clear()
        typedPreview = nil
    }

    private enum Move: Equatable {
        case first
        case last
        case page(Int)
    }

    /// Moves the selection without the sections getting in the way.
    ///
    /// The keyboard walks a flat list; the headings are a visual grouping and nothing more. A page is
    /// twelve rows, which is roughly a paneful at the default row height and the same distance
    /// whatever the window is doing — a page that changed size as the window did would make Page Down
    /// a different key on every screen.
    private func move(to move: Move) {
        let ids = model.flattenedIDs
        guard !ids.isEmpty else { return }

        let current = selection.first.flatMap { ids.firstIndex(of: $0) } ?? 0
        let target: Int = switch move {
        case .first: 0
        case .last: ids.count - 1
        case .page(let direction): min(ids.count - 1, max(0, current + direction * 12))
        }

        selection = [ids[target]]
        navigation.selectedItemIDs = selection
        pendingScroll = .person(ids[target])
    }

    /// A right-click acts on the whole selection when the clicked row is part of it, and on that row
    /// alone otherwise — the rule every macOS list follows, and the one that stops a context menu
    /// from quietly trashing four people when the user meant the one under the pointer.
    private func contextTargets(for person: Item) -> [Item] {
        selection.contains(person.id) ? selectedPeople : [person]
    }

    private var selectedPeople: [Item] {
        selection.compactMap { model.person(id: $0) }
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }

        do {
            let found = try people(in: scope, services: services)
            model.setPeople(
                found,
                lastInteraction: model.sort == .recentInteraction
                    ? lastInteractionDates(for: found, services: services)
                    : [:]
            )
        } catch {
            model.setPeople([], failure: error)
        }
    }

    private func people(in scope: PeopleScope, services: AppServices) throws(AppError) -> [Item] {
        switch scope {
        case .all:
            return try services.persons.allPeople(includingPlaceholders: false)

        case .recentlyViewed:
            var seen: [Item] = []
            for id in services.recentlyViewedPeople {
                if let person = try services.persons.person(id: id) { seen.append(person) }
            }
            return seen

        case .favorites:
            return try services.persons.allPeople(includingPlaceholders: true).filter(\.isFavorite)

        case .celebrations, .duplicates:
            // These have their own views; the list is not the right shape for either.
            return []

        case .fromContacts:
            let linkedIDs = Set(try services.contactImports.allLinks().compactMap { $0.person?.id })
            return try services.persons
                .allPeople(includingPlaceholders: false)
                .filter { linkedIDs.contains($0.id) }

        case .needsFollowUp:
            // Off by default, and it stays off: the suggestion machinery answers when asked and
            // never starts telling the user who they have neglected.
            guard services.showsFollowUpSuggestions else { return [] }
            let suggestions = try services.people.followUpSuggestions(
                thresholdDays: services.followUpThresholdDays
            )
            var found: [Item] = []
            for suggestion in suggestions {
                if let person = try services.persons.person(id: suggestion.personID) { found.append(person) }
            }
            return found

        case .group(let id):
            guard let group = try services.personGroups.group(id: id) else { return [] }
            return try services.personGroups.members(of: group)
        }
    }

    private func lastInteractionDates(for people: [Item], services: AppServices) -> [UUID: Date] {
        var dates: [UUID: Date] = [:]
        for person in people {
            dates[person.id] = services.people.context(for: person).lastContact?.date
        }
        return dates
    }

    // MARK: - Searching

    private func focusSearchField(selectingContents: Bool) {
        isSearchFocused = true
        guard selectingContents else { return }

        // `.searchFocused` makes the toolbar field first responder on the next run-loop turn. Send
        // the standard AppKit action then, so this keeps working with SwiftUI's private search field.
        Task { @MainActor in
            await Task.yield()
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            navigation.didSelectSearchQuery()
        }
    }

    /// Runs the search off the main thread and abandons a query the user has typed past.
    ///
    /// It used to run synchronously inside `onChange`, which meant every keystroke walked the index
    /// and resolved every result to a record before the field would accept the next letter. On a
    /// small library that is invisible; on a large one it is the field falling behind the typing,
    /// which is the one thing a search field may never do.
    private func beginSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }

        if !model.isSearching { selectionBeforeSearch = selection }

        searchTask?.cancel()
        searchTask = Task {
            // Long enough to swallow a burst of typing, short enough not to feel like a wait.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let services else { return }

            let ranked = (try? services.personSearch.search(trimmed)) ?? []
            guard !Task.isCancelled else { return }

            model.setSearchResults(ranked.map { ($0.id, $0.bestReason?.text) })
        }
    }

    /// Puts the list back where the search found it.
    ///
    /// Both halves matter. Clearing a search that leaves you at the top of the list with nothing
    /// selected has undone the navigation you did before searching, which is usually the reason you
    /// searched in the first place.
    private func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        model.setSearchResults(nil)

        if !selectionBeforeSearch.isEmpty {
            selection = selectionBeforeSearch
            navigation.selectedItemIDs = selection
            if let id = selectionBeforeSearch.first { pendingScroll = .person(id) }
        }
        selectionBeforeSearch = []
    }

    /// Lets the search field and its results behave as one keyboard surface.
    ///
    /// The search field remains first responder while arrows move the highlighted result. Return
    /// then commits that highlight and hands focus to the list, so finding somebody never requires
    /// a mouse or trackpad.
    private func moveSearchSelection(by direction: Int) -> KeyPress.Result {
        guard isSearchFocused, model.isSearching else { return .ignored }
        let ids = model.flattenedIDs
        guard !ids.isEmpty else { return .handled }

        let target: Int
        if let selected = selection.first, let current = ids.firstIndex(of: selected) {
            target = min(ids.count - 1, max(0, current + direction))
        } else {
            target = direction > 0 ? 0 : ids.count - 1
        }

        selectSearchResult(ids[target])
        return .handled
    }

    private func openSearchSelection() {
        guard model.isSearching else { return }
        let ids = model.flattenedIDs
        guard let id = selection.first.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else { return }
        selectSearchResult(id)
        isSearchFocused = false
        isListFocused = true
    }

    private func selectSearchResult(_ id: UUID) {
        selection = [id]
        navigation.selectedItemIDs = selection
        pendingScroll = .person(id)
    }

    /// Reloads the scope and re-runs any live search, so a change is reflected in whichever of the
    /// two the user is looking at.
    private func refresh() {
        reload()
        if !searchText.isEmpty { beginSearch(searchText) }
    }

    private func toggleFavorite(_ person: Item) {
        guard let services else { return }
        services.perform { try services.items.update(person) { $0.isFavorite.toggle() } }
        refresh()
    }

    private func trash(_ people: [Item]) {
        guard let services, !people.isEmpty else { return }

        // Where the selection should land once these are gone: the row after the last one removed,
        // or the row before it at the end of the list. Losing the selection entirely would blank the
        // detail pane and lose the user's place, which is a large punishment for deleting one row.
        let ids = model.flattenedIDs
        let removed = Set(people.map(\.id))
        let successor = ids.drop { !removed.contains($0) }.first { !removed.contains($0) }
            ?? ids.last { !removed.contains($0) }

        for person in people {
            services.perform { try services.items.moveToTrash(person) }
            services.noteRemoval(of: person.id)
        }

        selection = successor.map { [$0] } ?? []
        navigation.selectedItemIDs = selection
        refresh()
    }
}

/// One compact row: a person's name and, when recorded, their company.
///
/// Contact details, role, location, and relationship history belong on the person's page. Keeping
/// them out of the list also keeps row construction proportional to what the list actually shows.
struct PersonRow: View {
    let person: Item

    /// Suppresses the hover fill on a row that already carries the selection fill.
    var isSelected: Bool = false

    /// Why this person matched the search, when the list is answering one.
    var matchReason: String?

    var body: some View {
        let profile = person.personProfile
        let company = profile?.organizationName?.trimmingCharacters(in: .whitespacesAndNewlines)

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

                }

                if let company, !company.isEmpty {
                    Text(company)
                        .font(Theme.Text.metadata)
                        .rowForeground(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeightExpanded)
        .hoverHighlight(isEnabled: !isSelected, extending: Theme.Spacing.small)
        .help([person.displayTitle, company].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [person.displayTitle, company, matchReason]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
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
