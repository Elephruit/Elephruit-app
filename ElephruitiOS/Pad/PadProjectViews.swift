import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

// MARK: - List

/// The grouped list: the project's own headings as sections, ungrouped work first.
struct PadProjectList: View {
    @Environment(\.services) private var services

    let project: Item
    var open: (UUID) -> Void

    @State private var ungrouped: [Item] = []
    @State private var groups: [PadHeadingGroup] = []

    var body: some View {
        List {
            if !ungrouped.isEmpty || groups.isEmpty {
                Section {
                    ForEach(ungrouped) { task in
                        PadWorkRow(item: task, project: project, open: open)
                    }
                }
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { task in
                        PadWorkRow(item: task, project: project, open: open)
                    }
                }
            }

            if ungrouped.isEmpty, groups.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: "list.bullet",
                        headline: "Nothing here yet",
                        message: "Add the first piece of work below."
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .task(id: "\(services?.changeToken ?? 0)-\(project.id.uuidString)") { reload() }
    }

    private func reload() {
        ungrouped = project.ungroupedTasks().filter(\.isActive)
        groups = project.orderedHeadings().compactMap { heading in
            let items = ((try? services?.items.items(matching: ItemQuery.children(of: heading.id))) ?? [])
                .filter { $0.isActive && $0.kind.isWorkItem }
            guard !items.isEmpty else { return nil }
            return PadHeadingGroup(id: heading.id, title: heading.displayTitle, items: items)
        }
    }
}

/// One heading's work, built once per change rather than fetched from a row's body.
struct PadHeadingGroup: Identifiable {
    let id: UUID
    let title: String
    let items: [Item]
}

// MARK: - Table

/// The table — the presentation a big screen earns.
///
/// Facts in columns, sortable, one row per piece of work. A tap opens the canonical editor; the
/// context menu carries the same commands as everywhere else. Cells state their facts in words:
/// severity is a word here, not a dot.
struct PadProjectTable: View {
    @Environment(\.services) private var services

    let project: Item
    var open: (UUID) -> Void

    @State private var selection: Set<PadWorkTableRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\PadWorkTableRow.reference)]
    @State private var rows: [PadWorkTableRow] = []

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                Text(row.title)
                    .strikethrough(row.isDone, color: Theme.Colors.tertiaryText)
            }
            // The title is the row; every other column is a fact about it. Without an ideal the
            // table shares the surplus evenly and the one column anybody reads is the one that
            // truncates.
            .width(min: 240, ideal: 460)

            TableColumn("Key", value: \.reference) { row in
                Text(row.reference)
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Stage", value: \.stage)
                .width(min: 90, ideal: 120)

            TableColumn("Severity", value: \.severity)
                .width(min: 80, ideal: 100)

            TableColumn("Due", value: \.dueDescription)
                .width(min: 90, ideal: 110)

            TableColumn("Status", value: \.status)
                .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: PadWorkTableRow.ID.self) { ids in
            if let id = ids.first {
                Button("Open", systemImage: "arrow.up.forward.square") { open(id) }
                Button("Move to Trash", systemImage: "trash", role: .destructive) { trash(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        .task(id: "\(services?.changeToken ?? 0)-\(project.id.uuidString)") { reload() }
    }

    private func reload() {
        guard let services else { return }
        let stages = services.projectWorkspace.stages(in: project)
        let stageNames = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.name) })

        rows = project.descendantWork().filter(\.isActive).map { item in
            PadWorkTableRow(
                id: item.id,
                title: item.displayTitle,
                reference: item.referenceKey ?? "",
                stage: item.workflowStageID.flatMap { stageNames[$0] } ?? "—",
                severity: item.kind == .bug ? (item.bugRecord?.severity.displayName ?? "Minor") : "—",
                dueDescription: item.dueAt.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "—",
                status: item.status.displayName,
                isDone: item.status == .completed
            )
        }
    }

    private func trash(_ id: UUID) {
        guard let services, let item = try? services.items.item(id: id) else { return }
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
    }
}

/// One table row's facts, flattened so sorting is a value comparison rather than a fetch.
struct PadWorkTableRow: Identifiable, Hashable {
    let id: UUID
    let title: String
    let reference: String
    let stage: String
    let severity: String
    let dueDescription: String
    let status: String
    let isDone: Bool
}

// MARK: - Bugs

/// The bug queue, in severity bands, worst first.
struct PadProjectBugs: View {
    @Environment(\.services) private var services

    let project: Item
    var open: (UUID) -> Void

    @State private var awaiting: [Item] = []
    @State private var bands: [PadSeverityBand] = []

