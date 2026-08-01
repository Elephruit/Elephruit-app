import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Time destination: what is running, what was tracked, and where it went.
///
/// One screen rather than three. the layout's lesson is that tracking, reviewing and correcting are the
/// same activity — you look at yesterday *because* you are about to fix it — and splitting them
/// across tabs means every correction starts with navigation. The same lesson is why there is no
/// longer a sheet for adding time by hand: the bar at the top does both, because reaching for a
/// different surface is the same interruption in miniature.
public struct TimeView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    /// The period and the grouping live on the navigation model.
    ///
    /// They are what the Time module's sidebar navigates by, and a sidebar cannot reach a `@State`
    /// on the middle column. The pickers below still set them; they now set the same value the
    /// sidebar shows a checkmark against, rather than a private copy that disagreed with it.
    private var window: TimeWindow { navigation.timeWindow }
    private var grouping: TimeGrouping { navigation.timeGrouping }

    /// Whether alike entries collapse into one row.
    ///
    /// On by default and remembered, exactly as the design spec has it. Off is for the rarer job of
    /// reconstructing an exact sequence, where every start and stop matters and a collapsed row
    /// hides the thing being looked for.
    @AppStorage("time.groupsSimilarEntries") private var groupsSimilarEntries = true

    /// How totals are rounded. Set in Settings ▸ Time, never applied to a stored entry.
    @AppStorage("time.rounding") private var storedRounding = TimeRounding.exact.rawValue

    /// How long a working day is meant to be, in hours. Zero turns the progress bar off entirely.
    @AppStorage("time.dayTargetHours") private var dayTargetHours = 0.0

    /// Whether the sheet for time already spent is up.
    @State private var isAddingManually = false

    @State private var entries: [TimeEntrySnapshot] = []
    @State private var expandedGroups: Set<String> = []
    @State private var editingRowID: String?
    @State private var reloadTick = 0

    /// The row the keyboard is on. Also what the row actions act on when there is no pointer.
    @State private var selectedRowID: String?

    /// The last deletion, until the offer to undo it expires or is taken.
    @State private var undoableDeletion: DeletedTimeEntries?

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        VStack(spacing: 0) {
            banners

            if let undoableDeletion {
                DeletedEntriesBanner(
                    deletion: undoableDeletion,
                    onUndo: { restore(undoableDeletion) },
                    onDismiss: { self.undoableDeletion = nil }
                )
            }

            // ### One frame, not four
            // Everything below sits inside the same measure, applied once, here. It used to be
            // applied three times — centred on the tracker, centred on the summary, and
            // *left-aligned* on each log row through a `measuredRow()` helper — so on any window
            // wider than the measure the card and the totals sat in the middle of the screen and
            // the rows they described started at the far left, under a list whose own separators
            // and insets ran the full width regardless. Three columns, none of them aligned, and a
            // list that stretched however wide the window went.
            //
            // A measure is what makes a log readable at all: a description at the far left and a
            // total at the far right of a 2,000-point window have to be joined by eye across two
            // feet of nothing, and joining them is the only thing anybody does with a log. Applying
            // it to the whole page rather than to the parts means the parts cannot disagree, and
            // the list's separators stop where the content stops.
            VStack(spacing: 0) {
                VStack(spacing: Theme.Spacing.small) {
                    TimeTrackerCard(
                        onChange: { bump() },
                        onOpenSubject: { id in navigation.selectItem(id) },
                        onAddManually: { isAddingManually = true }
                    )

                    if let session = services?.timer.pomodoro {
                        FocusStrip(session: session)
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)

                // ### Why the rail sits under the tracker rather than above it
                // Everything below it is *of* the chosen period — the summary, the day sections,
                // the entries — and the tracker is not: it is about now, and starting a timer has
                // nothing to do with which week you happen to be reading. So the rail goes exactly
                // where its authority begins.
                //
                // On Reports it is at the very top, for the same rule rather than in spite of it:
                // there, everything on the page answers to it.
                TimeFilterBar(
                    // The short windows only. A log is a place you correct yesterday from, and a
                    // year of one is a list nobody can correct anything from — the long ranges
                    // belong to Reports, which is the surface that can draw one.
                    windows: TimeWindow.logWindows,
                    selectedWindow: window,
                    onSelectWindow: { navigation.timeWindow = $0 },
                    groupings: TimeGrouping.allCases,
                    grouping: grouping,
                    onSelectGrouping: { navigation.timeGrouping = $0 }
                )

                Divider()

                // ### Why the summary disappears rather than reading zero
                // A period with nothing in it used to say so three times on one screen: "Nothing
                // tracked" in the window subtitle, a large "0:00" over the words "Nothing tracked
                // in this period.", and then the centred empty state below saying "No time tracked
                // today" with the instruction and the button.
                //
                // Only the last of those is worth the room. It is the one that says what to do
                // about it. A headline zero and a sentence restating it are a summary of nothing,
                // and they push the useful part down the screen.
                if !report.isEmpty {
                    summary
                        .padding(.horizontal, Theme.Spacing.large)

                    Divider()
                }

                log
            }
            .frame(maxWidth: Self.measure)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(navigation.windowTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task(id: reloadToken) { reload() }
        .sheet(isPresented: $isAddingManually) {
            ManualTimeEntrySheet(onChange: { bump() })
                .appServicesIfAvailable(services)
        }
        .accessibilityIdentifier(AccessibilityID.Time.root)
    }

    /// Everything the app has to say about time it is not sure of.
    ///
    /// Stacked in the order the questions arrived, and each is dismissible on its own: a morning
    /// that produced a recovered timer *and* an idle gap is a morning where answering one must not
    /// bury the other.
    @ViewBuilder
    private var banners: some View {
        if let recovery = services?.timer.pendingRecovery {
            TimerRecoveryBanner(
                recovery: recovery,
                onChoose: { choice in
                    services?.timer.resolveRecovery(choice)
                    reload()
                },
                onDefer: { services?.timer.deferRecovery() }
            )
        }

        if let idle = services?.timer.pendingIdle {
            IdleTimeBanner(
                idle: idle,
                onChoose: { choice in
                    services?.timer.resolveIdle(choice)
                    bump()
                },
                onDefer: { services?.timer.deferIdle() }
            )
        }

        if let count = services?.timer.reconciledTimerCount, count > 0 {
            ReconciliationNote(count: count) { services?.timer.acknowledgeReconciliation() }
        }

        if let finished = services?.timer.finishedPhase, let session = services?.timer.pomodoro {
            FocusPhaseBanner(
                phase: finished,
                next: session.phase,
                isWaiting: session.isPaused,
                onStartNext: {
                    services?.timer.beginWaitingPhase()
                    bump()
                },
                onDismiss: { services?.timer.acknowledgeFinishedPhase() }
            )
        }
    }

    // MARK: - Summary

    /// The widest the tracker, the summary, and the log are allowed to get.
    ///
    /// A measure, in the typographic sense. Long lines are hard to read and long *rows* are hard to
    /// join up, and the fix is the same for both.
    ///
    /// Eight hundred and sixty rather than the eleven hundred it was. What a log row actually holds
    /// is a count badge, a description with a line of metadata under it, a couple of tags, a
    /// duration and two controls — and at eleven hundred points the duration column had already
    /// separated from the description it belongs to. Anything past this is not more room for the
    /// content; it is more distance between the two halves of one row.
    static let measure: CGFloat = 860

    private var summary: some View {
        TimeSummaryView(
            report: report,
            grouping: grouping,
            dayTarget: dayTargetHours > 0 ? dayTargetHours * 3_600 : nil,
            isSingleDay: window == .today || window == .yesterday,
            onOpen: { id in navigation.selectItem(id) }
        )
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var report: TimeReport {
        guard let services else { return .empty(range: window.range(using: SystemDateProvider())) }
        return TimeReporting.report(
            entries: entries,
            grouping: grouping,
            range: window.range(using: services.dateProvider),
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now,
            rounding: TimeRounding(rawValue: storedRounding) ?? .exact
        )
    }

    // MARK: - The log

    /// Day by day, newest first, exactly as the entries were made.
    ///
    /// Rebuilt on every pass rather than cached: a period holds a few hundred entries and the whole
    /// grouping is a dictionary walk over them, which is cheaper than the bookkeeping a cache would
    /// need to stay honest while a timer ticks.
    private var sections: [TimeDaySection] {
        guard let services else { return [] }
        return TimeLog.sections(
            entries: entries,
            groupSimilar: groupsSimilarEntries,
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now
        )
    }

    /// Day by day, and reachable without a pointer.
    ///
    /// ### Why the log has a selection now
    /// Because every correction in it was behind the pointer. Editing was a pencil that appeared on
    /// hover, deleting was a context menu, and both are invisible to somebody working from the
    /// keyboard — a row that cannot be reached cannot be corrected, and correcting is what this
    /// screen is for. A `List` with a selection gives arrow keys, Home and End, and a row that knows
    /// it is current; the row shows its controls when the pointer is over it *or* when it is the
    /// selected one, so the two ways in are the same set of actions.
    ///
    /// Return edits the selection and Delete removes it, which is what those keys do everywhere
    /// else in this app.
    @ViewBuilder
    private var log: some View {
        if entries.isEmpty {
            EmptyStateView(
                symbolName: "timer",
                headline: "No time tracked \(window.displayName.lowercased())",
                message: "Press Start above the moment you begin something. "
                    + "You can name it, file it, and tag it while the clock is running.",
                actionTitle: "Add Time by Hand…",
                action: { isAddingManually = true }
            )
        } else {
            List(selection: $selectedRowID) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.groups) { group in
                            groupRow(group)
                                .tag(group.id)

                            if expandedGroups.contains(group.id), !group.isSingle {
                                ForEach(group.entries) { entry in
                                    entryRow(entry)
                                        .tag(entry.id.uuidString)
                                }
                            }
                        }
                    } header: {
                        TimeDayHeader(section: section)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .onDeleteCommand { deleteSelection() }
            .onKeyPress(.return) {
                guard let selectedRowID, editingRowID == nil else { return .ignored }
                editingRowID = selectedRowID
                return .handled
            }
        }
    }

    private func groupRow(_ group: TimeEntryGroup) -> some View {
        TimeEntryGroupRow(
            group: group,
            isExpanded: expandedGroups.contains(group.id),
            isEditing: editingRowID == group.id,
            isCurrent: selectedRowID == group.id,
            onToggleExpanded: { toggleExpanded(group) },
            onResume: { group.lead.map(resume) },
            onOpen: { group.lead?.itemID.map { navigation.selectItem($0) } },
            onEdit: { editingRowID = group.id },
            onCommit: { edit in
                apply(edit, to: group.entries.map(\.id))
                editingRowID = nil
            },
            onCancelEdit: { editingRowID = nil },
            onDuplicate: { group.lead.map(duplicate) },
            onDelete: { delete(group.entries.map(\.id), describing: group.displayTitle) }
        )
    }

    private func entryRow(_ entry: TimeEntrySnapshot) -> some View {
        TimeEntryRow(
            entry: entry,
            isEditing: editingRowID == entry.id.uuidString,
            isCurrent: selectedRowID == entry.id.uuidString,
            onEdit: { editingRowID = entry.id.uuidString },
            onCommit: { edit in
                apply(edit, to: [entry.id])
                editingRowID = nil
            },
            onCancelEdit: { editingRowID = nil },
            onDuplicate: { duplicate(entry) },
            onDelete: { delete([entry.id], describing: entry.displayTitle) }
        )
    }

    /// Removes whatever the keyboard is on, group or single stretch.
    private func deleteSelection() {
        guard let selectedRowID else { return }

        if let group = sections.flatMap(\.groups).first(where: { $0.id == selectedRowID }) {
            delete(group.entries.map(\.id), describing: group.displayTitle)
        } else if let entry = entries.first(where: { $0.id.uuidString == selectedRowID }) {
            delete([entry.id], describing: entry.displayTitle)
        }
    }

    private func toggleExpanded(_ group: TimeEntryGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }

    // MARK: - Toolbar

    /// ### What is no longer in this toolbar
    /// The period and the grouping. They were here as two menus, in the sidebar as two sections of
    /// checkmark rows, and — once Reports grew a filter rail — in the view as well. Three copies of
    /// one control, two of which hid their options behind a click, on the surface where flipping
    /// between periods is most of the activity.
    ///
    /// They live in ``TimeFilterBar`` now, in the view, which both Time surfaces share. What stays
    /// here is what is genuinely about the *log* rather than about the period: how it is displayed,
    /// how to add time by hand, and the way across to Reports.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            // A menu rather than a bare `Toggle`, which rendered as an unlabelled filled circle —
            // a control whose only clue to what it does is whether it looks pressed.
            Menu {
                Toggle("Collapse Alike Entries", isOn: $groupsSimilarEntries)
                    .accessibilityIdentifier(AccessibilityID.Time.groupingToggle)
            } label: {
                Label("Display", systemImage: "slider.horizontal.3")
            }
            .help("How the log is shown")
        }

        ToolbarItem {
            Button("Add Time", systemImage: "plus") { isAddingManually = true }
                .help("Record time you have already spent")
                .accessibilityIdentifier(AccessibilityID.Time.addEntryButton)
        }

        ToolbarItem {
            Button("Reports", systemImage: "chart.bar.xaxis") {
                navigation.timeSurface = .report
            }
            .help("Totals over any period, ready to export")
        }
    }

    private var subtitle: String {
        let report = report
        guard report.entryCount > 0 else { return "Nothing tracked" }

        var parts = ["\(TimeFormatting.spelled(report.total)) tracked"]
        if report.billable > 0 {
            parts.append("\(TimeFormatting.spelled(report.billable)) billable")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Data

    /// Re-reads when the window changes, when a command runs, or when the timer starts or stops —
    /// the last of these because a running entry's row has to appear the moment it begins.
    private var reloadToken: String {
        "\(window.rawValue)|\(grouping.rawValue)|\(reloadTick)|\(services?.timer.running?.id.uuidString ?? "-")"
    }

    private func reload() {
        guard let services else { return }
        let range = window.range(using: services.dateProvider)

        services.perform {
            entries = try services.timeEntries.snapshots(in: range, limit: nil)
        }
    }

    private func bump() {
        reloadTick += 1
    }

    // MARK: - Commands

    private func resume(_ snapshot: TimeEntrySnapshot) {
        guard let services, let entry = try? services.timeEntries.entry(id: snapshot.id) else { return }
        services.timer.resume(entry)
        bump()
    }

    private func duplicate(_ snapshot: TimeEntrySnapshot) {
        guard let services, let entry = try? services.timeEntries.entry(id: snapshot.id) else { return }
        let copy = try? services.timeEntries.duplicate(entry)
        copy.map { services.mirrorTime(entryID: $0.id) }
        bump()
    }

    /// Removes tracked time, and offers it straight back.
    ///
    /// ### Why an offer rather than a question
    /// A confirmation dialogue in front of every deletion in a log is a dialogue somebody dismisses
    /// forty times a day and then, once, dismisses without reading. It also gets the cost backwards:
    /// this delete is *soft* — `TimeEntryRepository.delete(_:)` stamps `deletedAt` and
    /// `restore(_:)` puts it back — so the honest interface is one that does the thing and says how
    /// to have it back, in the place the user is already looking.
    ///
    /// It is the only offer on screen at a time, and taking it restores every stretch the action
    /// removed, which is what makes deleting a collapsed row of eight safe to try.
    private func delete(_ ids: [UUID], describing title: String) {
        guard let services else { return }
        services.perform {
            for id in ids {
                guard let entry = try services.timeEntries.entry(id: id) else { continue }
                try services.timeEntries.delete(entry)
            }
        }
        // After the delete, not before: the mirror reads the entry to decide, and a soft-deleted one
        // is what tells it to take the calendar copy back.
        ids.forEach { services.mirrorTime(entryID: $0) }
        services.timer.refresh()

        if selectedRowID != nil, ids.contains(where: { $0.uuidString == selectedRowID }) {
            selectedRowID = nil
        }
        undoableDeletion = DeletedTimeEntries(ids: ids, title: title)
        bump()
    }

    private func restore(_ deletion: DeletedTimeEntries) {
        guard let services else { return }
        services.perform {
            for id in deletion.ids {
                guard let entry = try services.timeEntries.entry(id: id) else { continue }
                try services.timeEntries.restore(entry)
            }
        }
        deletion.ids.forEach { services.mirrorTime(entryID: $0) }
        services.timer.refresh()
        undoableDeletion = nil
        bump()
    }

    /// Applies one edit to every entry it was made against.
    ///
    /// The span is applied only when there is one entry, which is what makes editing a collapsed
    /// row safe: the shared fields land on all eight stretches and their eight different pairs of
    /// clock times are left alone. See ``TimeEntryEdit``.
    private func apply(_ edit: TimeEntryEdit, to ids: [UUID]) {
        guard let services else { return }

        // Resolved once, outside the loop: a group edit against eight stretches would otherwise
        // fetch the same subject, project and people eight times over.
        let subject = resolve(edit.composition.subject, in: services)
        let project = resolve(edit.composition.project, in: services)
        let people = edit.composition.people.compactMap { resolve($0, in: services) }

        services.perform {
            for id in ids {
                guard let entry = try services.timeEntries.entry(id: id) else { continue }

                try services.timeEntries.update(entry) { subjectEntry in
                    subjectEntry.entryDescription = edit.composition.description
                    subjectEntry.item = subject
                    subjectEntry.isBillable = edit.composition.isBillable

                    if let span = edit.span, ids.count == 1 {
                        subjectEntry.startedAt = span.startedAt
                        if let endedAt = span.endedAt { subjectEntry.endedAt = endedAt }
                    }
                }

                try services.timeEntries.setTags(edit.composition.tagSlugs, on: entry)
                try services.timeEntries.setProject(project, on: entry)
                try services.timeEntries.setPeople(people, on: entry)
            }
        }

        ids.forEach { services.mirrorTime(entryID: $0) }
        services.timer.refresh()
        bump()
    }

    private func resolve(_ reference: SubjectReference?, in services: AppServices) -> Item? {
        guard let reference else { return nil }
        return (try? services.items.item(id: reference.id)) ?? nil
    }
}

// MARK: - Undo

/// What one delete removed, kept only long enough to offer it back.
///
/// The identifiers rather than the entries: a soft-deleted row is still in the store, and holding
/// `TimeEntry` in view state across a reload is the thing this codebase does not do.
struct DeletedTimeEntries: Equatable {
    var ids: [UUID]

    /// What the row said, so the offer can name what it would restore.
    var title: String

    var summary: String {
        let subject = title.isEmpty ? "That entry" : "“\(title)”"
        return ids.count == 1
            ? "\(subject) was deleted."
            : "\(ids.count) stretches of \(subject) were deleted."
    }
}

/// The offer to have deleted time back.
///
/// A banner in the flow rather than a toast over it, on the same terms as the recovery and idle
/// banners above: it is a statement about something that has already happened, it must not cover
/// the log it refers to, and it must not steal the next click.
struct DeletedEntriesBanner: View {
    let deletion: DeletedTimeEntries
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "trash")
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityHidden(true)

            Text(deletion.summary)
                .font(Theme.Text.rowSubtitle)

            Spacer(minLength: Theme.Spacing.small)

            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier(AccessibilityID.Time.undoDelete)

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.subtleFill)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(deletion.summary) Undo is available.")
    }
}

