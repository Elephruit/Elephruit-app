import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The useful part of a bug report, expanded directly beneath its queue row.
///
/// Triage controls stay visible across the top, while the narrative is arranged as a readable
/// report instead of the long label-and-field column used by the general-purpose item sheet.
struct BugInlineDetailView: View {
    @Environment(\.services) private var services
    let item: Item
    let model: ProjectWorkspaceModel
    let collapse: () -> Void

    @State private var editor: WorkItemEditorModel?
    @State private var notes = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var actual = ""
    @State private var environmentText = ""
    @State private var affectedVersion = ""
    @State private var fixVersion = ""
    @State private var showsDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable, CaseIterable {
        case notes, steps, expected, actual, environment, affected, fix
    }

    private var severityTint: Color {
        Theme.Palette.color(named: currentFacts.severity.colorName, neutral: Theme.Colors.secondaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            topBar
            triageStrip
            narrative
            environmentStrip
        }
        .padding(Theme.Spacing.large)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .fill(Theme.Colors.subtleFill.opacity(0.55))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(severityTint)
                        .frame(width: 3)
                        .padding(.vertical, Theme.Spacing.large)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.Colors.selection.opacity(0.22), lineWidth: 0.75)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
        .onAppear(perform: load)
        .onChange(of: focusedField) { previous, current in
            model.isEditingText = current != nil
            if let previous, previous != current { commit(previous) }
        }
        .onDisappear {
            commitAll()
            model.isEditingText = false
        }
        .confirmationDialog(
            "Move “\(item.title)” to Trash?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("bug.inlineDetail.\(item.id.uuidString)")
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "text.page.fill")
                .foregroundStyle(severityTint)
            Text("Bug report")
                .font(Theme.Text.sectionHeader)
            if currentFacts.isRegression {
                BugTrackerPill(
                    label: "Regression",
                    symbol: "arrow.counterclockwise",
                    tint: Theme.Colors.warning
                )
            }
            if editor?.isVerified == true {
                BugTrackerPill(
                    label: "Verified",
                    symbol: "checkmark.seal.fill",
                    tint: Theme.Colors.completed
                )
            }

            Spacer(minLength: 0)

