import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One day, in full.
///
/// ### The order, and why it is this order
/// Briefing, then what is wrong, then what is fixed in time, then what is not, then who, then what is
/// already done. It is the order somebody plans in: you find out what the day *is*, you deal with
/// what is late, you see where the immovable blocks are, you fit the rest around them, you remember
/// who you owe something to, and only then — if at all — do you look at what you finished.
///
/// Every section can be absent. A day with no meetings has no schedule heading, not an empty one; a
/// day with nothing overdue never mentions overdue. Headings that exist to say "nothing here" are
/// the fastest way to make a light day look like a broken page.
struct TodayDayView: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    let model: TodayModel
    let navigation: NavigationModel

    @Binding var draftDay: Date?
    @Binding var draftTitle: String
    var isDraftFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TodayDateRail(plan: plan, isEmphasised: true)
                .frame(width: TodayMetrics.railWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                TodayBriefingView(plan: plan, actions: actions)

                needsAttention
                schedule
                untimedTasks
                people
                dailyNote
                completed

                if plan.isEmpty {
                    TodayClearDayView(plan: plan, actions: actions) { openDraft() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(AccessibilityID.Today.day(dayKey))
    }

    private var dayKey: String {
        (services?.dateProvider ?? SystemDateProvider()).dayKey(for: plan.date)
    }

    private var actions: TodayActions? {
        guard let services else { return nil }
        return TodayActions(services: services, navigation: navigation, model: model)
    }

    private var calendar: Calendar {
        (services?.dateProvider ?? SystemDateProvider()).calendar
    }

    // MARK: - What is wrong

    /// Late work and people who are waiting, and nothing else.
    ///
    /// ### Why this is separate from the day's tasks
    /// Because "everything on today" and "everything that has gone wrong" are different lists, and
    /// the second one is short. Sorting the first list so the late items float to the top puts them
    /// in front of the reader but does not let them be *counted*, dealt with, and then gone — which
    /// is what somebody actually wants to do with them at nine in the morning.
    @ViewBuilder
    private var needsAttention: some View {
        let attention = plan.needsAttention
        if !attention.isEmpty, let actions {
            TodaySection(
                title: "Needs attention",
                count: attention.count,
                symbolName: "exclamationmark.circle",
                tone: attention.contains { $0.primaryReason?.rank == 0 } ? .urgent : .notable
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(attention) { task in
                        if let item = model.task(task.taskID) {
                            TodayTaskRow(
                                task: task,
                                item: item,
                                plan: plan,
                                actions: actions,
                                isSelected: navigation.selectedItemID == item.id
                            )
                        }
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Today.needsAttention)
        }
    }

    // MARK: - What is fixed in time

    @ViewBuilder
    private var schedule: some View {
        let allDay = plan.allDayEvents(calendar: calendar)
        let slots = agendaSlots
        if !allDay.isEmpty || !slots.isEmpty, let actions {
            TodaySection(title: "Schedule", count: plan.briefing.meetingCount > 0 ? plan.briefing.meetingCount : nil) {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    ForEach(allDay) { event in
                        TodayEventRow(event: event, plan: plan, model: model, actions: actions)
                    }

                    if !allDay.isEmpty, !slots.isEmpty {
                        Divider().padding(.vertical, Theme.Spacing.tight)
                    }

                    timeline(slots, actions: actions)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Today.schedule)
        }
    }

    /// Timed events, and the timed *tasks* that compete with them.
    ///
    /// Interleaved only when the reader wants one timeline. The grouped arrangement keeps events
    /// together and leaves timed tasks with the rest of the work, which is how some people plan and
    /// is not a mistake to correct.
    private var agendaSlots: [DayAgendaSlot] {
        let integrated = services?.todayPreferences.filters.usesIntegratedAgenda ?? true
        guard integrated else {
            return plan.timedEvents(calendar: calendar).map(DayAgendaSlot.event)
        }
        return DayAgenda.slots(for: plan, calendar: calendar)
    }

    @ViewBuilder
    private func timeline(_ slots: [DayAgendaSlot], actions: TodayActions) -> some View {
        let markerIndex = DayAgenda.nowMarkerIndex(
            in: slots,
            now: services?.dateProvider.now ?? Date(),
            isToday: plan.isToday
        )

        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                if index == markerIndex {
                    TodayNowMarker(now: services?.dateProvider.now ?? Date())
                }
                slotRow(slot, actions: actions)
            }

            // The day's remaining hours are all after everything on it.
            if plan.isToday, markerIndex == nil, !slots.isEmpty {
                TodayNowMarker(now: services?.dateProvider.now ?? Date())
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: DayAgendaSlot, actions: TodayActions) -> some View {
        switch slot {
        case .event(let event):
            TodayEventRow(event: event, plan: plan, model: model, actions: actions)
        case .task(let task, let at):
            if let item = model.task(task.taskID) {
                TodayTaskRow(
                    task: task,
                    item: item,
                    plan: plan,
                    actions: actions,
                    isSelected: navigation.selectedItemID == item.id,
                    pinnedAt: at
                )
            }
        }
    }

    // MARK: - What is not fixed in time

    /// The day's work, minus anything already shown above it.
    ///
    /// Deduplication is subtraction rather than a second query: everything the day holds was decided
    /// once, and a task that appeared under *Needs attention* or on the timeline is the same task,
    /// not a second one that happens to match.
    @ViewBuilder
    private var untimedTasks: some View {
        let shown = Set(plan.needsAttention.map(\.taskID))
        let remaining = plan.untimedTasks.filter { !shown.contains($0.taskID) }
        let isDrafting = draftDay == plan.date

        if !remaining.isEmpty || isDrafting || !(plan.isPast || plan.isEmpty), let actions {
            TodaySection(title: "Tasks", count: remaining.isEmpty ? nil : remaining.count) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(remaining) { task in
                        if let item = model.task(task.taskID) {
                            TodayTaskRow(
                                task: task,
                                item: item,
                                plan: plan,
                                actions: actions,
                                isSelected: navigation.selectedItemID == item.id
                            )
                        }
                    }

                    quickAdd(actions)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Today.tasks)
        }
    }

    @ViewBuilder
    private func quickAdd(_ actions: TodayActions) -> some View {
        if draftDay == plan.date {
            TodayQuickAddField(
                title: $draftTitle,
                isFocused: isDraftFocused,
                onCommit: { commitDraft(actions) },
                onCancel: closeDraft
            )
        } else if !plan.isPast {
            Button {
                openDraft()
            } label: {
                Label("Add Task", systemImage: "plus.circle")
                    .font(Theme.Text.rowSubtitle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.link)
            .padding(.top, Theme.Spacing.tight)
            .accessibilityIdentifier(AccessibilityID.Today.quickAdd)
        }
    }

    private func openDraft() {
        draftDay = plan.date
        draftTitle = ""
        isDraftFocused.wrappedValue = true
    }

    private func closeDraft() {
        draftDay = nil
        draftTitle = ""
    }

    /// Return creates the task and leaves the field open in the same place, so a run of five
    /// captures is five titles and five Returns.
    private func commitDraft(_ actions: TodayActions) {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            closeDraft()
            return
        }
        actions.createTask(titled: trimmed, on: plan.date)
        draftTitle = ""
        isDraftFocused.wrappedValue = true
    }

    // MARK: - Who

    @ViewBuilder
    private var people: some View {
        if !plan.people.isEmpty, let actions {
            TodaySection(title: "People", count: plan.people.count) {
                TodayPeopleGrid(people: plan.people, plan: plan, model: model, actions: actions)
            }
            .accessibilityIdentifier(AccessibilityID.Today.people)
        }
    }

    // MARK: - The day's own note

    @ViewBuilder
    private var dailyNote: some View {
        // Suppressed on a clear day, where the clear-day view already offers to start one. Two
        // controls for one thing, eight points apart, is the kind of duplication that makes a page
        // feel unfinished.
        if services?.todayPreferences.filters.showsDailyNote == true, !plan.isEmpty, let actions {
            TodayNoteView(plan: plan, actions: actions)
                .accessibilityIdentifier(AccessibilityID.Today.dailyNote)
        }
    }

    // MARK: - What is already done

    @ViewBuilder
    private var completed: some View {
        if !plan.completedTaskIDs.isEmpty, let actions {
            TodayCompletedView(
                tasks: model.completedTasks(in: plan),
                actions: actions
            )
            .accessibilityIdentifier(AccessibilityID.Today.completed)
        }
    }
}

/// A day the reader is not currently standing on.
///
/// ### Why this is a different view rather than the same one smaller
/// Because it answers a different question. Today's page is for *doing*; tomorrow's is for knowing
/// whether tomorrow is full. So it drops the briefing, the people, the note and the completed line,
/// and keeps the two things that decide "is there room" — what is booked and how much work is on it
/// — until somebody asks for more, at which point it becomes the full day.
struct TodayCompactDayView: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    let model: TodayModel
    let navigation: NavigationModel
    let isPast: Bool

    @State private var draftDay: Date?
    @State private var draftTitle = ""
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        Group {
            if model.isExpanded(plan) {
                // The full day draws its own rail, so drawing a second one here would put two dates
                // side by side. Collapsing is the disclosure control rather than the whole row,
                // because every row inside an expanded day is something you can click on its own —
                // and a tap target wrapping all of them would swallow every one of those clicks.
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    TodayDayView(
                        plan: plan,
                        model: model,
                        navigation: navigation,
                        draftDay: $draftDay,
                        draftTitle: $draftTitle,
                        isDraftFocused: $isDraftFocused
                    )

                    disclosure
                        .padding(.leading, TodayMetrics.railWidth)
                }
            } else {
                collapsed
            }
        }
        .opacity(isPast ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Today.day(dayKey))
    }

    /// The collapsed day, which is one control: the whole strip opens it.
    private var collapsed: some View {
        Button {
            withAnimation(Theme.Motion.standard) { model.toggleExpanded(plan) }
        } label: {
            HStack(alignment: .top, spacing: 0) {
                TodayDateRail(plan: plan, isEmphasised: false, isPast: isPast)
                    .frame(width: TodayMetrics.railWidth, alignment: .leading)

                summary
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open this day")
    }

    private var disclosure: some View {
        Button {
            withAnimation(Theme.Motion.standard) { model.toggleExpanded(plan) }
        } label: {
            Label("Collapse", systemImage: "chevron.up")
                .font(Theme.Text.metadata)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Colors.secondaryText)
        .accessibilityLabel("Collapse \(plan.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
    }

    private var accessibilityLabel: String {
        var parts = [plan.date.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        if plan.briefing.meetingCount > 0 {
            parts.append(plan.briefing.meetingCount == 1 ? "1 meeting" : "\(plan.briefing.meetingCount) meetings")
        }
        if !plan.tasks.isEmpty {
            parts.append(plan.tasks.count == 1 ? "1 task" : "\(plan.tasks.count) tasks")
        }
        if parts.count == 1 { parts.append(isPast ? "nothing recorded" : "clear") }
        return parts.joined(separator: ", ")
    }

    private var dayKey: String {
        (services?.dateProvider ?? SystemDateProvider()).dayKey(for: plan.date)
    }

    private var calendar: Calendar {
        (services?.dateProvider ?? SystemDateProvider()).calendar
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(previewEvents) { event in
                TodayCompactEventLine(event: event)
            }

            ForEach(previewTasks) { task in
                if let item = model.task(task.taskID) {
                    TodayCompactTaskLine(task: task, item: item)
                }
            }

            if let more = moreCount {
                Text(more)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            if !plan.hasContent {
                Text(isPast ? "Nothing recorded" : "Clear")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let previewLimit = 3

    private var previewEvents: [DayEvent] {
        Array(
            (plan.allDayEvents(calendar: calendar) + plan.timedEvents(calendar: calendar))
                .prefix(Self.previewLimit)
        )
    }

    private var previewTasks: [DayTask] {
        // Whatever room the events left. A compact day is a glance, and a glance is three lines.
        let room = max(0, Self.previewLimit - previewEvents.count)
        return Array(plan.tasks.prefix(room))
    }

    /// Says what is not shown rather than silently truncating. A day that looks like three things
    /// and is nine is a day somebody will plan against and be wrong about.
    private var moreCount: String? {
        let hidden = (plan.events.count - previewEvents.count) + (plan.tasks.count - previewTasks.count)
        guard hidden > 0 else { return nil }
        return hidden == 1 ? "1 more" : "\(hidden) more"
    }
}
