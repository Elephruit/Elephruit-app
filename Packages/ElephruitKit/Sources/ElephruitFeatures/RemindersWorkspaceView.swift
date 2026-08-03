import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The Reminders module: one compact list over first-class graph items.
struct RemindersWorkspaceView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let navigation: NavigationModel

    @State private var isComposing = false
    @State private var editingReminderID: UUID?
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
        .onAppear(perform: openLinkedReminderIfNeeded)
        .onChange(of: navigation.selectedItemID) { _, _ in openLinkedReminderIfNeeded() }
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
                message: "Keep everything you need to remember in one place.",
                actionTitle: "New Reminder",
                action: openComposer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    if isComposing && editingReminderID == nil {
                        ReminderComposer(
                            draft: $draft,
                            onQuickCommit: { commit(keepsOpen: true) },
                            onCommitAndClose: { commit(keepsOpen: false) },
                            onCancel: closeComposer
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }

                    ForEach(visibleReminders) { reminder in
                        if editingReminderID == reminder.id {
                            ReminderComposer(
                                draft: $draft,
                                onQuickCommit: { commit(keepsOpen: false) },
                                onCommitAndClose: { commit(keepsOpen: false) },
                                onCancel: closeComposer
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        } else {
                            reminderRow(reminder)
                        }
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

    private func reminderRow(_ reminder: Item) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Button {
                services?.perform {
                    guard let services else { return }
                    try services.reminderStore.toggleCompletion(of: reminder)
                    services.noteChange(to: reminder)
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

                if !reminder.body.isEmpty {
                    Text(reminder.body)
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openComposer(editing: reminder) }
        .accessibilityAction(named: "Edit Reminder") { openComposer(editing: reminder) }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                openComposer(editing: reminder)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                services?.perform {
                    guard let services else { return }
                    try services.reminderStore.delete(reminder)
                    services.noteChange(to: reminder)
                }
            }
        }
    }

    @ViewBuilder
    private func metadata(for reminder: Item) -> some View {
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

    private func metadataLabels(for reminder: Item) -> [String] {
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
        let people = reminder.outgoingLinks.compactMap { link -> String? in
            guard link.kind == .mentions,
                  let target = link.target,
                  target.kind == .person || target.kind == .organization
            else { return nil }
            return target.displayTitle
        }
        labels.append(contentsOf: people.sorted().map { "@" + $0 })
        if reminder.parent?.kind == .project, let projectTitle = reminder.parent?.title {
            labels.append(">" + projectTitle)
        }
        if !reminder.checklist.items.isEmpty {
            labels.append("\(reminder.checklist.items.count) checklist")
        }
        return labels
    }

    private var visibleReminders: [Item] {
        services?.reminderStore.reminders ?? []
    }

    private func openLinkedReminderIfNeeded() {
        guard !isComposing,
              let id = navigation.selectedItemID,
              let reminder = visibleReminders.first(where: { $0.id == id })
        else { return }
        openComposer(editing: reminder)
    }

    private func openComposer() {
        guard !isComposing else { return }
        editingReminderID = nil
        draft.reset()
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
    }

    private func openComposer(editing reminder: Item) {
        guard !isComposing else { return }
        draft = ReminderComposerDraft(reminder: reminder)
        editingReminderID = reminder.id
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
    }

    private func closeComposer() {
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = false
        }
        editingReminderID = nil
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
        let reminderID = editingReminderID
        services.perform {
            if let reminderID,
               let reminder = services.reminderStore.reminders.first(where: { $0.id == reminderID }) {
                try services.reminderStore.update(reminder, from: committed)
                services.noteChange(to: reminder)
            } else {
                let reminder = try services.reminderStore.create(from: committed)
                services.noteChange(to: reminder)
            }
        }

        if keepsOpen && reminderID == nil {
            draft.reset()
        } else {
            closeComposer()
        }
    }
}
