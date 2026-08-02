import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// A project, open on one of its views.
///
/// Replaces the middle column rather than filtering it, on the same terms as Time, the calendar and
/// Today: it *is* that column's contents. See ``ModuleLayoutPolicy`` for why it gets the whole width.
struct ProjectWorkspaceView: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel
    let projectID: UUID
    let viewID: UUID?

    @State private var model: ProjectWorkspaceModel?

    var body: some View {
        Group {
            if let model {
                if model.project != nil {
                    content(model)
                } else {
                    EmptyStateView(
                        symbolName: "square.stack.3d.up",
                        headline: "Project not found",
                        message: "It may have been deleted. Choose another from the sidebar."
                    )
                }
            } else {
                // Loading, not missing. This branch is on screen for however long the model takes
                // to walk the project — a moment on a small library, visibly long on a big one —
                // and it used to say "Project not found" for all of it.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading")
            }
        }
        // On the `Group`, NOT on `content`. The workspace's first frame renders before `start()`
        // has built the model, and on that frame the other branch is on screen. When the toolbar
        // lived on `content`, that frame declared no title at all — so the window's toolbar
        // collapsed to its title-less height, the sidebar rode up into the title-bar space, and
        // AppKit did not always give the inset back once the title arrived. That one frame is the
        // sidebar "jump" this window had on every entry into a project.
        .navigationTitle(model?.project?.title ?? "Project")
        .navigationSubtitle(subtitle)
        .searchable(
            text: searchBinding,
            placement: .toolbar,
            prompt: "Search this project"
        )
        .task(id: projectID) { start() }
        .onChange(of: viewID) { _, newValue in
            guard let model, let newValue else { return }
            model.selectView(newValue)
        }

        .onChange(of: services?.changeToken) { _, _ in
            // Without this, work captured into the open project from Quick Jot does not appear until
            // the project is left and re-entered — the workspace was only reloading on a project or
            // tab change, which are the two things that did *not* happen.
            model?.refresh()
        }
        .onDisappear {
            navigation.projectWorkspace = nil
        }
    }

    private func start() {
        guard let services else { return }
        let fresh = ProjectWorkspaceModel(services: services)
        fresh.load(projectID: projectID, viewID: viewID)
        model = fresh
        // The shell asks *this* to decide whether an inspector exists at all. A `@FocusedValue`
        // reaches the pane's contents but not that decision, which is how a project's work became
        // uneditable: `hidesWhenNothingSelected` kept the pane permanently shut.
        navigation.projectWorkspace = fresh
    }

    @ViewBuilder
    private func content(_ model: ProjectWorkspaceModel) -> some View {
        VStack(spacing: 0) {
            ProjectWorkspaceHeader(model: model)
            ProjectViewTabBar(model: model, navigation: navigation, projectID: projectID)
            Divider()
            if model.activeView?.kind == .bugs {
                ProjectBugAddBar(model: model)
                Divider()
            }
            body(for: model)
        }
        // The keyboard the workspace always claimed to have. Every handler goes through
        // ``ProjectWorkspaceModel/guarded(_:)`` so none of them fires while a title or the sheet
        // has the keyboard — the gate that was built for exactly these and then never used.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            model.guarded { model.moveFocus(by: -1) } ? .handled : .ignored
        }
        .onKeyPress(.downArrow) {
            model.guarded { model.moveFocus(by: 1) } ? .handled : .ignored
        }
        .onKeyPress(.return) {
            guard let id = model.focusedItemID ?? model.selectedItemIDs.first else { return .ignored }
            return model.guarded { model.present(id) } ? .handled : .ignored
        }
        .onDeleteCommand {
            _ = model.guarded { model.moveSelectionToTrash() }
        }
        // The Move to Trash menu command (⌘⌫), which was dead in the one module where work is
        // managed most. Published the same way every list publishes it.
        .focusedSceneValue(
            \.rowActions,
            RowActions(isEnabled: !model.selectedItemIDs.isEmpty) { [weak model] in
                model?.moveSelectionToTrash()
            }
        )
        .sheet(item: presented(model)) { presentation in
            WorkItemDetailView(item: presentation.item, model: model)
        }
    }

    @ViewBuilder
    private func body(for model: ProjectWorkspaceModel) -> some View {
        if model.isEmpty {
            ProjectEmptyState(model: model)
        } else if model.hasNoMatches {
            ProjectNoMatchesState(model: model)
        } else {
            switch model.activeView?.kind ?? .list {
            case .board:
                KanbanBoardView(model: model)
            case .table:
                WorkItemTableView(model: model)
            case .calendar:
                ProjectCalendarView(model: model)
            case .timeline:
                ProjectTimelineView(model: model)
            case .overview:
                ProjectOverviewView(model: model)
            case .list, .bugs:
                // One view for both, deliberately: they are the same rows under different
                // groupings — a bug view is the list with severity leading — and two copies is
                // how they would drift apart.
                WorkItemListView(model: model)
            }
        }
    }

    /// The toolbar's second line: the project key and the round figure, when either exists.
    ///
    /// This is where "EA" went. As a monospaced badge beside the title it read as clutter —
    /// three names stacked at the top of every project — and as a subtitle it is what a subtitle
    /// is for: present, quiet, and out of the title's way.
    private var subtitle: String {
        guard let model else { return "" }
        var parts: [String] = []
        if let key = model.project?.projectKey {
            parts.append(key)
        }
        if model.health.completionFraction != nil {
            parts.append("\(model.health.completedWork) of \(model.health.totalWork) done")
        }
        return parts.joined(separator: " — ")
    }

    /// The toolbar search field, folded into the arrangement as a transient rule.
    ///
    /// The model always knew how to search — ``ProjectWorkspaceModel/searchText`` was folded into
    /// every arrangement — but nothing on screen wrote to it. This is the field that does.
    private var searchBinding: Binding<String> {
        Binding(
            get: { model?.searchText ?? "" },
            set: { newValue in
                guard let model, model.searchText != newValue else { return }
                model.searchText = newValue
                model.rearrange()
            }
        )
    }

    /// The sheet's binding.
    ///
    /// Wrapped in an `Identifiable` box because `.sheet(item:)` needs one, and reading the item
    /// through the model means a deletion closes the sheet rather than leaving it over a ghost.
    private func presented(_ model: ProjectWorkspaceModel) -> Binding<PresentedWorkItem?> {
        Binding(
            get: { model.presentedItem.map(PresentedWorkItem.init) },
            set: { if $0 == nil { model.dismissPresentedItem() } }
        )
    }
}

