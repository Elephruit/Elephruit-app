import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A task, opened where it lives.
///
/// ### The decision this rests on
/// **The editor is the row.** Not a column beside the row, not a sheet over it, not a popover
/// anchored to it. Opening a task makes its own list row taller and puts the fields inside it, so the
/// rows above hold still, the rows below move down, and nothing else on screen is covered. The task
/// never leaves the list that explains it — which project it is in, what is above it, what is next.
///
/// A detail column had to answer "which task is this?" with a header, because by the time you were
/// reading it the list was three hundred points away and might have scrolled. A card does not have
/// that problem, so it carries no title bar, no breadcrumb and no container name: all three are
/// visible in the same glance, in the list it is sitting in.
///
/// ### What is on it, in order
/// Completion control and title · notes · steps · what is true and what could be · anything the app
/// needs to say quietly. Nothing here is a form. A field appears because it holds a value or because
/// the user asked for it, never because the model has a column for it — see ``TaskAttributeRow`` for
/// the rule and the assertions over it.
///
/// ### Why writes are debounced rather than immediate
/// Typing a title into the store on every keystroke runs validation, link reconciliation and a save
/// several times a second. So the title and the notes are local state written after half a second of
/// quiet, on exactly the discipline ``ItemDetailView`` already uses — and flushed on quit, on
/// switching app, on closing the card, and on any navigation, because the pending half-second matters
/// most at the moment nothing is left to run it.
struct TaskCard: View {
    @Environment(\.services) private var services

    let task: Item
    let navigation: NavigationModel

    /// Called after anything that changes what the list should show.
    var onChange: () -> Void = {}

    /// Called when the card should stop being open — Escape, or finishing the title with Return.
    var onClose: () -> Void = {}

    @State private var title = ""
    @State private var notes = ""
    @State private var loadedTaskID: UUID?
    @State private var pendingSave = PendingSave()
    @State private var editorID = UUID()

    @State private var newStepTitle = ""
    @State private var isStepFieldVisible = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title
        case step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            titleLine

            NotesField(text: notesBinding, title: "Notes", systemImage: nil, placeholder: "Notes")

            checklist

            subtasks

            TaskAttributeRow(
                task: task,
                onAddChecklist: {
                    isStepFieldVisible = true
                    focus = .step
                },
                onChange: onChange
            )

            backlinks

