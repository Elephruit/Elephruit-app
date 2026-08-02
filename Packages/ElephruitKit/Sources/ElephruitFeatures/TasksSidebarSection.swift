import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What the Tasks sidebar is made of, as data rather than as view code.
///
/// The order of these rows is a product decision — it is the app's answer to "what are the questions
/// somebody asks of their own work, and in what order" — and a product decision that only exists
/// inside a `body` is one that can be changed by accident while moving a `ForEach`. Declared here, it
/// is a value a test can read, which is what ``ElephruitFeaturesTests`` does.
///
/// Containers and smart lists are not here because they are not fixed: one is the user's tree and the
/// other is a list they can add to. What is fixed is the three bands above them.
public enum TasksSidebarComposition {
    /// The fixed rows, banded, in order. Each band is one `Section`.
    public static let bands: [[SidebarSelection]] = [
        // Unfiled work, alone. It is the only row that is a queue rather than a view: you go here to
        // empty it, and an empty Inbox is the point of it.
        [.taskView(.inbox)],

        // The four that answer *when*, in the order time runs.
        [.taskView(.today), .taskView(.upcoming), .taskView(.anytime), .taskView(.someday)],

        // What is behind you. Both of these are places you go to retrieve something rather than to
        // decide something.
        //
        // The Trash is also its own module — see ``AppModule/trash`` — and stays one, because
        // emptying it is an action that belongs beside a full-width list and not on a sidebar row.
        // This row is the *route* to it, not a second copy of it: selecting it enters that module,
        // the way selecting any row that belongs to another module does.
        [.taskView(.completed), .trash],
    ]

    /// The three system views that stopped being sidebar rows, and the built-in smart list each one
    /// became.
    ///
    /// All three were always rules over the library rather than places in it — "everything I
    /// flagged", "everything somebody else has", "everything". Keeping them as system views cost the
    /// sidebar a disclosure to hide them behind, which is the whole reason *More* existed.
    /// ``ElephruitPersistence/TaskViewService/contents(of:)`` returned a single ungrouped section for
    /// each of them, which is exactly what a smart list draws, so nothing about what a user sees when
    /// they open one has changed.
    ///
    /// The ``TaskSystemView`` cases stay: a scene stored by an earlier build still decodes to one,
    /// and the workspace still draws it.
    public static let demotedViews: [TaskSystemView: String] = [
        .flagged: "flagged",
        .waiting: "waiting",
        .all: "all-tasks",
    ]

    /// What a row says when the pointer rests on it. Never a restatement of the title.
    public static func hint(for selection: SidebarSelection) -> String {
        if let view = selection.taskSystemView { return view.hint }
        switch selection {
        case .trash: return "Deleted tasks, until you empty it."
        default: return ""
        }
    }
}

