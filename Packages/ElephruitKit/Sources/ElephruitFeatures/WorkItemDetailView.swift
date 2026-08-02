import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// One work item, in a sheet.
///
/// **A sheet, not a drawer.** This was an inspector first, on the brief's "avoid excessive modals"
/// line, and that line was explicitly withdrawn after use. A work item is nine sections wide, none
/// of it reads in a 440-point column, and the column came out of the board's width — so the board
/// paid for a pane that was still too narrow to use.
struct WorkItemDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    let item: Item
    let model: ProjectWorkspaceModel

    @State private var title = ""
    @State private var showsDeleteConfirmation = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    fields
                    if item.kind == .bug { bugSection }
                    historySection
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear { title = item.title }
        .confirmationDialog(
            "Move “\(item.title)” to Trash?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            WorkItemKindGlyph(kind: item.kind, severity: item.bugRecord?.severity)
            if let key = item.referenceKey { WorkItemReferenceLabel(reference: key) }

            // A single-line field, deliberately. A vertical TextField treats Return as a newline,
            // which is how a drawer's title ended up with no way to commit it at all.
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Text.title)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in
                    model.isEditingText = focused
                    if !focused { commitTitle() }
                }
        }
        .padding(Theme.Spacing.large)
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.small) {
            GridRow {
                Text("Status").foregroundStyle(Theme.Colors.secondaryText)
                Text(item.status == .completed ? "Done" : "Open")
            }
            GridRow {
                Text("Priority").foregroundStyle(Theme.Colors.secondaryText)
                Text(item.priority.displayName)
            }
            if let assignee = item.assignee() {
                GridRow {
                    Text("Assignee").foregroundStyle(Theme.Colors.secondaryText)
                    Text(assignee.title)
                }
            }
            if let estimate = item.estimateMinutes {
                GridRow {
                    Text("Estimate").foregroundStyle(Theme.Colors.secondaryText)
                    Text(EstimateLabel.duration(estimate))
                }
            }
        }
        .font(Theme.Text.rowTitle)
    }

    @ViewBuilder
    private var bugSection: some View {
        // Bug fields appear only on a bug — progressive disclosure, so a task is not asked which
        // build it affects.
        if let record = item.bugRecord {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Defect").font(Theme.Text.sectionHeader)
                Text(record.severity.displayName)
                if let steps = record.stepsToReproduce {
                    Text(steps).font(Theme.Text.rowSubtitle)
                }
                if !record.facts.missingFieldNames.isEmpty {
                    // Nudged, never blocked. A bug filed in eight seconds is a bug that got filed.
                    Text("Still missing: " + record.facts.missingFieldNames.formatted(.list(type: .and)))
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = services?.workItems.history(of: item) ?? []
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("History").font(Theme.Text.sectionHeader)
                ForEach(history.prefix(10)) { activity in
                    Text(activity.sentence)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            // The delete that was missing entirely. In the sheet rather than only in a context menu,
            // because a context menu is not somewhere people look for it.
            Button("Delete", role: .destructive) { showsDeleteConfirmation = true }
                .keyboardShortcut(.delete, modifiers: .command)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.large)
    }

    private func commitTitle() {
        guard let services, let name = title.nilIfBlank, name != item.title else { return }
        try? services.workItems.setTitle(name, on: item)
        model.refresh()
    }

    private func delete() {
        guard let services else { return }
        try? services.items.moveToTrash(item)
        model.refresh()
        dismiss()
    }
}
