import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Upcoming

/// A date-ordered agenda of what is coming.
///
/// ### Why every row says which kind of date it is
/// A task can appear twice in here — once because it starts on Tuesday and once because it is due on
/// Friday — and the two are different facts. A row that showed only a title would make the agenda a
/// list of the same task repeated, and dragging one would be a coin toss between moving a runway and
/// moving a commitment.
///
/// So the *reason* is on the row, and it is the reason that travels with a drop. Dragging the row
/// that says "Deadline" moves the deadline; dragging the one that says "Starts" moves the start
/// date; neither ever touches the other. That is `TaskService.reschedule(_:reason:to:)`, and it is
/// the one API a drop can call.
struct UpcomingAgendaView: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel
    let groups: [AgendaGroup]
    let onChange: () -> Void

    @State private var dropTarget: Date?

    var body: some View {
        if groups.allSatisfy(\.entries.isEmpty) {
            EmptyStateView(
                symbolName: "calendar",
                headline: "Nothing dated ahead",
                message: "Start dates, deadlines, and reminders appear here on the day they land.",
                tone: .accomplished
            )
        } else {
            List(selection: selectionBinding) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                        if group.entries.isEmpty {
                            Text("Nothing")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        header(for: group)
                    }
                    .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                        drop(payloads, on: group)
                    } isTargeted: { isTargeted in
                        dropTarget = isTargeted ? group.start : nil
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: UpcomingEntry) -> some View {
        if let task = task(for: entry.taskID) {
            HStack(spacing: Theme.Spacing.small) {
                Label(entry.reason.title, systemImage: entry.reason.symbolName)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11))
                    .rowForeground(.secondary)
                    .frame(width: Theme.Size.rowGlyph)
                    .help(reasonHelp(entry.reason))

                TaskRow(
                    task: task,
                    showsContainer: true,
                    isSelected: navigation.selectedItemIDs.contains(task.id),
                    onToggle: { toggle(task) }
                )
            }
            .tag(task.id)
            .draggable(TaskDragPayload(taskID: task.id, reason: TaskDragPayload.Reason(entry.reason)))
            .contextMenu { TaskContextMenu(task: task, navigation: navigation, onChange: onChange) }
        }
    }

    private func reasonHelp(_ reason: UpcomingReason) -> String {
        switch reason {
        case .becomesAvailable: "Becomes available on this day. Dragging moves the start date only."
        case .deadline: "Must be finished by this day. Dragging moves the deadline only."
        case .reminder: "You will be interrupted at this time. Dragging keeps the time of day."
        case .followUp: "The day to chase this up."
        }
    }

    @ViewBuilder
    private func header(for group: AgendaGroup) -> some View {
        switch group.span {
        case .day(let date):
            SectionHeader(dayTitle(date), count: group.entries.isEmpty ? nil : group.entries.count)
        case .week(let start):
            SectionHeader("Week of " + start.formatted(.dateTime.day().month(.abbreviated)), count: group.entries.count)
        case .month(let start):
            SectionHeader(start.formatted(.dateTime.month(.wide).year()), count: group.entries.count)
        }
    }

    private func dayTitle(_ date: Date) -> String {
        guard let clock = services?.dateProvider else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        if clock.calendar.isDate(date, inSameDayAs: clock.now) { return "Today" }
        if clock.calendar.isDate(date, inSameDayAs: clock.startOfDay(daysFromToday: 1)) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: - Dropping

    private func drop(_ payloads: [TaskDragPayload], on group: AgendaGroup) -> Bool {
        guard let services else { return false }
        guard case .day(let day) = group.span else {
            // A week or a month band has no single day to drop onto, and picking one — the first? the
            // Monday? — would be the app choosing a date on the user's behalf.
            return false
        }

        var moved = false
        for payload in payloads {
            guard let task = try? services.items.item(id: payload.taskID) else { continue }
            services.perform {
                try services.tasks.reschedule(task, reason: payload.reason.upcomingReason(for: task), to: day)
                services.noteChange(to: task)
            }
            moved = true
        }
        if moved { onChange() }
        return moved
    }

    private func task(for id: UUID) -> Item? {
        try? services?.items.item(id: id)
    }

    private func toggle(_ task: Item) {
        guard let services else { return }
        services.perform {
            _ = try services.tasks.complete(task)
            services.noteChange(to: task)
        }
        onChange()
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { navigation.selectedItemIDs },
            set: { navigation.selectedItemIDs = $0 }
        )
    }
}