            Button("Move to Trash", role: .destructive) { showsDeleteConfirmation = true }
                .buttonStyle(.plain)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.destructive)

            Button(action: collapse) {
                Label("Collapse", systemImage: "chevron.up")
            }
            .buttonStyle(.borderless)
            .font(Theme.Text.metadata)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var triageStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                primaryTriageControls
                secondaryTriageControls
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    primaryTriageControls
                    Spacer(minLength: 0)
                }
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    secondaryTriageControls
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var primaryTriageControls: some View {
        menuField("Status", value: statusBinding) {
            ForEach([ItemStatus.open, .completed, .cancelled], id: \.self) {
                Text($0.displayName).tag($0)
            }
        }

        if !model.stages.isEmpty {
            menuField("Stage", value: stageBinding) {
                Text("No Stage").tag(UUID?.none)
                ForEach(model.stages) { Text($0.name).tag(UUID?.some($0.id)) }
            }
        }

        menuField("Priority", value: priorityBinding) {
            ForEach(Priority.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
    }

    @ViewBuilder
    private var secondaryTriageControls: some View {
        menuField("Severity", value: severityBinding) {
            ForEach(BugSeverity.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }

        menuField("Assignee", value: assigneeBinding) {
            Text("Nobody").tag(UUID?.none)
            ForEach(editor?.assignableCandidates ?? []) {
                Text($0.title).tag(UUID?.some($0.id))
            }
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("Signals")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
            HStack(spacing: Theme.Spacing.medium) {
                Toggle("Regression", isOn: regressionBinding)
                Toggle("Verified", isOn: verifiedBinding)
            }
            .toggleStyle(.checkbox)
            .font(Theme.Text.metadata)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
    }

    private func menuField<Value: Hashable, Content: View>(
        _ label: String,
        value: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
            Picker(label, selection: value, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private var narrative: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            reportEditor(
                "Notes",
                prompt: "What is happening, and why does it matter?",
                text: $notes,
                field: .notes,
                minHeight: 54
            )

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                reportEditor(
                    "Steps to reproduce",
                    prompt: "How can someone see the issue?",
                    text: $steps,
                    field: .steps
                )
                reportEditor(
                    "Expected",
                    prompt: "What should happen?",
                    text: $expected,
                    field: .expected
                )
                reportEditor(
                    "Actual",
                    prompt: "What happens instead?",
                    text: $actual,
                    field: .actual
                )
            }
        }
    }

    private func reportEditor(
        _ label: String,
        prompt: String,
        text: Binding<String>,
        field: Field,
        minHeight: CGFloat = 86
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(label)
                .font(Theme.Text.rowTitleEmphasised)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(Theme.Colors.placeholderText)
                        .padding(.horizontal, Theme.Spacing.small + 1)
                        .padding(.vertical, Theme.Spacing.small + 2)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(Theme.Text.rowTitle)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.tight)
                    .focused($focusedField, equals: field)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .stroke(
                        focusedField == field ? Theme.Colors.selection.opacity(0.55) : Theme.Colors.separator,
                        lineWidth: focusedField == field ? 1 : 0.5
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var environmentStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) { environmentFields }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) { environmentFields }
        }
    }

    @ViewBuilder
    private var environmentFields: some View {
        compactField("Environment", placeholder: "Machine, OS, build", text: $environmentText, field: .environment)
        compactField("Affected", placeholder: "Found in version", text: $affectedVersion, field: .affected)
        compactField("Fix", placeholder: "Fixed in version", text: $fixVersion, field: .fix)

        if !currentFacts.missingFieldNames.isEmpty {
            Label(
                "Missing " + currentFacts.missingFieldNames.formatted(.list(type: .and)),
                systemImage: "circle.dashed"
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .lineLimit(2)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private func compactField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                .onSubmit { commit(field) }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private var currentFacts: BugFacts {
        editor?.bugFacts ?? item.bugRecord?.facts ?? BugFacts()
    }

    private var statusBinding: Binding<ItemStatus> {
        Binding(
            get: { item.status == .none ? .open : item.status },
            set: { editor?.setStatus($0) }
        )
    }

    private var stageBinding: Binding<UUID?> {
        Binding(
            get: { item.workflowStageID },
            set: { id in editor?.setStage(id.flatMap { target in model.stages.first { $0.id == target } }) }
        )
    }

    private var priorityBinding: Binding<Priority> {
        Binding(get: { item.priority }, set: { editor?.setPriority($0) })
    }

    private var severityBinding: Binding<BugSeverity> {
        Binding(get: { currentFacts.severity }, set: { editor?.setSeverity($0) })
    }

    private var assigneeBinding: Binding<UUID?> {
        Binding(
            get: { item.assignee()?.id },
            set: { id in
                editor?.setAssignee(id.flatMap { target in
                    editor?.assignableCandidates.first { $0.id == target }
                })
            }
        )
    }

    private var regressionBinding: Binding<Bool> {
        Binding(
            get: { currentFacts.isRegression },
            set: { value in editor?.updateBug { $0.isRegression = value } }
        )
    }

    private var verifiedBinding: Binding<Bool> {
        Binding(get: { editor?.isVerified ?? false }, set: { editor?.setVerified($0) })
    }

    private func load() {
        guard let services else { return }
        let editor = WorkItemEditorModel(services: services, itemID: item.id)
        editor.onChange = { model.refresh() }
        self.editor = editor

        notes = item.body
        let facts = item.bugRecord?.facts ?? BugFacts()
        steps = facts.stepsToReproduce ?? ""
        expected = facts.expectedBehavior ?? ""
        actual = facts.actualBehavior ?? ""
        environmentText = facts.environment ?? ""
        affectedVersion = facts.affectedVersion ?? ""
        fixVersion = facts.fixVersion ?? ""
    }

    private func commit(_ field: Field) {
        guard let editor else { return }
        switch field {
        case .notes: editor.setBody(notes)
        case .steps: editor.updateBug { $0.stepsToReproduce = steps.nilIfBlank }
        case .expected: editor.updateBug { $0.expectedBehavior = expected.nilIfBlank }
        case .actual: editor.updateBug { $0.actualBehavior = actual.nilIfBlank }
        case .environment: editor.updateBug { $0.environment = environmentText.nilIfBlank }
        case .affected: editor.updateBug { $0.affectedVersion = affectedVersion.nilIfBlank }
        case .fix: editor.updateBug { $0.fixVersion = fixVersion.nilIfBlank }
        }
    }

    private func commitAll() {
        Field.allCases.forEach(commit)
    }

    private func delete() {
        model.moveToTrash([item.id])
        collapse()
    }
}
