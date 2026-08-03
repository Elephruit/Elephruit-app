import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import AppKit
import SwiftUI

/// The middle column: whatever the sidebar selected.
///
/// Fetches through the repository rather than `@Query`, because the predicate depends on the
/// selection and on the injected clock, and because ``ItemQuery`` post-filtering has to run. The
/// cost is an explicit reload; the benefit is that "what does this view show?" is a value that can
/// be tested without a window.
public struct ItemListView: View {
    @Environment(\.services) private var services
    private let navigation: NavigationModel

    @State private var items: [Item] = []
    @State private var isLoading = false

    /// Built on first appearance, because the engine comes from the environment.
    @State private var session: SearchSessionModel?

    @State private var pendingSavedSearchName: String?

    /// The row a permanent deletion has been asked for.
    ///
    /// Only reachable inside the Trash, which is the one view in this app that genuinely represents
    /// a permanent-delete context. Even there the gesture stops at the button and the button asks,
    /// because nothing brings this one back.
    @State private var pendingPermanentDeletion: Item?

    /// The same preference the sidebar's Empty Trash honours. The toolbar button used to skip it,
    /// which made the safer-looking of the two buttons the dangerous one.
    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true
    @State private var isConfirmingEmptyTrash = false

    @FocusState private var isSearchFieldFocused: Bool


    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        content
            .background { permanentDeletionDialog }
            // ⌫, and the menu item that shows the shortcut for it. In the Trash the key does
            // nothing: a permanent deletion is not something a single keystroke may cause.
            .onDeleteCommand { trashSelection() }
            .focusedSceneValue(
                \.rowActions,
                RowActions(
                    isEnabled: !navigation.selectedItemIDs.isEmpty
                        && !navigation.selection.showsTrashedItems
                ) { trashSelection() }
            )
            .navigationTitle(navigation.isSearchActive ? "Search" : navigation.windowTitle)
            .navigationSubtitle(subtitle)
            .searchable(text: searchBinding, placement: .toolbar, prompt: searchPrompt)
            .searchScopes(scopeBinding) {
                Text("Everywhere").tag(SearchScope.everywhere)
                Text(navigation.selection.title).tag(SearchScope.thisList)
            }
            .searchFocused($isSearchFieldFocused)
            // Return in the field opens whatever the traversal is on, so a search begun and walked
            // from the keyboard can also be finished from it. `onSubmit(of: .search)` rather than
            // `onKeyPress`: the field lives in the toolbar, which is not in this view's responder
            // chain, and a key handler here never sees a keystroke typed into it.
            .onSubmit(of: .search) {
                guard let result = session?.highlightedResult else { return }
                open(result)
            }
            .toolbar { toolbarContent }
            .task { makeSessionIfNeeded() }
            .task(id: reloadToken) { await reload() }
            .onChange(of: navigation.isSearchActive) { _, isActive in
                searchModeDidChange(isActive: isActive)
            }
            .onChange(of: navigation.searchFocusRequest) { _, _ in
                guard navigation.isSearchActive else { return }
                focusSearchField(selectingContents: !(session?.text.isEmpty ?? true))
            }
            .accessibilityIdentifier(AccessibilityID.ItemList.root)
    }

    /// The one search field.
    ///
    /// There used to be two: a "Filter this list" box here and a separate search sheet on ⌘F, which
    /// looked identical and did different things. This is that field, and the scope picker is the
    /// part that used to be a whole second feature.
    @ViewBuilder
    private var content: some View {
        if navigation.isSearchActive, let session {
            InlineSearchResults(
                session: session,
                listTitle: navigation.selection.title,
                onHighlight: preview,
                onOpen: open,
                onSave: { pendingSavedSearchName = defaultSavedSearchName(for: session) }
            )
            .sheet(item: savedSearchNameBinding) { name in
                SaveSearchSheet(
                    initialName: name.value,
                    queryText: session.text,
                    onSave: { saveSearch(named: $0, query: session.text) },
                    onCancel: { pendingSavedSearchName = nil }
                )
            }
        } else if isLoading, items.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading")
        } else if displayedItems.isEmpty {
            emptyState
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            itemList

            if navigation.hasMultipleSelection {
                BatchActionBar(
                    count: navigation.selectedItemIDs.count,
                    isTrashScope: navigation.selection.showsTrashedItems,
                    onComplete: { batchToggleCompletion() },
                    onArchive: { batchArchive() },
                    onTrash: { batchTrash() },
                    onRestore: { batchRestore() },
                    onClear: { navigation.selectedItemIDs = [] }
                )
            }
        }
    }

    private var itemList: some View {
        List(selection: selectedItemBinding) {
            ForEach(displayedItems, id: \.id) { item in
                NavigationLink(value: SidebarSelection.item(id: item.id)) {
                    row(for: item)
                }
                .contextMenu { contextMenu(for: item) }
                .modifier(ItemSwipeActions(item: item, navigation: navigation, onPermanentDeletion: { pendingPermanentDeletion = $0 }, onChange: { Task { await reload() } }))
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }

    private func makeSessionIfNeeded() {
        guard session == nil, let services else { return }
        session = SearchSessionModel(engine: services.search)
    }

    /// Keeps the field, the session, and the window's search mode in step.
    ///
    /// Entering search from the menu or ⌘F offers the previous query back and focuses the field, so
    /// the shortcut lands somewhere you can type. Entering it *by typing* must not do that — the
    /// text is already what the user wants — which is why the restore is conditional on the session
    /// being empty rather than unconditional.
    private func searchModeDidChange(isActive: Bool) {
        guard let session else { return }

        guard isActive else {
            session.clear()
            return
        }

        if session.text.isEmpty, !navigation.searchQuery.isEmpty {
            session.text = navigation.searchQuery
            navigation.didSelectSearchQuery()
        }
        session.listItemIDs = Set(items.map(\.id))
        focusSearchField(selectingContents: !session.text.isEmpty)
    }

    private func focusSearchField(selectingContents: Bool) {
        isSearchFieldFocused = true
        guard selectingContents else { return }

        Task { @MainActor in
            await Task.yield()
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            navigation.didSelectSearchQuery()
        }
    }


    /// Each is one undo step, because each is one thing the user did.
    private func batchToggleCompletion() {
        runBatch { undo, targets in
            try undo.toggleCompletion(targets.filter { $0.kind.supportsStatus })
        }
    }

    private func batchArchive() {
        runBatch { undo, targets in try undo.setArchived(targets, true) }
    }

    private func batchTrash() {
        let ids = navigation.selectedItemIDs
        runBatch { undo, targets in try undo.moveToTrash(targets) }
        navigation.selectedItemIDs = []
        services?.noteRemoval(of: ids.first ?? UUID())
    }

    /// ⌫ on the selection, as one undo step.
    private func trashSelection() {
        guard !navigation.selection.showsTrashedItems else { return }
        batchTrash()
    }

    private func batchRestore() {
        let ids = Array(navigation.selectedItemIDs)
        guard let services else { return }
        services.perform { try services.undo.restore(ids: ids) }
        services.refreshDerivedState()
        Task { await reload() }
    }

    private func runBatch(_ body: (StructuralUndoCoordinator, [Item]) throws -> Void) {
        guard let services else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        services.perform { try body(services.undo, targets) }
        services.refreshDerivedState()
        Task { await reload() }
    }

    private func row(for item: Item) -> some View {
        ItemRow(
            item: item,
            dateProvider: services?.dateProvider ?? SystemDateProvider(),
            showsParent: showsParentColumn,
            onToggleStatus: item.kind.supportsStatus ? { toggleCompletion(item) } : nil
        )
    }

    /// A project's own list already implies its parent, so repeating it is noise.
    private var showsParentColumn: Bool {
        if case .item = navigation.selection { return false }
        return true
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        switch navigation.selection {
        // A project draws `ProjectWorkspaceView` instead of this list, so this arm is unreachable.
        // It exists because the switch is exhaustive, and because an empty state offering to add a
        // note is the wrong offer in a place that holds work.
        case .project, .projectInbox:
            EmptyView()
        case .inbox:
            EmptyStateView(
                symbolName: "tray",
                headline: "Inbox is clear",
                message: "Everything you captured has a home. Press ⌘⇧N to capture something new.",
                tone: .accomplished
            )
        case .today:
            EmptyStateView(
                symbolName: "checkmark.circle",
                headline: "Nothing due today",
                message: "No overdue work and nothing scheduled. Upcoming shows what is next.",
                tone: .accomplished
            )
        case .trash:
            EmptyStateView(
                symbolName: "trash",
                headline: "Trash is empty",
                message: "Deleted items wait here until you remove them permanently."
            )
        case .kind(let kind):
            EmptyStateView(
                symbolName: kind.symbolName,
                headline: "No \(kind.pluralDisplayName.lowercased()) yet",
                message: "Press ⌘N to create one.",
                actionTitle: "New \(kind.displayName)",
                action: { createItem(kind: kind) }
            )
        case .tag(let slug):
            EmptyStateView(
                symbolName: "number",
                headline: "Nothing tagged \(slug)",
                message: "Items you tag with this appear here."
            )
        case .savedSearch:
            EmptyStateView(
                symbolName: "line.3.horizontal.decrease.circle",
                headline: "No matches",
                message: "This saved search found nothing right now.",
                tone: .noResults
            )
        case .upcoming:
            EmptyStateView(
                symbolName: "calendar",
                headline: "Nothing scheduled",
                message: "Work due in the next two weeks appears here.",
                tone: .accomplished
            )
        case .item:
            EmptyStateView(
                symbolName: "square.stack.3d.up",
                headline: "Nothing inside yet",
                message: "Add tasks to this project."
            )
        case .archive:
            EmptyStateView(
                symbolName: "archivebox",
                headline: "Nothing archived",
                message: "Archiving keeps something without leaving it in your way."
            )
        case .records:
            // Records owns its browser and per-scope empty states.
            EmptyStateView(
                symbolName: "person.2",
                headline: "No one yet",
                message: "Press ⌘⇧K and type a name."
            )
        case .taskView, .smartList, .builtInSmartList:
            // Unreachable: `RootView` routes every task destination to `TaskWorkspaceView`, which
            // has an empty state per view — "your day is clear" and "nothing is waiting on anybody"
            // are different pieces of news and must not share a sentence.
            EmptyStateView(
                symbolName: "checkmark.circle",
                headline: "Nothing here",
                message: "This list is empty."
            )

        case .home, .calendar, .reminders, .time:
            // Unreachable: these destinations are declared but unavailable, so nothing selects them.
            EmptyStateView(
                symbolName: "questionmark.circle",
                headline: "Not available yet",
                message: "This view arrives in a later version."
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: sortBinding) {
                    ForEach(ItemQuery.Sort.allCases, id: \.self) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier(AccessibilityID.ItemList.sortMenu)
        }

        if navigation.selection == .trash, !items.isEmpty {
            ToolbarItem {
                Button("Empty Trash…", systemImage: "trash.slash") {
                    if confirmBeforeEmptyingTrash {
                        isConfirmingEmptyTrash = true
                    } else {
                        emptyTrash()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Trash.emptyTrashButton)
                .confirmationDialog(
                    "Empty the Trash?",
                    isPresented: $isConfirmingEmptyTrash
                ) {
                    Button("Empty Trash", role: .destructive) { emptyTrash() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Everything in the Trash is removed permanently. This cannot be undone.")
                }
            }
        } else {
            ToolbarItem {
                Button {
                    createItem(kind: navigation.selection.defaultNewItemKind)
                } label: {
                    Label("New \(navigation.selection.defaultNewItemKind.displayName)", systemImage: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.ItemList.newItemButton)
                .keyboardShortcut("n")
            }
        }
    }

    private var subtitle: String {
        if navigation.isSearchActive, let session {
            return session.explanation
        }
        let count = displayedItems.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    // MARK: - Search results

    /// Opens a result without leaving search.
    ///
    /// The results stay on screen and the detail pane changes, so several matches can be looked at
    /// one after another. Leaving search is Escape's job, and only Escape's — a click that both
    /// opened something *and* threw the results away would make the list feel like a trapdoor.
    private func open(_ result: SearchResult) {
        navigation.selectItem(result.item.id)
        navigation.focus(.detail)
    }

    /// Shows a result without leaving the results.
    ///
    /// What the arrow keys do. ``open(_:)`` is what Return does, and the difference between them is
    /// the whole reason arrowing through results works: moving focus on every keystroke would
    /// deliver the *next* arrow press to the detail pane.
    private func preview(_ result: SearchResult) {
        navigation.selectItem(result.item.id)
    }


    /// A name proposed from what was typed, so the common case is one Return.
    private func defaultSavedSearchName(for session: SearchSessionModel) -> String {
        let trimmed = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved Search" : trimmed
    }

    private func saveSearch(named name: String, query: String) {
        guard let services else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty else { return }

        services.perform {
            // The *text* is stored, not the parsed structure — so a saved search re-parses under a
            // newer grammar and keeps working, and the user can read and edit what they saved.
            let saved = SavedSearch(
                name: trimmedName,
                queryString: trimmedQuery,
                createdAt: services.dateProvider.now
            )
            services.context.insert(saved)
            try services.context.save()
        }

        pendingSavedSearchName = nil
        services.refreshDerivedState()
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: Item) -> some View {
        if navigation.selection.showsTrashedItems {
            Button("Put Back", systemImage: "arrow.uturn.backward") { restore(item) }
                .accessibilityIdentifier(AccessibilityID.Trash.restoreButton)
            Divider()
            Button("Delete Permanently", systemImage: "xmark.bin", role: .destructive) {
                deletePermanently(item)
            }
            .accessibilityIdentifier(AccessibilityID.Trash.deletePermanentlyButton)
        } else {
            if item.kind.supportsStatus {
                Button(item.isCompleted ? "Mark Incomplete" : "Mark Complete", systemImage: "checkmark.circle") {
                    toggleCompletion(item)
                }
            }

            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") {
                update(item) { $0.isFavorite.toggle() }
            }
            Button(item.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                update(item) { $0.isPinned.toggle() }
            }

            Divider()

            Menu("Convert To") {
                ForEach(convertibleKinds(from: item.kind), id: \.self) { kind in
                    Button(kind.displayName) { convert(item, to: kind) }
                }
            }

            Divider()

            Button(item.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
                setArchived(item, !item.isArchived)
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { moveToTrash(item) }
        }
    }

    /// The confirmation that stands between the Trash and the end.
    ///
    /// `deletePermanently` is the one operation in this app that structural undo cannot reverse —
    /// there is no restore point for a row that no longer exists — so it is the one operation a
    /// gesture is not allowed to complete and a click is not allowed to complete silently.
    @ViewBuilder
    private var permanentDeletionDialog: some View {
        EmptyView()
            .confirmationDialog(
                "Delete \u{201C}\(pendingPermanentDeletion?.displayTitle ?? "")\u{201D} permanently?",
                isPresented: Binding(
                    get: { pendingPermanentDeletion != nil },
                    set: { if !$0 { pendingPermanentDeletion = nil } }
                ),
                presenting: pendingPermanentDeletion
            ) { item in
                Button("Delete Permanently", role: .destructive) {
                    pendingPermanentDeletion = nil
                    deletePermanently(item)
                }
                Button("Cancel", role: .cancel) { pendingPermanentDeletion = nil }
            } message: { _ in
                Text("This cannot be undone.")
            }
    }

    /// Kinds this item could reasonably become. Areas and projects are excluded from casual
    /// conversion because they carry children whose containment would break.
    private func convertibleKinds(from kind: ItemKind) -> [ItemKind] {
        [.note, .task, .idea, .reference, .bookmark].filter { $0 != kind }
    }

    // MARK: - Data

    /// Changes that should trigger a refetch. A single value so `.task(id:)` handles it.
    ///
    /// ### Why these are values rather than a joined string
    /// They were `String(describing:)` over the selection, which is reflection: about 1.7µs a call,
    /// on a property read on every evaluation of this view's body, to produce a string whose only
    /// use is to be compared for equality. Every part of it is already `Equatable`, which is all
    /// `task(id:)` asks for, so the comparison can simply be the comparison.
    private struct ReloadToken: Equatable {
        var selection: SidebarSelection
        var sort: ItemQuery.Sort?

        /// The library's own change counter — see ``AppServices/changeToken``.
        ///
        /// This used to be `items.count`, which was a loop rather than a signal: `reload` is the
        /// only thing that sets `items`, so every navigation fetched, saw its own new count, and
        /// fetched a second time. On the reduced benchmark corpus that is another twenty-six
        /// milliseconds of main-thread work per module switch, spent confirming the answer it had
        /// just been given. It also caught nothing: a title edited elsewhere leaves the count alone.
        /// The change token is what the rest of the app already announces a write with.
        var changeToken: Int
    }

    private var reloadToken: ReloadToken {
        ReloadToken(
            selection: navigation.selection,
            sort: navigation.sortOverride,
            changeToken: services?.changeToken ?? 0
        )
    }

    private var displayedItems: [Item] { items }

    private func reload() async {
        guard let services else { return }

        if case .savedSearch(let id) = navigation.selection {
            await reloadSavedSearch(id: id, services: services)
            return
        }

        isLoading = true
        defer { isLoading = false }

        let query = navigation.currentQuery(using: services.dateProvider)
        services.perform {
            items = try services.items.items(matching: query)
        }
    }

    /// Runs a saved search and resolves its hits to items, once.
    ///
    /// The resolution used to live in `displayedItems`, which is a computed property the body reads
    /// three times — for the empty check, for the count in the subtitle, and for the rows — so a
    /// saved search matching five hundred items performed fifteen hundred store lookups on every
    /// evaluation. A search result names an item; turning the names into items is loading, and
    /// loading belongs here.
    private func reloadSavedSearch(id: UUID, services: AppServices) async {
        guard let search = savedSearch(id: id, services: services) else {
            items = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        let query = SearchQueryParser.parse(search.queryString)
        do {
            let results = try await services.search.search(query, limit: 500)
            items = results.compactMap { try? services.items.item(id: $0.item.id) }
        } catch {
            services.lastError = error
            items = []
        }
    }

    private func savedSearch(id: UUID, services: AppServices) -> SavedSearch? {
        var descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? services.context.fetch(descriptor).first
    }

    // MARK: - Bindings

    /// Typing enters search; emptying the field leaves it.
    ///
    /// Deliberately *not* symmetrical with Escape. Emptying the field is the user erasing their
    /// query, so restoring the list is what they asked for. Escape keeps the query in
    /// ``NavigationModel/lastSearchQuery`` so reopening search offers it back — one gesture undoes
    /// the search, the other undoes the typing, and neither destroys the other's work.
    private var searchBinding: Binding<String> {
        Binding(
            get: { session?.text ?? "" },
            set: { newValue in
                session?.text = newValue
                session?.listItemIDs = Set(items.map(\.id))

                if newValue.isEmpty {
                    navigation.endSearch()
                } else {
                    if !navigation.isSearchActive {
                        navigation.beginSearch(clearingQuery: true)
                        session?.text = newValue
                    }
                    // Mirrored so leaving search can keep it, and offer it back next time.
                    navigation.searchQuery = newValue
                }
            }
        )
    }

    private var scopeBinding: Binding<SearchScope> {
        Binding(
            get: { session?.scope ?? .everywhere },
            set: { newValue in
                session?.listItemIDs = Set(items.map(\.id))
                session?.scope = newValue
            }
        )
    }

    private var searchPrompt: String {
        navigation.isSearchActive ? "Search" : "Search everything"
    }

    /// Wraps the pending name so `.sheet(item:)` has something `Identifiable` to hold.
    private var savedSearchNameBinding: Binding<IdentifiedString?> {
        Binding(
            get: { pendingSavedSearchName.map(IdentifiedString.init) },
            set: { pendingSavedSearchName = $0?.value }
        )
    }

    private var sortBinding: Binding<ItemQuery.Sort> {
        Binding(
            get: {
                navigation.sortOverride
                    ?? navigation.selection.query(using: services?.dateProvider ?? SystemDateProvider()).sort
            },
            set: { navigation.sortOverride = $0 }
        )
    }

    /// The list's own selection — a set, so shift- and command-click work.
    private var selectedItemBinding: Binding<Set<UUID>> {
        Binding(
            get: { navigation.selectedItemIDs },
            set: { navigation.selectedItemIDs = $0 }
        )
    }

    /// The items behind the current selection, in the order they appear.
    private var selectedItems: [Item] {
        displayedItems.filter { navigation.selectedItemIDs.contains($0.id) }
    }

    // MARK: - Actions

    private func createItem(kind: ItemKind) {
        guard let services else { return }

        var draft = ItemDraft(kind: kind, title: "")
        if case .tag(let slug) = navigation.selection {
            draft.tagSlugs = [slug]
        }
        if case .item(let parentID) = navigation.selection {
            draft.parentID = parentID
        }
        if navigation.selection == .today, kind.supportedFields.contains(.dueDate) {
            draft.dueAt = services.dateProvider.startOfToday
        }

        services.perform {
            let created = try services.items.create(draft)
            navigation.selectItem(created.id)
            services.noteChange(to: created)
        }
        Task { await reload() }
    }

    private func toggleCompletion(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.toggleCompletion(item) }
        services.noteChange(to: item)
        Task { await reload() }
    }

    private func update(_ item: Item, _ mutate: @escaping (Item) -> Void) {
        guard let services else { return }
        services.perform { try services.items.update(item) { mutate($0) } }
        services.noteChange(to: item)
    }

    private func convert(_ item: Item, to kind: ItemKind) {
        guard let services else { return }
        services.perform { _ = try services.items.setKind(item, to: kind) }
        services.noteChange(to: item)
        Task { await reload() }
    }

    private func setArchived(_ item: Item, _ archived: Bool) {
        guard let services else { return }
        services.perform { try services.items.setArchived(item, archived) }
        Task { await reload() }
    }

    /// One row to the Trash, as one undo step.
    ///
    /// Through `StructuralUndoCoordinator` rather than straight at the repository, which is what the
    /// batch bar has always done and what this had not: trashing one row and trashing four were the
    /// same user action with different `⌘Z` behaviour, and only one of them was right.
    private func moveToTrash(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform { try services.undo.moveToTrash([item]) }
        navigation.selectedItemIDs.remove(id)
        services.refreshDerivedState()
        services.noteRemoval(of: id)
        Task { await reload() }
    }

    private func restore(_ item: Item) {
        guard let services else { return }
        // The same door the batch bar uses, so a restore is undoable however it was asked for.
        services.perform { try services.undo.restore(ids: [item.id]) }
        services.noteChange(to: item)
        Task { await reload() }
    }

    private func deletePermanently(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform { try services.items.deletePermanently(item) }
        navigation.selectedItemIDs.remove(id)
        services.noteRemoval(of: id)
        Task { await reload() }
    }

    private func emptyTrash() {
        guard let services else { return }
        services.perform { try services.items.emptyTrash() }
        navigation.selectedItemIDs = []
        Task {
            await services.warmSearchIndex()
            await reload()
        }
    }
}

import SwiftData

#Preview("Item list", traits: .fixedLayout(width: 420, height: 600)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.select(.kind(.task))

    return NavigationStack {
        ItemListView(navigation: navigation)
    }
    .appServices(services)
    .frame(width: 420, height: 600)
}
