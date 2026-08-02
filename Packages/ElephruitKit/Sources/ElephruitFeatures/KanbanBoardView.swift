import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI
import UniformTypeIdentifiers

/// Columns you drag work between.
///
/// The one view whose layout genuinely differs from the grouped list — everything else is rows under
/// a different grouping. It reads the same `WorkItemArrangement` output as every other view, so a
/// card and a row can never disagree about what is in the project.
struct KanbanBoardView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                ForEach(model.groups) { column in
                    KanbanColumnView(column: column, model: model)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header

            ForEach(column.items, id: \.id) { facts in
                KanbanCardView(facts: facts, model: model)
                    .draggable(WorkItemTransfer(id: facts.id))
            }

            QuickAddRow(placeholder: "Add to \(column.title)") { title in
                add(title)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 280)
        .dropDestination(for: WorkItemTransfer.self) { payload, _ -> Bool in
            return accept(payload)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(column.title)
                .font(Theme.Text.rowTitleEmphasised)
            Text("\(column.count)")
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)
            Spacer(minLength: 0)
            if column.isOverLimit {
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

    private func accept(_ payload: [WorkItemTransfer]) -> Bool {
        guard let services,
              let first = payload.first,
              let item = model.item(first.id)
        else { return false }
        let stage = column.stageID.flatMap { id in model.stages.first { $0.id == id } }
        _ = try? services.projectWorkspace.move(item, to: stage)
        model.refresh()
        return true
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
struct WorkItemTransfer: Codable, Transferable {
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