/// The direct filing path for a project's Bugs view.
///
/// A bug view that can only receive work through global Quick Jot is a report, not a workspace.
/// Keeping this above both the populated list and its empty state also means the first bug is no
/// harder to add than the fiftieth.
struct ProjectBugAddBar: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: ItemKind.bug.symbolName)
                .foregroundStyle(Theme.Colors.warning)
                .accessibilityHidden(true)
            QuickAddRow(placeholder: "Add a bug", model: model, onCommit: add)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.bugs.add")
    }

    private func add(_ title: String) {
        guard let services, let project = model.project else { return }
        guard let bug = try? services.workItems.createWorkItem(
            title: title,
            kind: .bug,
            in: project
        ) else { return }

        services.noteChange(to: bug)
        model.refresh()
        model.select(bug.id)
        model.present(bug.id)
    }
}

/// A work item on its way into a sheet.
struct PresentedWorkItem: Identifiable {
    let item: Item
    var id: UUID { item.id }
}

// MARK: - Header

/// The concerns line, and nothing else.
///
/// The name, the key, and the progress figure all used to be here too, stacked under the window
/// title's fallback — three lines saying where you are before the tabs said what you're looking
/// at. The name is the window title now, the key and the figure are its subtitle, and what remains
/// is the one thing the toolbar cannot carry: the sentences about what needs attention.
struct ProjectWorkspaceHeader: View {
    let model: ProjectWorkspaceModel

    var body: some View {
        if !model.health.concerns.isEmpty {
            // Sentences, not a row of counters. A dashboard of eleven figures where eight read
            // zero is one people stop looking at.
            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.tight) {
                ForEach(model.health.concerns.prefix(3)) { concern in
                    ProjectConcernRow(concern: concern, model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.small)
        }
    }
}

// MARK: - Tab bar

struct ProjectViewTabBar: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel
    let navigation: NavigationModel
    let projectID: UUID

    @State private var pendingRemoval: ProjectViewRecord?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(model.views) { view in
                    tab(view)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "Remove “\(pendingRemoval?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { confirmRemoval() }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            // Names the consequence, which for a view is smaller than it looks: a view is a way of
            // looking, and none of the work in the project goes with it.
            Text("The view's configuration is lost. The work it shows stays in the project.")
        }
    }

    private func tab(_ view: ProjectViewRecord) -> some View {
        let isActive = model.activeView?.id == view.id
        return Button {
            model.selectView(view.id)
            navigation.select(.project(id: projectID, viewID: view.id))
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: view.displaySymbolName)
                    // Coloured per kind, for the reason People colours a phone apart from an email:
                    // seven identical grey glyphs are read by their labels, which means read slowly.
                    .foregroundStyle(tint(view))
                Text(view.name)
            }
            .font(Theme.Text.rowTitle)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(isActive ? tint(view).opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.view.\(view.kind.rawValue)")
        .contextMenu {
            Button("Duplicate") { duplicate(view) }
            if model.views.count > 1 {
                Button("Remove…", role: .destructive) { pendingRemoval = view }
            } else {
                // Disabled with its reason in the label, because a context menu has nowhere else
                // to put one — and the old silent path clicked, failed the service's last-view
                // guard, and did nothing at all.
                Button("Remove (the last view stays)") {}.disabled(true)
            }
        }
    }

    private func tint(_ view: ProjectViewRecord) -> Color {
        Theme.Palette.color(named: view.kind.colorName, neutral: Theme.Colors.secondaryText)
    }

    private func duplicate(_ view: ProjectViewRecord) {
        _ = try? services?.projectWorkspace.duplicateView(view)
        model.refresh()
    }

    private func confirmRemoval() {
        defer { pendingRemoval = nil }
        guard let view = pendingRemoval else { return }
        _ = try? services?.projectWorkspace.removeView(view)
        model.refresh()
    }
}

// MARK: - Empty states

struct ProjectEmptyState: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        EmptyStateView(
            symbolName: "square.stack.3d.up",
            headline: "Nothing here yet",
            message: "Add the first piece of work, or capture one with ⌘⇧N and tag it to this project.",
            tone: .neutral
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectNoMatchesState: View {
    let model: ProjectWorkspaceModel

    var body: some View {
        // Offers to widen rather than to add. A filtered view with nothing in it is not an empty
        // project, and offering to create work is what turns an empty state into a dead end.
        EmptyStateView(
            symbolName: "line.3.horizontal.decrease.circle",
            headline: "Nothing matches",
            message: "There is work in this project, but none of it matches what this view is showing."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
