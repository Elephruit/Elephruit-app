import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// One work item, in a sheet — and every field of it editable.
///
/// **A sheet, not a drawer.** This was an inspector first, on the brief's "avoid excessive modals"
/// line, and that line was explicitly withdrawn after use. A work item is nine sections wide, none
/// of it reads in a 440-point column, and the column came out of the board's width — so the board
/// paid for a pane that was still too narrow to use.
///
/// **An editor, not a display.** The first version drew every field as `Text`, which made this the
/// only surface in the app that showed a bug's report and refused to change it — the literal shape
/// of the "can't edit any bug details" report. Every mutation goes through
/// ``WorkItemEditorModel``, which is where a test can hold the behaviour still.
///
/// There is no Save button. Each field commits when it is left — submit, focus loss, or the sheet
/// closing — because a sheet that batches its edits is a sheet whose edits a force-quit loses.
struct WorkItemDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: Item
    let model: ProjectWorkspaceModel

    @State private var editor: WorkItemEditorModel?
    @State private var title = ""
    @State private var notesText = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var actual = ""
    @State private var environmentText = ""
    @State private var affectedVersion = ""
    @State private var fixVersion = ""
    @State private var estimateText = ""
    @State private var showsDeleteConfirmation = false
    @State private var hasAppeared = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title, body, steps, expected, actual, environment, affected, fix, estimate
    }

    var body: some View {
        ZStack {
            Theme.Colors.subtleFill.opacity(0.38)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        sectionCard("Details", symbol: "slider.horizontal.3", tint: accentTint) {
                            fields
                        }
                        notesSection
                        if item.kind == .bug { bugSection }
                        historySection
                    }
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .background(Theme.Colors.contentBackground.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .stroke(Theme.Colors.separator, lineWidth: 0.5)
            }
            .padding(Theme.Spacing.small)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.985, anchor: .center)
            .offset(y: hasAppeared ? 0 : 8)
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 560, idealHeight: 660)
        .onAppear {
            load()
            withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
                hasAppeared = true
            }
        }
        // The gate the workspace's shortcuts honour. Every field in the sheet counts as typing.
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
            Button("Move to Trash", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            WorkItemKindGlyph(kind: item.kind, severity: item.bugRecord?.severity)
                .frame(width: 34, height: 34)
                .background(accentTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(spacing: Theme.Spacing.small) {
                    if let key = item.referenceKey { WorkItemReferenceLabel(reference: key) }
                    Text(item.kind.displayName)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // A single-line field, deliberately. A vertical TextField treats Return as a newline,
                // which is how a drawer's title ended up with no way to commit it at all.
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.title)
                    .focused($focusedField, equals: .title)
                    .onSubmit { commit(.title) }
            }

            Spacer(minLength: Theme.Spacing.large)

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(Theme.Text.rowSubtitle.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .background(Theme.Colors.subtleFill, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            .help("Close")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(Theme.Spacing.large)
        .background {
            Theme.Colors.contentBackground
                .overlay(accentTint.opacity(0.045))
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var accentTint: Color {
        guard item.kind == .bug else { return Theme.Colors.selection }
        return Theme.Palette.color(named: currentFacts.severity.colorName, neutral: Theme.Colors.selection)
    }

    private func sectionCard<Content: View>(
        _ title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(title, systemImage: symbol)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(tint)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .background(tint.opacity(0.10), in: Capsule())
            content()
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.Colors.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Metadata

    private var fields: some View {
        FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
            compactControl("Status") {
                Picker("Status", selection: statusBinding) {
                    ForEach([ItemStatus.open, .completed, .cancelled], id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityIdentifier("workItem.status")
            }

            if !model.stages.isEmpty {
                compactControl("Stage") {
                    Picker("Stage", selection: stageBinding) {
                        Text("No Stage").tag(UUID?.none)
                        ForEach(model.stages) { stage in
                            Text(stage.name).tag(UUID?.some(stage.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("workItem.stage")
                }
            }

            compactControl("Priority") {
                Picker("Priority", selection: priorityBinding) {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 205)
                .accessibilityIdentifier("workItem.priority")
            }

            compactControl("Assignee") {
                Picker("Assignee", selection: assigneeBinding) {
                    Text("Nobody").tag(UUID?.none)
                    ForEach(editor?.assignableCandidates ?? []) { person in
                        Text(person.title).tag(UUID?.some(person.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("workItem.assignee")
            }

            compactControl("Due") {
                HStack(spacing: Theme.Spacing.tight) {
                    if let due = item.dueAt {
                        DatePicker(
                            "Due",
                            selection: Binding(
                                get: { due },
                                set: { editor?.setDueDate($0) }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Button("Clear") { editor?.setDueDate(nil) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } else {
                        Button("Add Due Date") {
                            editor?.setDueDate(defaultDueDate)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .accessibilityIdentifier("workItem.due")
            }

            compactControl("Estimate") {
                HStack(spacing: Theme.Spacing.tight) {
                    TextField("None", text: $estimateText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 54)
                        .focused($focusedField, equals: .estimate)
                        .onSubmit { commit(.estimate) }
                    Text("min")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .accessibilityIdentifier("workItem.estimate")
            }

            markerControl(
                "Milestone",
                kind: .milestone,
                current: item.linkedTarget(kind: .targetsMilestone),
                set: { editor?.setMilestone($0) }
            )
            markerControl(
                "Release",
                kind: .release,
                current: item.linkedTarget(kind: .relatesToRelease),
                set: { editor?.setRelease($0) }
            )
        }
    }

    @ViewBuilder
    private func markerControl(
        _ label: String,
        kind: ItemKind,
        current: Item?,
        set: @escaping (Item?) -> Void
    ) -> some View {
        let candidates = model.markers.filter { $0.kind == kind }
        if !candidates.isEmpty || current != nil {
            compactControl(label) {
                Picker(label, selection: Binding(
                    get: { current?.id },
                    set: { id in set(id.flatMap { target in candidates.first { $0.id == target } }) }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(candidates) { candidate in
                        Text(candidate.title).tag(UUID?.some(candidate.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func compactControl<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
            content()
        }
        .padding(Theme.Spacing.small)
        .background(Theme.Colors.subtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    // MARK: - Notes

    private var notesSection: some View {
        sectionCard("Notes", symbol: "text.alignleft", tint: Theme.Colors.secondaryText) {
            TextEditor(text: $notesText)
                .font(Theme.Text.rowTitle)
                .frame(minHeight: 58)
                .focused($focusedField, equals: .body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(Theme.Colors.subtleFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .stroke(
                            focusedField == .body ? Theme.Colors.selection.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                }
                .accessibilityIdentifier("workItem.notes")
        }
    }

    // MARK: - The report

    /// Every field of the defect, editable — severity, the reproduction, the versions, the claims.
    ///
    /// Shown for every bug, record or no record. The record is created by the first *write*, never
    /// by looking (see ``WorkItemEditorModel/updateBug(_:)``) — so a bug filed in eight seconds
    /// opens onto an honest empty report rather than a missing section, which is what it used to
    /// do, and which read as "this bug cannot be edited".
    private var bugSection: some View {
        sectionCard("Bug report", symbol: "ladybug.fill", tint: accentTint) {
            FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                compactControl("Severity") {
                    Picker("Severity", selection: severityBinding) {
                        ForEach(BugSeverity.allCases, id: \.self) { severity in
                            Text(severity.displayName).tag(severity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 310)
                    .accessibilityIdentifier("workItem.severity")
                }

                compactControl("Signals") {
                    HStack(spacing: Theme.Spacing.medium) {
                        Toggle("Regression", isOn: regressionBinding)
                            .help("Whether this used to work. A regression means something changed, and that is a lead.")
                            .accessibilityIdentifier("workItem.regression")
                        Toggle("Verified", isOn: verifiedBinding)
                            .help("Fixed and verified are two different claims by two different people. This is the second one.")
                            .accessibilityIdentifier("workItem.verified")
                    }
                    .font(Theme.Text.rowSubtitle)
                    .controlSize(.small)
                    .toggleStyle(.checkbox)
                }

                compactControl("Affected version") {
                    TextField("Found in", text: $affectedVersion)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 125)
                        .focused($focusedField, equals: .affected)
                        .onSubmit { commit(.affected) }
                        .accessibilityIdentifier("workItem.affectedVersion")
                }

                compactControl("Fix version") {
                    TextField("Fixed in", text: $fixVersion)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 125)
                        .focused($focusedField, equals: .fix)
                        .onSubmit { commit(.fix) }
                        .accessibilityIdentifier("workItem.fixVersion")
                }

                compactControl("Environment") {
                    TextField("Machine, OS, build", text: $environmentText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 190)
                        .focused($focusedField, equals: .environment)
                        .onSubmit { commit(.environment) }
                        .accessibilityIdentifier("workItem.environment")
                }
            }

            reportEditor("Steps to reproduce", text: $steps, field: .steps, id: "workItem.steps", minHeight: 54)

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                reportEditor("Expected", text: $expected, field: .expected, id: "workItem.expected")
                reportEditor("Actual", text: $actual, field: .actual, id: "workItem.actual")
            }

            if !currentFacts.missingFieldNames.isEmpty {
                // Nudged, never blocked. A bug filed in eight seconds is a bug that got filed.
                Text("Still missing: " + currentFacts.missingFieldNames.formatted(.list(type: .and)))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private func reportEditor(
        _ label: String,
        text: Binding<String>,
        field: Field,
        id: String,
        minHeight: CGFloat = 58
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(label)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
            TextEditor(text: text)
                .font(Theme.Text.rowTitle)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .focused($focusedField, equals: field)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(Theme.Colors.subtleFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .stroke(
                            focusedField == field ? accentTint.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                }
                .accessibilityIdentifier(id)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        let history = services?.workItems.history(of: item) ?? []
        if !history.isEmpty {
            sectionCard("Recent history", symbol: "clock.arrow.circlepath", tint: Theme.Colors.secondaryText) {
                ForEach(history.prefix(10)) { activity in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Circle()
                            .fill(Theme.Colors.tertiaryText)
                            .frame(width: 4, height: 4)
                        Text(activity.sentence)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            // Named for what it does. It said "Delete" while the dialog said "Move to Trash", and
            // the two disagreeing about whether the action is recoverable is worse than either.
            Button("Move to Trash", role: .destructive) { showsDeleteConfirmation = true }
                .shortcut(.moveToTrash, in: services?.shortcuts ?? ShortcutRegistry())
            Spacer()
            Label("Changes save automatically", systemImage: "checkmark.circle")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.large)
        .background(Theme.Colors.contentBackground)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Bindings

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
        Binding(
            get: { item.priority },
            set: { editor?.setPriority($0) }
        )
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

    private var severityBinding: Binding<BugSeverity> {
        Binding(
            get: { currentFacts.severity },
            set: { editor?.setSeverity($0) }
        )
    }

    private var regressionBinding: Binding<Bool> {
        Binding(
            get: { currentFacts.isRegression },
            set: { value in editor?.updateBug { $0.isRegression = value } }
        )
    }

    private var verifiedBinding: Binding<Bool> {
        Binding(
            get: { editor?.isVerified ?? false },
            set: { editor?.setVerified($0) }
        )
    }

    /// Tomorrow morning, which is the least presumptuous non-empty answer.
    private var defaultDueDate: Date {
        Calendar.current.startOfDay(for: Date.now).addingTimeInterval(60 * 60 * 24)
    }

    // MARK: - Loading and committing

    private func load() {
        guard let services else { return }
        let editor = WorkItemEditorModel(services: services, itemID: item.id)
        editor.onChange = { model.refresh() }
        self.editor = editor

        title = item.title
        notesText = item.body
        estimateText = item.estimateMinutes.map(String.init) ?? ""

        let facts = item.bugRecord?.facts ?? BugFacts()
        steps = facts.stepsToReproduce ?? ""
        expected = facts.expectedBehavior ?? ""
        actual = facts.actualBehavior ?? ""
        environmentText = facts.environment ?? ""
        affectedVersion = facts.affectedVersion ?? ""
        fixVersion = facts.fixVersion ?? ""
    }

    /// One field, committed as it is left.
    private func commit(_ field: Field) {
        guard let editor else { return }
        switch field {
        case .title:
            editor.setTitle(title)
        case .body:
            editor.setBody(notesText)
        case .estimate:
            editor.setEstimate(minutes: Int(estimateText.trimmingCharacters(in: .whitespaces)))
        case .steps:
            editor.updateBug { $0.stepsToReproduce = steps.nilIfBlank }
        case .expected:
            editor.updateBug { $0.expectedBehavior = expected.nilIfBlank }
        case .actual:
            editor.updateBug { $0.actualBehavior = actual.nilIfBlank }
        case .environment:
            editor.updateBug { $0.environment = environmentText.nilIfBlank }
        case .affected:
            editor.updateBug { $0.affectedVersion = affectedVersion.nilIfBlank }
        case .fix:
            editor.updateBug { $0.fixVersion = fixVersion.nilIfBlank }
        }
    }

    private func commitAll() {
        for field in [Field.title, .body, .estimate, .steps, .expected, .actual, .environment, .affected, .fix] {
            commit(field)
        }
    }

    private func delete() {
        guard let services else { return }
        // Through the undo coordinator, so ⌘Z after a mistaken deletion works here the way it does
        // in every list.
        services.perform { try services.undo.moveToTrash([item]) }
        model.refresh()
        dismiss()
    }
}