// MARK: - Summary

/// Totals, and where the time went.
///
/// ### Why the big number is not alone on its line any more
/// It was, and the line under it was a single full-width bar — which is what a period with one
/// subject in it produces, and it reads as a stray progress indicator rather than as a chart of one
/// row. Beside the total now sit the facts that qualify it: how much is billable, how many stretches
/// it took, and how many focus blocks were finished. Those are three numbers somebody would
/// otherwise count by hand off the list below.
struct TimeSummaryView: View {
    let report: TimeReport
    let grouping: TimeGrouping

    /// A day's worth of work, when one has been set, for the progress bar.
    var dayTarget: TimeInterval?

    /// Whether the period is a single day, which is the only case a day target means anything in.
    var isSingleDay: Bool

    let onOpen: (UUID) -> Void

    /// How many rows are shown before the rest are summarised as a count.
    ///
    /// Six. Enough for a week's projects, short enough that the list below stays the thing on the
    /// screen — this is a summary, and a summary as long as what it summarises is a second list.
    private let visibleRows = 6

    /// Whether the bars earn their space.
    ///
    /// ### Why one row is not a chart, and why the total still is
    /// A single bar drawn at a hundred percent of a peak it is also setting says nothing the number
    /// above it did not, and it reads as a stray progress indicator rather than as a chart of one
    /// row. That much was already true and is still the rule.
    ///
    /// What did not follow was hiding the *whole summary* with it. A day spent on one project has a
    /// total, a billable figure and a count of stretches — three facts somebody would otherwise
    /// count by hand off the list — and they went missing precisely on the tidiest day of the week,
    /// leaving a tracker card, a rule, and a list, with the only total in the window's subtitle.
    /// The headline stays whenever there is anything to total. The chart waits for something to
    /// compare.
    private var showsChart: Bool {
        report.rows.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            headline

            if let dayTarget, isSingleDay {
                dayProgress(target: dayTarget)
            }

            if showsChart {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    ForEach(report.rows.prefix(visibleRows)) { row in
                        TimeSummaryBar(row: row, peak: report.peak, onOpen: onOpen)
                    }

                    if report.rows.count > visibleRows {
                        Text("and \(report.rows.count - visibleRows) more")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    if grouping.rowsCanOverlap {
                        // Said rather than left to be discovered in a column that does not add up.
                        Text("One entry can appear in more than one row, so these need not total \(TimeFormatting.short(report.total)).")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TimeFormatting.spelled(report.total)) tracked, grouped by \(grouping.displayName)")
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Text(TimeFormatting.short(report.total))
                .font(.system(.largeTitle, design: .rounded, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: Theme.Spacing.small) {
                if report.billable > 0 {
                    TimeFactLabel(
                        symbolName: "dollarsign.circle",
                        text: "\(TimeFormatting.short(report.billable)) billable"
                    )
                }

                TimeFactLabel(
                    symbolName: "rectangle.stack",
                    text: report.entryCount == 1 ? "1 entry" : "\(report.entryCount) entries"
                )
            }

            Spacer()
        }
    }

    /// How much of the day's target has been met.
    ///
    /// ### Why this only appears for a single day, and only when asked for
    /// A target across a week is a different measurement — five days times a daily figure, minus
    /// whatever the user counts as a working day — and guessing at that is how a tracker starts
    /// telling somebody they are behind on a Sunday. Off by default for the same reason: nobody
    /// should be shown a progress bar towards a number they never set.
    private func dayProgress(target: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Colors.subtleFill)

                    Capsule()
                        .fill(report.total >= target ? Theme.Colors.completed : Theme.Colors.selection)
                        .frame(width: max(0, min(1, report.total / target)) * proxy.size.width)
                }
            }
            .frame(height: 6)

