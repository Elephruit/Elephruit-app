import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The Reminders module: the open work, in the five buckets the scheduling model distinguishes,
/// with a reading pane beside it.
///
/// What this replaces: one flat list in creation order — overdue interleaved with someday — whose
/// rows had no selection, whose editor was an inline card with eight tab stops and five
/// application-defined popovers, and whose module policy declared no detail pane, making it the
/// app's one dead end. The list is a `List` now, with everything that buys: arrow keys, native
/// selection, type-ahead through the shell. Space completes. Creating is one line of the same
/// grammar Quick Jot reads. Editing is the pane.
struct RemindersWorkspaceView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let navigation: NavigationModel

    @State private var isComposing = false
    @State private var composition = QuickJotComposition()
    @State private var vocabulary = CaptureVocabulary.empty
    @State private var showsCompleted = false
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isListFocused: Bool

    var body: some View {
        content
        .background(Theme.Colors.windowBackground)
        .navigationTitle("Reminders")
        .navigationSubtitle(subtitle)
        .accessibilityIdentifier("reminders.workspace")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showsCompleted) {
                    Label("Show Completed", systemImage: "checkmark.circle")
                }
                .help(showsCompleted ? "Hide completed reminders" : "Show completed reminders")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openComposer()
                } label: {
                    Label("New Reminder", systemImage: "plus")
                }
                .help("New reminder — one line, the capture grammar")
            }
        }
        .onChange(of: navigation.reminderComposerRequest) { _, _ in openComposer() }
        .task(id: services?.changeToken) {
            vocabulary = (try? services?.capture.vocabulary()) ?? .empty
        }
        // ⌘N, through the File menu — which reads this to say "New Reminder" rather than
        // "New Note" while this surface has focus.
        .focusedSceneValue(
            \.newItemCommand,
            NewItemCommand(title: "New Reminder") { openComposer() }
        )
        // The Edit menu's work-item verbs, acting on the selected row.
        .focusedSceneValue(\.workItemActions, workItemCommandActions)
        .focusedSceneValue(
            \.rowActions,
            RowActions(isEnabled: !navigation.selectedItemIDs.isEmpty) { trashSelection() }
        )
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        let groups = sections
        if groups.isEmpty && !isComposing && !showsCompleted {
            EmptyStateView(
                symbolName: "bell",
                headline: "No reminders",
                message: "Keep everything you need to remember in one place.",
                actionTitle: "New Reminder",
                action: openComposer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A `ScrollView` rather than a `List`, and the choice is visual before it is
            // structural: rows sit plainly on the page with room around them — no rule under
            // every line, no table chrome. `List` on this platform paints its own opaque table
            // behind everything (`scrollContentBackground(.hidden)` does not reach a plain-style
            // list), which is exactly the look this module exists to avoid. A scroll view draws
            // nothing it is not asked to. The selection and keyboard behaviour the list provided
            // lives on below, by hand.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        if isComposing {
                            composerCard
                        }

                        ForEach(groups) { group in
                            SectionHeader(group.section.title, count: group.reminders.count)
                                .padding(.top, Theme.Spacing.medium)
                                .padding(.horizontal, Theme.Spacing.tight)

                            ForEach(group.reminders) { reminder in
                                card(reminder, in: group.section)
                            }
                        }

                        if showsCompleted {
                            let done = services?.reminderStore.completed ?? []
                            if !done.isEmpty {
                                SectionHeader("Completed", count: done.count)
                                    .padding(.top, Theme.Spacing.medium)
                                    .padding(.horizontal, Theme.Spacing.tight)

                                ForEach(done) { reminder in
                                    card(reminder, in: nil)
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: navigation.selectedItemID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onMoveCommand(perform: moveSelection)
            // Space completes the selected reminder — the same key Today already honours.
            .onKeyPress(.space) {
                let targets = selectedReminders
                guard !targets.isEmpty else { return .ignored }
                targets.forEach(toggleCompletion)
                return .handled
            }
            .onDeleteCommand { trashSelection() }
        }
    }

    // MARK: - Rows on the page

    /// One reminder, plainly on the page: no box, no rule, just the row and room around it.
    ///
    /// The only background a row ever draws is selection — a tinted rounded fill, quiet enough
    /// that an overdue date keeps its red while it is looked at.
    private func card(_ reminder: Item, in section: ReminderStore.Section?) -> some View {
        let isSelected = navigation.selectedItemIDs.contains(reminder.id)
        return row(reminder, in: section)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isSelected ? Theme.Colors.selectionFill : Color.clear)
            )
            .contentShape(.rect)
            .onTapGesture { select(reminder) }
            .id(reminder.id)
    }

    /// The one exception: the live input draws a hairline, because a field needs an edge.
    private var composerCard: some View {
        composer
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.selection.opacity(0.35))
            )
    }

    // MARK: - Selection, by hand

    /// Click selects; ⌘-click toggles membership; ⇧-click extends from the primary selection —
    /// the platform's grammar, reimplemented because the container is no longer a `List`.
    private func select(_ reminder: Item) {
        isListFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            navigation.selectedItemIDs.formSymmetricDifference([reminder.id])
        } else if flags.contains(.shift), let anchor = navigation.selectedItemID {
            let order = visibleOrder.map(\.id)
            if let from = order.firstIndex(of: anchor),
               let to = order.firstIndex(of: reminder.id) {
                navigation.selectedItemIDs.formUnion(order[min(from, to)...max(from, to)])
            }
        } else {
            navigation.selectedItemIDs = [reminder.id]
        }
    }

    /// Every reminder on screen, top to bottom — the order the arrow keys travel.
    private var visibleOrder: [Item] {
        var items = sections.flatMap(\.reminders)
        if showsCompleted {
            items += services?.reminderStore.completed ?? []
        }
        return items
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let order = visibleOrder
        guard !order.isEmpty else { return }

        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }

        if let current = navigation.selectedItemID,
           let index = order.firstIndex(where: { $0.id == current }) {
            let next = min(max(index + step, 0), order.count - 1)
            navigation.selectedItemIDs = [order[next].id]
        } else if let entry = step > 0 ? order.first : order.last {
            navigation.selectedItemIDs = [entry.id]
        }
    }

    private var sections: [ReminderStore.SectionGroup] {
        services?.reminderStore.sections ?? []
    }

    private var subtitle: String {
        let open = sections.reduce(0) { $0 + $1.reminders.count }
        let overdue = sections.first { $0.section == .overdue }?.reminders.count ?? 0
        if overdue > 0 { return "\(open) open · \(overdue) overdue" }
        return open == 1 ? "1 open" : "\(open) open"
    }

    private var selectedReminders: [Item] {
        guard let store = services?.reminderStore else { return [] }
        let ids = navigation.selectedItemIDs
        guard !ids.isEmpty else { return [] }
        return store.reminders.filter { ids.contains($0.id) }
    }

    private var selectedReminder: Item? {
        guard let id = navigation.selectedItemID else { return nil }
        return services?.reminderStore.reminders.first { $0.id == id }
    }

    // MARK: - Rows

    private func row(_ reminder: Item, in section: ReminderStore.Section?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            WorkItemCompletionControl(item: reminder) {
                toggleCompletion(reminder)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(reminder.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(reminder.isCompleted, color: Theme.Colors.tertiaryText)
                    .rowForeground(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(1)

                if let breadcrumb = breadcrumb(for: reminder) {
                    Text(breadcrumb)
                        .font(Theme.Text.rowSubtitle)
                        .rowForeground(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if reminder.isFlagged {
                Image(systemName: "flag.fill")
                    .font(Theme.Text.metadata)
                    .rowTint(Theme.Colors.favorite)
                    .accessibilityLabel("Flagged")
            }

            if let label = dateLabel(for: reminder, in: section) {
                Text(label.text)
                    .font(Theme.Text.metadata)
                    .rowTint(label.color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: Theme.Size.rowHeight)
        .contextMenu {
            Button(reminder.isCompleted ? "Mark Incomplete" : "Mark Complete") {
                toggleCompletion(reminder)
            }
            Button(reminder.isFlagged ? "Unflag" : "Flag") {
                perform { try $0.reminderLifecycle.setFlagged(!reminder.isFlagged, on: reminder) }
            }
            Button("Move to Today") {
                perform {
                    try $0.reminderLifecycle.commit(reminder, to: $0.dateProvider.startOfToday)
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                trash(reminder)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Only what the row's own section does not already say. Inside "Today", a date reading
    /// "Today" is the header repeated on every line.
    private func dateLabel(for reminder: Item, in section: ReminderStore.Section?) -> (text: String, color: Color)? {
        guard let services else { return nil }
        let clock = services.dateProvider

        if let due = reminder.dueAt {
            if due < clock.startOfToday {
                // Whole calendar days between the due *day* and today, so a deadline missed late
                // yesterday evening reads "1 day late" rather than the "0 days late" the raw
                // interval arithmetic produced.
                let days = max(
                    1,
                    clock.calendar.dateComponents(
                        [.day],
                        from: clock.calendar.startOfDay(for: due),
                        to: clock.startOfToday
                    ).day ?? 1
                )
                // Amber, and phrased as a fact — "a red row is an accusation"; red stays
                // reserved for due-today-and-not-done, the one state still actionable in time.
                return ("\(days == 1 ? "1 day" : "\(days) days") late", Theme.Colors.dueToday)
            }
            if clock.calendar.isDate(due, inSameDayAs: clock.startOfToday) {
                return section == .today ? ("Due today", Theme.Colors.overdue) : nil
            }
            return (due.formatted(.dateTime.month(.abbreviated).day()), Theme.Colors.secondaryText)
        }

        if let start = reminder.startAt, section == .upcoming {
            return ("Starts " + start.formatted(.dateTime.month(.abbreviated).day()), Theme.Colors.secondaryText)
        }

        return nil
    }

    private func breadcrumb(for reminder: Item) -> String? {
        guard let parent = reminder.parent, parent.kind == .project || parent.kind == .area else {
            return nil
        }
        return parent.displayTitle
    }

    // MARK: - The composer

    /// One line of the capture grammar, with a live receipt of what it understood.
    ///
    /// The same sigils as Quick Jot, parsed by the same parser — `>project @person #tag !friday`
    /// — because two grammars wearing one syntax was the audit's sharpest interaction finding:
    /// tokens this module used to leave in the title as literal text.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.Colors.selection)

                TextField(
                    "New reminder — try “Send draft >Q3 Launch @Sarah #writing !friday”",
                    text: $composition.titleText
                )
                .textFieldStyle(.plain)
                .font(Theme.Text.rowTitle)
                .focused($isComposerFocused)
                .onSubmit { commit(keepsOpen: true) }
                .onKeyPress(.escape) {
                    closeComposer()
                    return .handled
                }
                .accessibilityLabel("New reminder")
                .accessibilityHint("The capture grammar works here: project, person, tag, and date tokens.")
            }

            if !previewChips.isEmpty {
                HStack(spacing: Theme.Spacing.tight) {
                    ForEach(previewChips, id: \.text) { chip in
                        Chip(chip.text, systemImage: chip.symbol, tint: chip.tint)
                    }
                }
                .padding(.leading, Theme.Spacing.section)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Understood: \(previewChips.map(\.text).joined(separator: ", "))")
            }

            Text("Return saves and stays · Esc closes")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.leading, Theme.Spacing.section)
        }
        .padding(.vertical, Theme.Spacing.small)
    }

    /// The receipt: what the grammar lifted, before anything is created.
    private var previewChips: [(text: String, symbol: String?, tint: Color?)] {
        let preview = composition.previewDraft(knowing: vocabulary)
        let clock = services?.dateProvider ?? SystemDateProvider()
        var chips: [(String, String?, Color?)] = []

        if let project = preview.projectHint {
            chips.append((project, "square.stack.3d.up", Theme.Colors.selection))
        }
        for person in preview.personHints {
            chips.append((person, "person", Theme.Colors.workDetail))
        }
        for tag in preview.tagSlugs {
            chips.append((tag, "number", nil))
        }
        if let due = preview.dueDate?.resolve(using: clock) {
            chips.append((
                "due " + due.formatted(.dateTime.month(.abbreviated).day()),
                "flag", Theme.Colors.dueToday
            ))
        }
        if let follow = preview.followDate?.resolve(using: clock) {
            chips.append((
                "from " + follow.formatted(.dateTime.month(.abbreviated).day()),
                "calendar", nil
            ))
        }
        return chips.map { (text: $0.0, symbol: $0.1, tint: $0.2) }
    }

    // MARK: - Actions

    private func openComposer() {
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
        isComposerFocused = true
    }

    private func closeComposer() {
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = false
        }
        composition = QuickJotComposition()
    }

    private func commit(keepsOpen: Bool) {
        guard let services else { return }

        _ = composition.flush(knowing: vocabulary)
        var draft = composition.captured(knowing: vocabulary)
        guard !draft.isEmpty else {
            if !keepsOpen { closeComposer() }
            return
        }

        // Always a reminder here, whatever the grammar would have inferred: this is the
        // Reminders module's own composer, and an undated line is still a reminder in it.
        draft.kind = .reminder

        services.perform {
            if let created = try services.captureDraft(draft) {
                navigation.selectItem(created.id)
            }
        }

        composition = QuickJotComposition()
        if keepsOpen {
            isComposerFocused = true
        } else {
            closeComposer()
        }
    }

    private func toggleCompletion(_ reminder: Item) {
        perform { try $0.reminderStore.toggleCompletion(of: reminder) }
    }

    private func trashSelection() {
        let targets = selectedReminders
        guard !targets.isEmpty, let services else { return }
        // One undo step for the batch, because it was one act.
        services.perform { try services.undo.moveToTrash(targets) }
        navigation.selectedItemIDs = []
        services.noteRemoval(of: targets.first?.id ?? UUID())
    }

    private func trash(_ reminder: Item) {
        guard let services else { return }
        services.perform { try services.undo.moveToTrash([reminder]) }
        if navigation.selectedItemID == reminder.id {
            navigation.selectItem(nil)
        }
        services.noteRemoval(of: reminder.id)
    }

    private func perform(_ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.refreshDerivedState()
        }
    }

    private var workItemCommandActions: WorkItemCommandActions? {
        let targets = selectedReminders
        guard !targets.isEmpty else { return nil }
        let allFlagged = targets.allSatisfy(\.isFlagged)
        return WorkItemCommandActions(
            isEnabled: true,
            isFlagged: allFlagged,
            complete: { targets.forEach(toggleCompletion) },
            toggleFlag: {
                perform { services in
                    for reminder in targets {
                        try services.reminderLifecycle.setFlagged(!allFlagged, on: reminder)
                    }
                }
            },
            moveToToday: {
                perform { services in
                    for reminder in targets {
                        try services.reminderLifecycle.commit(
                            reminder, to: services.dateProvider.startOfToday
                        )
                    }
                }
            }
        )
    }
}
