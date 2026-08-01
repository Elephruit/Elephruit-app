import AppKit
import Charts
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Where the time went, over any stretch of it.
///
/// ### Why this is a second surface rather than a bigger summary
/// The log answers *what did I do* and is a place you correct things from; a report answers *where
/// did it go* and is a thing you take somewhere else. They want opposite layouts — the log is newest
/// first and editable in place, a report is oldest first and totals at the bottom — and the summary
/// strip above the log was already straining to be both, which is how it ended up as a single
/// full-width bar over a list.
///
/// Everything here reads from the same ``TimeReporting`` the summary does. There is no second set of
/// rules about what counts, and there cannot be: two answers to "how much did I work last week" is
/// the failure this whole module exists to avoid.
struct TimeReportView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    @AppStorage("time.rounding") private var storedRounding = TimeRounding.exact.rawValue
    @AppStorage("time.report.grouping") private var storedGrouping = TimeGrouping.project.rawValue

    @State private var period: TimePeriod = .window(.thisWeek)
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @State private var entries: [TimeEntrySnapshot] = []
    @State private var reloadTick = 0
    @State private var exportProblem: String?

    init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    var body: some View {
        VStack(spacing: 0) {
            controls

            Divider()

            if report.isEmpty {
                EmptyStateView(
                    symbolName: "chart.bar.xaxis",
                    headline: "Nothing tracked in this period",
                    message: "Change the period above, or track some time and come back. "
                        + "Reports read exactly the entries the log shows — there is no second set of rules."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        totals
                        chart
                        breakdown
                    }
                    .padding(Theme.Spacing.large)
                }
            }
        }
        .navigationTitle("Time Reports")
        .navigationSubtitle(period.displayName)
        .toolbar { toolbarContent }
        .task(id: reloadToken) { reload() }
        .alert("The report could not be written", isPresented: exportProblemBinding) {
            Button("OK") { exportProblem = nil }
        } message: {
            Text(exportProblem ?? "")
        }
        .accessibilityIdentifier(AccessibilityID.Time.reportRoot)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Picker("Period", selection: periodBinding) {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    Text(window.displayName).tag(TimePeriod.window(window))
                }
                Divider()
                Text("Custom…").tag(TimePeriod.custom(from: customFrom, through: customThrough))
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.Time.reportPeriodPicker)

            if period.isCustom {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .onChange(of: customFrom) { _, _ in syncCustomPeriod() }

                Text("to")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                DatePicker("To", selection: $customThrough, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .onChange(of: customThrough) { _, _ in syncCustomPeriod() }
            }

            Spacer()

            Picker("Grouped by", selection: groupingBinding) {
                ForEach(TimeGrouping.allCases, id: \.self) { grouping in
                    Label(grouping.displayName, systemImage: grouping.symbolName).tag(grouping)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button("Log", systemImage: "list.bullet.rectangle") {
                navigation.timeSurface = .log
            }
            .help("Back to what you did, day by day")
        }

        ToolbarItem {
            Menu {
                ForEach(TimeRounding.allCases, id: \.self) { rule in
                    Button {
                        storedRounding = rule.rawValue
                    } label: {
                        if rule.rawValue == storedRounding {
                            Label(rule.displayName, systemImage: "checkmark")
                        } else {
                            Text(rule.displayName)
                        }
                    }
                }
            } label: {
                Label("Rounding", systemImage: "ruler")
            }
            .help("How totals are rounded. Nothing here changes a recorded entry.")
            .accessibilityIdentifier(AccessibilityID.Time.reportRoundingPicker)
        }

        ToolbarItem {
            Menu {
                Button("Export Summary…", systemImage: "tablecells") { export(.summary) }
                Button("Export Every Entry…", systemImage: "list.bullet.rectangle") { export(.entries) }
                Divider()
                Button("Copy Summary", systemImage: "doc.on.doc") { copy(.summary) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Write this report as a spreadsheet")
            .accessibilityIdentifier(AccessibilityID.Time.reportExportButton)
        }
    }

    // MARK: - Totals

    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.section) {
            TimeTotalTile(
                title: "Tracked",
                value: TimeFormatting.short(report.total),
                detail: "\(TimeFormatting.decimalHours(report.total)) h"
            )

            TimeTotalTile(
                title: "Billable",
                value: TimeFormatting.short(report.billable),
                detail: report.total > 0
                    ? "\(Int((report.billable / report.total * 100).rounded()))% of tracked"
                    : nil
            )

            TimeTotalTile(
                title: "Entries",
                value: "\(report.entryCount)",
                detail: focusDetail
            )

            TimeTotalTile(
                title: "Busiest day",
                value: busiestDay?.value ?? "—",
                detail: busiestDay?.detail
            )

            Spacer()
        }
    }

    private var focusDetail: String? {
        let rounds = entries.reduce(0) { $0 + $1.focusRounds }
        guard rounds > 0 else { return nil }
        return rounds == 1 ? "1 focus block" : "\(rounds) focus blocks"
    }

    /// The heaviest day in the period, which is the one fact a total hides.
    private var busiestDay: (value: String, detail: String)? {
        guard let services else { return nil }
        let daily = TimeReporting.report(
            entries: entries,
            grouping: .day,
            range: range,
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now,
            rounding: rounding
        )
        guard let peak = daily.rows.max(by: { $0.total < $1.total }), peak.total > 0 else { return nil }
        return (TimeFormatting.short(peak.total), DayKey.date(from: peak.key)
            .map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? peak.key)
    }

    // MARK: - Chart

    /// A bar per day, always in date order.
    ///
    /// ### Why the day chart is not the grouping chart
    /// Because they answer different halves of the same question. The bars say *when* the work
    /// happened — which is how you spot the Thursday that took eleven hours — and the breakdown below
    /// says *what* it was. A single chart that switched between them would mean losing the shape of
    /// the period every time you asked what a row contained.
    private var chart: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("By day")

            Chart(dailyRows) { row in
                BarMark(
                    x: .value("Day", DayKey.date(from: row.key) ?? Date()),
                    y: .value("Hours", row.total / 3_600)
                )
                .foregroundStyle(Theme.Colors.selection)
                .cornerRadius(Theme.Radius.small)
            }
            .chartYAxisLabel("hours")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 180)
            .accessibilityIdentifier(AccessibilityID.Time.reportChart)
            .accessibilityLabel("Daily totals across \(period.displayName)")
        }
    }

    private var dailyRows: [TimeSummaryRow] {
        guard let services else { return [] }
        return TimeReporting.report(
            entries: entries,
            grouping: .day,
            range: range,
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now,
            rounding: rounding
        ).rows
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("By \(grouping.displayName.lowercased())", count: report.rows.count)

            if grouping.rowsCanOverlap, report.rows.count > 1 {
                Text("One entry can appear in more than one row, so this column adds up to more than \(TimeFormatting.short(report.total)).")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(report.rows) { row in
                    TimeReportRow(
                        row: row,
                        peak: report.peak,
                        onOpen: { id in navigation.selectItem(id) }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Colors.subtleFill.opacity(0.5))
            )
        }
    }

    // MARK: - Values

    private var grouping: TimeGrouping {
        TimeGrouping(rawValue: storedGrouping) ?? .project
    }

    private var rounding: TimeRounding {
        TimeRounding(rawValue: storedRounding) ?? .exact
    }

    private var range: Range<Date> {
        period.range(using: services?.dateProvider ?? SystemDateProvider())
    }

    private var report: TimeReport {
        guard let services else { return .empty(range: range) }
        return TimeReporting.report(
            entries: entries,
            grouping: grouping,
            range: range,
            calendar: services.dateProvider.calendar,
            now: services.dateProvider.now,
            rounding: rounding
        )
    }

    private var periodBinding: Binding<TimePeriod> {
        Binding(
            get: { period },
            set: { newValue in
                period = newValue
                if case .custom = newValue { syncCustomPeriod() }
            }
        )
    }

    private var groupingBinding: Binding<TimeGrouping> {
        Binding(get: { grouping }, set: { storedGrouping = $0.rawValue })
    }

    private var exportProblemBinding: Binding<Bool> {
        Binding(get: { exportProblem != nil }, set: { if !$0 { exportProblem = nil } })
    }

    private func syncCustomPeriod() {
        period = .custom(from: customFrom, through: customThrough)
        reloadTick += 1
    }

    // MARK: - Data

    private var reloadToken: String {
        "\(period.displayName)|\(reloadTick)|\(services?.timer.running?.id.uuidString ?? "-")"
    }

    private func reload() {
        guard let services else { return }
        let window = range
        services.perform {
            entries = try services.timeEntries.snapshots(in: window, limit: nil)
        }
    }

    // MARK: - Export

    private enum ExportShape {
        case summary
        case entries
    }

    private func text(for shape: ExportShape) -> String {
        switch shape {
        case .summary:
            TimeExport.summary(for: report, grouping: grouping)
        case .entries:
            TimeExport.rows(
                for: entries,
                rounding: rounding,
                now: services?.dateProvider.now ?? Date()
            )
        }
    }

    private func copy(_ shape: ExportShape) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: shape), forType: .string)
    }

    /// Writes the report where the user chooses.
    ///
    /// An `NSSavePanel` for the reason the library export uses one: it is the panel that grants the
    /// sandbox permission to write where the user picked, and this app holds no other way to reach a
    /// folder. One of the sanctioned AppKit bridges in `docs/02-architecture.md`.
    private func export(_ shape: ExportShape) {
        let panel = NSSavePanel()
        panel.title = "Export Time Report"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = TimeExport.filename(
            for: period.displayName,
            kind: shape == .summary ? "summary" : "entries"
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try text(for: shape).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Surfaced rather than logged. The user chose a destination and pressed a button; an
            // export that silently does nothing is one they will assume worked.
            exportProblem = error.localizedDescription
        }
    }
}

// MARK: - Pieces

/// One headline number, with the fact that qualifies it underneath.
struct TimeTotalTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)
                .kerning(0.4)

            Text(value)
                .font(.system(.title, design: .rounded, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(detail ?? " ")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One row of a report's breakdown.
struct TimeReportRow: View {
    let row: TimeSummaryRow
    let peak: TimeInterval
    let onOpen: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
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
            .frame(minWidth: 140, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.subtleFill)
                    Capsule()
                        .fill(Theme.Colors.selection.opacity(0.5))
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)

            Text(row.entryCount == 1 ? "1 entry" : "\(row.entryCount) entries")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 76, alignment: .trailing)

            // Both forms, because the two readers of a report want different ones: a person reads
            // `3:24` and a spreadsheet wants `3.40`, and doing that conversion by hand is where a
            // timesheet acquires its first wrong number.
            Text(TimeFormatting.decimalHours(row.total))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 52, alignment: .trailing)

            Text(TimeFormatting.short(row.total))
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(TimeFormatting.spelled(row.total)), \(row.entryCount) entries")
        .accessibilityIdentifier(AccessibilityID.Time.reportRow(key: row.key))
    }

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        return min(1, row.total / peak)
    }
}
