import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A task's scheduling, its steps, and who it is waiting on.
///
/// ### Progressive disclosure, and what decides what is open
/// A task with nothing set shows two lines and a row of buttons. A task with a deadline shows the
/// deadline. Nothing here is a form: a field appears because it holds a value or because the user
/// asked for it, never because the model has a column for it.
///
/// The rule for what starts open is "is it true?" rather than "is it important?". Importance is a
/// judgement the app would be making on the user's behalf; truth is a fact it can read.
struct TaskDetailPanels: View {
    @Environment(\.services) private var services
    let task: Item
    let navigation: NavigationModel

    @State private var newStepTitle = ""
    @FocusState private var isStepFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TaskAttributeRow(task: task)
            marks
            recurrence
            checklist
            waiting
            syncNotice
            reviewNotice
        }
        .padding(.horizontal, Theme.Spacing.large)
    }

    // MARK: - Marks

    /// The two marks that are not attributes.
    ///
    /// ### Why Today and Someday left this row
    /// They were two toggles beside a *Dates* disclosure holding three more date controls, so the
    /// question "when is this for" had five answers spread across two regions and one of them could
    /// contradict another. All five now live in ``WhenPopover``, which is one control that can only
    /// give one answer.
    ///
    /// A flag is genuinely not one of them: it means whatever the user decides, it implies no date
    /// and no priority, and it is the one mark whose whole value is that it says nothing specific.
    private var marks: some View {
        HStack(spacing: Theme.Spacing.small) {
            Toggle(isOn: flagBinding) {
                Label("Flag", systemImage: "flag")
            }
            .help("Worth coming back to. Implies no deadline, no priority, and no place in Today.")

            Spacer()
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var recurrence: some View {
        if let rule = task.recurrence {
            HStack(spacing: Theme.Spacing.small) {
                Label(rule.summary, systemImage: "repeat")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                Spacer()
                Button("Stop Repeating") { act { try $0.items.update(task) { $0.recurrence = nil } } }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }
        }
    }

    // MARK: - Checklist

    /// Steps inside this one action.
    ///
    /// A step is not a task and does not appear in any list. The distinction is explained where it
    /// costs nothing — on the button that converts one — rather than being something the user has to
    /// understand before typing.
    @ViewBuilder
    private var checklist: some View {
        let steps = task.checklist
        if !steps.isEmpty || isStepFieldFocused {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                SectionHeader("Steps", count: steps.total)

                ForEach(steps.items) { step in
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

                        Spacer()

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

                stepField
            }
        } else {
            Button("Add Steps", systemImage: "checklist") { isStepFieldFocused = true }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .help("Short steps inside this one action. For work that needs its own dates, add a subtask instead.")
        }
    }

    private var stepField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.Colors.tertiaryText)

            TextField("Add a step", text: $newStepTitle)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowSubtitle)
                .focused($isStepFieldFocused)
                .onSubmit {
                    let trimmed = newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    act { try $0.tasks.addChecklistItem(trimmed, to: task) }
                    newStepTitle = ""
                    isStepFieldFocused = true
                }
                .accessibilityIdentifier("task.stepField")
        }
        .frame(minHeight: Theme.Size.rowHeight)
    }

    // MARK: - Waiting

    @ViewBuilder
    private var waiting: some View {
        if task.waitingSince != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                SectionHeader("Waiting")

                HStack(spacing: Theme.Spacing.small) {
                    if let person = task.waitingOnPerson() {
                        Button {
                            navigation.selectItem(person.id)
                        } label: {
                            Label(person.displayTitle, systemImage: "person")
                        }
                        .buttonStyle(.borderless)
                        .help("Open \(person.displayTitle)")
                    } else {
                        Label("Somebody else", systemImage: "hourglass")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    if let since = task.waitingSince {
                        Text("since " + since.formatted(.dateTime.day().month(.abbreviated)))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Spacer()

                    Button("No Longer Waiting") { act { try $0.tasks.clearWaiting(task) } }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                }

                OptionalDateRow(
                    label: "Follow up",
                    hint: "The day to chase this. Until then it stays out of Today.",
                    symbolName: "arrow.turn.up.right",
                    date: followUpBinding
                )
            }
        }
    }

    // MARK: - Notices

    /// Said once, quietly, where the user is already looking.
    @ViewBuilder
    private var syncNotice: some View {
        if task.syncState != .local {
            Label(syncMessage, systemImage: syncSymbol)
                .font(Theme.Text.metadata)
                .foregroundStyle(task.syncState.needsAttention ? Theme.Colors.warning : Theme.Colors.secondaryText)
                .accessibilityIdentifier("task.syncNotice")
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

    /// A date the migration deliberately did not interpret.
    @ViewBuilder
    private var reviewNotice: some View {
        if let reason = task.dateReview {
            HStack(spacing: Theme.Spacing.small) {
                Label(reason.summary, systemImage: "questionmark.circle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

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

    // MARK: - Bindings

    private var flagBinding: Binding<Bool> {
        Binding(get: { task.isFlagged }, set: { value in act { try $0.tasks.setFlagged(value, on: task) } })
    }

    private var followUpBinding: Binding<Date?> {
        Binding(
            get: { task.followUpAt },
            set: { value in act { try $0.tasks.mutate(task) { $0.followUpAt = value } } }
        )
    }

    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: task)
        }
    }
}

/// A date that may not be set, with a switch to add or remove it.
///
/// ### Why a toggle rather than an always-present picker
/// A `DatePicker` bound to a non-optional date has to invent a value for "no date", and every one of
/// those inventions is a date the user did not choose sitting in a field that looks chosen. The
/// toggle makes absence the default and presence deliberate — which is the whole point when two of
/// the three dates here are optional almost all of the time.
struct OptionalDateRow: View {
    let label: String
    let hint: String
    let symbolName: String
    @Binding var date: Date?
    var includesTime = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Label(label, systemImage: symbolName)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 110, alignment: .leading)

            if let value = date {
                DatePicker(
                    label,
                    selection: Binding(get: { value }, set: { date = $0 }),
                    displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                .datePickerStyle(.compact)

                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label.lowercased())")
            } else {
                Button("Add") { date = Date() }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
                    .accessibilityLabel("Add \(label.lowercased())")
            }

            Spacer()
        }
        .help(hint)
        .accessibilityElement(children: .contain)
        .accessibilityHint(hint)
    }
}
