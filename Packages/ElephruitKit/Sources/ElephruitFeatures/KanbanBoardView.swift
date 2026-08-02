import ElephruitCore
import ElephruitDesign
import ElephruitModel
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Columns you drag work between.
///
/// The one view whose layout genuinely differs from the grouped list — everything else is rows under
/// a different grouping. It reads the same `WorkItemArrangement` output as every other view, so a
/// card and a row can never disagree about what is in the project.
struct KanbanBoardView: View {
    let model: ProjectWorkspaceModel

    @State private var drag = KanbanDragCoordinator()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                ForEach(model.groups) { column in
                    KanbanColumnView(column: column, model: model, drag: drag)
                }
            }
            .padding(Theme.Spacing.large)
        }
    }
}

struct KanbanColumnView: View {
    @Environment(\.services) private var services
    let column: WorkItemArrangement.Group
    let model: ProjectWorkspaceModel
    let drag: KanbanDragCoordinator

    private var displayedItems: [TaskFacts] {
        guard drag.isDragging else { return column.items }
        return drag.itemIDs(in: column.key).compactMap { model.item($0)?.taskFacts() }
    }

    private var isDropTargeted: Bool { drag.targetedColumnKey == column.key }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header

            ForEach(displayedItems, id: \.id) { facts in
                KanbanCardView(facts: facts, model: model)
                    .opacity(drag.draggedItemID == facts.id ? 0.32 : 1)
                    .draggable(WorkItemTransfer(id: facts.id)) {
                        KanbanCardView(facts: facts, model: model)
                            .frame(width: 248)
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    }
                    .onDragSessionUpdated { session in
                        switch session.phase {
                        case .initial:
                            drag.begin(
                                itemID: facts.id,
                                columns: Dictionary(
                                    uniqueKeysWithValues: model.groups.map {
                                        ($0.key, $0.items.map(\.id))
                                    }
                                )
                            )
                        case .ended, .dataTransferCompleted:
                            // `performDrop` ends first on a successful move. This is the matching
                            // cancellation path when the pointer is released outside the board.
                            drag.end()
                        case .active:
                            break
                        @unknown default:
                            break
                        }
                    }
                    .onDrop(
                        of: [.elephruitTaskDrag],
                        delegate: KanbanCardDropDelegate(
                            targetID: facts.id,
                            columnKey: column.key,
                            drag: drag,
                            performMove: accept
                        )
                    )
            }

            KanbanColumnEndDropZone(
                isActive: isDropTargeted && drag.isAtEnd(of: column.key)
            )
            .onDrop(
                of: [.elephruitTaskDrag],
                delegate: KanbanEndDropDelegate(
                    columnKey: column.key,
                    drag: drag,
                    performMove: accept
                )
            )

            QuickAddRow(placeholder: "Add to \(column.title)") { title in
                add(title)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.small)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .fill(isDropTargeted ? Theme.Colors.selectionFill : Theme.Colors.subtleFill.opacity(0.45))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(
                    isDropTargeted ? Theme.Colors.selection : Theme.Colors.separator,
                    style: StrokeStyle(
                        lineWidth: isDropTargeted ? 2 : 0.5,
                        dash: isDropTargeted ? [6, 4] : []
                    )
                )
        }
        .overlay(alignment: .bottom) {
            if isDropTargeted {
                Label("Release to move to \(column.title)", systemImage: "arrow.down.to.line")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.tight)
                    .background(Theme.Colors.selection, in: Capsule())
                    .padding(Theme.Spacing.small)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .accessibilityIdentifier("kanban.dropTarget.\(column.key)")
            }
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        .animation(.snappy(duration: 0.12), value: displayedItems.map(\.id))
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(column.title)
                .font(Theme.Text.rowTitleEmphasised)
            Text("\(displayedItems.count)")
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)
            Spacer(minLength: 0)
            if displayedItems.count > column.wipLimit, column.wipLimit > 0 {
                // Said, never enforced. A board that refuses a drop moves the work somewhere the
                // board cannot see it.
                Image(systemName: "arrow.up.and.down.square")
                    .foregroundStyle(Theme.Colors.warning)
                    .help("Over its limit of \(column.wipLimit)")
            }
        }
    }

    private func add(_ title: String) {
        guard let services, let project = model.project else { return }
        let stage = column.stageID.flatMap { id in model.stages.first { $0.id == id } }
        guard let item = try? services.workItems.createWorkItem(
            title: title,
            in: project,
            stage: stage
        ) else { return }
        model.refresh()
        model.beginRenaming(item.id)
    }

    private func accept(_ placement: KanbanPlacement) -> Bool {
        guard let services,
              let item = model.item(placement.itemID)
        else { return false }
        let stage = column.stageID.flatMap { id in model.stages.first { $0.id == id } }
        let predecessor = placement.predecessorID.flatMap(model.item)
        let successor = placement.successorID.flatMap(model.item)
        guard (try? services.projectWorkspace.move(
            item,
            to: stage,
            after: predecessor,
            before: successor
        )) != nil else { return false }
        model.refresh()
        return true
    }
}

/// The live order of a single board drag.
///
/// This state is deliberately in memory until release. Hovering across ten cards should perform
/// ten tiny array moves and zero database writes; only the final placement is persisted.
@MainActor
@Observable
final class KanbanDragCoordinator {
    private(set) var draggedItemID: UUID?
    private(set) var targetedColumnKey: String?
    private(set) var itemIDsByColumn: [String: [UUID]] = [:]

