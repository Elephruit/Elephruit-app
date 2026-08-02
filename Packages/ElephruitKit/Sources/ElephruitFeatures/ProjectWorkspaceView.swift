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
            if let model, model.project != nil {
                content(model)
            } else {
                EmptyStateView(
                    symbolName: "square.stack.3d.up",
                    headline: "Project not found",
                    message: "It may have been deleted. Choose another from the sidebar."
                )
            }
        }
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
            body(for: model)
        }
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
            default:
                // The list draws every grouped arrangement. The board is the one view whose layout
                // genuinely differs; the rest are the same rows under different groupings, and
                // giving each its own view is how they drift apart.
                WorkItemListView(model: model)
            }
        }
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

/// A work item on its way into a sheet.
struct PresentedWorkItem: Identifiable {
    let item: Item
    var id: UUID { item.id }
}

// MARK: - Header

struct ProjectWorkspaceHeader: View {
    let model: ProjectWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.small) {
                Text(model.project?.title ?? "")
                    .font(Theme.Text.title)

                if let key = model.project?.projectKey {
                    Text(key)
                        .font(Theme.Text.rowSubtitle)
                        .monospaced()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer(minLength: 0)
                progress
            }

            if !model.health.concerns.isEmpty {
                // Sentences, not a row of counters. A dashboard of eleven figures where eight read
                // zero is one people stop looking at.
                ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.tight) {
                    ForEach(model.health.concerns.prefix(3)) { concern in
                        Label(concern.sentence, systemImage: concern.symbolName)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(
                                concern.isUrgent ? Theme.Colors.overdue : Theme.Colors.secondaryText
                            )
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
    }

    /// In words, and absent when there is nothing to describe.
    ///
    /// This is where the progress figure lives, rather than as a ring beside the project's name in
    /// the sidebar — see `ProjectSidebarRow.hasIndicators`.
    @ViewBuilder
    private var progress: some View {
        if let fraction = model.health.completionFraction {
            Text("\(model.health.completedWork) of \(model.health.totalWork) done")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityLabel("\(Int(fraction * 100)) per cent complete")
        }
    }
}

// MARK: - Tab bar

struct ProjectViewTabBar: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel
    let navigation: NavigationModel
    let projectID: UUID

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(model.views) { view in
                    tab(view)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.small)
        }
        .scrollIndicators(.never)
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
            Button("Remove", role: .destructive) { remove(view) }
        }
    }

    private func tint(_ view: ProjectViewRecord) -> Color {
        Theme.Palette(rawValue: view.kind.colorName)?.color ?? Theme.Colors.secondaryText
    }

    private func duplicate(_ view: ProjectViewRecord) {
        _ = try? services?.projectWorkspace.duplicateView(view)
        model.refresh()
    }

    private func remove(_ view: ProjectViewRecord) {
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
