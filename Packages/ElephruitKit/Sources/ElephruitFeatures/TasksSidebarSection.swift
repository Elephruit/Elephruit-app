import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Tasks band of the sidebar.
///
/// ### Why the system views are not all at the same weight
/// Nine destinations at equal weight is a menu, and a menu is what you read when you do not know
/// where you are going. Four of these answer a question you have every day — what needs me now, what
/// did I choose, what is coming, where does this go — and the rest answer questions you have
/// occasionally. So Today, Upcoming, Inbox, and Anytime are always visible, and Someday, Flagged,
/// Waiting, the Logbook, and All Tasks live behind a disclosure that remembers whether you opened it.
///
/// Counts appear on exactly two rows. A number beside every destination turns a sidebar into a
/// scoreboard, and a scoreboard is what this app has decided not to be.
public struct TasksSidebarSection: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel

    init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    @SceneStorage("sidebar.tasks.more") private var isMoreExpanded = false
    @SceneStorage("sidebar.tasks.lists") private var isListsExpanded = true
    @SceneStorage("sidebar.tasks.smart") private var isSmartExpanded = false

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    /// The four that earn a permanent row.
    private static let primaryViews: [TaskSystemView] = [.today, .upcoming, .inbox, .anytime]

    /// The rest, one step quieter.
    private static let secondaryViews: [TaskSystemView] = [
        .someday, .flagged, .waiting, .completed, .all,
    ]

    public var body: some View {
        Section {
            ForEach(Self.primaryViews, id: \.self) { view in
                systemRow(view)
            }

            DisclosureGroup(isExpanded: $isMoreExpanded) {
                ForEach(Self.secondaryViews, id: \.self) { view in
                    systemRow(view)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .frame(minHeight: rowHeight)
                    .help("Someday, Flagged, Waiting, and the log of what you have finished")
            }

            containersDisclosure
            smartListsDisclosure
        } header: {
            Text("Tasks")
        }
    }

    // MARK: - Rows

    private func systemRow(_ view: TaskSystemView) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: view.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .accessibilityHidden(true)

            Text(view.title)
                .lineLimit(1)

            Spacer(minLength: 0)

            if view.showsCount, let count = badge(for: view), count > 0 {
                Text("\(count)")
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .rowForeground(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: rowHeight)
        .hoverHighlight(
            isEnabled: navigation.selection != .taskView(view),
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(SidebarSelection.taskView(view))
        .help(view.hint)
        .accessibilityIdentifier("sidebar.tasks.\(view.rawValue)")
        .accessibilityLabel(accessibilityLabel(for: view))
        .accessibilityHint(view.hint)
    }

    /// Areas, projects, and lists, in the user's own hierarchy.
    ///
    /// Areas are shown at the top level with their contents indented, because "where does this
    /// belong" is answered by the shape of the tree and not by a flat list of every container the
    /// user has ever made.
    @ViewBuilder
    private var containersDisclosure: some View {
        let rows = containerRows()
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: $isListsExpanded) {
                ForEach(rows) { row in
                    containerRow(row)
                }
            } label: {
                Label("Areas & Projects", systemImage: "square.grid.2x2")
                    .frame(minHeight: rowHeight)
                    .help("Your own organisation: standing responsibilities, work with an end, and plain lists")
            }
        }
    }

    private func containerRow(_ row: ContainerRow) -> some View {
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
            isEnabled: navigation.selection != .item(id: row.id),
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(SidebarSelection.item(id: row.id))
        .help(row.title)
        .accessibilityIdentifier("sidebar.container.\(row.id.uuidString)")
        .accessibilityLabel(row.title)
    }

    @ViewBuilder
    private var smartListsDisclosure: some View {
        DisclosureGroup(isExpanded: $isSmartExpanded) {
            ForEach(BuiltInSmartList.all) { list in
                smartRow(
                    title: list.title,
                    symbolName: list.symbolName,
                    hint: list.hint,
                    selection: .builtInSmartList(id: list.id)
                )
            }

            ForEach(savedSmartLists(), id: \.id) { saved in
                smartRow(
                    title: saved.displayName,
                    symbolName: saved.effectiveSymbolName,
                    hint: "A list you built. Membership is worked out each time you open it.",
                    selection: .smartList(id: saved.id)
                )
            }
        } label: {
            Label("Smart Lists", systemImage: "line.3.horizontal.decrease.circle")
                .frame(minHeight: rowHeight)
                .help("Lists whose contents are worked out rather than filed. Nothing here owns a task.")
        }
    }

    private func smartRow(
        title: String,
        symbolName: String,
        hint: String,
        selection: SidebarSelection
    ) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(minHeight: rowHeight)
        .hoverHighlight(
            isEnabled: navigation.selection != selection,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(selection)
        .help(hint)
        .accessibilityIdentifier(selection.accessibilityIdentifier)
        .accessibilityLabel(title)
    }

    // MARK: - Data

    /// A container as the sidebar draws it.
    public struct ContainerRow: Identifiable, Hashable {
        public var id: UUID
        public var title: String
        public var symbolName: String
        public var colorName: String?
        public var depth: Int
        /// `nil` where progress would be meaningless — an area, or a list.
        public var progress: Double?

        public init(
            id: UUID,
            title: String,
            symbolName: String,
            colorName: String? = nil,
            depth: Int = 0,
            progress: Double? = nil
        ) {
            self.id = id
            self.title = title
            self.symbolName = symbolName
            self.colorName = colorName
            self.depth = depth
            self.progress = progress
        }
    }

    /// Reads what the sidebar model already computed.
    ///
    /// No store access happens while rendering; this walks values held on `TaskSidebarModel`, which
    /// recomputes on change. That is criterion A1-1 and `FetchAudit` is what proves it.
    private func containerRows() -> [ContainerRow] {
        services?.taskSidebar.containers ?? []
    }

    private func savedSmartLists() -> [SavedSearch] {
        services?.taskSidebar.smartLists ?? []
    }

    private func badge(for view: TaskSystemView) -> Int? {
        services?.taskSidebar.badges[view]
    }

    private func accessibilityLabel(for view: TaskSystemView) -> String {
        guard view.showsCount, let count = badge(for: view), count > 0 else { return view.title }
        return "\(view.title), \(count) items"
    }
}

/// A project's progress, as a dot rather than a bar.
///
/// ### Why this is the smallest thing that could work
/// A percentage is a productivity metric, and a bar beside every project in a sidebar is a wall of
/// them. What the user actually wants to know at a glance is "is this one nearly done?", and a ring
/// that fills answers it in the width of a glyph. The exact figure is available in the project
/// itself, where there is room for it to be read rather than compared.
struct ProjectProgressDot: View {
    let progress: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.02, min(progress, 1)))
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 10, height: 10)
            .rowForeground(.tertiary)
            .accessibilityHidden(true)
            .help(progressDescription)
    }

    private var progressDescription: String {
        let percent = Int((progress * 100).rounded())
        return percent >= 100 ? "Every task done" : "\(percent)% of tasks done"
    }
}