    var isDragging: Bool { draggedItemID != nil }

    func begin(itemID: UUID, columns: [String: [UUID]]) {
        guard draggedItemID != itemID else { return }
        draggedItemID = itemID
        targetedColumnKey = columns.first { $0.value.contains(itemID) }?.key
        itemIDsByColumn = columns
    }

    func itemIDs(in columnKey: String) -> [UUID] {
        itemIDsByColumn[columnKey] ?? []
    }

    /// Moves the ghost card immediately as the pointer crosses the upper or lower half of a card.
    func move(to columnKey: String, relativeTo targetID: UUID?, placeAfter: Bool) {
        guard let draggedItemID, targetID != draggedItemID else { return }

        var next = itemIDsByColumn
        for key in next.keys {
            next[key]?.removeAll { $0 == draggedItemID }
        }

        var destination = next[columnKey] ?? []
        if let targetID, let targetIndex = destination.firstIndex(of: targetID) {
            destination.insert(draggedItemID, at: targetIndex + (placeAfter ? 1 : 0))
        } else {
            destination.append(draggedItemID)
        }

        guard next[columnKey] != destination || targetedColumnKey != columnKey else { return }
        next[columnKey] = destination
        itemIDsByColumn = next
        targetedColumnKey = columnKey
    }

    func placement(in columnKey: String) -> KanbanPlacement? {
        guard let draggedItemID,
              let items = itemIDsByColumn[columnKey],
              let index = items.firstIndex(of: draggedItemID)
        else { return nil }
        return KanbanPlacement(
            itemID: draggedItemID,
            predecessorID: index > items.startIndex ? items[index - 1] : nil,
            successorID: index < items.index(before: items.endIndex) ? items[index + 1] : nil
        )
    }

    func isAtEnd(of columnKey: String) -> Bool {
        guard let draggedItemID else { return false }
        return itemIDsByColumn[columnKey]?.last == draggedItemID
    }

    func end() {
        draggedItemID = nil
        targetedColumnKey = nil
        itemIDsByColumn = [:]
    }
}

struct KanbanPlacement: Equatable {
    let itemID: UUID
    let predecessorID: UUID?
    let successorID: UUID?
}

/// A card is two insertion targets: its upper half means before, its lower half means after.
@MainActor
struct KanbanCardDropDelegate: DropDelegate {
    static let midpoint: CGFloat = 24

    let targetID: UUID
    let columnKey: String
    let drag: KanbanDragCoordinator
    let performMove: (KanbanPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool { drag.isDragging }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.move(
            to: columnKey,
            relativeTo: targetID,
            placeAfter: info.location.y > Self.midpoint
        )
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let placement = drag.placement(in: columnKey) else { return false }
        let accepted = performMove(placement)
        drag.end()
        return accepted
    }
}

/// The generous target after the last card, also serving an otherwise empty column.
@MainActor
struct KanbanEndDropDelegate: DropDelegate {
    let columnKey: String
    let drag: KanbanDragCoordinator
    let performMove: (KanbanPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool { drag.isDragging }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.move(to: columnKey, relativeTo: nil, placeAfter: true)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let placement = drag.placement(in: columnKey) else { return false }
        let accepted = performMove(placement)
        drag.end()
        return accepted
    }
}

struct KanbanColumnEndDropZone: View {
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium)
            .fill(isActive ? Theme.Colors.selectionFill : .clear)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .overlay {
                if isActive {
                    Capsule()
                        .fill(Theme.Colors.selection)
                        .frame(height: 3)
                        .padding(.horizontal, Theme.Spacing.small)
                }
            }
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

struct KanbanCardView: View {
    @Environment(\.services) private var services
    let facts: TaskFacts
    let model: ProjectWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.tight) {
                WorkItemKindGlyph(kind: facts.kind, severity: facts.severity)
                if let key = facts.referenceKey { WorkItemReferenceLabel(reference: key) }
                Spacer(minLength: 0)
                if facts.isBlocked { BlockedMarker() }
            }
            WorkItemTitleField(facts: facts, model: model)
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.Colors.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(
                    model.selectedItemIDs.contains(facts.id)
                        ? Theme.Colors.selection : Theme.Colors.separator,
                    lineWidth: 1
                )
        )
        .contentShape(.rect)
        // Gated the same way the list row is: the card's tap gestures stand down while its title
        // is being edited in place, or the field cannot be clicked into.
        .onTapGesture {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            model.select(facts.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            model.present(facts.id)
        })
        .contextMenu { WorkItemMenu(facts: facts, model: model, services: services) }
    }
}

/// A work item crossing a drag.
///
/// Reuses the existing `.elephruitTaskDrag` type, so a card dragged out of a board onto a task list
/// is understood there rather than arriving as an opaque payload nothing accepts.
struct WorkItemTransfer: Codable, Transferable, Identifiable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .elephruitTaskDrag)
    }
}

/// The one-line "add something here" row.
struct QuickAddRow: View {
    let placeholder: String
    var model: ProjectWorkspaceModel?
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(placeholder: String, model: ProjectWorkspaceModel? = nil, onCommit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.model = model
        self.onCommit = onCommit
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Text.rowSubtitle)
            .focused($isFocused)
            .padding(Theme.Spacing.small)
            .onSubmit {
                guard let title = draft.nilIfBlank else { return }
                onCommit(title)
                draft = ""
            }
            .onChange(of: isFocused) { _, focused in
                model?.isEditingText = focused
            }
    }
}
