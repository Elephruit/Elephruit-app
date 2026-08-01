import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The sidebar, once a module has been entered.
///
/// One `List` per module rather than one list with ten conditionals inside it, because the sections
/// a module needs are genuinely different: Tasks has a container tree and smart lists, People has
/// scopes and groups, Calendar has views and calendar sets. What they share — the list style, the
/// selection binding, the row geometry — is shared; what differs is written out.
///
/// The modules whose navigation is a single destination say so with one row and stop. A module is
/// not obliged to have a lot in it; Bookmarks genuinely is one list, and inventing three rows to
/// make it look busier would be inventing three claims about the data.
struct ModuleSidebar: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        List(selection: selectionBinding) {
            switch module {
            case .calendar:
                CalendarSidebarSection(navigation: navigation)
            case .tasks:
                TasksSidebarSection(navigation: navigation)
            case .people:
                if PeoplePerformanceIsolation.usesIsolatedSidebar {
                    IsolatedPeopleSidebarSection(navigation: navigation)
                } else {
                    PeopleSidebarSection(navigation: navigation)
                }
            case .notes:
                NotesSidebarSection(navigation: navigation)
            case .time:
                TimeSidebarSection(navigation: navigation)
            case .projects:
                ProjectsSidebarSection(navigation: navigation)
            case .areas:
                AreasSidebarSection(navigation: navigation)
            case .bookmarks, .archive, .trash:
                SingleDestinationSection(module: module, navigation: navigation)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.module.\(module.rawValue).list")
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { navigation.selection },
            set: { newValue in
                guard let newValue else { return }
                navigation.select(newValue)
            }
        )
    }
}

// MARK: - Notes

/// Notes, and the kinds that are notes by every measure this app applies to them.
///
/// Ideas, reference and daily entries are separate rows rather than a filter somebody has to
/// remember, because each is a different question — "what have I half-thought", "what do I look up",
/// "what happened that day" — and each is already a kind the store can answer directly.
struct NotesSidebarSection: View {
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .notes)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }
    }
}

// MARK: - Time

/// Time, and the window it is being read over.
///
/// The window used to be state inside `TimeView`, which meant the only way to change it was a
/// control in the middle column and the sidebar had one row that did nothing. It lives on the
/// navigation model now, so choosing a window here *is* choosing what the report covers — the same
/// arrangement the calendar's view switcher uses.
struct TimeSidebarSection: View {
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .time)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }

        Section("Period") {
            ForEach(TimeWindow.allCases, id: \.self) { window in
                ModeRow(
                    title: window.displayName,
                    symbolName: window.symbolName,
                    hint: window.hint,
                    isOn: navigation.timeWindow == window,
                    identifier: "sidebar.time.window.\(window.rawValue)",
                    rowHeight: rowHeight
                ) {
                    navigation.select(.time)
                    navigation.timeWindow = window
                }
            }
        }

        Section("Grouped By") {
            ForEach(TimeGrouping.allCases, id: \.self) { grouping in
                ModeRow(
                    title: grouping.displayName,
                    symbolName: grouping.symbolName,
                    hint: grouping.hint,
                    isOn: navigation.timeGrouping == grouping,
                    identifier: "sidebar.time.grouping.\(grouping.rawValue)",
                    rowHeight: rowHeight
                ) {
                    navigation.select(.time)
                    navigation.timeGrouping = grouping
                }
            }
        }
    }
}

// MARK: - Projects and Areas

/// Every project, then the ones the user actually made.
///
/// The rows come from `TaskSidebarModel`, which already computes the container tree for the Tasks
/// module. Reading it here rather than fetching again is what keeps "no store access while
/// rendering" true, and means a project renamed in one module is renamed in both.
struct ProjectsSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .projects)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }

        if !rows.isEmpty {
            Section("Yours") {
                ForEach(rows) { row in
                    ContainerSidebarRow(
                        row: row,
                        isSelected: navigation.selection == .item(id: row.id),
                        rowHeight: rowHeight
                    )
                }
            }
        }
    }

    /// Projects and lists, with their area shown as an inset rather than repeated on every row.
    private var rows: [TasksSidebarSection.ContainerRow] {
        (services?.taskSidebar.containers ?? []).filter { $0.kind != .area }
    }
}

/// Standing responsibilities, and what is inside each of them.
struct AreasSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .areas)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }

        if !rows.isEmpty {
            Section("Yours") {
                ForEach(rows) { row in
                    ContainerSidebarRow(
                        row: row,
                        isSelected: navigation.selection == .item(id: row.id),
                        rowHeight: rowHeight
                    )
                }
            }
        }
    }

    private var rows: [TasksSidebarSection.ContainerRow] {
        services?.taskSidebar.containers ?? []
    }
}

// MARK: - One-destination modules

/// Bookmarks, Archive and Trash, each of which genuinely is one list.
///
/// The Trash carries the one action that belongs beside it rather than in a menu three levels away,
/// and it is the one action in this app that cannot be undone — so it asks first, and says why.
struct SingleDestinationSection: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight
    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true
    @State private var isConfirmingEmpty = false

    var body: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: module)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }

            if module == .trash {
                Button("Empty Trash…", systemImage: "xmark.bin") {
                    if confirmBeforeEmptyingTrash {
                        isConfirmingEmpty = true
                    } else {
                        emptyTrash()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(minHeight: rowHeight)
                .hoverHighlight(
                    cornerRadius: SidebarMetrics.selectionRadius,
                    extending: SidebarMetrics.selectionInset
                )
                .help("Removes everything in the Trash. This cannot be undone.")
                .accessibilityIdentifier("sidebar.trash.empty")
                .confirmationDialog(
                    "Empty the Trash?",
                    isPresented: $isConfirmingEmpty
                ) {
                    Button("Empty Trash", role: .destructive) { emptyTrash() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Everything in the Trash is removed permanently. This cannot be undone.")
                }
            }
        }
    }

    private func emptyTrash() {
        guard let services else { return }
        services.perform { try services.items.emptyTrash() }
        navigation.selectItem(nil)
        Task { await services.warmSearchIndex() }
    }
}

// MARK: - Shared rows

/// A container — an area, a project, or a list — as a sidebar row.
struct ContainerSidebarRow: View {
    let row: TasksSidebarSection.ContainerRow
    var isSelected: Bool
    var rowHeight: CGFloat

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: row.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .rowTint(row.colorName == nil ? Theme.Colors.secondaryText : Theme.Palette.color(named: row.colorName))
                .accessibilityHidden(true)

            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Progress, and only where it means something. A list never finishes, so a figure
            // against one would be a number with no destination.
            if let progress = row.progress {
                ProjectProgressDot(progress: progress)
            }
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(row.depth) * Theme.Spacing.medium)
        .hoverHighlight(
            isEnabled: !isSelected,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(SidebarSelection.item(id: row.id))
        .help(row.title)
        .accessibilityIdentifier("sidebar.container.\(row.id.uuidString)")
        .accessibilityLabel(row.title)
    }
}

/// A row that turns a mode on rather than selecting a destination.
///
/// Calendar views, time windows and groupings are all this shape: the destination does not change,
/// the way it is drawn does. A checkmark rather than the list's selection fill, because the list's
/// selection already means something else on the rows above.
struct ModeRow: View {
    let title: String
    let symbolName: String
    let hint: String
    let isOn: Bool
    let identifier: String
    let rowHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: symbolName)
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(isOn ? Theme.Colors.selection : Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isOn {
                    Image(systemName: "checkmark")
                        .font(Theme.Text.metadata.weight(.semibold))
                        .foregroundStyle(Theme.Colors.selection)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .help(hint)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
