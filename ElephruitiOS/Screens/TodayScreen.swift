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

    /// Whether a development launch has already been given the history it asked for.
    ///
    /// One-shot for the same reason the sheet below is: pressing "Today" closes the past again, the
    /// window token changes, and a flag-driven reveal that re-reads the argument would open it
    /// straight back up — a page that cannot be returned to now, which is exactly what it broke.
    @State private var hasOpenedReviewPast = false

    /// Whether a development launch has already had its sheet.
    ///
    /// Once per launch, not once per change. Without this, writing anything from the sheet changes
    /// the library, which changes the source token, which opens the sheet again over the page the
    /// write was meant to reveal — which is exactly how a passing test started failing.
    @State private var hasOpenedReviewSheet = false

    /// How close to the end the scroll has to get before the next week is asked for.
    ///
    /// About a screen. Less and the feed visibly stops before it continues; more and a flick that
    /// was never going to reach the bottom has already spent a calendar read.
    private static let pagingReach: CGFloat = 600

    /// How much of the page's strength a day that is over keeps.
    private static let pastDimming: CGFloat = 0.55

    /// Whether today's first and last rows have been drawn.
    ///
    /// Both start false, and that is the fix rather than the cautious default. Today is taller than
    /// the window, so its *end* is below the fold on arrival and a list never realises it — a flag
    /// that started true therefore stayed true forever, and the page believed today was on screen
    /// from a month away. What keeps the pill from flashing at launch is the day below, which is
    /// unset until something has actually been seen.
    @State private var topEdgeVisible = false
    @State private var bottomEdgeVisible = false

    /// The day that most recently came into view.
    ///
    /// ### Why this and not the geometry
    /// The first version measured where today's edges sat in the scroll view and compared that with
    /// the window's height. It reported that today was on screen from three weeks away, because a
    /// `List` recycles the rows it has scrolled past: the markers stopped being asked, their last
    /// answers stayed in state, and the page went on believing them. Anything derived from a row's
    /// *position* has that hole in it.
    ///
    /// What a recycled row can still say is "I have just come into view", which is the one event it
    /// is guaranteed to be alive for. So each day says so as it arrives, and the page keeps the last
    /// one — which also answers *which way* today is, by comparing dates instead of offsets.
    @State private var visibleDay: Date?

    /// Whether the next arrival of earlier days is the first, which is the one time the page moves.
    @State private var isFirstRevealOfPast = false

    private static let todayTopID = "today.anchor.top"
    private static let todayBottomID = "today.anchor.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            page(proxy)
        }
    }

    private func page(_ proxy: ScrollViewProxy) -> some View {
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
                earlierFeed
                todayEdge(id: Self.todayTopID) { topEdgeVisible = $0 }
                daySections(plan, isAnchor: true)
                todayEdge(id: Self.todayBottomID) { bottomEdgeVisible = $0 }
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
        // Days arriving above the viewport move nothing under the thumb, and that is the *List's*
        // doing rather than this page's — it holds the visible row still and grows upward behind it.
        // Proved by accident: the first version of this reveal scrolled to yesterday by hand and
        // appeared to do nothing at all, because the list had already stayed exactly where it was.
        // A hand-written restore on top of that is worse than redundant — it re-pins the reader to
        // one row every time a week loads, which turns scrolling into the past into hitting a wall.
        //
        // What does need saying is the first reveal: somebody who pressed "Earlier days" has to see
        // the days they asked for, so the page steps up to the oldest of them.
        .onChange(of: model.previousDays.count) { _, _ in
            // A development launch asking for a deeper past keeps asking until it has one — and
            // only while its one reveal is still in progress.
            if let wanted = TodayReviewLaunch.earlierDays(),
               hasOpenedReviewPast, model.isShowingPreviousDays, model.pastDayCount < wanted {
                askForEarlierDays()
            }

            guard isFirstRevealOfPast, let earliest = model.previousDays.first else { return }
            isFirstRevealOfPast = false

            // Deferred by a frame: the rows exist as values the moment the count changes, but the
            // list has not laid out the ones above the viewport yet, and a `scrollTo` aimed at a row
            // it has not realised does nothing — silently, which is how this first read as "the
            // button is broken".
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                withCalmAnimation(Theme.Motion.standard) {
                    proxy.scrollTo(dayRowID(earliest.date), anchor: .top)
                }
            }
        }
        .refreshable {
            // Honest refresh: re-reads the calendar, which genuinely can have changed
            // underneath the app. The library itself needs no pulling — it is local.
            await model.reload()
        }
        // Two ways back, because they answer at different moments. The toolbar is where somebody
        // *looks* for it; the pill is under the thumb that scrolled away, and it says which way.
        .overlay(alignment: .bottom) {
            if !isTodayOnScreen { backToNow(proxy) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Shown when the page is standing on another day *or* when today has been scrolled
                // out of sight. The second case is new and is most of them: the anchor has not
                // changed, the reader has simply run three weeks down the feed.
                if !model.isOnToday || !isTodayOnScreen {
                    Button("Today") { returnToNow(proxy) }
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
        .task(id: model.windowToken) {
            await model.reload()
            if TodayReviewLaunch.earlierDays() != nil, !hasOpenedReviewPast, !model.isShowingPreviousDays {
                hasOpenedReviewPast = true
                askForEarlierDays()
            }
        }
        // Animated, because one of the things that changes the source token is this page writing to
        // the calendar. A block written as busy takes back the free time it was made from, so the
        // thread reassembles under the thumb that just wrote it. That is honest, and it must not
        // read as a glitch.
        .onChange(of: model.sourceToken) { _, _ in
            withCalmAnimation(Theme.Motion.standard) { model.assemble() }
            openBlockSheetIfReviewing()
        }
        // The horizontal day-swipe is gone, and the feed is why. It existed when this page showed
        // one day and moving to another meant replacing it; now tomorrow is simply further down and
        // yesterday is further up, so the swipe was a second, less obvious way to do what the scroll
        // already does — while competing for the same gesture as the rows' own swipe actions. The
        // toolbar's Previous and Next Day remain for anyone who wants to *stand on* another day.
    }

    /// Whether any part of the anchor day is on screen.
    ///
    /// Three ways of being on screen, and the third is the one a single flag would miss: today is
    /// taller than the window, so somebody reading the middle of it can see neither end. What they
    /// *have* seen most recently is today, and that is what the last visible day says.
    private var isTodayOnScreen: Bool {
        if topEdgeVisible || bottomEdgeVisible { return true }
        guard let visibleDay, let calendar = services?.dateProvider.calendar else { return true }
        return calendar.isDate(visibleDay, inSameDayAs: model.selectedDate)
    }

    /// Whether today lies below what is on screen, which is what makes the pill's arrow honest.
    private var isTodayBelow: Bool {
        guard let visibleDay else { return false }
        return visibleDay < model.selectedDate
    }

    /// A one-point row marking where today begins and ends, so the page can tell whether the day is
    /// on screen without asking every row in it.
    private func todayEdge(id: String, report: @escaping (Bool) -> Void) -> some View {
        Color.clear
            .frame(height: 1)
            .id(id)
            // Realisation, not visibility. `onScrollVisibilityChange` never fired once for these
            // rows — a `List` is not the scroll view the modifier is documented against — and the
            // page spent three attempts believing a signal that was never sent. Appearing and
            // disappearing is the one thing a list cell definitely does.
            .onAppear {
                report(true)
                visibleDay = model.selectedDate
            }
            .onDisappear { report(false) }
            .onTimeline()
    }

    /// The pill that says which way now is.
    ///
    /// It says the direction because "Today" alone is a button whose result is a surprise: from
    /// three weeks ahead the page has to travel up, from last month it has to travel down, and an
    /// arrow is the cheapest possible way to stop that being a guess.
    private func backToNow(_ proxy: ScrollViewProxy) -> some View {
        Button {
            returnToNow(proxy)
        } label: {
            Label("Today", systemImage: isTodayBelow ? "arrow.down" : "arrow.up")
                .font(Theme.Text.metadata.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .background(Theme.Colors.selection, in: Capsule())
                .foregroundStyle(Theme.Colors.onAccent)
        }
        .buttonStyle(.plain)
        .elevation(.floating)
        // Clear of the shell's floating plus, which owns the bottom trailing corner.
        .padding(.bottom, Theme.Spacing.section)
        .transition(.opacity)
        .accessibilityIdentifier("today.backToNow")
    }

    /// Takes the reader back to now, which is usually a scroll rather than a change of day.
    ///
    /// ### Why the history is left loaded
    /// Because "back to today" is a statement about where you are *looking*, not a request to
    /// forget what you opened. Resetting the window at the same time removed every row above today
    /// while the scroll to it was still in flight, and the page landed wherever the collapse left
    /// it — which was never today. Standing on another day is the one case that really is a
    /// different page, and only that one rebuilds.
    private func returnToNow(_ proxy: ScrollViewProxy) {
        guard model.isOnToday else {
            withCalmAnimation(Theme.Motion.standard) { model.returnToToday() }
            return
        }
        withCalmAnimation(Theme.Motion.standard) {
            proxy.scrollTo(Self.todayTopID, anchor: .top)
        }
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
            feedDay(plan)
        }

        if model.selectedPlan != nil {
            TodayFeedFooter(
                isExtending: model.isExtendingFuture,
                canLoadMore: model.canLoadMoreDays
            )
            .onTimeline()
        }
    }

    // MARK: - The days before it

    /// The run of days above the one you are standing on.
    ///
    /// ### Why the past is dimmed and the line with it
    /// Because it is the same page and it is not the same *kind* of information. A day that is over
    /// cannot be planned, only read, and drawing it at full strength above today makes the page open
    /// on a record rather than on a plan. Dimming the rows says "this is behind you"; fading the
    /// rail says the thread itself is older up there, which the rows alone cannot say — a
    /// full-strength line running up through three grey days reads as somebody having turned the
    /// lights down rather than as time.
    @ViewBuilder
    private var earlierFeed: some View {
        TodayFeedHeader(
            isShowingPast: model.isShowingPreviousDays,
            isExtending: model.isExtendingPast,
            canLoadMore: model.canLoadEarlierDays,
            reveal: { askForEarlierDays() }
        )
        .environment(\.timelineIsPast, true)
        // The top of the page pages itself, but on *reaching* it rather than on being near it.
        //
        // The feed below uses proximity, and doing the same here ran the window straight back to
        // its ninety-day ceiling in one gesture: each load leaves the reader where they were with
        // the new days above them, so "near the top" is true again immediately, and a week of clear
        // days is barely four hundred points tall. Reaching this row converges instead — after a
        // load it is a week further up, and asking again means scrolling to it again.
        .onAppear {
            guard model.isShowingPreviousDays else { return }
            askForEarlierDays()
        }
        .onTimeline()

        ForEach(model.previousDays) { plan in
            feedDay(plan)
                .opacity(Self.pastDimming)
                .environment(\.timelineIsPast, true)
        }
    }

    /// One day of a feed: its marker, and either its summary or the whole day opened out.
    ///
    /// The same builder above today and below it. A day behind you and a day ahead of you are the
    /// same object read in two directions, and giving them two renderings is how a page ends up
    /// meaning different things at its two ends.
    @ViewBuilder
    private func feedDay(_ plan: DayPlan) -> some View {
        TodayFeedDayHeader(plan: plan, isExpanded: model.isExpanded(plan)) {
            withCalmAnimation(Theme.Motion.standard) { model.toggleExpanded(plan) }
        }
        .id(dayRowID(plan.date))
        // Each day says when it arrives, which is how the page knows where the reader is without
        // asking a recycled row where it used to be.
        .onAppear { visibleDay = plan.date }
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

    /// Asks for the days behind, noting whether this is the first time.
    ///
    /// The guard against asking twice for the same week is the model's, so a run of scroll events
    /// costs one calendar read rather than one each.
    private func askForEarlierDays() {
        guard model.canLoadEarlierDays, !model.isExtendingPast else { return }

        isFirstRevealOfPast = !model.isShowingPreviousDays
        model.extendPast()
    }

    private func dayRowID(_ date: Date) -> String {
        "day:" + (services?.dateProvider.dayKey(for: date) ?? "\(date.timeIntervalSinceReferenceDate)")
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
        guard !hasOpenedReviewSheet,
              blocking == nil,
              let subject = TodayReviewLaunch.blockSheet(),
              services?.calendar.calendars.isEmpty == false,
              let plan = model.selectedPlan
        else { return }

        switch subject {
        case .gap:
            guard let slot = plan.briefing.focus.slots.first else { return }
            blocking = .slot(slot, plan)
        case .work:
            guard let entry = model.openTasks(in: plan).first(where: { $0.day.pinnedAt == nil })
            else { return }
            blocking = .task(entry.item, plan)
        }
        hasOpenedReviewSheet = true
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

                        // The same sheet the gaps open, arriving from the other direction: from
                        // work looking for room rather than from room looking for work.
                        Button {
                            blocking = .task(entry.item, plan)
                        } label: {
                            Label("Block Time", systemImage: "shield")
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
        Button("Block Time", systemImage: "shield") {
            blocking = .task(task, plan)
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
            // Both ends of it, now that no column to the left is saying where it starts.
            // `rangeSummary` already knows to say "until 4:00 PM" for a stretch under way, where a
            // start time in the past is a number the reader has to subtract from before it means
            // anything.
            Text("\(slot.durationSummary) free · \(slot.rangeSummary)")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.durationSummary) free, \(slot.rangeSummary)")
        // Named so a test can count the gaps without matching on their text. Scanning labels for
        // "free" finds the briefing's line at the top of the page as well, and a predicate walking
        // the whole hierarchy of a long list is slow enough to time the test out.
        .accessibilityIdentifier("today.freeSlot")
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
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                // When, above what — the line the eye runs down when it is looking for a time
                // rather than for a name. It used to be a column of its own to the left of the
                // rail; see `Timeline` for why the page is better off without one.
                Text(whenLine)
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.secondaryText)

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

    /// "9:30 AM – 9:45 AM", or the one word an all-day entry has instead.
    private var whenLine: String {
        guard !dayEvent.event.isAllDay else { return "All day" }
        return dayEvent.event.startAt.formatted(date: .omitted, time: .shortened)
            + " – " + dayEvent.event.endAt.formatted(date: .omitted, time: .shortened)
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

    /// Whether the circle is filled in.
    ///
    /// Read from the record rather than kept here, so the fill appears the moment the task is
    /// completed and stays right if the same task is completed from somewhere else.
    private var isCompleted: Bool { task.status == .completed }

    var body: some View {
        TimelineRow(
            // The mark on the thread *is* the checkbox. Everywhere else the badge says what kind of
            // thing a row is; for work, the only thing worth saying is whether it is done, and a
            // circle on the line saying it is one mark instead of two.
            //
            // Outlined in the reason's own colour, so a page of work still reads as late, due, or
            // merely chosen without a word being read. Completed, it fills and takes a check —
            // the same colour, now solid, which is what "done" has looked like since paper.
            badge: Timeline.Badge(
                symbolName: isCompleted ? "checkmark" : nil,
                tint: tint,
                isHollow: !isCompleted
            ),
            badgeAction: toggle,
            badgeLabel: isCompleted ? "Reopen \(task.displayTitle)" : "Complete \(task.displayTitle)"
        ) {
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
        // No face on this row any more. It used to sit in a gutter *outside* the rail, which put a
        // person's initials beside the day rather than in it — and their colour is already on the
        // badge, where every other row says what kind of thing it is. Faces still belong to the
        // gathering row, where four of them at a glance answer "who am I with at four".
        TimelineRow(
            badge: isNested
                ? nil
                : Timeline.Badge(
                    symbolName: person.primaryReason?.symbolName ?? "person",
                    tint: Theme.Palette.color(named: person.colorName)
                )
        ) {
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