/// What travels with a dragged agenda row.
///
/// The **reason** rides along, because that is what decides which date a drop moves. A payload of
/// only an identifier would arrive at the drop handler with no way to tell a runway from a
/// commitment, and the handler would have to guess.
struct TaskDragPayload: Codable, Transferable, Hashable {
    /// A codable mirror of ``UpcomingReason``, which carries a `Date` this payload does not need.
    enum Reason: String, Codable, Hashable {
        case start, deadline, reminder, followUp

        init(_ reason: UpcomingReason) {
            switch reason {
            case .becomesAvailable: self = .start
            case .deadline: self = .deadline
            case .reminder: self = .reminder
            case .followUp: self = .followUp
            }
        }

        /// Rebuilds the reason, reading the task's current reminder so a moved reminder keeps its
        /// time of day.
        func upcomingReason(for task: Item) -> UpcomingReason {
            switch self {
            case .start: .becomesAvailable
            case .deadline: .deadline
            case .reminder: .reminder(task.reminderAt ?? Date())
            case .followUp: .followUp
            }
        }
    }

    var taskID: UUID
    var reason: Reason

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .elephruitTaskDrag)
    }
}

extension UTType {
    /// A private type, so a task dragged into another app carries nothing and a drop from elsewhere
    /// is never mistaken for one of ours.
    static let elephruitTaskDrag = UTType(exportedAs: "com.elephruit.task-drag")
}

// MARK: - Planning

/// The start-of-day review, offered rather than imposed.
///
/// ### What it deliberately does not do
/// It does not move overdue work into Today automatically. Something that has slipped needs a
/// decision — do it, reschedule it, or drop it — and quietly relocating it makes tomorrow's Today
/// the same pile as today's with one more thing in it.
///
/// It does not show a score, a streak, or how many tasks were finished yesterday. It shows what is
/// late, what has just become available, and a bounded handful of things that could be pulled in.
struct TodayPlanningSection: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel
    let onChange: () -> Void
    let onDismiss: () -> Void

    @State private var suggestions: [Item] = []

    var body: some View {
        Section {
            ForEach(suggestions, id: \.id) { task in
                HStack(spacing: Theme.Spacing.small) {
                    TaskRow(task: task, showsContainer: true, isSelected: false, onToggle: { complete(task) })

                    Button("Today") { commit(task) }
                        .buttonStyle(.borderless)
                        .font(Theme.Text.metadata)
                        .help("Put this on today's plan")
                }
                .listRowSeparator(.hidden)
            }

            if suggestions.isEmpty {
                Text("Nothing else is available to pull in.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .listRowSeparator(.hidden)
            }
        } header: {
            HStack {
                SectionHeader("Could be today", count: suggestions.count)
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }
        }
        .task { load() }
    }

    private func load() {
        guard let services else { return }
        services.perform { suggestions = try services.taskViews.todaySuggestions() }
    }

    private func commit(_ task: Item) {
        guard let services else { return }
        services.perform {
            try services.tasks.commitToToday(task)
            services.noteChange(to: task)
        }
        load()
        onChange()
    }

    private func complete(_ task: Item) {
        guard let services else { return }
        services.perform {
            _ = try services.tasks.complete(task)
            services.noteChange(to: task)
        }
        load()
        onChange()
    }
}

// MARK: - Context menu

/// Everything that can be done to one task, in the order somebody reaches for it.
struct TaskContextMenu: View {
    @Environment(\.services) private var services
    let task: Item
    let navigation: NavigationModel
    let onChange: () -> Void

