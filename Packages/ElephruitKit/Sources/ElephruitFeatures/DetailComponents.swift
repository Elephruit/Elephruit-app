import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The header every detail view shares: glyph, editable title, and one line of context.
///
/// One line, not a block. The item being viewed should remain the visual focus, and a header that
/// grows to four rows of metadata is competing with it.
struct DetailHeader<Context: View>: View {
    let item: Item
    @Binding var title: String
    let isEditable: Bool
    @ViewBuilder let context: Context

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: item.effectiveSymbolName)
                    .foregroundStyle(Theme.Palette.color(named: item.colorName))
                    .accessibilityHidden(true)

                TextField("Title", text: $title, prompt: Text("Untitled \(item.kind.displayName)"))
                    .textFieldStyle(.plain)
                    .font(Theme.Text.title)
                    .disabled(!isEditable)
                    .accessibilityIdentifier(AccessibilityID.Detail.titleField)
                    .accessibilityLabel("Title")
            }

            context
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }
}

/// A dot-separated run of context facts, skipping the ones that are absent.
///
/// Nothing is reserved space for something that might be there; a project with no due date simply has
/// one fewer fact on the line. That is what keeps the line short enough to read at a glance.
struct ContextLine: View {
    let facts: [String]

    var body: some View {
        Text(facts.filter { !$0.isEmpty }.joined(separator: " · "))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A collapsed section at the foot of a detail view.
///
/// Backlinks, attachments, and time are all *about* the item rather than part of it, so they sit
/// below, closed, with their count visible. Progressive disclosure: the count is enough to decide
/// whether to open it.
struct DetailDisclosure<Content: View>: View {
    let title: String
    let count: Int?
    let systemImage: String
    @ViewBuilder let content: Content

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, Theme.Spacing.small)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .font(Theme.Text.rowSubtitle)
        }
        .disclosureGroupStyle(.automatic)
    }
}

/// The banner shown over an item in the Trash.
struct TrashBanner: View {
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "trash")
            Text("This item is in the Trash and cannot be edited.")
            Spacer()
            Button("Put Back", action: onRestore)
                .accessibilityIdentifier(AccessibilityID.Trash.restoreButton)
        }
        .font(Theme.Text.rowSubtitle)
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
        .padding(.horizontal, Theme.Spacing.large)
    }
}

/// A task row inside a detail view — a project's list, a task's subtasks.
///
/// Distinct from `ItemRow`: this one lives inside content rather than in a list column, so it shows
/// less. The container is already the context.
struct DetailTaskRow: View {
    let task: Item
    let dateProvider: any DateProvider
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: onToggle) {
                Image(systemName: task.status.symbolName)
                    .foregroundStyle(task.isCompleted ? Theme.Colors.completed : Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityIdentifier(AccessibilityID.ItemList.statusToggle(id: task.id.uuidString))

            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(task.displayTitle)
                        .strikethrough(task.isCompleted, color: Theme.Colors.tertiaryText)
                        .foregroundStyle(task.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText)
                        .lineLimit(1)

                    if !task.body.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: Theme.Spacing.small)

                    if !task.tagSlugs.isEmpty {
                        TagChipRow(slugs: task.tagSlugs, limit: 2)
                    }

                    if let dueAt = task.dueAt {
                        DueDateLabel(date: dueAt, dateProvider: dateProvider, isActionable: task.isActionable)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: Theme.Size.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.accessibilityDescription(using: dateProvider))
        .accessibilityIdentifier(AccessibilityID.ItemList.row(id: task.id.uuidString))
    }
}

/// The inline suggestion to complete a project.
///
/// Inline at the foot of the task list — not a sheet, not an alert, not a toast that steals focus.
/// A suggestion that interrupts is a decision being made for you; this one waits to be noticed.
struct CompletionSuggestion: View {
    let onComplete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text("Everything here is done.")
                .font(Theme.Text.rowSubtitle)

            Spacer(minLength: Theme.Spacing.small)

            Button("Complete Project", action: onComplete)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button("Not yet", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
        .accessibilityIdentifier("detail.completionSuggestion")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Everything in this project is done. Complete the project, or not yet.")
    }
}

/// What a destructive or cascading heading action will actually do, stated before it happens.
struct HeadingActionConfirmation: Identifiable {
    enum Action {
        case archive
        case trash
    }

    let id = UUID()
    let heading: Item
    let action: Action
    let taskCount: Int

    var title: String {
        switch action {
        case .archive: "Archive “\(heading.displayTitle)”?"
        case .trash: "Move “\(heading.displayTitle)” to the Trash?"
        }
    }

    /// Names the count, so the cascade is never a surprise.
    var message: String {
        guard taskCount > 0 else {
            return "This heading is empty."
        }
        let plural = taskCount == 1 ? "task" : "tasks"
        switch action {
        case .archive:
            return "Its \(taskCount) \(plural) will be archived with it. You can move them out first instead."
        case .trash:
            return "Its \(taskCount) \(plural) will go to the Trash with it. You can move them out first instead."
        }
    }

    var confirmTitle: String {
        switch action {
        case .archive: taskCount > 0 ? "Archive Heading and \(taskCount) Tasks" : "Archive Heading"
        case .trash: taskCount > 0 ? "Trash Heading and \(taskCount) Tasks" : "Trash Heading"
        }
    }
}
