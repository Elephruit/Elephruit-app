import ElephruitDesign
import SwiftUI

/// The lightweight Reminders module.
///
/// This is deliberately not a task view: no task sections, projects, planning state, lifecycle,
/// inspector, or task service participates. The module owns one compact list and one local draft.
struct RemindersWorkspaceView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isComposing = false
    @State private var draft = ReminderComposerDraft()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            bottomBar
        }
        .background(Theme.Colors.windowBackground)
        .navigationTitle("Reminders")
        .accessibilityIdentifier("reminders.workspace")
    }

    private var header: some View {
        HStack {
            Label("Reminders", systemImage: "bell")
                .font(Theme.Text.title)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        if visibleReminders.isEmpty && !isComposing {
            EmptyStateView(
                symbolName: "bell",
                headline: "No reminders",
                message: "Keep the small things here, without turning them into tasks.",
                actionTitle: "New Reminder",
                action: openComposer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    if isComposing {
                        ReminderComposer(
                            draft: $draft,
                            onQuickCommit: { commit(keepsOpen: true) },
                            onCommitAndClose: { commit(keepsOpen: false) },
                            onCancel: closeComposer
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }

                    ForEach(visibleReminders) { reminder in
                        reminderRow(reminder)
                    }
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: openComposer) {
                Label("New Reminder", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(isComposing)
            .keyboardShortcut("n")

            Spacer()

            Text("Return saves · ⌘Return closes · Esc cancels")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: 44)
        .background(.bar)
    }

    private func reminderRow(_ reminder: LightweightReminder) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Button {
                services?.perform {
                    try services?.lightweightReminders.toggleCompletion(of: reminder.id)
                }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        reminder.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(reminder.title)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(
                        reminder.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                    )

                if !reminder.notes.isEmpty {
                    Text(reminder.notes)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                }

                metadata(for: reminder)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                services?.perform { try services?.lightweightReminders.delete(reminder.id) }
            }
        }
    }

    @ViewBuilder
    private func metadata(for reminder: LightweightReminder) -> some View {
        let labels = metadataLabels(for: reminder)
        if !labels.isEmpty {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
    }

    private func metadataLabels(for reminder: LightweightReminder) -> [String] {
        var labels: [String] = []
        if reminder.isSomeday {
            labels.append("Someday")
        } else if let startAt = reminder.startAt {
            labels.append(startAt.formatted(.dateTime.month(.abbreviated).day()))
        }
        if let dueAt = reminder.dueAt {
            labels.append("Deadline " + dueAt.formatted(.dateTime.month(.abbreviated).day()))
        }
        labels.append(contentsOf: reminder.tagSlugs.map { "#" + $0 })
        if !reminder.checklist.isEmpty {
            labels.append("\(reminder.checklist.count) checklist")
        }
        return labels
    }

    private var visibleReminders: [LightweightReminder] {
        services?.lightweightReminders.reminders ?? []
    }

    private func openComposer() {
        guard !isComposing else { return }
        draft.reset()
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
    }

    private func closeComposer() {
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = false
        }
        draft.reset()
    }

    private func commit(keepsOpen: Bool) {
        draft.commitPendingStep()
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let services
        else {
            if !keepsOpen { closeComposer() }
            return
        }

        let committed = draft
        services.perform {
            try services.lightweightReminders.create(from: committed, now: services.dateProvider.now)
        }

        if keepsOpen {
            draft.reset()
        } else {
            closeComposer()
        }
    }
}