            Text(targetDescription(target: target))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(targetDescription(target: target))
    }

    private func targetDescription(target: TimeInterval) -> String {
        let remaining = target - report.total
        guard remaining > 0 else {
            return "\(TimeFormatting.spelled(report.total)) of \(TimeFormatting.spelled(target)) — done"
        }
        return "\(TimeFormatting.spelled(remaining)) left of \(TimeFormatting.spelled(target))"
    }
}

/// A small symbol-and-text fact beside the headline total.
struct TimeFactLabel: View {
    let symbolName: String
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.hairline) {
            Image(systemName: symbolName)
            Text(text)
        }
        .font(Theme.Text.metadata)
        .foregroundStyle(Theme.Colors.secondaryText)
    }
}

/// One row of the summary, with a bar proportional to the largest.
///
/// A bar rather than a number alone: the question "where did the week go" is answered by shape
/// faster than by reading seven durations and comparing them.
struct TimeSummaryBar: View {
    let row: TimeSummaryRow
    let peak: TimeInterval
    let onOpen: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Group {
                if let itemID = row.itemID {
                    Button(row.title) { onOpen(itemID) }
                        .buttonStyle(.link)
                } else {
                    Text(row.title)
                }
            }
            .font(Theme.Text.rowSubtitle)
            .lineLimit(1)
            .frame(width: 150, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // A track under every bar, so a short row still reads as a row rather than as an
                    // empty patch of window. Without it, a chart of one large and five small values
                    // looks like a chart of one value.
                    Capsule()
                        .fill(Theme.Colors.subtleFill)

                    Capsule()
                        .fill(Theme.Colors.selection.opacity(0.5))
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)

