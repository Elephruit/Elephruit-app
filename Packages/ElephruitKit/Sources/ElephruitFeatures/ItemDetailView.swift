import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The third column: one item, in whatever form suits its kind.
///
/// ### Why this is a router
/// The previous version rendered title + body + backlinks for *everything*, so a project got a note
/// view with a different glyph — no task list, no headings, no people. `ItemKind` discriminated the
/// data but not the presentation, and that mismatch is why the app read as a note-taker with extra
/// fields rather than as a connected system.
///
/// This view now owns only what every kind shares: loading the editable text, debouncing the write,
/// and flushing it. Which surface to draw is a switch, and each surface is its own type.
public struct ItemDetailView: View {
    @Environment(\.services) private var services

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
                VStack(spacing: 0) {
                    if item.isInTrash {
                        TrashBanner { restore(item) }
                            .padding(.top, Theme.Spacing.medium)
                    }
                    surface(for: item)
                }
                .toolbar { detailToolbar(for: item) }
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

    /// The one place kind becomes presentation.
    @ViewBuilder
    private func surface(for item: Item) -> some View {
        switch item.kind {
        case .project, .area, .goal:
            ProjectDetailView(
                project: item,
                navigation: navigation,
                title: titleBinding,
                brief: bodyBinding
            )

        case .task:
            TaskDetailView(
                item: item,
                navigation: navigation,
                title: titleBinding,
                bodyText: bodyBinding
            )

        case .bookmark:
            BookmarkDetailView(item: item, title: titleBinding, bodyText: bodyBinding)

        case .person, .organization:
            PersonDetailView(
                item: item,
                navigation: navigation,
                title: titleBinding,
                bodyText: bodyBinding
            )

        case .heading:
            // A heading is edited in place inside its project and never opened on its own. Reaching
            // here means something selected one directly, so point back rather than showing a
            // stripped editor for a thing with nothing to edit.
            EmptyStateView(
                symbolName: "text.append",
                headline: item.displayTitle,
                message: "Headings are edited inside their project.",
                actionTitle: item.parent.map { "Open \($0.displayTitle)" },
                action: item.parent.map { parent in { navigation.selectItem(parent.id) } }
            )

        case .note, .idea, .reference, .decision, .interaction, .meeting, .dailyEntry:
            NoteDetailView(
                item: item,
                navigation: navigation,
                title: titleBinding,
                bodyText: bodyBinding,
                pendingInsertion: $pendingInsertion,
                completionContext: completionContext,
                completionSuggestions: completionSuggestions,
                onCompletionContextChange: handleCompletionContextChange,
                onAcceptCompletion: acceptCompletion
            )
        }
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
                update(item) { $0.isPinned.toggle() }
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.fill" : "pin")
            }
            .accessibilityIdentifier(AccessibilityID.Inspector.pinToggle)
        }

        ToolbarItem {
            Button {
                navigation.isInspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityIdentifier(AccessibilityID.Detail.inspectorToggle)
        }
    }

    // MARK: - Link completion

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

    private func acceptCompletion(_ title: String) {
        guard let context = completionContext else { return }
        pendingInsertion = WikiLinkInsertion(title: title, context: context)
        completionContext = nil
    }

    // MARK: - Loading and saving

    private var currentItem: Item? {
        guard let services, let id = navigation.selectedItemID else { return nil }
        return try? services.items.item(id: id)
    }

    /// Pulls the item's text into local state.
    ///
    /// Local state, rather than binding straight to the model, so typing does not write to the store
    /// on every keystroke — which would run validation, link reconciliation, and a save several
    /// times a second.
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
    /// Half a second: long enough that a burst of typing produces one save, short enough that a
    /// force-quit loses at most a phrase. Autosave on the context and a flush on disappear cover
    /// the rest.
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
                // A heading has no body, so writing one would fail validation.
                if subject.kind.supportedFields.contains(.body) {
                    subject.body = newBody
                }
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

    private func restore(_ item: Item) {
        guard let services else { return }
        services.perform { try services.items.restore(item) }
        services.noteChange(to: item)
    }
}

#Preview("Project", traits: .fixedLayout(width: 760, height: 640)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.selectItem((try? services.items.items(matching: .kind(.project)))?.first?.id)

    return ItemDetailView(navigation: navigation)
        .appServices(services)
        .frame(width: 760, height: 640)
}

#Preview("Note", traits: .fixedLayout(width: 760, height: 640)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.selectItem((try? services.items.items(matching: .kind(.note)))?.first?.id)

    return ItemDetailView(navigation: navigation)
        .appServices(services)
        .frame(width: 760, height: 640)
}