    var body: some View {
        Button(task.status == .completed ? "Mark Incomplete" : "Mark Complete", systemImage: "checkmark.circle") {
            act { services in
                if task.status == .completed {
                    try services.tasks.reopen(task)
                } else {
                    _ = try services.tasks.complete(task)
                }
            }
        }

        if task.status == .open {
            Button("Cancel Task", systemImage: "xmark.circle") {
                act { try $0.tasks.cancel(task) }
            }
            .help("Deliberately abandoned. Kept in the log, because deciding not to do something is worth remembering.")
        }

        Divider()

        Menu("Schedule") {
            Button("Today") { act { try $0.tasks.commitToToday(task) } }
            Button("Later Today") { act { try $0.tasks.moveToLaterToday(task) } }
            Button("Tomorrow") {
                act { try $0.tasks.setStartDate($0.dateProvider.startOfDay(daysFromToday: 1), on: task) }
            }
            Button("Next Week") {
                act { try $0.tasks.setStartDate($0.dateProvider.startOfDay(daysFromToday: 7), on: task) }
            }
            Divider()
            Button("Clear Start Date") { act { try $0.tasks.setStartDate(nil, on: task) } }
            Button("Remove from Today") { act { try $0.tasks.removeFromToday(task) } }
        }

        Menu("Deadline") {
            Button("Today") { act { try $0.tasks.setDeadline($0.dateProvider.startOfToday, on: task) } }
            Button("Tomorrow") {
                act { try $0.tasks.setDeadline($0.dateProvider.startOfDay(daysFromToday: 1), on: task) }
            }
            Button("In a Week") {
                act { try $0.tasks.setDeadline($0.dateProvider.startOfDay(daysFromToday: 7), on: task) }
            }
            Divider()
            Button("Clear Deadline") { act { try $0.tasks.setDeadline(nil, on: task) } }
        }

        Divider()

        Button(task.isFlagged ? "Unflag" : "Flag", systemImage: "flag") {
            act { try $0.tasks.setFlagged(!task.isFlagged, on: task) }
        }
        Button(task.isSomeday ? "Bring Back from Someday" : "Move to Someday", systemImage: "archivebox") {
            act { try $0.tasks.setSomeday(!task.isSomeday, on: task) }
        }
        if task.waitingSince == nil {
            Button("Mark as Waiting", systemImage: "hourglass") {
                act { try $0.tasks.markWaiting(task, on: nil) }
            }
        } else {
            Button("No Longer Waiting", systemImage: "hourglass.bottomhalf.filled") {
                act { try $0.tasks.clearWaiting(task) }
            }
        }

        Divider()

        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            // A linked task asks before it takes a reminder with it — see `TaskDeletionPrompt`.
            act { try $0.items.moveToTrash(task) }
        }
        .disabled(task.syncState != .local)
        .help(task.syncState == .local ? "" : "This task is linked to a reminder. Use Delete… so you can say what happens to it.")
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

// MARK: - Batch actions

/// What can be done to several tasks at once.
///
/// Each button is **one** undo step, because each is one thing the user did. Anything that would
/// reach a system reminder is not here: a batch that silently wrote to somebody's iCloud account is
/// exactly the kind of thing this integration promises not to do.
struct TaskBatchBar: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel
    let tasks: [Item]
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text("\(tasks.count) selected")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer()

            Button("Complete", systemImage: "checkmark.circle") {
                apply { services, task in _ = try services.tasks.complete(task) }
            }
            Button("Today", systemImage: "sun.horizon") {
                apply { services, task in try services.tasks.commitToToday(task) }
            }
            Button("Flag", systemImage: "flag") {
                apply { services, task in try services.tasks.setFlagged(true, on: task) }
            }
            Button("Someday", systemImage: "archivebox") {
                apply { services, task in try services.tasks.setSomeday(true, on: task) }
            }
            Button("Clear", systemImage: "xmark") { navigation.selectedItemIDs = [] }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(Theme.Text.metadata)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
        .accessibilityIdentifier("tasks.batchBar")
    }

    private func apply(_ work: (AppServices, Item) throws -> Void) {
        guard let services else { return }
        services.perform {
            for task in tasks { try work(services, task) }
        }
        services.refreshDerivedState()
        onChange()
    }
}
