import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What a task has, and what it could have — in one row.
///
/// ### The rule
/// **A value is a chip; the absence of one is a button.** Setting a deadline replaces the Deadline
/// button with a deadline chip. Clearing it brings the button back. There is never both, and there
/// is never an empty field with a label beside it waiting to be filled in.
///
/// Two things follow from that, and both are the point. A task with nothing set is one short row of
/// small buttons rather than six blank form rows, so the ordinary case — a title and nothing else —
/// looks like the ordinary case. And a task with things set reads as a list of what is true about it,
/// with no scaffolding between the facts.
///
/// The rule is asserted rather than trusted: ``TaskAttributes`` is the same decision as a value, and
/// there is a suite over it.
struct TaskAttributeRow: View {
    @Environment(\.services) private var services

    let task: Item

    /// Offered only where there is somewhere to put steps. The detail panel has its own step field
    /// below, so it passes `nil` rather than growing a second way in.
    var onAddChecklist: (() -> Void)?

    var onChange: () -> Void = {}

    @State private var isShowingTags = false
    @State private var isShowingPeople = false

    var body: some View {
        ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            ForEach(attributes.chips) { chip in
                TaskValueChip(chip: chip) { clear(chip.kind) }
            }

            if attributes.buttons.contains(.when) {
                TaskWhenControl(task: task, onChange: onChange)
            }

            if attributes.buttons.contains(.tags) {
                attributeButton("Tags", symbolName: "tag", kind: .tags) { isShowingTags = true }
                    .popover(isPresented: $isShowingTags, arrowEdge: .bottom) {
                        TaskTagPopover(task: task) { isShowingTags = false }
                    }
            }

            if attributes.buttons.contains(.checklist), let onAddChecklist {
                attributeButton("Checklist", symbolName: "checklist", kind: .checklist, action: onAddChecklist)
            }

            if attributes.buttons.contains(.deadline) {
                TaskDeadlineControl(task: task, onChange: onChange)
            }

            if attributes.buttons.contains(.people) {
                attributeButton("People", symbolName: "person.2", kind: .people) { isShowingPeople = true }
                    .popover(isPresented: $isShowingPeople, arrowEdge: .bottom) {
                        TaskPeoplePopover(task: task) { isShowingPeople = false }
                    }
            }

            if attributes.buttons.contains(.priority) {
                priorityMenu
            }
        }
        .accessibilityIdentifier("task.attributes")
    }

    /// A menu rather than a popover, because the three values fit in one and a menu is what macOS
    /// uses for "pick one of a short fixed set".
    private var priorityMenu: some View {
        Menu {
            ForEach(Priority.allCases, id: \.self) { priority in
                Button(priority.displayName) {
                    act { try $0.tasks.setPriority(priority, on: task) }
                }
            }
        } label: {
            Label("Priority", systemImage: "exclamationmark")
                .font(Theme.Text.metadata)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How much this matters relative to everything else you could do instead.")
        .accessibilityIdentifier("task.button.priority")
    }

    private func attributeButton(
        _ title: String,
        symbolName: String,
        kind: TaskAttributes.Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: symbolName, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(kind.hint)
            .accessibilityIdentifier("task.button.\(kind.rawValue)")
    }

    private var attributes: TaskAttributes.Layout {
        let clock = services?.dateProvider ?? SystemDateProvider()
        return TaskAttributes.layout(
            for: task.taskFacts(),
            names: TaskAttributes.Names(
                people: task.linkedPeople(kinds: [.mentions]).map(\.displayTitle),
                waitingOn: task.waitingOnPerson()?.displayTitle
            ),
            now: clock.now,
            calendar: clock.calendar,
            offersChecklist: onAddChecklist != nil
        )
    }

    private func clear(_ kind: TaskAttributes.Kind) {
        switch kind {
        case .when:
            act { try $0.tasks.apply(.clear, to: task) }
        case .deadline:
            act { try $0.tasks.setDeadline(nil, on: task) }
        case .reminder:
            act { try $0.tasks.setReminder(nil, timed: false, on: task) }
        case .tags:
            act { try $0.items.setTags(task, slugs: []) }
        case .people:
            act { try $0.tasks.setRelatedPeople([], on: task) }
        case .priority:
            act { try $0.tasks.setPriority(.normal, on: task) }
        case .waiting:
            act { try $0.tasks.clearWaiting(task) }
        case .checklist:
            break
        }
    }

    private func act(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: task)
        }
        onChange()
    }
}

// MARK: - A value, as a chip

/// One thing that is true about a task, with the way to make it not true.
struct TaskValueChip: View {
    let chip: TaskAttributes.Chip
    let onClear: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: chip.symbolName)
                .font(.system(size: 9))

            Text(chip.text)
                .font(Theme.Text.metadata)
                .lineLimit(1)

            // Revealed on hover rather than always drawn. A row of five chips each carrying a
            // permanent ✕ is a row of five things offering to be deleted, which is not what a
            // summary of a task should look like.
            if isHovering, chip.isClearable {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(chip.text)")
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background {
            Capsule().fill(tint.opacity(0.12))
        }
        .onHover { isHovering = $0 }
        .help(chip.hint)
        .accessibilityIdentifier("task.chip.\(chip.kind.rawValue)")
    }

    /// The chip names a colour; the surface resolves it. Only one is ever named, and only for a date
    /// that has arrived.
    private var tint: Color {
        switch chip.tintName {
        case .dueToday: Theme.Colors.dueToday
        case nil: Theme.Colors.secondaryText
        }
    }
}