/// The Tasks band of the sidebar.
///
/// ### Four bands, no disclosure
/// The system views used to be split four-and-five, with the five behind a row labelled *More*. That
/// hid Someday — a decision the user made about a task, which they then have to go looking for — and
/// it put a second disclosure affordance thirty points from the one on *Smart Lists*, pointing the
/// other way. Two ways to open something, in one column, is the shape of a control panel.
///
/// So the views are flat, and grouped by what they answer rather than by how often they are asked:
///
/// | Band | Rows | The question |
/// |---|---|---|
/// | 1 | Inbox | What have I not filed? |
/// | 2 | Today, Upcoming, Anytime, Someday | When? |
/// | 3 | Logbook, Trash | What is behind me? |
/// | 4 | Areas and projects | Where does this live? |
/// | 5 | Smart Lists | What matches? |
///
/// Flagged, Waiting and All Tasks are gone from the system views and are ``BuiltInSmartList``s
/// instead, because that is what all three always were: a rule over the library rather than a place
/// in it. Nothing about their contents changed — ``ElephruitPersistence/TaskViewService`` already
/// returned a single ungrouped section for each of them, which is exactly what a smart list draws.
///
/// The container tree has no header. A header would name what the tree already says, and the tree is
/// the one band whose contents the user built themselves. Smart Lists keeps its disclosure, and is
/// now the only one in the column.
///
/// Counts appear on exactly two rows. A number beside every destination turns a sidebar into a
/// scoreboard, and a scoreboard is what this app has decided not to be.
public struct TasksSidebarSection: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel

    init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    @SceneStorage("sidebar.tasks.smart") private var isSmartExpanded = false

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    private struct SmartListDeletion {
        let id: UUID
        let name: String
    }

    @State private var pendingSmartListDeletion: SmartListDeletion?

    public var body: some View {
        ForEach(Array(TasksSidebarComposition.bands.enumerated()), id: \.offset) { _, band in
            Section {
                ForEach(band, id: \.self) { selection in
                    row(for: selection)
                }
            }
        }

        containersSection
        smartListsSection
    }

    // MARK: - Rows

    /// A task view draws a badge-aware row; anything else in a band is a plain destination.
    @ViewBuilder
    private func row(for selection: SidebarSelection) -> some View {
        if let view = selection.taskSystemView {
            systemRow(view)
        } else {
            destinationRow(
                title: selection.title,
                symbolName: selection.symbolName,
                hint: TasksSidebarComposition.hint(for: selection),
                selection: selection
            )
        }
    }

    private func systemRow(_ view: TaskSystemView) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: view.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .accessibilityHidden(true)

            Text(view.title)
                .lineLimit(1)

            Spacer(minLength: 0)
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
    ///
    /// Unheaded, and not collapsible. A tree of named containers explains itself, and "Areas &
    /// Projects" over the top of one was a label restating its own contents. Collapsing it hid the
    /// only part of this sidebar the user wrote.
    @ViewBuilder
    private var containersSection: some View {
        let rows = containerRows()
        if !rows.isEmpty {
            Section {
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

    @ViewBuilder
    private var smartListsSection: some View {
        Section("Smart Lists", isExpanded: $isSmartExpanded) {
            ForEach(BuiltInSmartList.all) { list in
                destinationRow(
                    title: list.title,
                    symbolName: list.symbolName,
                    hint: list.hint,
                    selection: .builtInSmartList(id: list.id)
                )
            }

            ForEach(savedSmartLists(), id: \.id) { saved in
                destinationRow(
                    title: saved.displayName,
                    symbolName: saved.effectiveSymbolName,
                    hint: "A list you built. Membership is worked out each time you open it.",
                    selection: .smartList(id: saved.id)
                )
                // The delete a smart list never had — the built-in lists above rightly have none,
                // but one the user made was just as permanent. Confirmed, not trashed: a list is
                // its rules, and the dialog says the tasks stay.
                .contextMenu {
                    Button("Delete Smart List…", role: .destructive) {
                        pendingSmartListDeletion = SmartListDeletion(id: saved.id, name: saved.displayName)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingSmartListDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingSmartListDeletion != nil },
                set: { if !$0 { pendingSmartListDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Smart List", role: .destructive) { confirmSmartListDeletion() }
            Button("Cancel", role: .cancel) { pendingSmartListDeletion = nil }
        } message: {
            Text("The list is only its rules. The tasks it shows stay where they are.")
        }
    }

    private func confirmSmartListDeletion() {
        defer { pendingSmartListDeletion = nil }
        guard let services, let pending = pendingSmartListDeletion else { return }
        services.deleteSavedSearch(id: pending.id)
        if navigation.selection == .smartList(id: pending.id) {
            navigation.select(.taskView(.today))
        }
    }

    private func destinationRow(
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

        /// What the container actually is.
        ///
        /// Carried so the Projects and Areas modules can draw the half of this tree that belongs to
        /// them without inferring it from the symbol, which the user is free to change.
        public var kind: ItemKind

        public init(
            id: UUID,
            title: String,
            symbolName: String,
            colorName: String? = nil,
            depth: Int = 0,
            progress: Double? = nil,
            kind: ItemKind = .project
        ) {
            self.id = id
            self.title = title
            self.symbolName = symbolName
            self.colorName = colorName
            self.depth = depth
            self.progress = progress
            self.kind = kind
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
