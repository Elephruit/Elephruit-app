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

    /// ### Why the layout is computed once and handed down
    /// Because it is expensive and it was being asked for seven times. `TaskAttributes.layout` reads
    /// ``ElephruitModel/Item/taskFacts()``, which walks the ancestor chain, traverses `outgoingLinks`
    /// twice faulting every target, touches `children` and `attachments`, and decodes the checklist
    /// JSON — twice, once for the total and once for the completed count. Referring to `attributes`
    /// from each of the seven `if` statements below ran all of that seven times per body pass, and a
    /// card sits inside a `List` that re-evaluates its rows freely.
    ///
    /// A computed property cannot cache; a `let` in a function can. So the body is one call and the
    /// content is a function of the answer.
    var body: some View {
        content(attributes)
            .accessibilityIdentifier("task.attributes")
    }

    private func content(_ layout: TaskAttributes.Layout) -> some View {
        ElephruitDesign.FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            ForEach(layout.chips) { chip in
                TaskValueChip(chip: chip) { clear(chip.kind) }
            }

            if layout.buttons.contains(.when) {
                TaskWhenControl(task: task, onChange: onChange)
            }

            if layout.buttons.contains(.tags) {
                attributeButton("Tags", symbolName: "tag", kind: .tags) { isShowingTags = true }
                    .popover(isPresented: $isShowingTags, arrowEdge: .bottom) {
                        TaskTagPopover(task: task) { isShowingTags = false }
                    }
            }

            if layout.buttons.contains(.checklist), let onAddChecklist {
                attributeButton("Checklist", symbolName: "checklist", kind: .checklist, action: onAddChecklist)
            }

            if layout.buttons.contains(.deadline) {
                TaskDeadlineControl(task: task, onChange: onChange)
            }

            if layout.buttons.contains(.people) {
                attributeButton("People", symbolName: "person.2", kind: .people) { isShowingPeople = true }
                    .popover(isPresented: $isShowingPeople, arrowEdge: .bottom) {
                        TaskPeoplePopover(task: task) { isShowingPeople = false }
                    }
            }

            if layout.buttons.contains(.priority) {
                priorityMenu
            }
        }
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

    /// The names are looked up only for the chips that will actually exist.
    ///
    /// `linkedPeople` and `waitingOnPerson` each walk `outgoingLinks` and fault every target, and
    /// `taskFacts()` has already walked the same collection to produce the identifiers. Resolving
    /// both unconditionally meant three traversals for the ordinary task, which has nobody on it and
    /// is not waiting on anyone — so both are now guarded by the fact that decides whether their chip
    /// is drawn at all.
    private var attributes: TaskAttributes.Layout {
        let clock = services?.dateProvider ?? SystemDateProvider()
        let facts = task.taskFacts()

        var names = TaskAttributes.Names()
        if !facts.relatedPersonIDs.isEmpty {
            names.people = task.linkedPeople(kinds: [.mentions]).map(\.displayTitle)
        }
        if facts.lifecycle == .waiting {
            names.waitingOn = task.waitingOnPerson()?.displayTitle
        }

        return TaskAttributes.layout(
            for: facts,
            names: names,
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
