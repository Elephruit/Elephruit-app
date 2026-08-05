import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI
import UniformTypeIdentifiers

/// The board, with real columns — the presentation the phone honestly could not hold.
///
/// Columns scroll horizontally when the project has more than the stage fits; each column scrolls
/// its own cards. A drag between columns calls the same
/// `ProjectWorkspaceService.move(_:to:after:before:)` every other surface calls, so the two-axis
/// rules hold whatever the input: dropping into a terminal column completes, dragging finished
/// work back out reopens, and a move between two open columns writes no status at all.
///
/// The keyboard-and-touch equal of every drag is the same command in the card's context menu. A
/// drag is never the only way to move something, because a drag is not available to everybody.
struct PadProjectBoard: View {
    @Environment(\.services) private var services

    let project: Item
    var open: (UUID) -> Void

    private static let columnWidth: CGFloat = 300

    /// Stages and work, read on change rather than on every render — a board asks the store for
    /// its columns once per card otherwise.
    @State private var stages: [WorkflowStage] = []
    @State private var work: [Item] = []

    var body: some View {
        Group {
            if stages.isEmpty {
                EmptyStateView(
                    symbolName: "rectangle.split.3x1",
                    headline: "No stages yet",
                    message: "Add work below and the board sets itself up."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        // Leading, not trailing: unplaced work is what the board is *for* —
                        // something to pick up and put somewhere. Past three columns and off the
                        // right edge is where work goes to be forgotten.
                        unplacedColumn

                        ForEach(stages, id: \.id) { stage in
                            PadBoardColumn(
                                stage: stage,
                                items: work
                                    .filter { $0.workflowStageID == stage.id }
                                    .sorted { $0.boardOrder < $1.boardOrder },
                                project: project,
                                stages: stages,
                                open: open
                            )
                            .frame(width: Self.columnWidth)
                        }
                    }
                    .padding(Theme.Spacing.large)
                }
            }
        }
        .task(id: reloadKey) { reload() }
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(project.id.uuidString)"
    }

    private func reload() {
        guard let services else { return }
        stages = services.projectWorkspace.stages(in: project)
        work = project.descendantWork().filter(\.isActive)
    }

    /// Work in no column — drawn, not hidden, because nothing stops at the boundary of what is
    /// placed. Dropping it on a stage files it like any other move.
    @ViewBuilder
    private var unplacedColumn: some View {
        let stageIDs = Set(stages.map(\.id))
        let unplaced = work.filter { item in
            item.workflowStageID.map { !stageIDs.contains($0) } ?? true
        }
        if !unplaced.isEmpty {
            PadBoardColumn(
                stage: nil,
                items: unplaced,
                project: project,
                stages: stages,
                open: open
            )
            .frame(width: Self.columnWidth)
        }
    }
}

/// One column: a header that counts, and the cards in board order.
private struct PadBoardColumn: View {
    @Environment(\.services) private var services

    /// `nil` for the unplaced column.
    let stage: WorkflowStage?
    let items: [Item]
    let project: Item
    let stages: [WorkflowStage]
    var open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    ForEach(items) { item in
                        PadBoardCard(item: item, project: project, stages: stages, open: open)
                            .dropDestination(for: DraggedWorkItem.self) { dragged, _ in
                                _ = drop(dragged, before: item)
                            }
                    }

