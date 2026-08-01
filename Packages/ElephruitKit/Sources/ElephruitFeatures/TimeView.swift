import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Time destination: what is running, what was tracked, and where it went.
///
/// One screen rather than three. Toggl's lesson is that tracking, reviewing and correcting are the
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
    /// On by default and remembered, exactly as Toggl has it. Off is for the rarer job of
    /// reconstructing an exact sequence, where every start and stop matters and a collapsed row
    /// hides the thing being looked for.
    @AppStorage("time.groupsSimilarEntries") private var groupsSimilarEntries = true

    /// Remembered across launches, because which mode you are in is a fact about how you work —
    /// somebody who logs yesterday's hours every morning should not switch modes every morning.
    @AppStorage("time.entryMode") private var storedMode = TimeEntryMode.timer.rawValue

    @State private var entries: [TimeEntrySnapshot] = []
    @State private var expandedGroups: Set<String> = []
    @State private var editingRowID: String?
    @State private var reloadTick = 0

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        VStack(spacing: 0) {
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

            TimeEntryBar(
                mode: modeBinding,
                onChange: { bump() },
                onOpenSubject: { id in navigation.selectItem(id) }
            )

            Divider()

            summary

            Divider()

            log
        }
        .navigationTitle(navigation.windowTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task(id: reloadToken) { reload() }
        .accessibilityIdentifier(AccessibilityID.Time.root)
    }

    // MARK: - Summary

    private var summary: some View {
        TimeSummaryView(
            report: report,
            grouping: grouping,
            onOpen: { id in navigation.selectItem(id) }
        )
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var report: TimeReport {
        guard let services else { return .empty(range: window.range(using: SystemDateProvider())) }
        return TimeReporting.report(
            entries: entries,
            grouping: grouping,
            range: window.range(using: services.dateProvider),
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now
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

    @ViewBuilder
    private var log: some View {
        if entries.isEmpty {
            EmptyStateView(
                symbolName: "timer",
                headline: "No time tracked \(window.displayName.lowercased())",
                message: "Say what you are doing in the bar above and press play, "
                    + "or switch it to Manual to record time you have already spent.",
                actionTitle: "Add Time…",
                action: { mode = .manual }
            )
        } else {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.groups) { group in
                            groupRow(group)

                            if expandedGroups.contains(group.id), !group.isSingle {
                                ForEach(group.entries) { entry in
                                    entryRow(entry)
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
        }
    }

    private func groupRow(_ group: TimeEntryGroup) -> some View {
        TimeEntryGroupRow(
            group: group,
            isExpanded: expandedGroups.contains(group.id),
            isEditing: editingRowID == group.id,
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
            onDelete: { delete(group.entries.map(\.id)) }
        )
    }

    private func entryRow(_ entry: TimeEntrySnapshot) -> some View {
        TimeEntryRow(
            entry: entry,
            isEditing: editingRowID == entry.id.uuidString,
            onEdit: { editingRowID = entry.id.uuidString },
            onCommit: { edit in
                apply(edit, to: [entry.id])
                editingRowID = nil
            },
            onCancelEdit: { editingRowID = nil },
            onDuplicate: { duplicate(entry) },
            onDelete: { delete([entry.id]) }
        )
    }

    private func toggleExpanded(_ group: TimeEntryGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Period", selection: windowBinding) {
                ForEach(TimeWindow.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(AccessibilityID.Time.windowPicker)
        }

        ToolbarItem {
            Picker("Group By", selection: groupingBinding) {
                ForEach(TimeGrouping.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(AccessibilityID.Time.groupingPicker)
        }

        ToolbarItem {
            Toggle(isOn: $groupsSimilarEntries) {
                Label("Group Similar", systemImage: "rectangle.stack")
            }
            .help("Collapse entries that share a description, subject and tags")
            .accessibilityIdentifier(AccessibilityID.Time.groupingToggle)
        }

        ToolbarItem {
            Button("Add Time", systemImage: "plus") { mode = .manual }
                .help("Record time you have already spent")
                .accessibilityIdentifier(AccessibilityID.Time.addEntryButton)
        }
    }

    private var modeBinding: Binding<TimeEntryMode> {
        Binding(
            get: { TimeEntryMode(rawValue: storedMode) ?? .timer },
            set: { storedMode = $0.rawValue }
        )
    }

    private var mode: TimeEntryMode {
        get { modeBinding.wrappedValue }
        nonmutating set { modeBinding.wrappedValue = newValue }
    }

    private var windowBinding: Binding<TimeWindow> {
        Binding(get: { navigation.timeWindow }, set: { navigation.timeWindow = $0 })
    }

    private var groupingBinding: Binding<TimeGrouping> {
        Binding(get: { navigation.timeGrouping }, set: { navigation.timeGrouping = $0 })
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
        services.perform { try services.timeEntries.duplicate(entry) }
        bump()
    }

    private func delete(_ ids: [UUID]) {
        guard let services else { return }
        services.perform {
            for id in ids {
                guard let entry = try services.timeEntries.entry(id: id) else { continue }
                try services.timeEntries.delete(entry)
            }
        }
        services.timer.refresh()
        bump()
    }

    /// Applies one edit to every entry it was made against.
    ///
    /// The span is applied only when there is one entry, which is what makes editing a collapsed
    /// row safe: the shared fields land on all eight stretches and their eight different pairs of
    /// clock times are left alone. See ``TimeEntryEdit``.
    private func apply(_ edit: TimeEntryEdit, to ids: [UUID]) {
        guard let services else { return }

        let subject = edit.composition.subject.flatMap { reference in
            (try? services.items.item(id: reference.id)) ?? nil
        }

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
            }
        }

        services.timer.refresh()
        bump()
    }
}

// MARK: - Summary

/// Totals, and where the time went.
struct TimeSummaryView: View {
    let report: TimeReport
    let grouping: TimeGrouping
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                Text(TimeFormatting.short(report.total))
                    .font(.system(.largeTitle, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                if report.billable > 0 {
                    Text("\(TimeFormatting.short(report.billable)) billable")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()
            }

            if report.isEmpty {
                Text("Nothing tracked in this period.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                ForEach(report.rows.prefix(6)) { row in
                    TimeSummaryBar(row: row, peak: report.peak, onOpen: onOpen)
                }

                if report.rows.count > 6 {
                    Text("and \(report.rows.count - 6) more")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TimeFormatting.spelled(report.total)) tracked, grouped by \(grouping.displayName)")
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
            .frame(width: 160, alignment: .leading)

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Colors.selection.opacity(0.35))
                    .frame(width: max(2, proxy.size.width * fraction))
            }
            .frame(height: 10)

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
