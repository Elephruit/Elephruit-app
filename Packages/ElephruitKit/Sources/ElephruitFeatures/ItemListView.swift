import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
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
    @State private var savedSearchResults: [SearchResult] = []
    @State private var isLoading = false

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        content
            .navigationTitle(navigation.selection.title)
            .navigationSubtitle(subtitle)
            .searchable(text: filterBinding, placement: .toolbar, prompt: "Filter this list")
            .toolbar { toolbarContent }
            .task(id: reloadToken) { await reload() }
            .accessibilityIdentifier(AccessibilityID.ItemList.root)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, items.isEmpty {
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

    private var list: some View {
        List(selection: selectedItemBinding) {
            ForEach(displayedItems, id: \.id) { item in
                NavigationLink(value: SidebarSelection.item(id: item.id)) {
                    row(for: item)
                }
                .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
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
        case .kind(let kind) where !navigation.listFilterText.isEmpty:
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "No \(kind.pluralDisplayName.lowercased()) match",
                message: "Nothing here matches “\(navigation.listFilterText)”.",
                tone: .noResults,
                actionTitle: "Clear Filter",
                action: { navigation.listFilterText = "" }
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
        case .home, .calendar, .time:
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
                Button("Empty Trash", systemImage: "trash.slash") { emptyTrash() }
                    .accessibilityIdentifier(AccessibilityID.Trash.emptyTrashButton)
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
        let count = displayedItems.count
        return count == 1 ? "1 item" : "\(count) items"
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

            Button(item.isFavorite ? "Remove from Favourites" : "Add to Favourites", systemImage: "star") {
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

    /// Kinds this item could reasonably become. Areas and projects are excluded from casual
    /// conversion because they carry children whose containment would break.
    private func convertibleKinds(from kind: ItemKind) -> [ItemKind] {
        [.note, .task, .idea, .reference, .bookmark].filter { $0 != kind }
    }

    // MARK: - Data

    /// Changes that should trigger a refetch. A single value so `.task(id:)` handles it.
    private var reloadToken: String {
        var parts = [
            String(describing: navigation.selection),
            navigation.listFilterText,
            String(describing: navigation.sortOverride),
        ]
        // Ensures a refetch after items change, since the repository is not observable.
        parts.append(String(items.count))
        return parts.joined(separator: "|")
    }

    private var displayedItems: [Item] {
        if case .savedSearch = navigation.selection {
            return savedSearchResults.compactMap { result in
                try? services?.items.item(id: result.item.id)
            }
        }
        return items
    }

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

    private func reloadSavedSearch(id: UUID, services: AppServices) async {
        guard let search = savedSearch(id: id, services: services) else {
            savedSearchResults = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        let query = SearchQueryParser.parse(search.queryString)
        do {
            savedSearchResults = try await services.search.search(query, limit: 500)
        } catch {
            services.lastError = error
            savedSearchResults = []
        }
    }

    private func savedSearch(id: UUID, services: AppServices) -> SavedSearch? {
        var descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? services.context.fetch(descriptor).first
    }

    // MARK: - Bindings

    private var filterBinding: Binding<String> {
        Binding(get: { navigation.listFilterText }, set: { navigation.listFilterText = $0 })
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

    private var selectedItemBinding: Binding<UUID?> {
        Binding(get: { navigation.selectedItemID }, set: { navigation.selectedItemID = $0 })
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
            navigation.selectedItemID = created.id
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

    private func moveToTrash(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform { try services.items.moveToTrash(item) }
        if navigation.selectedItemID == id { navigation.selectedItemID = nil }
        services.noteRemoval(of: id)
        Task { await reload() }
    }

    private func restore(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.restore(item) }
        services.noteChange(to: item)
        Task { await reload() }
    }

    private func deletePermanently(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform { try services.items.deletePermanently(item) }
        if navigation.selectedItemID == id { navigation.selectedItemID = nil }
        services.noteRemoval(of: id)
        Task { await reload() }
    }

    private func emptyTrash() {
        guard let services else { return }
        services.perform { try services.items.emptyTrash() }
        navigation.selectedItemID = nil
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
