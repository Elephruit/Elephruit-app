import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

// MARK: - The date rail

/// The date marker down the left of every day.
///
/// ### Why a rail and not a heading
/// Because the page is a run of days and a heading per day makes the run read as a stack of separate
/// screens. A marker in a fixed column makes the dates a spine: the eye can travel down it without
/// reading, which is how somebody finds Thursday in a page of five days. It is also where the
/// distinction between *today* and *a day* lives, so the day's own content does not have to carry a
/// tint or a border to say which one it is.
struct TodayDateRail: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    var isEmphasised: Bool
    var isPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plan.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(isEmphasised ? .system(.title3, design: .default, weight: .semibold) : Theme.Text.rowTitleEmphasised)
                .foregroundStyle(Theme.Colors.primaryText)
                .monospacedDigit()

            if let relative {
                Text(relative)
                    .font(Theme.Text.rowSubtitle)
                    // The only place accent colour appears in the rail, and only for today. A whole
                    // column of coloured labels would say nothing; one says *here*.
                    .foregroundStyle(plan.isToday ? Theme.Colors.link : Theme.Colors.secondaryText)
            }

            Text(plan.date.formatted(.dateTime.weekday(.wide)))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(.trailing, Theme.Spacing.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// "Today", "Tomorrow", "Yesterday" — and nothing for the rest, where the weekday already says it.
    private var relative: String? {
        let clock = services?.dateProvider ?? SystemDateProvider()
        let calendar = clock.calendar

        if plan.isToday { return "Today" }
        if calendar.isDate(plan.date, inSameDayAs: clock.startOfTomorrow) { return "Tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: clock.startOfToday),
           calendar.isDate(plan.date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return nil
    }

    private var accessibilityLabel: String {
        var parts = [plan.date.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        if let relative { parts.append(relative) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sections

/// A heading and what is under it.
///
/// ### Why this is not a card
/// Because a page of cards is a page of borders, and borders are the least informative thing on a
/// screen. Hierarchy here is typography and space: a small capitalised heading, a count where the
/// count means something, and the content directly beneath it aligned to the same edge as every
/// other section. A tint appears only when the section's *state* is worth a colour, which is late
/// work and nothing else.
struct TodaySection<Content: View>: View {
    let title: String
    var count: Int?
    var symbolName: String?
    var tone: BriefingFigure.Tone = .plain

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.tight) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(toneColor)
                        .accessibilityHidden(true)
                }

                Text(title.uppercased())
                    .font(Theme.Text.sectionHeader)
                    .tracking(Theme.Text.Tracking.caps)
                    .foregroundStyle(toneColor)

                if let count {
                    Text("\(count)")
                        .font(Theme.Text.sectionHeader)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer(minLength: 0)
            }

            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }

    private var toneColor: Color {
        switch tone {
        // Reserved for genuinely late work. Everywhere else a heading is a heading.
        case .urgent: Theme.Colors.overdue
        case .notable: Theme.Colors.dueToday
        case .plain: Theme.Colors.secondaryText
        }
    }
}

// MARK: - The briefing

/// The few lines at the top of a day.
///
/// ### Why so few numbers
/// Each one has to change what somebody does next. "Three meetings" decides whether the afternoon is
/// worth planning; "two overdue" decides what happens first; "four hours free" decides what can be
/// attempted at all. A count of notes written this week decides nothing, so it is not here, and the
/// space it would have taken is why the three that matter can be read in a second.
struct TodayBriefingView: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    let actions: TodayActions?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if plan.isToday, let greeting {
                Text(greeting)
                    .font(.system(.largeTitle, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.Colors.primaryText)
            } else {
                Text(plan.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.Colors.primaryText)
            }

            figures

            nextCommitment
            celebrations
        }
        .accessibilityIdentifier(AccessibilityID.Today.briefing)
    }

    private var greeting: String? {
        guard let clock = services?.dateProvider else { return nil }
        return DayBriefing.greeting(at: clock.now, calendar: clock.calendar)
    }

    @ViewBuilder
    private var figures: some View {
        let figures = plan.briefing.figures
        if figures.isEmpty {
            Text(plan.isPast ? "Nothing recorded." : "Nothing scheduled.")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
        } else {
            // A flow rather than a row: at a narrow width the figures wrap rather than truncating,
            // and a truncated number is worse than no number.
            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.medium, lineSpacing: Theme.Spacing.tight) {
                ForEach(figures) { figure in
                    HStack(spacing: Theme.Spacing.tight) {
                        Image(systemName: figure.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(color(for: figure.tone))
                            .accessibilityHidden(true)

                        Text(figure.value)
                            .font(Theme.Text.rowTitleEmphasised)
                            .monospacedDigit()
                            .foregroundStyle(color(for: figure.tone))

                        Text(figure.label)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(figure.value) \(figure.label)")
                }
            }
            .accessibilityIdentifier(AccessibilityID.Today.figures)
        }
    }

    private func color(for tone: BriefingFigure.Tone) -> Color {
        switch tone {
        // The one figure entitled to red, because it is the one that is genuinely wrong.
        case .urgent: Theme.Colors.overdue
        case .notable: Theme.Colors.dueToday
        case .plain: Theme.Colors.primaryText
        }
    }

    @ViewBuilder
    private var nextCommitment: some View {
        if let next = plan.briefing.next, let clock = services?.dateProvider {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: next.isInProgress ? "record.circle" : "arrow.right.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(next.isInProgress ? Theme.Colors.dueToday : Theme.Colors.tertiaryText)
                    .accessibilityHidden(true)

                Text(plan.isToday ? "Next" : "First")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text(next.title)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                Text(plan.isToday
                    ? next.relativeText(from: clock.now)
                    : next.startAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Today.nextCommitment)
        }
    }

    /// Birthdays and anniversaries falling today, and nothing else.
    ///
    /// ### Why only today's
    /// Because a celebration seven days out is a fact about that day, and the roster below already
    /// carries it with the person it belongs to. Repeating a week of birthdays at the top of every
    /// morning is how a briefing turns into a newsletter.
    @ViewBuilder
    private var celebrations: some View {
        let today = plan.briefing.celebrations.filter { $0.daysAway == 0 }
        if !today.isEmpty {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: today[0].celebration.kind.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                Text(ListPhrase.joined(today.map(\.summaryLine)))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension UpcomingCelebration {
    /// "Maya Chen turns 39" — the person and the occasion, without the "today" the line already says.
    var summaryLine: String {
        if let milestoneYears {
            return "\(celebration.personName) \(celebration.kind.milestonePhrase(years: milestoneYears))"
        }
        return "\(celebration.personName)'s \(celebration.displayTitle.lowercased())"
    }
}

// MARK: - Now

/// Where the day currently is.
///
/// A hairline and a time rather than a coloured band. The line's job is to be findable while
/// scanning and to be ignorable while reading, and a filled bar across the content is neither.
struct TodayNowMarker: View {
    let now: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.destructive)
                .frame(width: TodayMetrics.timeGutterWidth, alignment: .leading)

            Rectangle()
                .fill(Theme.Colors.destructive)
                .frame(height: 1)
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(now.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Adding work

/// A field that asks only for a title.
struct TodayQuickAddField: View {
    @Binding var title: String
    var isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText)

            TextField("New reminder", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Text.rowTitle)
                .focused(isFocused)
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                // Losing focus commits what was typed rather than discarding it, and an empty draft
                // simply disappears. Without this, clicking elsewhere left an empty circle and the
                // grey words "New task" sitting in the day with no control on it — a row that looked
                // like a task that could not be deleted, because it looked like a task.
                .onChange(of: isFocused.wrappedValue) { _, hasFocus in
                    guard !hasFocus else { return }
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? onCancel() : onCommit()
                }
                .accessibilityIdentifier(AccessibilityID.Today.quickAdd)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.Size.rowHeight)
    }
}

// MARK: - The day's note

/// The day's own note, if there is one, and a way to start one if there is not.
///
/// ### Why this is a line and not a panel
/// Because most days have no note, and an empty panel with a heading is the single largest thing on
/// a light day's page — a box the size of the day's actual content, containing the word "Empty". A
/// note that exists gets its first lines; a note that does not gets one control.
struct TodayNoteView: View {
    let plan: DayPlan
    let actions: TodayActions?

    @State private var thought = ""
    @FocusState private var isThoughtFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let excerpt = plan.dailyNoteExcerpt, let id = plan.dailyNoteID {
                TodaySection(title: "Note", symbolName: "note.text") {
                    Button {
                        actions?.select(id)
                    } label: {
                        Text(excerpt)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.primaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the note for this day")
                }
            } else if !plan.isPast {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "note.text")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .accessibilityHidden(true)

                    TextField("Add a thought", text: $thought)
                        .textFieldStyle(.plain)
                        .font(Theme.Text.rowSubtitle)
                        .focused($isThoughtFocused)
                        .onSubmit(commit)

                    if !thought.isEmpty {
                        Button("Save", action: commit)
                            .buttonStyle(.borderless)
                            .font(Theme.Text.metadata)
                    }

                    Button("Open Note") {
                        actions?.openDailyNote(for: plan.date, creatingIfNeeded: true)
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
                    .accessibilityIdentifier(AccessibilityID.Today.startDailyNote)
                }
                .padding(.vertical, Theme.Spacing.tight)
            }
        }
    }

    /// Writes into the day's note, creating it only because somebody typed into it.
    private func commit() {
        actions?.appendToDailyNote(thought, on: plan.date)
        thought = ""
        isThoughtFocused = false
    }
}

// MARK: - What is already done

/// Finished work, collapsed.
///
/// ### Why a line rather than a list
/// Because completed work has already had its moment. Leaving eleven ticked rows above the four that
/// are left means the day looks fullest at the point it is emptiest, and the reward for finishing
/// something is that it takes up more of the screen than the thing you have not started.
struct TodayCompletedView: View {
    let tasks: [Item]
    let actions: TodayActions?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(Theme.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.completed)

                    Text(summary)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityHint(isExpanded ? "Hide finished work" : "Show finished work")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks, id: \.id) { task in
                        TodayCompletedRow(task: task, actions: actions)
                    }
                }
            }
        }
    }

    private var summary: String {
        let completed = tasks.count { $0.status == .completed }
        let cancelled = tasks.count - completed

        var parts: [String] = []
        if completed > 0 { parts.append(completed == 1 ? "1 finished" : "\(completed) finished") }
        // Deciding not to do something is worth remembering, and worth counting separately from
        // having done it — the same distinction the logbook keeps.
        if cancelled > 0 { parts.append(cancelled == 1 ? "1 dropped" : "\(cancelled) dropped") }
        return parts.joined(separator: " · ")
    }
}