            Text(TimeFormatting.short(row.total))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(TimeFormatting.spelled(row.total))")
    }

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        return min(1, row.total / peak)
    }
}

// MARK: - Recovery

/// The three-way choice about a timer that was running when the app was not.
///
/// A banner rather than an alert. An alert would block the window over a question about the *past*,
/// and would make "not now" feel like the wrong answer — which is how someone discards a day's work
/// to get on with their morning.
struct TimerRecoveryBanner: View {
    let recovery: TimerRecovery
    let onChoose: (TimerRecoveryChoice) -> Void
    let onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "timer")
                    .foregroundStyle(Theme.Colors.warning)
                Text(message)
                    .font(Theme.Text.rowSubtitle)
                Spacer(minLength: Theme.Spacing.small)
                Button("Not Now", action: onDefer)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            HStack(spacing: Theme.Spacing.small) {
                Button("Stop at \(stopTimeDescription)") { onChoose(.stopAtLastActivity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Time.recoveryStop)

                Button("Keep Running") { onChoose(.keepRunning) }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Time.recoveryKeep)

                Button("Discard") { onChoose(.discard) }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Time.recoveryDiscard)

                Spacer()
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.recoveryBanner)
    }

    /// States the facts and nothing else — how long it ran for, and how long nobody was watching.
    private var message: String {
        let confirmed = TimeFormatting.spelled(recovery.confirmedDuration)
        let gap = TimeFormatting.spelled(recovery.unaccountedFor)
        return "A timer for “\(recovery.displayTitle)” was running when Elephruit last quit. "
            + "\(confirmed) is accounted for, and \(gap) is not."
    }

    private var stopTimeDescription: String {
        recovery.lastHeartbeatAt.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Idle

/// The four-way choice about time that passed with nobody at the machine.
///
/// A banner rather than an alert, for the same reason recovery is one: this is a question about the
/// past, and an alert that blocks the window makes whichever answer closes it fastest the one
/// people give. It is also why *Keep* is offered as plainly as *Discard* — a timer left running
/// through a two-hour meeting away from the desk recorded two hours of real work, and a banner that
/// nudged towards discarding would quietly delete it.
struct IdleTimeBanner: View {
    let idle: IdleObservation
    let onChoose: (IdleChoice) -> Void
    let onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(Theme.Colors.warning)
                Text(message)
                    .font(Theme.Text.rowSubtitle)
                Spacer(minLength: Theme.Spacing.small)
                Button("Not Now", action: onDefer)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            HStack(spacing: Theme.Spacing.small) {
                Button("Discard and Continue") { onChoose(.discardAndContinue) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(IdleChoice.discardAndContinue.hint)
                    .accessibilityIdentifier(AccessibilityID.Time.idleDiscardAndContinue)

                Button("Discard") { onChoose(.discard) }
                    .controlSize(.small)
                    .help(IdleChoice.discard.hint)
                    .accessibilityIdentifier(AccessibilityID.Time.idleDiscard)

                Button("Keep") { onChoose(.keep) }
                    .controlSize(.small)
                    .help(IdleChoice.keep.hint)
                    .accessibilityIdentifier(AccessibilityID.Time.idleKeep)

                Button("Keep Separately") { onChoose(.keepAsSeparateEntry) }
                    .controlSize(.small)
                    .help(IdleChoice.keepAsSeparateEntry.hint)
                    .accessibilityIdentifier(AccessibilityID.Time.idleSeparate)

                Spacer()
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Time.idleBanner)
    }

    /// States the facts and nothing else — how long, and since when.
    private var message: String {
        let gap = TimeFormatting.spelled(idle.duration)
        let since = idle.idleSince.formatted(date: .omitted, time: .shortened)
        return "The timer for “\(idle.displayTitle)” kept running, but nothing has been typed since "
            + "\(since) — \(gap) ago."
    }
}

/// Shown when two devices each left a timer running.
struct ReconciliationNote: View {
    let count: Int
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Theme.Colors.secondaryText)
            Text(count == 1
                ? "Another timer was still running, so it was closed where this one began. Nothing was deleted."
                : "\(count) other timers were still running and have been closed in sequence. Nothing was deleted.")
                .font(Theme.Text.metadata)
            Spacer(minLength: Theme.Spacing.small)
            Button("OK", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.subtleFill)
        .overlay(alignment: .bottom) { Divider() }
    }
}