    var body: some View {
        List {
            if !awaiting.isEmpty {
                Section("Awaiting verification") {
                    ForEach(awaiting) { bug in
                        PadWorkRow(item: bug, project: project, open: open)
                    }
                }
            }

            ForEach(bands) { band in
                Section {
                    ForEach(band.bugs) { bug in
                        PadWorkRow(item: bug, project: project, open: open)
                    }
                } header: {
                    // The band names the severity; the row need not repeat it. A word and a
                    // count — never a colour alone.
                    HStack {
                        Text(band.title)
                        Text("\(band.bugs.count)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }

            if bands.isEmpty, awaiting.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: "ant",
                        headline: "No open bugs",
                        message: "File one below when something breaks.",
                        tone: .accomplished
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .task(id: "\(services?.changeToken ?? 0)-\(project.id.uuidString)") { reload() }
    }

    private func reload() {
        guard let services else { return }
        awaiting = services.bugs.awaitingVerification(in: project)
        let open = services.bugs.openBugs(in: project)
        let grouped = Dictionary(grouping: open) { $0.bugRecord?.severity ?? .minor }
        bands = [BugSeverity.critical, .major, .minor, .cosmetic].compactMap { severity in
            guard let bugs = grouped[severity], !bugs.isEmpty else { return nil }
            return PadSeverityBand(id: severity.rawValue, title: severity.displayName, bugs: bugs)
        }
    }
}

/// One severity's open bugs.
struct PadSeverityBand: Identifiable {
    let id: String
    let title: String
    let bugs: [Item]
}

// MARK: - Overview

/// Standing back: what the project is, how it is going, and what rides along.
struct PadProjectOverview: View {
    @Environment(\.services) private var services

    let project: Item
    var open: (UUID) -> Void

    @State private var markers: [Item] = []
    @State private var filed: [Item] = []

    var body: some View {
        List {
            if !project.body.isEmpty {
                Section("Brief") {
                    Text(project.body)
                        .font(Theme.Text.rowSubtitle)
                }
            }

            if !markers.isEmpty {
                Section("Milestones & releases") {
                    ForEach(markers) { marker in
                        PadWorkRow(item: marker, project: project, open: open)
                    }
                }
            }

            if !filed.isEmpty {
                Section("Project notes") {
                    ForEach(filed) { note in
                        PadWorkRow(item: note, project: project, open: open)
                    }
                }
            }

            if markers.isEmpty, filed.isEmpty, project.body.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: ProjectViewKind.overview.symbolName,
                        headline: "Nothing to stand back from yet",
                        message: "Milestones, releases, and filed notes appear here."
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .task(id: "\(services?.changeToken ?? 0)-\(project.id.uuidString)") { reload() }
    }

    private func reload() {
        markers = project.planningMarkers().filter(\.isActive)
        filed = project.filedItems().filter { $0.isActive && !$0.kind.isWorkItem }
    }
}

// MARK: - Rows

/// One piece of work in any of the project's list-shaped views.
///
/// The same anatomy as every other row in this app, plus the reference key — and the same
/// canonical commands from the context menu and the swipe, so no presentation has private
/// behaviour.
struct PadWorkRow: View {
    @Environment(\.services) private var services
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    let item: Item
    let project: Item
    var open: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            MobileItemRow(
                item: item,
                // The workspace already names the project; a row repeating it is the list
                // stuttering.
                showsParent: false,
                onToggleCompletion: completionAction
            )

            if let key = item.referenceKey {
                Text(key)
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(item.id) }
        .hoverEffect(.highlight)
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") { open(item.id) }
            if supportsMultipleWindows {
                Button("Open in New Window", systemImage: "rectangle.badge.plus") {
                    openWindow(value: MobileShellModel.route(for: item.kind, id: item.id))
                }
            }
            stageMenu
            Button("Start Timer", systemImage: "play.circle") {
                services?.timer.switchTo(item: item, project: project)
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { trash() }
        }
        .swipeActions(edge: .trailing) {
            Button {
                trash()
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .tint(Theme.Colors.destructive)
        }
        .accessibilityIdentifier("pad.work.row.\(item.id.uuidString)")
    }

    @ViewBuilder
    private var stageMenu: some View {
        if let services, item.kind.isWorkItem {
            let stages = services.projectWorkspace.stages(in: project)
            if !stages.isEmpty {
                Menu {
                    ForEach(stages, id: \.id) { stage in
                        Button(stage.name) {
                            act { _ = try $0.projectWorkspace.move(item, to: stage) }
                        }
                    }
                } label: {
                    Label("Move to Stage", systemImage: "rectangle.split.3x1")
                }
            }
        }
    }

    /// Present only where the leading control means completion — a note filed under a project has
    /// no status, and a circle beside it would be a control that does nothing.
    private var completionAction: (() -> Void)? {
        guard item.kind.supportsStatus else { return nil }
        return { act { try $0.items.toggleCompletion(item) } }
    }

    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: item)
        }
    }

    private func trash() {
        guard let services else { return }
        let id = item.id
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
    }
}
