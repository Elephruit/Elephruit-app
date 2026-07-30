import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The third column: one item, editable.
///
/// Edits are debounced and written through the repository, so validation, `searchText`, and wiki-link
/// reconciliation all happen on every save without the view knowing about any of them.
public struct ItemDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    private let navigation: NavigationModel

    @State private var title = ""
    @State private var bodyText = ""
    @State private var loadedItemID: UUID?
    @State private var completionContext: WikiLinkCompletionContext?
    @State private var completionSuggestions: [(id: UUID, title: String)] = []
    @State private var pendingInsertion: WikiLinkInsertion?
    @State private var saveTask: Task<Void, Never>?

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        Group {
            if let item = currentItem {
                editor(for: item)
            } else {
                EmptyStateView(
                    symbolName: "square.text.square",
                    headline: "Nothing selected",
                    message: "Choose something from the list, or press ⌘N to make something new."
                )
                .accessibilityIdentifier(AccessibilityID.Detail.emptyState)
            }
        }
        .task(id: navigation.selectedItemID) { load() }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Editor

    private func editor(for item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: item)

            Divider()

            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(
                    text: bodyBinding,
                    pendingInsertion: $pendingInsertion,
                    isMonospaced: prefersMonospaced,
                    isEditable: !item.isInTrash,
                    onCompletionContextChange: handleCompletionContextChange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let completionContext, !completionSuggestions.isEmpty {
                    linkCompletionList(context: completionContext)
                        .padding(.leading, Theme.Spacing.large)
                        .padding(.top, Theme.Spacing.section)
                }
            }

            if !visibleBacklinks(for: item).isEmpty {
                Divider()
                backlinks(for: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.Detail.root)
        .toolbar { detailToolbar(for: item) }
    }

    private func header(for item: Item) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if item.isInTrash {
                trashBanner(for: item)
            }

            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: item.effectiveSymbolName)
                    .foregroundStyle(Theme.Palette.color(named: item.colorName))
                    .accessibilityHidden(true)

                TextField("Title", text: titleBinding, prompt: Text("Untitled \(item.kind.displayName)"))
                    .textFieldStyle(.plain)
                    .font(Theme.Text.title)
                    .disabled(item.isInTrash)
                    .accessibilityIdentifier(AccessibilityID.Detail.titleField)
                    .accessibilityLabel("Title")
            }

            metadataLine(for: item)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private func trashBanner(for item: Item) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "trash")
            Text("This item is in the Trash and cannot be edited.")
            Spacer()
            Button("Put Back") { restore(item) }
                .accessibilityIdentifier(AccessibilityID.Trash.restoreButton)
        }
        .font(Theme.Text.rowSubtitle)
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
    }

    private func metadataLine(for item: Item) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            if item.kind.supportsStatus {
                Button {
                    toggleCompletion(item)
                } label: {
                    Label(
                        item.isCompleted ? "Completed" : "Open",
                        systemImage: item.status.symbolName
                    )
                    .font(Theme.Text.metadata)
                }
                .buttonStyle(.borderless)
                .disabled(item.isInTrash)
            }

            if let dueAt = item.dueAt {
                DueDateLabel(
                    date: dueAt,
                    dateProvider: services?.dateProvider ?? SystemDateProvider(),
                    isActionable: item.isActionable
                )
            }

            if let parent = item.parent {
                Button {
                    navigation.select(.item(id: parent.id))
                } label: {
                    Label(parent.displayTitle, systemImage: parent.effectiveSymbolName)
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.borderless)
            }

            if !item.tagSlugs.isEmpty {
                TagChipRow(slugs: item.tagSlugs, limit: 4)
            }

            Spacer()

            Text("Edited \(item.updatedAt.formatted(.relative(presentation: .named)))")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .foregroundStyle(Theme.Colors.secondaryText)
    }

    // MARK: - Link completion

    /// The `[[` completion list.
    ///
    /// Offers to create the missing item when nothing matches, which is what makes writing a link to
    /// something not yet written a natural act rather than a dead end.
    private func linkCompletionList(context: WikiLinkCompletionContext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(completionSuggestions.prefix(6), id: \.id) { suggestion in
                Button {
                    pendingInsertion = WikiLinkInsertion(title: suggestion.title, context: context)
                    completionContext = nil
                } label: {
                    HStack {
                        Image(systemName: "link")
                            .font(Theme.Text.metadata)
                        Text(suggestion.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.tight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(Theme.Spacing.tight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Colors.separator)
        )
        .shadow(radius: 8, y: 2)
        .accessibilityLabel("Link suggestions")
    }

    private func handleCompletionContextChange(_ context: WikiLinkCompletionContext?) {
        completionContext = context

        guard let context, let services else {
            completionSuggestions = []
            return
        }

        Task {
            let suggestions = await services.search.titleSuggestions(prefix: context.query, limit: 8)
            // Discard a stale result if the caret moved on while we were asking.
            guard completionContext == context else { return }
            completionSuggestions = suggestions.filter { $0.id != navigation.selectedItemID }
        }
    }

    // MARK: - Backlinks

    private func visibleBacklinks(for item: Item) -> [ItemLink] {
        item.visibleBacklinks()
    }

    private func backlinks(for item: Item) -> some View {
        let links = visibleBacklinks(for: item)

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Linked from", count: links.count)

            ForEach(links, id: \.id) { link in
                if let source = link.source {
                    Button {
                        navigation.selectedItemID = source.id
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: source.effectiveSymbolName)
                                .foregroundStyle(Theme.Colors.secondaryText)
                            Text(source.displayTitle)
                                .lineLimit(1)
                            Text(link.kind.displayName)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .frame(maxHeight: 180)
        .accessibilityIdentifier(AccessibilityID.Detail.backlinksSection)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func detailToolbar(for item: Item) -> some ToolbarContent {
        ToolbarItem {
            Button {
                update(item) { $0.isFavorite.toggle() }
            } label: {
                Label(
                    item.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                    systemImage: item.isFavorite ? "star.fill" : "star"
                )
            }
            .accessibilityIdentifier(AccessibilityID.Inspector.favoriteToggle)
        }

        ToolbarItem {
            Button {
                navigation.isInspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityIdentifier(AccessibilityID.Detail.inspectorToggle)
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    // MARK: - Loading and saving

    private var currentItem: Item? {
        guard let services, let id = navigation.selectedItemID else { return nil }
        return try? services.items.item(id: id)
    }

    /// Pulls the item's text into local state.
    ///
    /// Local state, rather than binding straight to the model, so that typing does not write to the
    /// store on every keystroke — which would run validation, link reconciliation, and a save
    /// several times a second.
    private func load() {
        flushPendingSave()

        guard let item = currentItem else {
            loadedItemID = nil
            title = ""
            bodyText = ""
            return
        }

        loadedItemID = item.id
        title = item.title
        bodyText = item.body
        completionContext = nil
        completionSuggestions = []
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { newValue in
                title = newValue
                scheduleSave()
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { bodyText },
            set: { newValue in
                bodyText = newValue
                scheduleSave()
            }
        )
    }

    /// Debounces the write.
    ///
    /// Half a second: long enough that a burst of typing produces one save, short enough that the
    /// user never loses more than a phrase if the app is force-quit. Autosave on the context and
    /// ``ItemDetailView/flushPendingSave()`` on disappear cover the rest.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        commit()
    }

    private func commit() {
        guard let services,
              let id = loadedItemID,
              let item = try? services.items.item(id: id),
              !item.isInTrash
        else { return }

        // Nothing changed; do not touch `updatedAt`.
        guard item.title != title || item.body != bodyText else { return }

        let newTitle = title
        let newBody = bodyText

        services.perform {
            try services.items.update(item) { subject in
                subject.title = newTitle
                subject.body = newBody
            }
        }
        services.noteChange(to: item)
    }

    // MARK: - Actions

    private func update(_ item: Item, _ mutate: @escaping (Item) -> Void) {
        guard let services else { return }
        services.perform { try services.items.update(item) { mutate($0) } }
        services.noteChange(to: item)
    }

    private func toggleCompletion(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.toggleCompletion(item) }
        services.noteChange(to: item)
    }

    private func restore(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.restore(item) }
        services.noteChange(to: item)
    }
}

#Preview("Detail", traits: .fixedLayout(width: 640, height: 560)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.selectedItemID = (try? services.items.items(matching: .kind(.note)))?.first?.id

    return ItemDetailView(navigation: navigation)
        .appServices(services)
        .frame(width: 640, height: 560)
}
