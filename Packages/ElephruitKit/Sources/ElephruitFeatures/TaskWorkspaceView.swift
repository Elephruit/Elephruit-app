import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The centre column, for every task destination.
///
/// One view rather than nine, because the differences between Today and Anytime are *which rows*
/// and *which headings*, both of which `TaskViewService` already decides. Nine views would be nine
/// copies of the same list with nine chances for the selection, the keyboard handling, and the
/// inline creation to drift apart.
///
/// Upcoming is the exception and gets its own body: it is grouped by day rather than by container,
/// its rows carry a reason, and dragging one means something different.
struct TaskWorkspaceView: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel

    @State private var sections: [TaskSectionGroup] = []
    @State private var flatTasks: [Item] = []
    @State private var agenda: [AgendaGroup] = []
    @State private var isPlanning = false
    @State private var draftTitle = ""
    @State private var draftSectionID: String?
    @State private var pendingLinkedDeletion: Item?
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        content
            .navigationTitle(navigation.windowTitle)
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .task(id: reloadToken) { reload() }
            .background { linkedDeletionDialog }
            // ⌫ on the selection, which is what somebody tries before they find any menu.
            .onDeleteCommand { trashSelection() }
            .focusedSceneValue(
                \.rowActions,
                RowActions(isEnabled: !navigation.selectedItemIDs.isEmpty) { trashSelection() }
            )
            .accessibilityIdentifier("tasks.workspace")
    }

    @ViewBuilder
    private var content: some View {
        if navigation.selection == .taskView(.upcoming) {
            UpcomingAgendaView(navigation: navigation, groups: agenda, onChange: reload)
        } else if sections.isEmpty, flatTasks.isEmpty, draftSectionID == nil {
            emptyState
        } else {
            list
        }
    }

    // MARK: - The list

    private var list: some View {
        List(selection: selectionBinding) {
            if isPlanning, navigation.selection == .taskView(.today) {
                TodayPlanningSection(navigation: navigation, onChange: reload) { isPlanning = false }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(tasks(in: section), id: \.id) { task in
                        row(for: task)
                    }
                    .onMove { offsets, destination in
                        move(in: section, from: offsets, to: destination)
                    }

                    inlineDraft(for: section)
                } header: {
                    header(for: section)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .safeAreaInset(edge: .bottom, spacing: 0) { batchBar }
    }

    private func row(for task: Item) -> some View {
        TaskRow(
            task: task,
            showsContainer: showsContainer,
            isSelected: navigation.selectedItemIDs.contains(task.id),
            onToggle: { toggle(task) }
        )
        .tag(task.id)
        .contextMenu { TaskContextMenu(task: task, navigation: navigation, onChange: reload) }
        // Every one of these is on the context menu too, and reachable from the keyboard. A gesture
        // is a shortcut for something that must already be possible without it.
        .rowSwipeActions(
            id: task.id,
            leading: RowSwipeActions.taskLeading(task, services: services, onChange: reload),
            trailing: RowSwipeActions.taskTrailing(
                task,
                services: services,
                onLinkedDeletion: { pendingLinkedDeletion = $0 },
                onChange: reload
            ),
            allowsFullSwipe: RowSwipeActions.taskAllowsFullSwipe(task)
        )
    }

    /// The one deletion a swipe is not allowed to finish.
    ///
    /// A task linked to Apple Reminders may live in an iCloud account shared with other people, and
    /// removing it from there because somebody tidied up in a different app is not recoverable. So
    /// the gesture reveals the button, the button asks, and the question is the same pair of
    /// commands the context menu already offers rather than a dialogue that Return dismisses.
    @ViewBuilder
    private var linkedDeletionDialog: some View {
        EmptyView()
            .confirmationDialog(
                "Delete “\(pendingLinkedDeletion?.displayTitle ?? "")”?",
                isPresented: linkedDeletionBinding,
                presenting: pendingLinkedDeletion
            ) { task in
                Button("Remove from Elephruit Only") { removeLocally(task) }
                Button("Delete Here and in Reminders", role: .destructive) { deleteBoth(task) }
                Button("Cancel", role: .cancel) { pendingLinkedDeletion = nil }
            } message: { _ in
                Text("""
                    This task is linked to a reminder. Removing it here leaves the reminder exactly \
                    where it is; deleting both removes it from Reminders on every device it syncs \
                    to, and from anybody the list is shared with.
                    """)
            }
    }

    private var linkedDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingLinkedDeletion != nil },
            set: { if !$0 { pendingLinkedDeletion = nil } }
        )
    }

    private func removeLocally(_ task: Item) {
        guard let services else { return }
        pendingLinkedDeletion = nil
        Task {
            _ = await services.reminderSync.delete(task, choice: .removeLocally)
            services.noteRemoval(of: task.id)
            reload()
        }
    }

    private func deleteBoth(_ task: Item) {
        guard let services else { return }
        pendingLinkedDeletion = nil
        Task {
            _ = await services.reminderSync.delete(task, choice: .deleteBoth)
            services.noteRemoval(of: task.id)
            reload()
        }
    }

    /// Repeating the container inside a smart list is the point of it; repeating it inside a
    /// container-grouped list would put the heading on every row beneath the heading.
    private var showsContainer: Bool {
        switch navigation.selection {
        case .taskView(.anytime), .taskView(.someday): false
        default: true
        }
    }

    @ViewBuilder
    private func header(for section: TaskSectionGroup) -> some View {
        switch section.heading {
        case .today(let part):
            SectionHeader(part.title, count: section.taskIDs.count)
        case .container(_, let title, let symbolName, let colorName):
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: symbolName)
                    .foregroundStyle(Theme.Palette.color(named: colorName))
                SectionHeader(title, count: section.taskIDs.count)
            }
        case .unfiled:
            SectionHeader("No project", count: section.taskIDs.count)
        case .day(let date):
            SectionHeader(dayTitle(date), count: section.taskIDs.count)
        case .none:
            EmptyView()
        }
    }

    private func dayTitle(_ date: Date) -> String {
        guard let clock = services?.dateProvider else { return date.formatted(date: .abbreviated, time: .omitted) }
        if clock.calendar.isDate(date, inSameDayAs: clock.now) { return "Today" }
        if clock.calendar.isDate(date, inSameDayAs: clock.startOfDay(daysFromToday: -1)) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: - Inline creation

    /// A row that asks only for a title.
    ///
    /// Return creates the task and leaves the field open in the same place, so a run of five
    /// captures is five titles and five Returns. Escape on an empty draft closes it without leaving
    /// a blank task behind — which is what a modal sheet per task cannot do.
    @ViewBuilder
    private func inlineDraft(for section: TaskSectionGroup) -> some View {
        if draftSectionID == section.id {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                TextField("New task", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.rowTitle)
                    .focused($isDraftFocused)
                    .onSubmit { commitDraft(in: section) }
                    .onExitCommand { closeDraft() }
                    .accessibilityIdentifier("tasks.inlineDraft")
            }
            .padding(.vertical, Theme.Spacing.tight)
            .frame(minHeight: Theme.Size.rowHeight)
            .listRowSeparator(.hidden)
        }
    }

    private func openDraft(in section: TaskSectionGroup?) {
        draftSectionID = section?.id ?? sections.first?.id ?? "flat"
        draftTitle = ""
        isDraftFocused = true
    }

    private func closeDraft() {
        draftSectionID = nil
        draftTitle = ""
    }

    private func commitDraft(in section: TaskSectionGroup) {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            closeDraft()
            return
        }
        guard let services else { return }

        services.perform {
            var draft = ItemDraft(kind: .task, title: trimmed)
            draft.parentID = containerID(for: section)
            let created = try services.items.create(draft)

            // Created *into* the view it was typed in, so a task added while looking at Today is on
            // today's plan rather than in a pile the user has to find again.
            if navigation.selection == .taskView(.today) {
                try services.tasks.commitToToday(created)
            }
            if navigation.selection == .taskView(.someday) {
                try services.tasks.setSomeday(true, on: created)
            }
            services.noteChange(to: created)
        }

        draftTitle = ""
        isDraftFocused = true
        reload()
    }

    private func containerID(for section: TaskSectionGroup) -> UUID? {
        if case .container(let id, _, _, _) = section.heading { return id }
        if case .item(let id) = navigation.selection { return id }
        return nil
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        switch navigation.selection {
        case .taskView(.today):
            EmptyStateView(
                symbolName: "sun.horizon",
                headline: "Your day is clear.",
                message: "Choose something from Anytime, or enjoy the space.",
                tone: .accomplished,
                actionTitle: "Plan today",
                action: { isPlanning = true }
            )
        case .taskView(.inbox):
            EmptyStateView(
                symbolName: "tray",
                headline: "Nothing waiting to be sorted",
                message: "Everything you captured has a home.",
                tone: .accomplished
            )
        case .taskView(.upcoming):
            EmptyStateView(
                symbolName: "calendar",
                headline: "Nothing dated ahead",
                message: "Start dates, deadlines, and reminders appear here on the day they land.",
                tone: .accomplished
            )
        case .taskView(.anytime):
            EmptyStateView(
                symbolName: "square.stack",
                headline: "Nothing to pick up",
                message: "Work becomes available here on its start date.",
                tone: .accomplished
            )
        case .taskView(.someday):
            EmptyStateView(
                symbolName: "archivebox",
                headline: "Nothing parked",
                message: "Ideas you are not ready for can wait here without being late."
            )
        case .taskView(.flagged):
            EmptyStateView(
                symbolName: "flag",
                headline: "Nothing flagged",
                message: "A flag marks something worth coming back to. It means whatever you decide."
            )
        case .taskView(.waiting):
            EmptyStateView(
                symbolName: "hourglass",
                headline: "Nobody owes you anything",
                message: "Mark a task as waiting when the next move belongs to somebody else.",
                tone: .accomplished
            )
        case .taskView(.completed):
            EmptyStateView(
                symbolName: "checkmark.seal",
                headline: "Nothing logged yet",
                message: "Finished and abandoned work is kept here."
            )
        case .builtInSmartList(let id):
            EmptyStateView(
                symbolName: BuiltInSmartList.list(id: id)?.symbolName ?? "line.3.horizontal.decrease.circle",
                headline: "Nothing matches",
                message: BuiltInSmartList.list(id: id)?.hint ?? "This list found nothing right now.",
                tone: .accomplished
            )
        case .smartList:
            EmptyStateView(
                symbolName: "line.3.horizontal.decrease.circle",
                headline: "Nothing matches",
                message: "This list found nothing right now. Its rules are unchanged.",
                tone: .noResults
            )
        default:
            EmptyStateView(
                symbolName: "checkmark.circle",
                headline: "No tasks",
                message: "Press ⌘N to add one.",
                actionTitle: "New Task",
                action: { openDraft(in: nil) }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if navigation.selection == .taskView(.today) {
            ToolbarItem {
                Button("Plan Today", systemImage: "sparkles") { isPlanning.toggle() }
                    .help("Review what is overdue and pull a manageable amount from Anytime")
                    .accessibilityIdentifier("tasks.planToday")
            }
        }

        ToolbarItem {
            Button {
                openDraft(in: sections.first)
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .keyboardShortcut("n")
            .disabled(!allowsCreation)
            .help(allowsCreation ? "Add a task here" : "This list is worked out rather than filed, so nothing can be added to it")
            .accessibilityIdentifier("tasks.newTask")
        }
    }

    /// A smart list computes its membership, so there is no "here" to add to. The Logbook is
    /// history. Offering a disabled button rather than hiding it keeps the toolbar from reshuffling
    /// as the selection changes.
    private var allowsCreation: Bool {
        switch navigation.selection {
        case .smartList, .builtInSmartList, .taskView(.completed), .taskView(.all), .taskView(.upcoming):
            false
        default:
            true
        }
    }

    private var subtitle: String {
        let count = flatTasks.count
        return count == 1 ? "1 task" : "\(count) tasks"
    }

    // MARK: - Batch actions

    @ViewBuilder
    private var batchBar: some View {
        if navigation.hasMultipleSelection {
            TaskBatchBar(
                navigation: navigation,
                tasks: flatTasks.filter { navigation.selectedItemIDs.contains($0.id) },
                onChange: reload
            )
        }
    }

    // MARK: - Data

    private var reloadToken: String {
        [
            String(describing: navigation.selection),
            String(services?.changeToken ?? 0),
        ].joined(separator: "|")
    }

    private func reload() {
        guard let services else { return }

        services.perform {
            switch navigation.selection {
            case .taskView(.today):
                sections = try services.taskViews.today()
                flatTasks = try services.taskViews.tasks(in: .today)

            case .taskView(.upcoming):
                agenda = try services.taskViews.upcoming()
                flatTasks = try services.taskViews.tasks(in: .upcoming)
                sections = []

            case .taskView(.anytime):
                sections = try services.taskViews.anytime()
                flatTasks = try services.taskViews.tasks(in: .anytime)

            case .taskView(.someday):
                sections = try services.taskViews.someday()
                flatTasks = try services.taskViews.tasks(in: .someday)

            case .taskView(.completed):
                sections = try services.taskViews.logbook()
                flatTasks = try services.taskViews.tasks(in: .completed)

            case .taskView(let view):
                let tasks = try services.taskViews.tasks(in: view)
                flatTasks = tasks
                sections = [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))]

            case .builtInSmartList(let id):
                let filter = BuiltInSmartList.list(id: id)?.filter ?? TaskFilter()
                let tasks = try services.taskViews.tasks(matching: filter)
                flatTasks = tasks
                sections = [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))]

            case .smartList(let id):
                let saved = services.taskViews.smartLists().first { $0.id == id }
                let tasks = try services.taskViews.tasks(matching: saved?.taskFilter ?? TaskFilter())
                flatTasks = tasks
                sections = [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))]

            default:
                sections = []
                flatTasks = []
            }
        }
    }

    private func tasks(in section: TaskSectionGroup) -> [Item] {
        let byID = Dictionary(flatTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return section.taskIDs.compactMap { byID[$0] }
    }

    // MARK: - Actions

    /// ⌫ on whatever is selected, as one undo step.
    ///
    /// The keyboard equivalent of the swipe, and the reason the gesture is a shortcut rather than
    /// the only way through. Linked tasks are held back and asked about one at a time, on the same
    /// terms the swipe uses: a batch that silently wrote to somebody's iCloud account is exactly
    /// what this integration promises not to do.
    private func trashSelection() {
        guard let services else { return }
        let targets = flatTasks.filter { navigation.selectedItemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        let owned = targets.filter { $0.syncState == .local }
        if !owned.isEmpty {
            services.perform { try services.undo.moveToTrash(owned) }
            services.refreshDerivedState()
            for task in owned { services.noteRemoval(of: task.id) }
        }

        navigation.selectedItemIDs = []
        pendingLinkedDeletion = targets.first { $0.syncState != .local }
        reload()
    }

    private func toggle(_ task: Item) {
        guard let services else { return }
        services.perform {
            if task.status == .completed {
                try services.tasks.reopen(task)
            } else {
                let outcome = try services.tasks.complete(task)
                if outcome.needsReminderPush {
                    Task { await services.reminders.sync(using: services.reminderSync) }
                }
            }
            services.noteChange(to: task)
        }
        reload()
    }

    /// Reordering, applied to whichever order this list is actually showing.
    ///
    /// In Today that is `todayOrder`; everywhere else it is the item's own `sortOrder`. Writing the
    /// wrong one would mean dragging a task in Today silently rearranged the project it belongs to.
    private func move(in section: TaskSectionGroup, from offsets: IndexSet, to destination: Int) {
        guard let services else { return }
        var ordered = tasks(in: section)
        guard !ordered.isEmpty else { return }

        let moved = offsets.compactMap { ordered.indices.contains($0) ? ordered[$0] : nil }
        for index in offsets.sorted(by: >) where ordered.indices.contains(index) {
            ordered.remove(at: index)
        }
        let landing = min(max(destination - offsets.count { $0 < destination }, 0), ordered.count)
        ordered.insert(contentsOf: moved, at: landing)

        services.perform {
            if navigation.selection == .taskView(.today) {
                try services.tasks.reorderToday(ordered)
            } else {
                for (offset, task) in ordered.enumerated() {
                    try services.items.update(task) { $0.sortOrder = Double(offset + 1) * 1_024 }
                }
            }
        }
        reload()
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { navigation.selectedItemIDs },
            set: { navigation.selectedItemIDs = $0 }
        )
    }
}