            notices
        }
        .padding(Theme.Spacing.medium)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.contentBackground)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Colors.separator, lineWidth: 1)
        }
        .padding(.vertical, Theme.Spacing.tight)
        // Escape closes, wherever the focus is inside the card.
        .onExitCommand { close() }
        .task(id: task.id) { load() }
        .task { navigation.registerEditFlush(editorID) { pendingSave.flush() } }
        .onDisappear {
            navigation.unregisterEditFlush(editorID)
            pendingSave.flush()
        }
        // `scenePhase` does not report a macOS quit, so the notification is the only hook that fires
        // before the process goes.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            pendingSave.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            pendingSave.flush()
        }
        .accessibilityIdentifier("task.card.\(task.id.uuidString)")
    }

    // MARK: - Title

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            TaskCompletionControl(task: task) { toggle() }

            TextField("New task", text: titleBinding)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowTitle)
                .focused($focus, equals: .title)
                // Return finishes the task rather than inserting a newline: the notes field below is
                // where more than one line goes, and a title that can wrap is a row whose height
                // depends on how much somebody typed.
                .onSubmit { close() }
                .accessibilityIdentifier("task.card.title")

            if task.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .rowTint(Theme.Colors.dueToday)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Steps

    /// Steps inside this one action.
    ///
    /// A step is not a task and appears in no list. The distinction is explained where it costs
    /// nothing — on the menu item that converts one — rather than being something to understand
    /// before typing.
    @ViewBuilder
    private var checklist: some View {
        let steps = task.checklist
        if !steps.isEmpty || isStepFieldVisible {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                ForEach(steps.items) { step in
                    stepRow(step)
                }

                stepField
            }
        }
    }

    private func stepRow(_ step: ChecklistItem) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                act { try $0.tasks.setChecklistItem(step.id, completed: !step.isCompleted, on: task) }
            } label: {
                Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(step.isCompleted ? Theme.Colors.completed : Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)

            Text(step.title)
                .font(Theme.Text.rowSubtitle)
                .strikethrough(step.isCompleted, color: Theme.Colors.tertiaryText)
                .foregroundStyle(step.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText)

            Spacer(minLength: 0)

            Menu {
                Button("Make This a Subtask") {
                    act { _ = try $0.tasks.promoteChecklistItem(step.id, of: task) }
                }
                .help("A subtask has its own dates, project, and place in Today. A step has none of those.")

                Button("Remove", role: .destructive) {
                    act { try $0.tasks.removeChecklistItem(step.id, from: task) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(minHeight: Theme.Size.rowHeight)
    }

    private var stepField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.Colors.tertiaryText)

            TextField("Add a step", text: $newStepTitle)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowSubtitle)
                .focused($focus, equals: .step)
                .onSubmit {
                    let trimmed = newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    act { try $0.tasks.addChecklistItem(trimmed, to: task) }
                    newStepTitle = ""
                    focus = .step
                }
                .accessibilityIdentifier("task.stepField")
        }
        .frame(minHeight: Theme.Size.rowHeight)
    }

    // MARK: - Subtasks

    /// Tasks that live under this one.
    ///
    /// ### Why they are on the card rather than a level down
    /// Because a subtask is the work and the parent is the container for it, so "what is inside
    /// this" is the question the card is open to answer. They sit below the steps and above the
    /// attributes because both of those describe *this* task, and a subtask is a different task that
    /// happens to live beneath it.
    ///
    /// Opening one opens its own card, in the list, in place. That is the whole reason the detail
    /// column could go: following a subtask no longer means leaving the list to a pane that has to
    /// re-explain where you are.
    @ViewBuilder
    private var subtasks: some View {
        let children = subtaskList
        if !children.isEmpty || isShowingSubtaskButton {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                ForEach(children, id: \.id) { subtask in
                    DetailTaskRow(
                        task: subtask,
                        dateProvider: services?.dateProvider ?? SystemDateProvider(),
                        onToggle: { act { try $0.items.toggleCompletion(subtask) } },
                        onOpen: { navigation.selectItem(subtask.id) }
                    )
                    // A subtask is a task; it gets the task's canonical deletion. This row was the
                    // one place a task could be seen and completed but not deleted.
                    .contextMenu {
                        Button("Open") { navigation.selectItem(subtask.id) }
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            guard let services else { return }
                            services.perform { try services.undo.moveToTrash([subtask]) }
                            services.refreshDerivedState()
                            services.noteRemoval(of: subtask.id)
                        }
                    }
                }

                Button("New Subtask", systemImage: "plus") { addSubtask() }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
                    .help("A task of its own, with its own dates and its own place in Today.")
            }
        }
    }

    /// The button is offered while there is already at least one subtask, or the task has steps —
    /// which is when somebody is thinking in parts. On a plain task it would be a sixth control
    /// competing with the five that answer more common questions.
    private var isShowingSubtaskButton: Bool {
        !task.checklist.isEmpty
    }

    private var subtaskList: [Item] {
        task.children
            .filter { $0.kind == .task && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func addSubtask() {
        guard let services else { return }
        services.perform {
            let subtask = try services.items.create(ItemDraft(kind: .task, parentID: task.id))
            services.noteChange(to: subtask)
        }
        onChange()
    }

    // MARK: - Backlinks

    /// What points at this task.
    ///
    /// Quiet, and last but for the notices, because it is context rather than content: a meeting
    /// note that mentions this task is a reason the task exists, not part of doing it.
    @ViewBuilder
    private var backlinks: some View {
        let links = task.visibleBacklinks()
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Linked from")
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .kerning(0.4)

                BacklinkList(links: links) { navigation.selectItem($0) }
            }
        }
    }

    // MARK: - Notices

    /// What the app needs to say about this task, quietly, at the bottom where it is out of the way
    /// of everything that is a control.
    @ViewBuilder
    private var notices: some View {
        if task.syncState != .local {
            Label(syncMessage, systemImage: syncSymbol)
                .font(Theme.Text.metadata)
                .foregroundStyle(task.syncState.needsAttention ? Theme.Colors.warning : Theme.Colors.secondaryText)
                .accessibilityIdentifier("task.syncNotice")
        }

        if let reason = task.dateReview {
            HStack(spacing: Theme.Spacing.small) {
                Label(reason.summary, systemImage: "questionmark.circle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer(minLength: 0)

                if reason == .deadlineMayHaveBeenAReminder, let deadline = task.dueAt {
                    Button("Make It a Reminder") {
                        act { services in
                            try services.tasks.setReminder(deadline, timed: true, on: task)
                            try services.tasks.setDeadline(nil, on: task)
                            try services.items.update(task) { $0.dateReview = nil }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
                }

                Button("Keep As Is") { act { try $0.items.update(task) { $0.dateReview = nil } } }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }
            .accessibilityIdentifier("task.reviewNotice")
        }
    }

    private var syncSymbol: String {
        task.syncState.needsAttention ? "exclamationmark.triangle" : "arrow.trianglehead.2.clockwise.rotate.90"
    }

    private var syncMessage: String {
        switch task.syncState {
        case .local: ""
        case .linked: "Linked to Reminders. Title, notes, dates, and completion stay in step."
        case .pendingUpload: "Waiting to send changes to Reminders."
        case .conflicted: "This and its reminder were both changed. Nothing has been overwritten."
        case .externalMissing: "The reminder this was linked to is gone. Everything here is untouched."
        case .externalReadOnly: "The reminder is on a list that does not accept changes."
        }
    }

    // MARK: - Text

    private var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { newValue in
                title = newValue
                pendingSave.schedule { commitText() }
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { notes },
            set: { newValue in
                notes = newValue
                pendingSave.schedule { commitText() }
            }
        )
    }

    /// Pulls the task's text into local state, flushing whatever the last card left pending.
    private func load() {
        pendingSave.flush()
        loadedTaskID = task.id
        title = task.title
        notes = task.body
        newStepTitle = ""
        isStepFieldVisible = false
        focus = .title
    }

    private func commitText() {
        guard let services,
              let id = loadedTaskID,
              let subject = (try? services.items.item(id: id)) ?? nil,
              !subject.isInTrash
        else { return }

        // Nothing changed; do not touch `updatedAt`.
        guard subject.title != title || subject.body != notes else { return }

        let newTitle = title
        let newNotes = notes

        services.perform {
            try services.items.update(subject) { item in
                item.title = newTitle
                item.body = newNotes
            }
            services.noteChange(to: subject)
        }
        onChange()
    }

    // MARK: - Actions

    private func close() {
        pendingSave.flush()
        onClose()
    }

    private func toggle() {
        act {
            if task.status == .completed {
                try $0.tasks.reopen(task)
            } else {
                _ = try $0.tasks.complete(task)
            }
        }
    }

    /// ### Why this does not also call `onChange`
    /// `services.noteChange(to:)` already bumps `AppServices.changeToken`, which is half of the
    /// workspace's `reloadToken` — so the list reloads on its own, through the same path every other
    /// change in the app uses. Calling `onChange` here as well ran the whole reload twice per tick of
    /// a checkbox: two fetches of the destination and two passes of the scheduling rules over
    /// everything in it, for one edit.
    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: task)
        }
    }
}

// MARK: - Shared completion control

/// The tick, drawn the same way on a row and on an open card.
///
/// Extracted so the control does not move or change size at the moment a row becomes a card. It is
/// the one thing on both, and a tick that shifted two points on opening would make the card look like
/// a different object rather than the same one, larger.
struct TaskCompletionControl: View {
    let task: Item
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: symbolName)
                .font(.system(size: 13))
                .rowTint(controlColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .calmAnimation(value: task.status)
        .accessibilityLabel(task.status == .completed ? "Mark incomplete" : "Mark complete")
        .accessibilityIdentifier("task.toggle.\(task.id.uuidString)")
    }

    private var symbolName: String {
        switch task.status {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        default: task.isFlagged ? "circle.dotted.circle" : "circle"
        }
    }

    private var controlColor: Color {
        switch task.status {
        case .completed: Theme.Colors.completed
        case .cancelled: Theme.Colors.tertiaryText
        default: Theme.Colors.secondaryText
        }
    }
}
