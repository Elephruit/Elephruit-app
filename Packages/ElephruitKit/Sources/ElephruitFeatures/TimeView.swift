import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Time destination: what is running, what was tracked, and where it went.
///
/// One screen rather than three. Toggl's lesson is that tracking, reviewing and correcting are the
/// same activity — you look at yesterday *because* you are about to fix it — and splitting them
/// across tabs means every correction starts with navigation.
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
    @State private var entries: [TimeEntrySnapshot] = []
    @State private var recents: [TimeEntrySnapshot] = []
    @State private var isAddingManualEntry = false
    @State private var editingEntryID: UUID?
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

            if let count = services?.timer.reconciledTimerCount, count > 0 {
                ReconciliationNote(count: count) { services?.timer.acknowledgeReconciliation() }
            }

            TimerBar(
                onStart: { startBlankTimer() },
                onStop: { stopTimer() },
                onOpenSubject: { id in navigation.selectItem(id) }
            )

            Divider()

            summary

            Divider()

            entryList
        }
        .navigationTitle(navigation.windowTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task(id: reloadToken) { reload() }
        .sheet(isPresented: $isAddingManualEntry) {
            ManualTimeEntrySheet(
                onSave: { draft in
                    addManual(draft)
                    isAddingManualEntry = false
                },
                onCancel: { isAddingManualEntry = false }
            )
        }
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

    // MARK: - Entries

    @ViewBuilder
    private var entryList: some View {
        if entries.isEmpty {
            EmptyStateView(
                symbolName: "timer",
                headline: "No time tracked \(window.displayName.lowercased())",
                message: recents.isEmpty
                    ? "Press ⌃⌘T to start a timer, or add time you have already spent."
                    : "Start one of your recent entries below, or add time by hand.",
                actionTitle: "Add Time…",
                action: { isAddingManualEntry = true }
            )
        } else {
            List {
                Section {
                    ForEach(entries) { entry in
                        TimeEntryRow(
                            entry: entry,
                            isEditing: editingEntryID == entry.id,
                            onResume: { resume(entry) },
                            onOpen: { entry.itemID.map { navigation.selectItem($0) } },
                            onEdit: { editingEntryID = entry.id },
                            onCommit: { change in
                                apply(change, to: entry)
                                editingEntryID = nil
                            },
                            onCancelEdit: { editingEntryID = nil },
                            onDelete: { delete(entry) }
                        )
                    }
                } header: {
                    SectionHeader(window.displayName, count: entries.count)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
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
            Button("Add Time", systemImage: "plus") { isAddingManualEntry = true }
                .accessibilityIdentifier(AccessibilityID.Time.addEntryButton)
        }
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
        let now = services.dateProvider.now

        services.perform {
            entries = try services.timeEntries.snapshots(in: range, limit: nil)
            recents = try services.timeEntries.recentEntries(limit: 8).map { $0.snapshot(at: now) }
        }
    }

    private func bump() {
        reloadTick += 1
    }

    // MARK: - Commands

    private func startBlankTimer() {
        services?.timer.switchTo(item: nil)
        bump()
    }

    private func stopTimer() {
        services?.timer.stop()
        bump()
    }

    private func resume(_ snapshot: TimeEntrySnapshot) {
        guard let services, let entry = try? services.timeEntries.entry(id: snapshot.id) else { return }
        services.timer.resume(entry)
        bump()
    }

    private func delete(_ snapshot: TimeEntrySnapshot) {
        guard let services, let entry = try? services.timeEntries.entry(id: snapshot.id) else { return }
        services.perform { try services.timeEntries.delete(entry) }
        services.timer.refresh()
        bump()
    }

    private func apply(_ change: TimeEntryEdit, to snapshot: TimeEntrySnapshot) {
        guard let services, let entry = try? services.timeEntries.entry(id: snapshot.id) else { return }
        services.perform {
            try services.timeEntries.update(entry) { subject in
                subject.entryDescription = change.description
                subject.startedAt = change.startedAt
                if let endedAt = change.endedAt { subject.endedAt = endedAt }
                subject.isBillable = change.isBillable
            }
        }
        services.timer.refresh()
        bump()
    }

    private func addManual(_ draft: ManualTimeEntryDraft) {
        guard let services else { return }
        services.perform {
            try services.timeEntries.addManual(
                item: draft.itemID.flatMap { try? services.items.item(id: $0) },
                description: draft.description,
                startedAt: draft.startedAt,
                endedAt: draft.endedAt,
                tagSlugs: draft.tagSlugs
            )
        }
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
