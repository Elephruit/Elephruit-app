import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// One task in a list.
///
/// ### What a row does not show
/// Every field a task has is not information; it is noise with a field name attached. A row carries
/// the completion control, the title, and **only the metadata that is currently true and currently
/// relevant** — a deadline that is close, a start date that has not arrived, a flag that was set, a
/// person being waited on, steps that exist. A task with none of those is one line and nothing else,
/// which is what most tasks are.
///
/// Deliberately absent: a card border, a shadow, a coloured background, a second row of chips, a
/// progress bar, and a red fill for overdue work. Overdue is drawn with the same weight as
/// everything else and a colour on the date alone — the news is the date, not the whole row, and a
/// list of red rows stops meaning anything by the third one.
struct TaskRow: View {
    @Environment(\.services) private var services

    let task: Item

    /// Whether to show where the task lives. Suppressed inside a project, where it would repeat the
    /// heading above it on every line.
    var showsContainer = true

    /// Whether the row is the one the detail pane is showing.
    var isSelected = false

    /// Whether this row is currently the open card.
    ///
    /// ### Why a row and a card are one view rather than two
    /// Because they are one object in two states, and the list has to be able to tell that. Two
    /// sibling views swapped by the parent would mean the row's identity changed at the moment of
    /// opening — and `List` reads identity to decide what to animate, what stays selected, and what
    /// a drag is carrying. Swapping the *body* keeps the row the same row, which is what makes the
    /// rows below simply move down.
    ///
    /// The same shape ``TimeEntryGroupRow`` uses for the tracker's editable rows.
    var isEditing = false

    let navigation: NavigationModel

    var onToggle: () -> Void

    /// Called after the card writes something the list should redraw for.
    var onChange: () -> Void = {}

    /// Called when the card asks to close.
    var onClose: () -> Void = {}

    var body: some View {
        if isEditing {
            TaskCard(task: task, navigation: navigation, onChange: onChange, onClose: onClose)
        } else {
            summary
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            completionControl

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                titleLine

                if !metadata.isEmpty {
                    metadataLine
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeight)
        .hoverHighlight(isEnabled: !isSelected, extending: Theme.Spacing.small)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(task.status == .completed ? [.isSelected] : [])
    }

    // MARK: - Completion

    /// The same control the card draws, so it neither moves nor changes size on opening.
    ///
    /// The satisfying part of ticking something off is that it happens immediately; an animation
    /// that delays the next action is the opposite of satisfying. So the fill changes with the
    /// standard motion and nothing waits for it. See ``TaskCompletionControl``.
    private var completionControl: some View {
        TaskCompletionControl(task: task, onToggle: onToggle)
    }

    // MARK: - Title

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(task.displayTitle)
                .font(Theme.Text.rowTitle)
                .rowForeground(task.title.isEmpty ? .placeholder : .primary)
                .strikethrough(task.status == .cancelled, color: Theme.Colors.tertiaryText)
                .lineLimit(1)

            if task.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .rowTint(Theme.Colors.dueToday)
                    .accessibilityHidden(true)
            }

