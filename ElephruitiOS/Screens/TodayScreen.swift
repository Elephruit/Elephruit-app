import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The day, on a phone: what is happening, what is owed, who matters, and how much room
/// is left — in one scroll, most urgent first.
///
/// The Mac lays a day out in two columns with a date rail; a phone gets one column and a
/// swipe. Same `TodayModel`, same `DailyPlanService`, same rules — different geometry.
struct TodayScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var model: TodayModel?
    /// Present so `TodayActions` — the canonical action layer — can be reused verbatim.
    /// Only its mutation half runs here; navigation goes through the shell.
    @State private var navigation = NavigationModel()

    var body: some View {
        Group {
            if let services, let model {
                TodayContent(
                    model: model,
                    actions: TodayActions(services: services, navigation: navigation, model: model)
                )
            } else {
                Color.clear
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard model == nil, let services else { return }
            model = TodayModel(services: services)
        }
    }

    private var title: String {
        guard let model, !model.isOnToday else { return "Today" }
        return model.selectedDate.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// The scrolling day itself, once the model exists.
private struct TodayContent: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let model: TodayModel
    let actions: TodayActions

    /// Which gatherings have been opened out into their people. Keyed by the gathering's own
    /// identifier so it survives a reassembly — a reload must not close what somebody opened.
    @State private var expandedGatherings: Set<String> = []

    /// The gap or the task the block sheet is up about, if it is up.
    @State private var blocking: BlockTimeSubject?

    /// How close to the end the scroll has to get before the next week is asked for.
    ///
    /// About a screen. Less and the feed visibly stops before it continues; more and a flick that
    /// was never going to reach the bottom has already spent a calendar read.
    private static let pagingReach: CGFloat = 600

    var body: some View {
        List {
            if let failure = model.failure {
                TimelineRow(
                    railStyle: .none,
                    badge: Timeline.Badge(
                        symbolName: "exclamationmark.triangle", tint: Theme.Colors.warning
                    )
                ) {
                    Text(failure.summary)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.warning)
                }
                .onTimeline()
            }

            if let plan = model.selectedPlan {
                daySections(plan, isAnchor: true)
                upcomingFeed
            } else if model.isLoadingInitially {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.extraLarge)
                .onTimeline()
            }
        }
        // Plain, because every grouped style insets and rounds each section into a card of its own —
        // which is the thing the rail exists instead of. The rows draw their own background and
        // their own hairlines, so the list contributes geometry and nothing else.
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Theme.Colors.contentBackground)
        // A different anchor day is a different page, and a page that opens two hundred rows down
        // because that is where the last one was left is a page somebody has to scroll back up.
        // Rebuilding on the date puts the new day under the thumb rather than under whatever offset
        // the old one happened to end on.
        .id(model.selectedDate)
        // The feed pages on proximity rather than on a row appearing. A row's `onAppear` fires once
        // and never again while it stays on screen, so a week of clear days — which adds barely a
        // screen of height — would leave the marker visible and the feed stopped with nothing to
        // press. Geometry keeps answering, including when the answer is "the days you just loaded
        // did not fill the gap", so it carries on until the screen is full.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // `visibleRect` rather than `contentOffset`: it is already inset-corrected, which
            // matters under a large navigation title.
            geometry.contentSize.height - geometry.visibleRect.maxY
        } action: { _, remaining in
            guard remaining < Self.pagingReach else { return }
            model.extendFuture()
        }
        .refreshable {
            // Honest refresh: re-reads the calendar, which genuinely can have changed
            // underneath the app. The library itself needs no pulling — it is local.
            await model.reload()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !model.isOnToday {
                    Button("Today") {
                        withCalmAnimation(Theme.Motion.standard) { model.returnToToday() }
                    }
                    .accessibilityIdentifier("today.return")
                }
                Menu {
                    Button("Previous Day", systemImage: "chevron.backward") {
                        model.step(days: -1)
                    }
                    Button("Next Day", systemImage: "chevron.forward") {
                        model.step(days: 1)
                    }
                    Divider()
                    Button("Open Calendar", systemImage: "calendar") {
                        shell.push(.calendar)
                    }
                } label: {
                    Label("Change day", systemImage: "calendar")
                }
            }
        }
        .sheet(item: $blocking) { subject in
            BlockTimeSheet(
                actions: actions, plan: subject.plan, slot: subject.slot, task: subject.task
            )
        }
        // The same two-token drive as the Mac: the window token reloads the calendar,
        // the source token reassembles from memory. See `TodayModel` for why they differ.
        .task(id: model.windowToken) { await model.reload() }
        // Animated, because one of the things that changes the source token is this page writing to
        // the calendar. A block written as busy takes back the free time it was made from, so the
        // thread reassembles under the thumb that just wrote it. That is honest, and it must not
        // read as a glitch.
        .onChange(of: model.sourceToken) { _, _ in
            withCalmAnimation(Theme.Motion.standard) { model.assemble() }
            openBlockSheetIfReviewing()
        }
        // A day is a horizontal thing: swipe back and forward through it.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    withCalmAnimation(Theme.Motion.standard) {
                        model.step(days: value.translation.width < 0 ? 1 : -1)
                    }
                }
        )
    }

    // MARK: - A day, in full

    /// Everything one day has to say, in the order somebody plans in.
    ///
    /// The same builder for the day at the top and for a day further down that has been opened out,
    /// because "open it in full" has to mean the *same* full — a second, thinner rendering of a day
    /// is a second set of rules about what a day contains, and the two drift.
    ///
    /// `isAnchor` marks the day the page is standing on. Only it carries the calendar's own state
    /// and the empty-day illustration: a banner about calendar access repeated on ninety days is
    /// ninety copies of one fact, and a full-height "A clear day" under every free Thursday is a
    /// feed made mostly of empty states.
    @ViewBuilder
    private func daySections(_ plan: DayPlan, isAnchor: Bool) -> some View {
        briefingSection(plan)

        if isAnchor {
            calendarStateSection
        }

        awarenessSection(plan)
        eventsSection(plan)
        tasksSection(plan)
        completedSection(plan)
        peopleSection(plan)
        dailyNoteSection(plan)

        if isAnchor, plan.isEmpty, model.failure == nil {
            EmptyStateView(
                symbolName: plan.isToday ? "sun.max" : "calendar",
                headline: plan.isToday ? "A clear day" : "Nothing planned",
                message: plan.isToday
                    ? "Nothing scheduled, nothing due. Capture something, or enjoy it."
                    : "Nothing scheduled or due on this day yet.",
                tone: .accomplished
            )
            .onTimeline()
        }
    }

    // MARK: - The days after it

    /// The run of days under the one you are standing on, on the same thread.
    @ViewBuilder
    private var upcomingFeed: some View {
        if !model.followingDays.isEmpty {
            TimelineHeader("Upcoming").onTimeline()
        }

        ForEach(model.followingDays) { plan in
            TodayFeedDayHeader(plan: plan, isExpanded: model.isExpanded(plan)) {
                withCalmAnimation(Theme.Motion.standard) { model.toggleExpanded(plan) }
            }
            .onTimeline()

            // Closed, the day is its own summary. Open, the full sections carry it — drawing both
            // would put every meeting on the screen twice.
            if model.isExpanded(plan) {
                daySections(plan, isAnchor: false)
            } else {
                let calendar = services?.dateProvider.calendar ?? .current

                ForEach(plan.scheduleEvents(calendar: calendar)) { event in
                    TodayFeedEventLine(dayEvent: event).onTimeline()
                }

                ForEach(model.openTasks(in: plan), id: \.day.id) { entry in
                    TodayFeedTaskLine(task: entry.day, item: entry.item).onTimeline()
                }
            }
        }

        if model.selectedPlan != nil {
            TodayFeedFooter(
                isExtending: model.isExtendingFuture,
                canLoadMore: model.canLoadMoreDays
            )
            .onTimeline()
        }
    }

    // MARK: - Briefing

    /// The day in figures, above the thread rather than on it.
    ///
    /// The one part of the page that is not an entry in the day: it is *about* the day, so it sits
    /// full-width with no rail, and the thread starts underneath it. Path puts a cover photo here
    /// for the same structural reason — something has to establish the top of the line.
    @ViewBuilder
    private func briefingSection(_ plan: DayPlan) -> some View {
        let figures = plan.briefing.figures
        if !figures.isEmpty || plan.briefing.next != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if !figures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.small) {
                            ForEach(figures) { figure in
                                BriefingFigureChip(figure: figure)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                    }
                    .padding(.horizontal, -Theme.Spacing.large)
                }

                if let next = plan.briefing.next {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: next.isInProgress ? "timer" : "arrow.right.circle")
                            .foregroundStyle(Theme.Colors.selection)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(next.isInProgress ? "Now" : "Next")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                            Text(next.title)
                                .font(Theme.Text.rowTitle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(next.startAt.formatted(date: .omitted, time: .shortened))
                            .font(Theme.Text.metadata)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }

                if plan.briefing.focus.hasAny, let stretch = plan.briefing.focus.longestStretchSummary {
                    Label {
                        // `proportionSummary` already says "free" and says what of — "3h 20m free
                        // of 8h · 1h from 2:00 PM". The denominator is the working day the reader
                        // set in Settings, which is what makes the first number mean anything.
                        Text("\(plan.briefing.focus.proportionSummary) · \(stretch)")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } icon: {
                        Image(systemName: "hourglass")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .onTimeline()
        }
    }

    /// Why the calendar half of the day may be silent, said in place rather than left to
    /// be discovered. Shown only when it would explain something.
    @ViewBuilder
    private var calendarStateSection: some View {
        if let services {
            let calendar = services.calendar
            if !calendar.isEnabled {
                NavigationLink(value: MobileRoute.settings) {
                    TimelineRow(
                        badge: Timeline.Badge(
                            symbolName: "calendar.badge.plus", tint: Theme.Colors.selection
                        )
                    ) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text("Calendar is off")
                                .font(Theme.Text.rowTitle)
                            Text("Turn it on in Settings to see meetings here.")
                                .font(Theme.Text.rowSubtitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onTimeline()
            } else if calendar.authorization == .denied || calendar.authorization == .restricted {
                TimelineRow(
                    badge: Timeline.Badge(
                        symbolName: "calendar.badge.exclamationmark", tint: Theme.Colors.warning
                    )
                ) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text("Calendar access is denied")
                            .font(Theme.Text.rowTitle)
                        Text("Allow access in Settings › Privacy to see meetings here.")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .onTimeline()
            }
        }
    }

    // MARK: - Awareness

    /// What today *is*, as opposed to what is in it.
    ///
    /// ### Why this is not part of the schedule
    /// A four-day trip and a day of leave were being drawn as agenda rows with "All day" where the
    /// clock time goes, which reads as an appointment that forgot to say when. They are neither
    /// appointments nor meetings; they are the shape of the day, and the right way to read them is
    /// once, at the top, before looking at the hours. Nothing here has a time column, and nothing
    /// here carries a conflict warning — an all-day entry overlaps everything by construction, which
    /// is why `DayEventRules.conflicts` already refuses to count it.
    @ViewBuilder
    private func awarenessSection(_ plan: DayPlan) -> some View {
        let calendar = services?.dateProvider.calendar ?? .current
        let awareness = plan.awarenessEvents(calendar: calendar)
        if !awareness.isEmpty {
            TimelineHeader("Awareness", identifier: "today.awareness.header")
                .onTimeline()

            ForEach(awareness) { event in
                TodayAwarenessRow(dayEvent: event, day: plan.date, calendar: calendar)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        shell.push(.event(event.event.identity.storageKey))
                    }
                    .onTimeline()
            }
        }
    }

    // MARK: - Events

    @ViewBuilder
    private func eventsSection(_ plan: DayPlan) -> some View {
        let calendar = services?.dateProvider.calendar ?? .current
        let rows = scheduleRows(plan, calendar: calendar)
        if !rows.isEmpty {
            scheduleHeader.onTimeline()

            ForEach(rows) { row in
                switch row {
                case .event(let event):
                    TodayEventRow(dayEvent: event)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            shell.push(.event(event.event.identity.storageKey))
                        }
                        .contextMenu {
                            if actions.joinLink(for: event) != nil {
                                Button("Join", systemImage: "video") { actions.join(event) }
                            }
                            Button("Open in Calendar", systemImage: "calendar") {
                                shell.push(.calendar)
                            }
                            Button("Meeting Notes", systemImage: "note.text") {
                                openMeetingNotes(event)
                            }
                        }
                        .onTimeline()
                case .free(let slot):
                    TodayFreeSlotRow(slot: slot)
                        .contentShape(Rectangle())
                        .onTapGesture { blocking = .slot(slot, plan) }
                        // Said, because the row does not look like a button and should not: it is a
                        // gap in a line. What it can do has to be spoken instead of drawn.
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Block this time")
                        .onTimeline()
                }
            }
        }
    }

    /// The section title, with the one control the schedule has of its own.
    ///
    /// Both parts are named. A header holding a control stops exposing its title as a plain piece of
    /// text — the first test to look for "Schedule" after this button arrived waited ten seconds and
    /// found nothing — so neither the title nor the button is reachable by its words alone.
    private var scheduleHeader: some View {
        TimelineHeader(title: "Schedule", identifier: "today.schedule.header") {
            if let preferences = services?.todayPreferences {
                let isShowing = preferences.filters.showsFreeTime
                Button {
                    withCalmAnimation(Theme.Motion.standard) { preferences.toggleFreeTime() }
                } label: {
                    // An `Image` with a measured frame rather than a `Label` with `.iconOnly`.
                    // A section header applies its own text styling to whatever it holds, and the
                    // label came out with no intrinsic size at all — the accessibility tree had this
                    // button at zero by zero, which is a control nobody can press, by hand or
                    // otherwise. The frame and the content shape are what make it a target.
                    Image(systemName: isShowing ? "hourglass" : "hourglass.slash")
                        .font(Theme.Text.metadata)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isShowing ? Theme.Colors.selection : Theme.Colors.secondaryText)
                .accessibilityLabel(isShowing ? "Hide free time" : "Show free time")
                .accessibilityIdentifier("today.freeTime.toggle")
            }
        }
        // Without this the header is one element and the button inside it is unreachable — the rule
        // `SwiftUI` applies everywhere: a container that owns an identifier hides its children.
        .accessibilityElement(children: .contain)
    }

    /// The day against the clock: what is booked, and — unless switched off — what is not.
    ///
    /// ### Why the gaps are rows rather than a figure at the top
    /// Because "four hours free" is something to know and "eleven-thirty to half twelve is free" is
    /// something to use, and only the second one is in the place where a person is already deciding
    /// what to do next. The briefing keeps the total; this is where it becomes an offer.
    ///
    /// The gaps come from ``DayFocusTime/slots``, which is already bounded by the working day and
    /// already starts at *now* for today, so nothing here has to re-derive either. A day in the past
    /// produces none, which is right: a gap in a day that is over is not an opportunity.
    private func scheduleRows(_ plan: DayPlan, calendar: Calendar) -> [ScheduleRow] {
        var rows = plan.scheduleEvents(calendar: calendar).map(ScheduleRow.event)

        if services?.todayPreferences.filters.showsFreeTime ?? true {
            rows += plan.briefing.focus.slots.map(ScheduleRow.free)
        }

        return rows.sorted { left, right in
            if left.startAt != right.startAt { return left.startAt < right.startAt }
            // A commitment before the gap it opens onto, when a meeting ends exactly where a free
            // stretch begins — which is most of them.
            switch (left, right) {
            case (.event, .free): return true
            case (.free, .event): return false
            default: return left.id < right.id
            }
        }
    }

    /// Opens the block sheet on the first gap of the day, when a development launch asked for it.
    ///
    /// Driven off the source token rather than off the first reload, and refusing to open until the
    /// calendar has answered: a day assembled before the events arrive has one enormous gap where
    /// the whole working afternoon is, and photographing *that* would be photographing a state no
    /// user ever sees.
    private func openBlockSheetIfReviewing() {
        guard blocking == nil,
              TodayReviewLaunch.opensBlockSheet(),
              services?.calendar.calendars.isEmpty == false,
              let plan = model.selectedPlan,
              let slot = plan.briefing.focus.slots.first
        else { return }
        blocking = .slot(slot, plan)
    }

    private func openMeetingNotes(_ event: DayEvent) {
        guard let services else { return }
        services.perform {
            guard let meeting = try services.eventLinks.meetingItem(for: event.event) else { return }
            services.noteChange(to: meeting)
            shell.push(.item(meeting.id))
        }
    }

    // MARK: - Tasks

    @ViewBuilder
    private func tasksSection(_ plan: DayPlan) -> some View {
        let open = model.openTasks(in: plan)
        if !open.isEmpty {
            TimelineHeader(plan.isToday ? "To do" : "Due or planned").onTimeline()

            ForEach(open, id: \.day.id) { entry in
                TodayTaskRow(task: entry.item, day: entry.day) {
                    withCalmAnimation(Theme.Motion.standard) {
                        actions.toggleCompletion(entry.item)
                    }
                }
                    .contentShape(Rectangle())
                    .onTapGesture { shell.push(.item(entry.item.id)) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            withCalmAnimation(Theme.Motion.standard) {
                                actions.toggleCompletion(entry.item)
                            }
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle.fill")
                        }
                        .tint(Theme.Colors.completed)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            actions.reschedule(entry.item, to: nextDay(after: plan.date))
                        } label: {
                            Label("Tomorrow", systemImage: "arrow.turn.right.down")
                        }
                        .tint(Theme.Colors.selection)

                        Button {
                            actions.moveToLaterToday(entry.item)
                        } label: {
                            Label("This Evening", systemImage: "moon")
                        }
                    }
                    .contextMenu { taskMenu(entry.item, plan: plan) }
                    .onTimeline()
            }
        }
    }

    @ViewBuilder
    private func taskMenu(_ task: Item, plan: DayPlan) -> some View {
        Button("Open", systemImage: "arrow.up.forward.square") {
            shell.push(.item(task.id))
        }
        Button("Start Timer", systemImage: "play.circle") {
            actions.startTimer(on: task)
        }
        Button(
            task.isFlagged ? "Remove Flag" : "Flag",
            systemImage: task.isFlagged ? "flag.slash" : "flag"
        ) {
            actions.setFlagged(!task.isFlagged, on: task)
        }
        Menu("Move") {
            Button("Tomorrow") { actions.reschedule(task, to: nextDay(after: plan.date)) }
            Button("This Evening") { actions.moveToLaterToday(task) }
            Button("Off This Day") { actions.reschedule(task, to: nil) }
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            guard let services else { return }
            services.perform {
                try services.items.moveToTrash(task)
                services.noteRemoval(of: task.id)
            }
        }
    }

    private func nextDay(after date: Date) -> Date {
        guard let services else { return date }
        return services.dateProvider.calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    // MARK: - Completed

    @ViewBuilder
    private func completedSection(_ plan: DayPlan) -> some View {
        let completed = model.completedTasks(in: plan)
        if !completed.isEmpty {
            TimelineRow(
                badge: Timeline.Badge(
                    symbolName: "checkmark", tint: Theme.Colors.completed
                )
            ) {
                DisclosureGroup {
                    ForEach(completed) { item in
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Colors.completed)
                            Text(item.displayTitle)
                                .font(Theme.Text.rowSubtitle)
                                .strikethrough()
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withCalmAnimation(Theme.Motion.standard) {
                                actions.toggleCompletion(item)
                            }
                        }
                    }
                } label: {
                    Text("^[\(completed.count) completed reminder](inflect: true)")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .onTimeline()
        }
    }

    // MARK: - People

    /// Who the day puts you with, grouped by the thing that puts you with them.
    ///
    /// ### Why the meeting is the row and the person is not
    /// Because five people in one Roadmap sync were five rows, each repeating "4:00 PM · Roadmap
    /// sync" underneath a different name. The interesting fact there is the *meeting* — one thing,
    /// at one time, with five faces on it — and stating its time and title five times pushes the
    /// rest of the day off the screen to say one thing badly.
    ///
    /// So a meeting is one row: when, who, and what. The faces are the content, because who is in
    /// the room is what the row is for. Opening it puts the person-by-person detail underneath,
    /// which is the only place the role, the last contact and the quick facts have room to be
    /// useful anyway.
    ///
    /// Everybody the day names for some *other* reason — a birthday, a chase, a task about them —
    /// keeps a row of their own. There is no shared interaction to gather them under, and inventing
    /// one would be grouping for the sake of it.
    @ViewBuilder
    private func peopleSection(_ plan: DayPlan) -> some View {
        let groups = TodayPeopleGrouping.groups(in: plan)
        if !groups.isEmpty {
            TimelineHeader("People today").onTimeline()

            ForEach(groups) { group in
                switch group.kind {
                case .gathering(let title, let startAt, let isAllDay):
                    TodayGatheringRow(
                        title: title,
                        startAt: startAt,
                        isAllDay: isAllDay,
                        people: group.people,
                        isExpanded: expandedGatherings.contains(group.id),
                        toggle: {
                            withCalmAnimation(Theme.Motion.standard) {
                                if expandedGatherings.contains(group.id) {
                                    expandedGatherings.remove(group.id)
                                } else {
                                    expandedGatherings.insert(group.id)
                                }
                            }
                        },
                        open: { shell.push(.person($0)) }
                    )
                    .onTimeline()

                case .alone:
                    ForEach(group.people) { person in
                        TodayPersonRow(person: person)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let id = person.personID {
                                    shell.push(.person(id))
                                }
                            }
                            .onTimeline()
                    }
                }
            }
        }
    }

    // MARK: - Daily note

    /// The end of the thread: the day's own note.
    ///
    /// The rail stops here rather than running off the bottom of the screen, because a line that
    /// continues past the last entry promises something below it that is not there.
    @ViewBuilder
    private func dailyNoteSection(_ plan: DayPlan) -> some View {
        Button {
            openDailyNote(plan)
        } label: {
            TimelineRow(
                railStyle: .tail,
                badge: Timeline.Badge(
                    symbolName: "sun.horizon", tint: Theme.Colors.secondaryText
                ),
                showsDivider: false
            ) {
                if let excerpt = plan.dailyNoteExcerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                } else {
                    Text(plan.dailyNoteID == nil ? "Write about this day" : "Open the day's note")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .onTimeline()
    }

    private func openDailyNote(_ plan: DayPlan) {
        guard let services else { return }
        services.perform {
            guard let note = try services.people.dailyEntry(for: plan.date, creatingIfNeeded: true)
            else { return }
            services.noteChange(to: note)
            shell.push(.item(note.id))
        }
    }
}

// MARK: - Small pieces

/// One line of the schedule: something booked, or the room between two things.
private enum ScheduleRow: Identifiable {
    case event(DayEvent)
    case free(DayFreeSlot)

    var id: String {
        switch self {
        case .event(let event): "event:\(event.id)"
        case .free(let slot): "free:\(slot.range.lowerBound.timeIntervalSinceReferenceDate)"
        }
    }

    var startAt: Date {
        switch self {
        case .event(let event): event.event.startAt
        case .free(let slot): slot.range.lowerBound
        }
    }
}

/// A stretch of the working day with nothing in it.
///
/// Drawn quietly and drawn differently: a dashed rule rather than a calendar's colour, because this
/// is the absence of an event rather than a pale one. The row has to be legible as *space* at a
/// glance, or a day of five gaps reads as a day of ten meetings.
private struct TodayFreeSlotRow: View {
    let slot: DayFreeSlot

    var body: some View {
        // The thread itself goes dashed. That is the whole idea: free time is not another entry to
        // read, it is the absence of one, and drawing it as a gap in the line says so before a
        // single word is read.
        TimelineRow(railStyle: .dashed) {
            Text(slot.isCurrent ? "Now" : slot.range.lowerBound.formatted(date: .omitted, time: .shortened))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)
        } content: {
            // "15m free · until 10:00 AM". Not the whole range: the column to the left has already
            // said when it starts, and "9:45 AM │ 15m free · 9:45 AM – 10:00 AM" says it twice.
            Text("\(slot.durationSummary) free · until \(endLabel)")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        // Spoken with both ends, unlike the drawn row: a combined element is read as one sentence,
        // so there is no column to the left to have already said when it starts.
        .accessibilityLabel("\(slot.durationSummary) free, \(slot.rangeSummary)")
        // Named so a test can count the gaps without matching on their text. Scanning labels for
        // "free" finds the briefing's line at the top of the page as well, and a predicate walking
        // the whole hierarchy of a long list is slow enough to time the test out.
        .accessibilityIdentifier("today.freeSlot")
    }

    private var endLabel: String {
        slot.range.upperBound.formatted(date: .omitted, time: .shortened)
    }
}

/// One briefing figure — "2 overdue", "3 meetings" — as a quiet chip.
private struct BriefingFigureChip: View {
    let figure: BriefingFigure

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: figure.symbolName)
            Text(figure.value).fontWeight(.semibold).monospacedDigit()
            Text(figure.label)
        }
        .font(Theme.Text.metadata)
        .foregroundStyle(tone)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(Theme.Colors.subtleFill, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(figure.value) \(figure.label)")
    }

    private var tone: Color {
        switch figure.tone {
        case .urgent: Theme.Colors.overdue
        case .notable: Theme.Colors.dueToday
        case .plain: Theme.Colors.primaryText
        }
    }
}

