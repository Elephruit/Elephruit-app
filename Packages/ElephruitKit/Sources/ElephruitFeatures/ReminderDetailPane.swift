import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One reminder, read and edited in the pane beside the list.
///
/// The pane the module never had: editing used to mean an inline card with eight tab stops, five
/// application-defined popovers, and a focus router — 1,650 lines of plumbing to make Tab work.
/// A persistent pane needs none of it. The fields sit still, the pickers are the system's, Tab
/// traverses them because that is what Tab does, and every change lands through the same
/// `ReminderComposerDraft` round trip the store already had.
struct ReminderDetailPane: View {
    @Environment(\.services) private var services

    let reminder: Item

    @State private var draft: ReminderComposerDraft
    @State private var newStep = ""
    @State private var newTag = ""

    /// Writes are debounced for the typing fields and immediate for everything else. A `Task`
    /// rather than a timer so a burst of keystrokes cancels its predecessor's save.
    @State private var pendingSave: Task<Void, Never>?

    init(reminder: Item) {
        self.reminder = reminder
        _draft = State(initialValue: ReminderComposerDraft(reminder: reminder))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                scheduling
                filing
                checklist
            }
            .padding(Theme.Spacing.section)
            .frame(maxWidth: Theme.Size.editorMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.contentBackground)
        .onChange(of: reminder.id) { _, _ in
            pendingSave?.cancel()
            draft = ReminderComposerDraft(reminder: reminder)
        }
        .onDisappear { commitNow() }
        .accessibilityIdentifier("reminder.detail")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            WorkItemCompletionControl(item: reminder) {
                perform { try $0.reminderStore.toggleCompletion(of: reminder) }
            }
            .padding(.top, Theme.Spacing.tight)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.title)
                    .strikethrough(reminder.isCompleted, color: Theme.Colors.tertiaryText)
                    .onChange(of: draft.title) { _, _ in scheduleCommit() }
                    .accessibilityLabel("Reminder title")

                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.editorBody)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1...12)
                    .onChange(of: draft.notes) { _, _ in scheduleCommit() }
                    .accessibilityLabel("Notes")
            }

            Spacer(minLength: 0)

            Button {
                perform { try $0.reminderLifecycle.setFlagged(!reminder.isFlagged, on: reminder) }
            } label: {
                Image(systemName: reminder.isFlagged ? "flag.fill" : "flag")
                    .rowTint(reminder.isFlagged ? Theme.Colors.favorite : Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
            .help(reminder.isFlagged ? "Unflag" : "Flag")
            .accessibilityLabel(reminder.isFlagged ? "Unflag" : "Flag")
        }
    }

    // MARK: - Scheduling

    private var scheduling: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Schedule")

            LabeledContent("Start") {
                optionalDate(
                    $draft.startAt,
                    prompt: "Add a start date",
                    help: "Out of view until then. A start never turns red."
                )
            }

            LabeledContent("Deadline") {
                optionalDate(
                    $draft.dueAt,
                    prompt: "Add a deadline",
                    help: "The only date that can make this late."
                )
            }

            Toggle("Someday", isOn: somedayBinding)
                .toggleStyle(.checkbox)
                .help("Parked on purpose — out of every dated list until you bring it back")
        }
    }

    @ViewBuilder
    private func optionalDate(_ date: Binding<Date?>, prompt: String, help: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            if let current = date.wrappedValue {
                DatePicker(
                    prompt,
                    selection: Binding(
                        get: { current },
                        set: { date.wrappedValue = $0; commitNow() }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)

                Button {
                    date.wrappedValue = nil
                    commitNow()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove date")
            } else {
                Button(prompt) {
                    date.wrappedValue = services?.dateProvider.startOfToday
                    commitNow()
                }
                .buttonStyle(.link)
            }
        }
        .help(help)
    }

    private var somedayBinding: Binding<Bool> {
        Binding(
            get: { draft.isSomeday },
            set: { parked in
                draft.isSomeday = parked
                if parked {
                    draft.startAt = nil
                    draft.dueAt = nil
                }
                commitNow()
            }
        )
    }

    // MARK: - Filing

    private var filing: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Filing")

            LabeledContent("Project") {
                Menu {
                    Button("None") {
                        draft.projectTitle = nil
                        commitNow()
                    }
                    ForEach(projectTitles, id: \.self) { title in
                        Button(title) {
                            draft.projectTitle = title
                            commitNow()
                        }
                    }
                } label: {
                    Text(draft.projectTitle ?? "None")
                        .foregroundStyle(
                            draft.projectTitle == nil
                                ? Theme.Colors.tertiaryText
                                : Theme.Colors.primaryText
                        )
                }
                .fixedSize()
            }

            LabeledContent("Tags") {
                chipEditor(
                    values: draft.tagSlugs,
                    field: $newTag,
                    prompt: "Add tag",
                    tint: nil,
                    onAdd: { slug in
                        let cleaned = slug.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !cleaned.isEmpty, !draft.tagSlugs.contains(cleaned) else { return }
                        draft.tagSlugs.append(cleaned)
                        commitNow()
                    },
                    onRemove: { slug in
                        draft.tagSlugs.removeAll { $0 == slug }
                        commitNow()
                    }
                )
            }

            if !draft.personNames.isEmpty {
                LabeledContent("People") {
                    FlowLayout(spacing: Theme.Spacing.tight) {
                        ForEach(draft.personNames, id: \.self) { name in
                            Chip(name, systemImage: "person", tint: Theme.Colors.workDetail) {
                                draft.personNames.removeAll { $0 == name }
                                commitNow()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chipEditor(
        values: [String],
        field: Binding<String>,
        prompt: String,
        tint: Color?,
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        FlowLayout(spacing: Theme.Spacing.tight) {
            ForEach(values, id: \.self) { value in
                Chip(value, tint: tint) { onRemove(value) }
            }

            TextField(prompt, text: field)
                .textFieldStyle(.plain)
                .font(Theme.Text.chip)
                .frame(minWidth: 64, maxWidth: 120)
                .onSubmit {
                    onAdd(field.wrappedValue)
                    field.wrappedValue = ""
                }
        }
    }

    private var projectTitles: [String] {
        guard let services else { return [] }
        var query = ItemQuery()
        query.kinds = [.project]
        query.scope = .active
        query.sort = .manual
        return ((try? services.items.items(matching: query)) ?? []).map(\.displayTitle)
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Checklist", count: draft.checklist.isEmpty ? nil : draft.checklist.count)

            ForEach(draft.checklist) { step in
                HStack(spacing: Theme.Spacing.small) {
                    Button {
                        toggleStep(step)
                    } label: {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                step.isCompleted ? Theme.Colors.completed : Theme.Colors.secondaryText
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.isCompleted ? "Mark step not done" : "Mark step done")

                    Text(step.title)
                        .font(Theme.Text.rowSubtitle)
                        .strikethrough(step.isCompleted, color: Theme.Colors.tertiaryText)
                        .foregroundStyle(
                            step.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                        )

                    Spacer(minLength: 0)

                    Button {
                        draft.checklist.removeAll { $0.id == step.id }
                        commitNow()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.Text.keyHint)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove step")
                }
            }

            TextField("Add a step", text: $newStep)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowSubtitle)
                .onSubmit {
                    let cleaned = newStep.trimmingCharacters(in: .whitespaces)
                    guard !cleaned.isEmpty else { return }
                    draft.checklist.append(ChecklistItem(title: cleaned))
                    newStep = ""
                    commitNow()
                }
        }
    }

    private func toggleStep(_ step: ChecklistItem) {
        guard let index = draft.checklist.firstIndex(where: { $0.id == step.id }) else { return }
        draft.checklist[index].isCompleted.toggle()
        commitNow()
    }

    // MARK: - Saving

    private func scheduleCommit() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commitNow()
        }
    }

    private func commitNow() {
        pendingSave?.cancel()
        let current = draft
        perform { try $0.reminderStore.update(reminder, from: current) }
    }

    private func perform(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: reminder)
        }
    }
}
