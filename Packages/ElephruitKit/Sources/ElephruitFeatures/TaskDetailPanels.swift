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
            quickActions
            scheduling
            checklist
            waiting
            syncNotice
            reviewNotice
        }
        .padding(.horizontal, Theme.Spacing.large)
    }

    // MARK: - Quick actions

    /// The four things done most often, one click each.
    private var quickActions: some View {
        HStack(spacing: Theme.Spacing.small) {
            Toggle(isOn: todayBinding) {
                Label("Today", systemImage: "sun.horizon")
            }
            .help("Choose this for today. It stays chosen until you finish it or take it off.")

            Toggle(isOn: flagBinding) {
                Label("Flag", systemImage: "flag")
            }
            .help("Worth coming back to. Implies no deadline, no priority, and no place in Today.")

            Toggle(isOn: somedayBinding) {
                Label("Someday", systemImage: "archivebox")
            }
            .help("Parked on purpose. It leaves every count and cannot be late.")

            Spacer()

            Picker("Priority", selection: priorityBinding) {
                ForEach(Priority.allCases, id: \.self) { priority in
                    Text(priority.displayName).tag(priority)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Scheduling

    /// The three dates, always in this order and never sharing a name.
    ///
    /// "Start" and "Deadline" are separate rows with separate labels, because the entire scheduling
    /// model rests on somebody being able to tell them apart at a glance. The word "Due" appears only
    /// beside the deadline.
    @ViewBuilder
    private var scheduling: some View {
        DetailDisclosure(
            title: "Dates",
            count: dateCount,
            systemImage: "calendar",
            // Open when the task has a date, closed when it does not — so a plain task is two lines
            // and a dated one shows what it is committed to without a click.
            startsExpanded: dateCount > 0
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                OptionalDateRow(
                    label: "Start",
                    hint: "When this becomes worth thinking about. It can never be late.",
                    symbolName: "play.circle",
                    date: startBinding
                )

                OptionalDateRow(
                    label: "Deadline",
                    hint: "The date this must be finished by. The only date that can make it overdue.",
                    symbolName: "flag.pattern.checkered",
                    date: deadlineBinding
                )

                OptionalDateRow(
                    label: "Reminder",
                    hint: "When to interrupt you. Setting a date above never creates one of these.",
                    symbolName: "bell",
                    date: reminderBinding,
                    includesTime: true
                )

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

                if task.reminderOwner == .system {
                    Label(
                        "The alarm belongs to Reminders, so Elephruit will not send a second one.",
                        systemImage: "bell.badge"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    private var dateCount: Int {
        [task.availableFrom, task.dueAt, task.reminderAt].count { $0 != nil }
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

    private var todayBinding: Binding<Bool> {
        Binding(
            get: { services.map { task.isCommittedTo(today: $0.dateProvider) } ?? false },
            set: { newValue in
                act { newValue ? try $0.tasks.commitToToday(task) : try $0.tasks.removeFromToday(task) }
            }
        )
    }

    private var flagBinding: Binding<Bool> {
        Binding(get: { task.isFlagged }, set: { value in act { try $0.tasks.setFlagged(value, on: task) } })
    }

    private var somedayBinding: Binding<Bool> {
        Binding(get: { task.isSomeday }, set: { value in act { try $0.tasks.setSomeday(value, on: task) } })
    }

    private var priorityBinding: Binding<Priority> {
        Binding(get: { task.priority }, set: { value in act { try $0.tasks.setPriority(value, on: task) } })
    }

    private var startBinding: Binding<Date?> {
        Binding(get: { task.availableFrom }, set: { value in act { try $0.tasks.setStartDate(value, on: task) } })
    }

    private var deadlineBinding: Binding<Date?> {
        Binding(get: { task.dueAt }, set: { value in act { try $0.tasks.setDeadline(value, on: task) } })
    }

    private var reminderBinding: Binding<Date?> {
        Binding(
            get: { task.reminderAt },
            set: { value in act { try $0.tasks.setReminder(value, timed: true, on: task) } }
        )
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