/// One thing that is true of the whole day: a trip, a day off, a birthday.
///
/// No time column, because there is no time to put in it — that was the tell that these did not
/// belong in the schedule. What takes its place is the symbol for what the entry *is*, which is a
/// distinction `DayEventKind` already draws and the schedule had no room to say.
private struct TodayAwarenessRow: View {
    let dayEvent: DayEvent
    let day: Date
    let calendar: Calendar

    var body: some View {
        TimelineRow(
            badge: Timeline.Badge(
                symbolName: dayEvent.kind.symbolName,
                tint: Theme.Palette.color(named: dayEvent.event.calendarColorName)
            )
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(dayEvent.event.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(dayEvent.event.isCancelled)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .opacity(dayEvent.event.isCancelled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    /// Where in a multi-day entry today falls, or what kind of entry it is.
    ///
    /// "Day 2 of 4" is the line that makes a trip useful rather than decorative: an entry that says
    /// only "Berlin" on each of four mornings tells you nothing you did not know on the first.
    private var subtitle: String? {
        if let span = spanDescription { return span }
        guard dayEvent.kind != .allDay else { return nil }
        return dayEvent.kind.displayName
    }

    private var spanDescription: String? {
        let start = calendar.startOfDay(for: dayEvent.event.startAt)
        // An all-day entry ends at midnight *after* its last day, so the last inclusive day is a
        // moment before the end. Without that step a one-day entry reads as spanning two.
        let last = calendar.startOfDay(
            for: dayEvent.event.isAllDay
                ? dayEvent.event.endAt.addingTimeInterval(-1)
                : dayEvent.event.endAt
        )

        guard let total = calendar.dateComponents([.day], from: start, to: last).day, total > 0,
              let elapsed = calendar.dateComponents(
                  [.day], from: start, to: calendar.startOfDay(for: day)
              ).day
        else { return nil }

        return "Day \(elapsed + 1) of \(total + 1)"
    }
}

/// One event of the day: when on the left, what kind of thing it is on the rail, the rest beside it.
private struct TodayEventRow: View {
    let dayEvent: DayEvent

    var body: some View {
        TimelineRow(
            badge: Timeline.Badge(
                symbolName: dayEvent.kind.symbolName,
                tint: Theme.Palette.color(named: dayEvent.event.calendarColorName)
            )
        ) {
            VStack(alignment: .trailing, spacing: 0) {
                if dayEvent.event.isAllDay {
                    Text("All day")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                } else {
                    Text(dayEvent.event.startAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                    Text(dayEvent.event.endAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(dayEvent.event.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(dayEvent.event.isCancelled)
                    .lineLimit(2)

                if let location = dayEvent.event.locationName, !location.isEmpty {
                    Text(location)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }

                if dayEvent.hasConflict {
                    Label("Overlaps another event", systemImage: "exclamationmark.triangle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.warning)
                }

                if !dayEvent.participants.isEmpty {
                    Text(dayEvent.participants.map(\.name).joined(separator: ", "))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .opacity(dayEvent.event.isCancelled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A task on the day, on the thread.
///
/// ### Why this is not `MobileItemRow`
/// The Reminders module's row is owner-polished and stays exactly as it is. Its job is a list of
/// work; this one's job is to be a *link in a chain* that also holds meetings, gaps and people, and
/// the two want different skeletons — the same reason a calendar entry does not draw itself as a
/// task. Nothing about the Reminders module changes because of this.
private struct TodayTaskRow: View {
    let task: Item
    let day: DayTask
    let toggle: () -> Void

    var body: some View {
        TimelineRow(
            badge: Timeline.Badge(
                symbolName: day.primaryReason?.symbolName ?? "circle",
                tint: tint
            )
        ) {
            // The completion circle takes the column that a time takes on a meeting: the leading
            // column is always "when, or who", and for work you have chosen to do today the honest
            // answer is neither — it is whether it is done.
            Button(action: toggle) {
                Image(systemName: "circle")
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.displayTitle)")
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(task.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(2)

                if let reason = day.primaryReason {
                    Text(reason.label)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(tint)
                }
            }
        }
    }

    private var tint: Color {
        switch day.primaryReason {
        case .overdue?: Theme.Colors.overdue
        case .due?: Theme.Colors.dueToday
        default: Theme.Colors.secondaryText
        }
    }
}

/// A person on the day: who, why, and the one fact worth walking in with.
struct TodayPersonRow: View {
    @Environment(\.services) private var services

    let person: DayPerson

    /// Whether to say why they are here.
    ///
    /// Off underneath a gathering, where the meeting one row up has already said the time and the
    /// title and repeating it against every face is the redundancy the grouping exists to remove.
    var showsReason: Bool = true

    /// Whether this person sits underneath the gathering that named them.
    ///
    /// A nested row gives up its badge. The meeting one row up already carries the people symbol,
    /// and repeating it against every face says "who" twice while making a child look like a
    /// sibling — the rail runs plain behind them instead, which is what subordinate reads as.
    var isNested: Bool = false

    var body: some View {
        TimelineRow(
            badge: isNested
                ? nil
                : Timeline.Badge(
                    symbolName: person.primaryReason?.symbolName ?? "person",
                    tint: Theme.Palette.color(named: person.colorName)
                )
        ) {
            // A face where a time would be. Same column, same promise: this says *who*.
            PersonAvatar(name: person.name, colorName: person.colorName)
                .accessibilityHidden(true)
        } content: {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(person.name)
                        .font(Theme.Text.rowTitle)
                    if let role = person.roleLine {
                        Text(role)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }
                    if showsReason, let reason = person.primaryReason, let services {
                        Text(reason.sentence(calendar: services.dateProvider.calendar))
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }
                    if let fact = person.quickFacts.first {
                        Text(fact)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if person.isKnown {
                    Image(systemName: "chevron.forward")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
