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

    var body: some View {
        List {
            if let failure = model.failure {
                Section {
                    Label(failure.summary, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warning)
                }
            }

            if let plan = model.selectedPlan {
                briefingSection(plan)
                calendarStateSection
                awarenessSection(plan)
                eventsSection(plan)
                tasksSection(plan)
                completedSection(plan)
                peopleSection(plan)
                dailyNoteSection(plan)

                if plan.isEmpty, model.failure == nil {
                    Section {
                        EmptyStateView(
                            symbolName: plan.isToday ? "sun.max" : "calendar",
                            headline: plan.isToday ? "A clear day" : "Nothing planned",
                            message: plan.isToday
                                ? "Nothing scheduled, nothing due. Capture something, or enjoy it."
                                : "Nothing scheduled or due on this day yet.",
                            tone: .accomplished
                        )
                    }
                    .listRowBackground(Color.clear)
                }
            } else if model.isLoadingInitially {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
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
        // The same two-token drive as the Mac: the window token reloads the calendar,
        // the source token reassembles from memory. See `TodayModel` for why they differ.
        .task(id: model.windowToken) { await model.reload() }
        .onChange(of: model.sourceToken) { _, _ in model.assemble() }
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

    // MARK: - Briefing

    @ViewBuilder
    private func briefingSection(_ plan: DayPlan) -> some View {
        let figures = plan.briefing.figures
        if !figures.isEmpty || plan.briefing.next != nil {
            Section {
                if !figures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.small) {
                            ForEach(figures) { figure in
                                BriefingFigureChip(figure: figure)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(
                        top: Theme.Spacing.small, leading: Theme.Spacing.large,
                        bottom: Theme.Spacing.small, trailing: Theme.Spacing.large
                    ))
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
                        // `summary` already says "free" — "3h 20m free · 1h from 2:00 PM".
                        Text("\(plan.briefing.focus.summary) · \(stretch)")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } icon: {
                        Image(systemName: "hourglass")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }
        }
    }

    /// Why the calendar half of the day may be silent, said in place rather than left to
    /// be discovered. Shown only when it would explain something.
    @ViewBuilder
    private var calendarStateSection: some View {
        if let services {
            let calendar = services.calendar
            if !calendar.isEnabled {
                Section {
                    NavigationLink(value: MobileRoute.settings) {
                        Label {
                            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                Text("Calendar is off")
                                    .font(Theme.Text.rowTitle)
                                Text("Turn it on in Settings to see meetings here.")
                                    .font(Theme.Text.rowSubtitle)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.plus")
                                .foregroundStyle(Theme.Colors.selection)
                        }
                    }
                }
            } else if calendar.authorization == .denied || calendar.authorization == .restricted {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text("Calendar access is denied")
                                .font(Theme.Text.rowTitle)
                            Text("Allow access in Settings › Privacy to see meetings here.")
                                .font(Theme.Text.rowSubtitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
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
            Section("Awareness") {
                ForEach(awareness) { event in
                    TodayAwarenessRow(dayEvent: event, day: plan.date, calendar: calendar)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            shell.push(.event(event.event.identity.storageKey))
                        }
                }
            }
        }
    }

    // MARK: - Events

    @ViewBuilder
    private func eventsSection(_ plan: DayPlan) -> some View {
        let calendar = services?.dateProvider.calendar ?? .current
        let schedule = plan.scheduleEvents(calendar: calendar)
        if !schedule.isEmpty {
            Section("Schedule") {
                ForEach(schedule) { event in
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
                }
            }
        }
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
            Section(plan.isToday ? "To do" : "Due or planned") {
                ForEach(open, id: \.day.id) { entry in
                    MobileItemRow(item: entry.item) {
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
                }
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
            Section {
                DisclosureGroup {
                    ForEach(completed) { item in
                        MobileItemRow(item: item) {
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
        }
    }

    // MARK: - People

    @ViewBuilder
    private func peopleSection(_ plan: DayPlan) -> some View {
        if !plan.people.isEmpty {
            Section("People today") {
                ForEach(plan.people) { person in
                    TodayPersonRow(person: person)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let id = person.personID {
                                shell.push(.person(id))
                            }
                        }
                }
            }
        }
    }

    // MARK: - Daily note

    @ViewBuilder
    private func dailyNoteSection(_ plan: DayPlan) -> some View {
        Section {
            Button {
                openDailyNote(plan)
            } label: {
                Label {
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
                } icon: {
                    Image(systemName: "sun.horizon")
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .buttonStyle(.plain)
        }
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
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: dayEvent.kind.symbolName)
                .foregroundStyle(Theme.Palette.color(named: dayEvent.event.calendarColorName))
                .frame(width: 20)
                .accessibilityHidden(true)

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

            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
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

/// One event of the day: time column, then what and where, conflict said in words.
private struct TodayEventRow: View {
    let dayEvent: DayEvent

    /// Scales with the text it holds, so an accessibility size widens the column
    /// rather than wrapping a time mid-digit. 64 points is what "10:00 AM" needs in
    /// monospaced caption digits at the standard size — 56 fit "9:30 AM" and split
    /// every double-digit hour onto two lines, which the first live screenshot caught.
    @ScaledMetric(relativeTo: .caption) private var timeColumnWidth: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
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
            .frame(width: timeColumnWidth, alignment: .trailing)

            Capsule()
                .fill(Theme.Palette.color(named: dayEvent.event.calendarColorName))
                .frame(width: 3)

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
        .frame(minHeight: 44)
        .opacity(dayEvent.event.isCancelled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A person on the day: who, why, and the one fact worth walking in with.
private struct TodayPersonRow: View {
    @Environment(\.services) private var services

    let person: DayPerson

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.color(named: person.colorName).opacity(0.2))
                Text(initials)
                    .font(Theme.Text.metadata.weight(.semibold))
                    .foregroundStyle(Theme.Palette.color(named: person.colorName))
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(person.name)
                    .font(Theme.Text.rowTitle)
                if let reason = person.primaryReason, let services {
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
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let parts = person.name.split(separator: " ")
        let letters = [parts.first, parts.count > 1 ? parts.last : nil]
            .compactMap { $0?.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
