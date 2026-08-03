import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The actions available on whatever the list is currently about.
///
/// ### Why the actions left the window toolbar
/// Because they stopped being properties of the window. A toolbar button is available for as long as
/// the window is, and the moment a task's row can become an editor the useful actions depend on
/// *whether a card is open* — Move and Trash and Repeat mean a task when one is open and mean nothing
/// when none is. A toolbar that changed its contents as you clicked rows would be a toolbar nobody
/// could aim at; a bar at the foot of the list, under the thing it acts on, is allowed to.
///
/// ### Why it takes the multi-selection bar's slot rather than sitting beside it
/// `TaskBatchBar` already occupied the bottom safe-area inset, and a second bar there would be two
/// rows of buttons stacked at the foot of a list, one of which is empty most of the time. Multiple
/// selection is not a different surface — it is a third thing this bar can be about, alongside "the
/// list" and "the open task".
///
/// The bar is centred on the content column rather than on the window, so it stays under the rows it
/// acts on however wide the pane is dragged.
struct TaskBottomBar: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    /// The task whose card is open, if one is.
    let editingTask: Item?

    /// Everything currently selected. More than one puts the bar into its batch state.
    let selectedTasks: [Item]

    /// Whether this destination can be added to at all. A smart list computes its membership and the
    /// Logbook is history, so neither has a "here" to add to.
    let allowsCreation: Bool

    /// Whether a heading makes sense here — only inside a project or a list.
    let allowsHeadings: Bool

    var onNewTask: @MainActor () -> Void
    var onNewHeading: @MainActor () -> Void
    var onChange: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let summary {
                Text(summary)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            AdaptiveActionBar(actions)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // ### Where ⌘N lives now
        // `AdaptiveActionBar` draws its buttons from `ActionItem`s, which describe an action rather
        // than carry a key binding — deliberately, since the same action appears in a row, in an
        // overflow menu, and at three widths. So the shortcut is hosted by an invisible twin of the
        // New Task button, placed here rather than left in the window toolbar: a shortcut belongs
        // beside the control it fires, not in the region that control just left.
        .background {
            Button("New Task", action: onNewTask)
                .keyboardShortcut("n")
                .disabled(!allowsCreation)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .popover(item: $moveTarget, arrowEdge: .top) { task in
            TaskMovePopover(task: task) {
                moveTarget = nil
                onChange()
            }
        }
        .popover(item: $repeatTarget, arrowEdge: .top) { task in
            repeatPopover(for: task)
        }
        .accessibilityIdentifier("tasks.bottomBar")
    }

    /// The four cadences, and the way out.
    ///
    /// ### Why four fixed choices rather than an editor
    /// ``ElephruitCore/RecurrenceRule`` can express far more than this — intervals, weekday sets, a
    /// day of the month, two anchors, three ways to end — and quick entry already reads most of it
    /// from a phrase like "every 3 days after completion". What does not exist is a screen for
    /// building one, and inventing a half-editor here would be a worse answer than four buttons that
    /// cover the common cases honestly. The sentence at the foot says where the rest lives, so
    /// somebody who wants "every other Tuesday" is told how to get it rather than left hunting.
    private func repeatPopover(for task: Item) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { frequency in
                Button(frequency.displayName) { setRepeat(RecurrenceRule(frequency: frequency), on: task) }
                    .buttonStyle(.plain)
                    .font(Theme.Text.rowSubtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if task.recurrence != nil {
                Divider()
                Button("Stop Repeating") { setRepeat(nil, on: task) }
                    .buttonStyle(.plain)
                    .font(Theme.Text.rowSubtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Text("For anything else — every third day, from when you finish it — type it into quick entry: “every 3 days after completion”.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 240)
    }

    /// Said only when the bar is about something other than the list, because "you are looking at a
    /// list" is not news.
    private var summary: String? {
        if selectedTasks.count > 1 { return "\(selectedTasks.count) selected" }
        return nil
    }

    // MARK: - What is offered, and when

    private var actions: [ActionItem] {
        if selectedTasks.count > 1 { return batchActions }
        if let editingTask { return cardActions(for: editingTask) }
        return listActions
    }

    /// Adding to the list, and moving around it.
    private var listActions: [ActionItem] {
        [
            ActionItem(
                id: "task.new",
                title: "New Task",
                symbolName: "plus",
                priority: .essential,
                unavailabilityReason: allowsCreation
                    ? nil
                    : "This list is worked out rather than filed, so nothing can be added to it",
                shortcut: "⌘N",
                perform: onNewTask
            ),
            ActionItem(
                id: "task.newHeading",
                title: "New Heading",
                symbolName: "text.append",
                priority: allowsHeadings ? .common : .occasional,
                unavailabilityReason: allowsHeadings
                    ? nil
                    : "A heading divides a project or a list. This is neither.",
                detail: "A section inside this project",
                perform: onNewHeading
            ),
        ]
    }

    /// What can be done to the one task whose card is open.
    private func cardActions(for task: Item) -> [ActionItem] {
        [
            ActionItem(
                id: "task.move",
                title: "Move",
                symbolName: "arrow.right",
                priority: .essential,
                detail: "File this under a project, a list, or the Inbox",
                perform: { moveTarget = task }
            ),
            ActionItem(
                id: "task.trash",
                title: "Trash",
                symbolName: "trash",
                priority: .common,
                role: .destructive,
                perform: { trash(task) }
            ),
            ActionItem(
                id: "task.repeat",
                title: task.recurrence == nil ? "Repeat" : "Repeating",
                symbolName: "repeat",
                priority: .occasional,
                detail: task.recurrence?.summary ?? "Finishing it creates the next one",
                perform: { repeatTarget = task }
            ),
            ActionItem(
                id: "task.duplicate",
                title: "Duplicate",
                symbolName: "plus.square.on.square",
                priority: .occasional,
                detail: "A copy in the same place, with the same dates",
                perform: { duplicate(task) }
            ),
            ActionItem(
                id: "task.convert",
                title: "Convert to Project",
                symbolName: "square.stack.3d.up",
                priority: .occasional,
                // Offered on any task, not only one with subtasks. Realising that something is
                // bigger than one action is the moment this is wanted, and that moment usually comes
                // before the subtasks exist.
                detail: task.checklist.isEmpty
                    ? "Keeps its links, its dates, and everything pointing at it"
                    : "Its steps become the project's first tasks",
                perform: { convert(task) }
            ),
        ]
    }

    /// The actions that make sense applied to several tasks at once.
    ///
    /// Deliberately the short list. Everything here is a single fact set the same way on every
    /// selected task; anything that needs a decision per task — a date, a project, a person — belongs
    /// on a card, one at a time.
    ///
    /// ### What a batch is not allowed to do
    /// Reach a system reminder. Completing twenty tasks here completes them *in Elephruit*; the push
    /// to Reminders that a single completion performs is deliberately not run, because a batch that
    /// silently wrote to somebody's shared iCloud list is exactly what that integration promises not
    /// to do. Deleting is absent for the same reason and is asked about one task at a time — see the
    /// dialogue in ``TaskWorkspaceView``.
    ///
    /// Each button is **one** undo step, because each is one thing the user did.
    private var batchActions: [ActionItem] {
        [
            ActionItem(id: "batch.complete", title: "Complete", symbolName: "checkmark.circle", priority: .essential) {
                applyToSelection { services, task in _ = try services.tasks.complete(task) }
            },
            ActionItem(id: "batch.today", title: "Today", symbolName: "star", priority: .common) {
                applyToSelection { services, task in try services.tasks.apply(.today, to: task) }
            },
            ActionItem(id: "batch.flag", title: "Flag", symbolName: "flag", priority: .common) {
                applyToSelection { services, task in try services.tasks.setFlagged(true, on: task) }
            },
            ActionItem(id: "batch.someday", title: "Someday", symbolName: "archivebox", priority: .occasional) {
                applyToSelection { services, task in try services.tasks.apply(.someday, to: task) }
            },
            ActionItem(id: "batch.clear", title: "Deselect", symbolName: "xmark", priority: .occasional) {
                navigation.selectedItemIDs = []
            },
        ]
    }

    // MARK: - Doing them

    @State private var moveTarget: Item?
    @State private var repeatTarget: Item?

    private func setRepeat(_ rule: RecurrenceRule?, on task: Item) {
        guard let services else { return }
        repeatTarget = nil
        services.perform {
            try services.items.update(task) { $0.recurrence = rule }
            services.noteChange(to: task)
        }
        onChange()
    }

    private func trash(_ task: Item) {
        guard let services else { return }
        services.perform { try services.undo.moveToTrash([task]) }
        services.noteRemoval(of: task.id)
        onChange()
    }

    /// A copy in the same place, open and untouched.
    ///
    /// Not a copy of everything: the duplicate keeps the dates, the tags and the steps — the parts
    /// that took work — and drops completion, the place in Today, and any link to a reminder. A
    /// duplicate that arrived already finished, or that claimed the same reminder as its original, is
    /// two rows disagreeing about one fact.
    private func duplicate(_ task: Item) {
        guard let services else { return }
        services.perform {
            var draft = ItemDraft(kind: .task, title: task.title, parentID: task.parent?.id)
            draft.body = task.body
            draft.tagSlugs = task.tags.map(\.slug)
            let copy = try services.items.create(draft)

            // Written through `TaskService` rather than onto the object, so the copy goes past the
            // same invariants the original did — a start after a deadline is refused here exactly as
            // it would be if somebody typed it.
            if let start = task.availableFrom { try services.tasks.setStartDate(start, on: copy) }
            if let deadline = task.dueAt { try services.tasks.setDeadline(deadline, on: copy) }
            if task.isSomeday { try services.tasks.setSomeday(true, on: copy) }
            if task.priority != .normal { try services.tasks.setPriority(task.priority, on: copy) }

            // Steps come across unticked, on the same reasoning recurrence uses: the steps are the
            // work, and a copy that arrived half-finished is a copy of a state rather than of a plan.
            var steps = task.checklist
            steps.reset()
            try services.tasks.setChecklist(steps, on: copy)

            services.noteChange(to: copy)
        }
        onChange()
    }

    private func convert(_ task: Item) {
        guard let services else { return }
        services.perform {
            try services.tasks.convertToProject(task)
            services.noteChange(to: task)
        }
        onChange()
    }

    private func applyToSelection(_ work: (AppServices, Item) throws -> Void) {
        guard let services else { return }
        services.perform {
            for task in selectedTasks { try work(services, task) }
        }
        services.refreshDerivedState()
        onChange()
    }
}
