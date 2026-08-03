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

    /// ``flatTasks`` keyed by identifier, so a section can find its rows without the list rebuilding
    /// the index once per section.
    @State private var tasksByID: [UUID: Item] = [:]
    @State private var agenda: [AgendaGroup] = []
    @State private var isPlanning = false
    @State private var draftTitle = ""
    @State private var draftSectionID: String?
    @State private var pendingLinkedDeletion: Item?

    /// The one task whose row is currently a card.
    ///
    /// One rather than a set, deliberately. Two cards open at once would be two editors competing
    /// for Escape and for the debounced write, and the reason to open one is to work on it — which
    /// is a thing you do to one task at a time.
    @State private var editingState = InlineListEditingState<UUID>()

    @FocusState private var isDraftFocused: Bool

    var body: some View {
        content
            .navigationTitle(navigation.windowTitle)
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .task(id: reloadToken) { reload() }
            // A card is open *in a list*. Changing which list you are looking at closes it, because
            // the row it was is no longer on screen and an editor with no row under it is a detail
            // pane by another name.
            .onChange(of: navigation.selection) { _, _ in
                _ = editingState.endEditing()
            }
            // Somebody followed a link to a task from outside the list — see ``TaskRedirect``. The
            // destination has already been selected; this is the half that opens the card, once the
            // rows for that destination have actually loaded.
            .onChange(of: navigation.taskToOpen) { _, _ in openRequestedTask() }
            .onChange(of: reloadToken) { _, _ in openRequestedTask() }
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
            UpcomingAgendaView(navigation: navigation, groups: agenda, tasksByID: tasksByID, onChange: reload)
        } else if sections.isEmpty, flatTasks.isEmpty, draftSectionID == nil {
            emptyState
        } else {
            // The column is capped for the ordinary reason a column of text is: a task title
            // dragged out to 1400 points puts its own metadata a foot away from itself. Anchored
            // leading rather than centred, because the window title sits at the column's left edge
            // and a page floating in the middle of a wide column reads as content that has escaped
            // its space — the same decision Time's log makes. The bottom bar rides inside this
            // frame, so it stays under the rows it acts on.
            list
                .frame(maxWidth: Theme.Size.editorMaxWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    ForEach(visibleTasks(in: section), id: \.id) { task in
                        row(for: task)
                    }
                    .onMove { offsets, destination in
                        move(in: section, from: offsets, to: destination)
                    }

                    showMoreRow(for: section)
                    inlineDraft(for: section)
                } header: {
                    header(for: section)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        // ### Why the list gives up its chrome
        // A separator between every row, an alternating fill behind every other one, and a grey
        // panel behind all of them are three different ways of saying "these are separate things"
        // to somebody who can already see that they are separate things. What is left doing the
        // work is the one thing that was always doing it: the space between rows.
        //
        // The column is capped and centred for the ordinary reason a column of text is: a task
        // title dragged out to 1400 points puts its own metadata a foot away from itself.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // Return on the selection, which is the way through the list without the mouse. A focused
        // field inside the open card consumes Return before this sees it, so the guard is belt and
        // braces rather than the mechanism.
        .onKeyPress(.return) {
            guard editingState.editingID == nil,
                  navigation.selectedItemIDs.count == 1,
                  let id = navigation.selectedItemIDs.first,
                  let task = tasksByID[id]
            else { return .ignored }
            open(task)
            return .handled
        }
        // Arrowing away from an open card closes it, on the same terms as clicking another row: the
        // card is an editor for the selected task, so a card for a task that is no longer selected
        // is a second answer to "which one am I looking at".
        .onChange(of: navigation.selectedItemIDs) { _, selection in
            if let id = editingState.editingID,
               !selection.isEmpty,
               !selection.contains(id) {
                _ = editingState.endEditing()
            }
        }
    }

    private func row(for task: Item) -> some View {
        TaskRow(
            task: task,
            showsContainer: showsContainer,
            isSelected: navigation.selectedItemIDs.contains(task.id),
            isEditing: editingState.editingID == task.id,
            navigation: navigation,
            onToggle: { toggle(task) },
            onChange: reload,
            onClose: {
                navigation.selectedItemIDs = editingState.endEditing(restoringSelection: task.id)
            }
        )
        .tag(task.id)
        .nativeListSelectionHighlightDisabled()
        .listRowSeparator(.hidden)
        // ### Why the selection is ours rather than the system's
        // macOS draws a solid accent fill behind a selected row. Compact rows use a quiet tint of
        // that accent instead; an open card is removed from selection altogether by
        // `InlineListEditingState`, because even a quiet row fill does not belong behind a form.
        .listRowBackground(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(navigation.selectedItemIDs.contains(task.id)
                    ? Theme.Colors.selectionFill
                    : Color.clear)
        )
        // ### The two ways in, and why there is no longer a third
        // Double-click, or Return on the selection. There used to also be "click a row that is
        // already selected", and it cost more than it was worth.
        //
        // Implementing it meant a single-tap `onTapGesture` beside the double-tap one, and two tap
        // gestures on one view force SwiftUI to disambiguate: it cannot fire the single until the
        // double-click interval has elapsed without a second click. So *every* click in the list
        // paid a quarter-second before anything happened, and the gesture swallowed the click on its
        // way past the `List`, which is what actually performs selection — so selection went through
        // SwiftUI state instead of AppKit and lost its immediacy too.
        //
        // A lone `simultaneousGesture` does neither. It does not consume the click, so the list
        // selects on mouse-up exactly as it always did, and with no single-tap gesture to
        // disambiguate against there is nothing to wait for.
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(task) })
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

    /// A glyph, a title, and a rule out to the edge.
    ///
    /// ### Why not the shared `SectionHeader`
    /// Because that one is built for a form: small caps, a count, and nothing else, which is right
    /// above a group of fields and wrong above a group of *things*. A list of tasks under a project
    /// wants the project — its icon, its colour, its name at reading weight — because the header is
    /// the answer to "what am I looking at" rather than a label on a region. The hairline carries the
    /// eye across the gap and gives the group an edge without a box.
    @ViewBuilder
    private func header(for section: TaskSectionGroup) -> some View {
        switch section.heading {
        case .today(let part):
            TaskSectionHeader(title: part.title, count: section.taskIDs.count)
        case .container(_, let title, let symbolName, let colorName):
            TaskSectionHeader(
                title: title,
                symbolName: symbolName,
                tint: Theme.Palette.color(named: colorName),
                count: section.taskIDs.count
            )
        case .unfiled:
            TaskSectionHeader(title: "No project", symbolName: "tray", count: section.taskIDs.count)
        case .day(let date):
            TaskSectionHeader(title: dayTitle(date), count: section.taskIDs.count)
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
                    // ### Why losing focus has to close it
                    // Escape closed the draft and Return committed it, and both need the field to
                    // still have focus. Clicking anywhere else — another row, another module, the
                    // desktop — took the focus away and left the row behind: an empty circle and the
                    // grey word "New task", sitting in a section it does not belong to, with no
                    // control on it and no way to get rid of it. It looked like a task that could
                    // not be deleted, because it looked like a task.
                    //
                    // Whatever was typed is kept: if the draft has text, losing focus commits it
                    // rather than discarding it, on the same terms as Return. Only an empty draft
                    // disappears, and an empty draft is not something anybody can lose.
                    .onChange(of: isDraftFocused) { _, hasFocus in
                        guard !hasFocus, draftSectionID == section.id else { return }
                        commitDraft(in: section)
                    }
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
            var draft = ItemDraft(kind: .reminder, title: trimmed)
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

    /// What is left in the window toolbar once the actions moved to the foot of the list.
    ///
    /// Plan Today stays, and only Plan Today. It is not an action on a task or on a selection — it is
    /// a mode for the whole view, which is what a window toolbar is for. Everything else went to the
    /// foot of the list, where it can depend on whether a card is open.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if navigation.selection == .taskView(.today) {
            ToolbarItem {
                Button("Plan Today", systemImage: "sparkles") { isPlanning.toggle() }
                    .help("Review what is overdue and pull a manageable amount from Anytime")
                    .accessibilityIdentifier("tasks.planToday")
            }
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

    // MARK: - The bottom bar

    /// One bar, in the slot the multi-selection bar used to have to itself.
    ///
    /// Multiple selection is not a different surface; it is a third thing this bar can be about,
    /// alongside "the list" and "the open task". Two bars stacked at the foot of a list, one of them
    /// empty most of the time, is what the alternative looked like.
    private var bottomBar: some View {
        TaskBottomBar(
            navigation: navigation,
            editingTask: editingState.editingID.flatMap { tasksByID[$0] },
            selectedTasks: flatTasks.filter { navigation.selectedItemIDs.contains($0.id) },
            allowsCreation: allowsCreation,
            allowsHeadings: allowsHeadings,
            onNewTask: { openDraft(in: sections.first) },
            onNewHeading: { createHeading() },
            onChange: reload
        )
    }

    /// A heading divides a project or a list, so it is offered inside one and nowhere else.
    ///
    /// Stored rather than computed, because working it out means fetching the container from the
    /// store — and this is read by the bottom bar, which sits in the list's `safeAreaInset` and is
    /// therefore re-evaluated on every pass the list makes. A fetch per render is the shape of
    /// problem `FetchAudit` exists to catch; it is answered once per load instead, beside the rows
    /// it describes.
    @State private var allowsHeadings = false

    private func createHeading() {
        guard let services, case .item(let id) = navigation.selection else { return }
        services.perform {
            var draft = ItemDraft(kind: .heading, title: "New Heading")
            draft.parentID = id
            let created = try services.items.create(draft)
            services.noteChange(to: created)
        }
        reload()
    }

    // MARK: - Data

    /// Both halves are already `Equatable`, which is all `task(id:)` asks for — so there is no need
    /// to reflect over the selection and build a string on every evaluation of this body just to
    /// compare it with the last one.
    private struct ReloadToken: Equatable {
        var selection: SidebarSelection
        var changeToken: Int
    }

    private var reloadToken: ReloadToken {
        ReloadToken(selection: navigation.selection, changeToken: services?.changeToken ?? 0)
    }

    private func reload() {
        guard let services else { return }

        services.perform {
            switch navigation.selection {
            // One call rather than two. Each of the pair this replaced fetched every open task and
            // ran the scheduling rules over all of it, so arriving here traversed the library twice
            // to answer one question — see ``TaskViewService/contents(of:)``.
            case .taskView(let view):
                let contents = try services.taskViews.contents(of: view)
                sections = contents.sections
                agenda = contents.agenda
                flatTasks = contents.tasks

            case .builtInSmartList(let id):
                let filter = BuiltInSmartList.list(id: id)?.filter ?? TaskFilter()
                let tasks = try services.taskViews.tasks(matching: filter)
                flatTasks = tasks
                sections = [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))]
                agenda = []

            case .smartList(let id):
                let saved = services.taskViews.smartLists().first { $0.id == id }
                let tasks = try services.taskViews.tasks(matching: saved?.taskFilter ?? TaskFilter())
                flatTasks = tasks
                sections = [TaskSectionGroup(heading: .none, taskIDs: tasks.map(\.id))]
                agenda = []

            default:
                sections = []
                flatTasks = []
                agenda = []
            }

            tasksByID = Dictionary(flatTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            if case .item(let id) = navigation.selection, let container = try services.items.item(id: id) {
                allowsHeadings = container.kind.canContain(.heading)
            } else {
                allowsHeadings = false
            }
        }
    }

    /// The tasks in one section.
    ///
    /// The index is built when the tasks are loaded rather than here: this is called once per
    /// section from inside the body, and rebuilding a dictionary of every task for each of them made
    /// drawing the list quadratic in the number of sections for no reason.
    private func tasks(in section: TaskSectionGroup) -> [Item] {
        section.taskIDs.compactMap { tasksByID[$0] }
    }

    /// How much of a long section is drawn before it offers the rest.
    ///
    /// ### Why a section truncates at all
    /// Because a view that groups by container is answering "what is in each of these", and a
    /// project with sixty tasks in it answers that question in the first five and then buries the
    /// next project under fifty-five rows nobody is reading. Five is enough to know what a project
    /// is *about*; opening the project itself is where you go to work through it.
    ///
    /// Only ever container sections. Today has three sections and every row in them is there because
    /// the user or the calendar put it there, so hiding any of them would hide the plan.
    private static let sectionRowLimit = 5

    @State private var expandedSectionIDs: Set<String> = []

    private func truncates(_ section: TaskSectionGroup) -> Bool {
        guard case .container = section.heading else { return false }
        return section.taskIDs.count > Self.sectionRowLimit
            && !expandedSectionIDs.contains(section.id)
    }

    /// Resolves only the rows that will be drawn.
    ///
    /// The prefix is taken over the *identifiers*, before they are looked up. Taking it afterwards
    /// materialised the whole section — five hundred rows for a large project — and then threw all
    /// but five away, which made truncation cost more than not truncating.
    private func visibleTasks(in section: TaskSectionGroup) -> [Item] {
        guard truncates(section) else { return tasks(in: section) }
        return section.taskIDs.prefix(Self.sectionRowLimit).compactMap { tasksByID[$0] }
    }

    @ViewBuilder
    private func showMoreRow(for section: TaskSectionGroup) -> some View {
        if truncates(section) {
            let hidden = section.taskIDs.count - Self.sectionRowLimit
            Button("Show \(hidden) more") { expandedSectionIDs.insert(section.id) }
                .buttonStyle(.plain)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(minHeight: Theme.Size.rowHeight)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("tasks.showMore.\(section.id)")
        }
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

    /// Opens a task's card, closing whichever one was open.
    ///
    /// Closing the previous one is what makes "clicking another row closes this one" true without a
    /// dismissal gesture: the click that opens the next card is the same click that closes this one,
    /// and `TaskCard` flushes its pending write on the way out.
    /// Honours a pending open request, if its task is in this list yet.
    ///
    /// Called both when the request arrives and after each reload, because the two race: the request
    /// is set at the moment the destination changes, and the rows for that destination do not exist
    /// until `reload` has run. Clearing the request only once the task is found means an arrival that
    /// lands before the data does is picked up by the reload that follows.
    private func openRequestedTask() {
        guard let id = navigation.taskToOpen, let task = tasksByID[id] else { return }
        navigation.taskToOpen = nil
        open(task)
    }

    private func open(_ task: Item) {
        navigation.selectedItemIDs = editingState.beginEditing(task.id)
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
            set: { navigation.selectedItemIDs = editingState.acceptSelection($0) }
        )
    }
}