                    // The column's own body is a drop target even when empty — an empty column is
                    // somewhere to drop something; it is the column you were reaching for.
                    Color.clear
                        .frame(height: items.isEmpty ? 160 : 60)
                        .dropDestination(for: DraggedWorkItem.self) { dragged, _ in
                            _ = drop(dragged, before: nil)
                        }
                }
                .padding(.bottom, Theme.Spacing.section)
            }
        }
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
        .accessibilityIdentifier("pad.board.column.\(stage?.id.uuidString ?? "unplaced")")
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if let colorName = stage?.colorName {
                Circle()
                    .fill(Theme.Palette.color(named: colorName))
                    .frame(width: 8, height: 8)
            }
            Text(stage?.name ?? "Unplaced")
                .font(Theme.Text.rowTitleEmphasised)
            Text("\(items.count)")
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)

            if let stage, stage.wipLimit > 0, items.count >= stage.wipLimit {
                // Reported, never enforced: a board that refuses a drop does not reduce work in
                // progress; it moves it somewhere the board cannot see.
                Text(items.count > stage.wipLimit ? "over limit" : "at limit")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.tight)
        .accessibilityElement(children: .combine)
    }

    /// One drop, wherever it landed in this column.
    private func drop(_ dragged: [DraggedWorkItem], before successor: Item?) -> Bool {
        guard let services, let first = dragged.first,
            let item = try? services.items.item(id: first.id)
        else { return false }

        let predecessor: Item? = {
            guard let successor, let index = items.firstIndex(of: successor), index > 0
            else { return successor == nil ? items.last : nil }
            return items[index - 1]
        }()

        services.perform {
            _ = try services.projectWorkspace.move(
                item,
                to: stage,
                after: predecessor,
                before: successor
            )
            services.noteChange(to: item)
        }
        return true
    }
}

/// One card: the work, its key, and what matters about it — never colour alone.
private struct PadBoardCard: View {
    @Environment(\.services) private var services
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    let item: Item
    let project: Item
    let stages: [WorkflowStage]
    var open: (UUID) -> Void

    var body: some View {
        Button {
            open(item.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(item.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .strikethrough(item.status == .completed, color: Theme.Colors.tertiaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                HStack(spacing: Theme.Spacing.small) {
                    if let key = item.referenceKey {
                        Text(key)
                            .font(Theme.Text.keyHint)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    if item.kind == .bug, let severity = item.bugRecord?.severity {
                        Label(severity.displayName, systemImage: "ant")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(severityColor(severity))
                    }

                    if let due = item.dueAt, let clock = services?.dateProvider {
                        Text(due, format: .dateTime.day().month(.abbreviated))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(DateUrgency.color(for: due, using: clock))
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.contentBackground)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .draggable(DraggedWorkItem(id: item.id)) {
            // A quiet preview: the title on a card, not the whole subtree.
            Text(item.displayTitle)
                .font(Theme.Text.rowTitle)
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(Theme.Colors.contentBackground)
                )
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") { open(item.id) }
            if supportsMultipleWindows {
                Button("Open in New Window", systemImage: "rectangle.badge.plus") {
                    openWindow(value: MobileRoute.item(item.id))
                }
            }
            moveMenu
            Button("Start Timer", systemImage: "play.circle") {
                services?.timer.switchTo(item: item, project: project)
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                guard let services else { return }
                let id = item.id
                services.perform {
                    try services.items.moveToTrash(item)
                    services.noteRemoval(of: id)
                }
            }
        }
        .accessibilityIdentifier("pad.board.card.\(item.id.uuidString)")
    }

    /// The drag's keyboard-and-touch equal: the same move, as a named command.
    @ViewBuilder
    private var moveMenu: some View {
        if !stages.isEmpty, let services {
            Menu {
                ForEach(stages, id: \.id) { stage in
                    Button(stage.name) {
                        services.perform {
                            _ = try services.projectWorkspace.move(item, to: stage)
                            services.noteChange(to: item)
                        }
                    }
                }
            } label: {
                Label("Move to Stage", systemImage: "rectangle.split.3x1")
            }
        }
    }

    private func severityColor(_ severity: BugSeverity) -> Color {
        Theme.Palette.color(named: severity.colorName, neutral: Theme.Colors.secondaryText)
    }
}

/// What a board drag carries: the identity, nothing else.
struct DraggedWorkItem: Codable, Hashable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .elephruitWorkItem)
    }
}

extension UTType {
    /// A private type, because a work item dragged inside the app is a move and not an export —
    /// dropping it in another app should do nothing rather than paste a UUID.
    static let elephruitWorkItem = UTType(exportedAs: "com.elephruit.workitem")
}