struct TodayCompletedRow: View {
    let task: Item
    let actions: TodayActions?

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button { actions?.toggleCompletion(task) } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(task.status == .completed
                        ? Theme.Colors.completed
                        : Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reopen \(task.displayTitle)")

            Text(task.displayTitle)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .strikethrough(task.status == .cancelled, color: Theme.Colors.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .hoverHighlight(extending: Theme.Spacing.small)
    }
}

// MARK: - A day with nothing in it

/// What a clear day says.
///
/// ### Why this is not an empty state
/// Because the day is not empty in the sense an empty list is: there is nothing wrong, and the
/// correct response to that is to confirm it and offer the next useful thing, not to draw a large
/// grey glyph apologising. Four small controls, one line of text, and no container.
struct TodayClearDayView: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    let actions: TodayActions?
    let onAddTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(message)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)

            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                Button("Add a Reminder", systemImage: "plus.circle", action: onAddTask)

                Button("Write Today's Note", systemImage: "note.text") {
                    actions?.openDailyNote(for: plan.date, creatingIfNeeded: true)
                }

                Button("Block Focus Time", systemImage: "shield.lefthalf.filled") {
                    actions?.openInCalendarForFocus(on: plan.date)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var message: String {
        if plan.isPast { return "Nothing was recorded for this day." }
        if plan.isToday { return "Your day is clear. Nothing is overdue and nothing is booked." }
        return "Nothing booked yet."
    }
}
