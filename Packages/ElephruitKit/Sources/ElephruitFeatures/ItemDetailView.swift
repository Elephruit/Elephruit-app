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
    @State private var pendingSave = PendingSave()

    /// Identifies this editor to the navigation model, so a window with two of them can hold two.
    @State private var editorID = UUID()

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    /// What this pane says when it is empty, which depends on where it is empty.
    ///
    /// See ``DetailEmptyState`` — the one sentence this replaces was shown in eleven destinations
    /// and told the user to press ⌘N in the Trash.
    private var emptyState: some View {
        let content = DetailEmptyState.forSelection(navigation.selection)
        return EmptyStateView(
            symbolName: content.symbolName,
            headline: content.headline,
            message: content.message
        )
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
                emptyState
                    .accessibilityIdentifier(AccessibilityID.Detail.emptyState)
            }
        }
        .task(id: navigation.selectedItemID) { load() }
        // Registered so that *any* navigation flushes first, not only a change of item.
        //
        // `task(id:)` already covers changing which item is shown. It does not cover leaving a
        // module, following a deep link, or a menu command that moves the window somewhere the
        // editor is torn down rather than reloaded — and those are exactly the cases where a
        // debounced half-second of typing had nowhere to go.
        .task { navigation.registerEditFlush(editorID) { flushPendingSave() } }
        .onDisappear {
            navigation.unregisterEditFlush(editorID)
            flushPendingSave()
        }
        // `scenePhase` does not report a macOS quit, so the notification is the only hook that
        // fires before the process goes. `NSSupportsSuddenTermination` is already `false` for
        // exactly this reason — the plist half of the promise was kept and this half was not.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingSave()
        }
        // Switching away is the other moment the pending half-second stops being cheap.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            flushPendingSave()
        }
    }

    /// The one place kind becomes presentation.
    @ViewBuilder
    private func surface(for item: Item) -> some View {
        switch item.kind {
        // A list is a container of tasks with headings, which is the same surface a project needs.
        // What differs is what the header says about it — a list has no outcome and no progress —
        // and that difference lives inside `ProjectDetailView` rather than in a second view.
        case .project, .area, .goal, .list:
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

        case .person:
            PersonWorkspaceView(
                person: item,
                navigation: navigation,
                title: titleBinding,
                bodyText: bodyBinding
            )

        case .organization:
            // An organisation keeps the simpler shape. It has no age to estimate, no family, and no
            // last-contact line, so the portrait's whole apparatus would be scaffolding around a
            // name and a note.
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
                    item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
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
    /// force-quit loses at most a phrase. Quitting, switching app, and changing item all flush,
    /// so in practice the window is only ever a real crash.
    private func scheduleSave() {
        pendingSave.schedule { commit() }
    }

    private func flushPendingSave() {
        pendingSave.flush()
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