            if let symbol = task.priority.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 8))
                    .rowForeground(.secondary)
                    .accessibilityHidden(true)
            }

            if task.syncState.needsAttention {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 8))
                    .rowTint(Theme.Colors.warning)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Metadata

    /// One line, at most, of what is currently true.
    private var metadataLine: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(metadata) { piece in
                HStack(spacing: Theme.Spacing.hairline) {
                    Image(systemName: piece.symbolName)
                        .font(.system(size: 9))
                    Text(piece.text)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)
                }
                .modifier(MetadataTint(color: piece.color))
            }
        }
    }

    private struct MetadataPiece: Identifiable {
        var id: String
        var symbolName: String
        var text: String
        /// `nil` means secondary, which is most of them. A colour is reserved for a date that has
        /// actually arrived.
        var color: Color?
    }

    private var metadata: [MetadataPiece] {
        guard let clock = services?.dateProvider else { return [] }
        let facts = task.taskFacts()
        var pieces: [MetadataPiece] = []

        // Where this task lives, and the list in Reminders counts as a place it lives.
        //
        // ### Why an imported task cites its list
        // Because it has no container, no filing and no tags — that is what an imported reminder
        // looks like, and it is why the Inbox used to collect every one of them. Now that they sit
        // outside the Inbox on the strength of a home nothing on the row mentioned, the row has to
        // mention it: a task appearing in Anytime with no visible origin is a task the user did not
        // create and cannot account for. The list's own name, not the word "System".
        if showsContainer, let container = containerTitle {
            pieces.append(MetadataPiece(id: "container", symbolName: "folder", text: container))
        } else if showsContainer, task.isKeptInStepWithAnExternalList {
            pieces.append(
                MetadataPiece(
                    id: "reminders",
                    symbolName: "app.badge.checkmark",
                    text: services?.reminders.listName(id: task.externalListIdentifier) ?? "Reminders"
                )
            )
        }

        switch facts.deadlineUrgency(on: clock.now, calendar: clock.calendar) {
        case .overdue(let days):
            pieces.append(
                MetadataPiece(
                    id: "deadline",
                    symbolName: "flag.pattern.checkered",
                    text: days == 1 ? "1 day late" : "\(days) days late",
                    // Calm urgency: the *date* is amber, not the row, and never red. Overdue is
                    // information about a date, and a red row is an accusation about a person.
                    color: Theme.Colors.dueToday
                )
            )
        case .today:
            pieces.append(
                MetadataPiece(
                    id: "deadline",
                    symbolName: "flag.pattern.checkered",
                    text: "Due today",
                    color: Theme.Colors.dueToday
                )
            )
        case .soon(let days):
            pieces.append(
                MetadataPiece(
                    id: "deadline",
                    symbolName: "flag.pattern.checkered",
                    text: days == 1 ? "Due tomorrow" : "Due in \(days) days"
                )
            )
        case .distant:
            if let deadline = facts.deadlineAt {
                pieces.append(
                    MetadataPiece(
                        id: "deadline",
                        symbolName: "flag.pattern.checkered",
                        text: deadline.formatted(.dateTime.day().month(.abbreviated))
                    )
                )
            }
        case .none:
            break
        }

        // A start date is only news while it is still in the future. Once it has arrived the task is
        // simply available, and saying so on every row would be a column of the word "available".
        if case .scheduled(let date) = facts.availability(on: clock.now, calendar: clock.calendar) {
            pieces.append(
                MetadataPiece(
                    id: "start",
                    symbolName: "play.circle",
                    text: "Starts " + date.formatted(.dateTime.day().month(.abbreviated))
                )
            )
        }

        if let reminderAt = facts.reminderAt {
            pieces.append(
                MetadataPiece(
                    id: "reminder",
                    symbolName: "bell",
                    text: facts.reminderIsTimed
                        ? reminderAt.formatted(date: .omitted, time: .shortened)
                        : reminderAt.formatted(.dateTime.day().month(.abbreviated))
                )
            )
        }

        if let person = task.waitingOnPerson() {
            pieces.append(
                MetadataPiece(id: "waiting", symbolName: "hourglass", text: person.displayTitle)
            )
        }

        if facts.checklistTotal > 0 {
            pieces.append(
                MetadataPiece(
                    id: "steps",
                    symbolName: "checklist",
                    text: "\(facts.checklistCompleted)/\(facts.checklistTotal)"
                )
            )
        }

        if facts.isRepeating {
            pieces.append(MetadataPiece(id: "repeat", symbolName: "repeat", text: ""))
        }

        if !task.tags.isEmpty {
            pieces.append(
                MetadataPiece(
                    id: "tags",
                    symbolName: "number",
                    text: task.tags.map(\.leafName).sorted().joined(separator: " ")
                )
            )
        }

        return pieces
    }

    private var containerTitle: String? {
        let containers = task.enclosingContainers()
        return (containers.project ?? containers.list ?? containers.area)?.displayTitle
    }

    // MARK: - Description

    /// The note preview, which the row does not have room for.
    private var tooltip: String {
        var lines = [task.displayTitle]
        if !task.body.isEmpty {
            lines.append(String(task.body.prefix(240)))
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityDescription: String {
        var parts = [task.displayTitle]
        if task.status == .completed { parts.append("completed") }
        if task.isFlagged { parts.append("flagged") }
        parts.append(contentsOf: metadata.map { $0.text.isEmpty ? "repeating" : $0.text })
        return parts.joined(separator: ", ")
    }
}

/// Applies a meaning-carrying colour, or the row's ordinary secondary style when there is none.
///
/// A modifier rather than a conditional inside the row, because `rowTint` and `rowForeground` are
/// different modifiers returning different types and a ternary between them does not typecheck.
private struct MetadataTint: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.rowTint(color)
        } else {
            content.rowForeground(.secondary)
        }
    }
}
