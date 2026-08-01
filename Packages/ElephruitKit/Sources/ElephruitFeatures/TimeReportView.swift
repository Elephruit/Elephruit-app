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
            // The same measure the log uses, applied to the controls and the content alike — see
            // `TimeView.measure`. A report is the surface this module's width problem showed up on
            // worst: a project name at the far left of a nineteen-hundred-point window and its total
            // at the far right, with a bar stretched between them, and the only way to find out how
            // long you spent on something was to track along a line with your finger. The chart had
            // the same trouble in the other direction — two hairline bars in an acre of grid.
            //
            // One frame for both Time surfaces rather than one each, so switching between the log
            // and the report does not move every column.
            VStack(spacing: 0) {
                controls
            }
            .frame(maxWidth: TimeView.measure)
            .frame(maxWidth: .infinity)

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
                    .frame(maxWidth: TimeView.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
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

    /// The four figures a period comes down to.
    ///
    /// Spread across the measure rather than huddled at its leading edge behind a `Spacer`. Four
    /// tiles bunched into the first third of the row and a third of a window of nothing after them
    /// is not restraint, it is the row having been laid out for a narrower screen; and evenly spaced
    /// they read as four columns of one table, which is what they are.
    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
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

            Chart(dailyBars) { bar in
                BarMark(
                    // `unit: .day` is what makes this a bar per day rather than a hairline at an
                    // instant. Without it a `BarMark` on a continuous date axis has no width of its
                    // own and gets a default one, which in a week-wide plot is a thread — two
                    // three-pixel lines in an acre of grid, which is what the chart was.
                    x: .value("Day", bar.day, unit: .day),
                    y: .value("Hours", bar.hours)
                )
                .foregroundStyle(Theme.Colors.selection)
                .cornerRadius(Theme.Radius.small)
            }
            .chartYAxisLabel("hours")
            .chartYAxis {
                // Leading, so the last bar of the period is not drawn underneath its own axis
                // labels. On the trailing edge a still-running day sat behind the numbers.
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                // ### Why this is a stride and not `.automatic(desiredCount: 8)`
                // Because eight was a count of *marks*, not of days. Asked for eight ticks across a
                // two-day domain, the axis put one every six hours and formatted each as a date —
                // so a week's report read "Jul 30, Jul 30, Jul 30, Jul 30, Jul 31, Jul 31, Jul 31,
                // Jul 31". Eight labels, two distinct values, and no way to tell which bar was
                // which day.
                //
                // A calendar stride cannot do that: every mark is a day, a week or a month, and the
                // spacing follows the period rather than a fixed number.
                AxisMarks(values: .stride(by: axis.unit, count: axis.count)) { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel { Text(axis.label(for: date)) }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityIdentifier(AccessibilityID.Time.reportChart)
            .accessibilityLabel("Daily totals across \(period.displayName)")
            .accessibilityValue(chartDescription)
        }
    }

    /// One bar per calendar day in the period, including the days with nothing on them.
    ///
    /// ### Why the empty days are drawn
    /// Because a chart of a week is a statement about the *week*, and one that plots only the days
    /// that happen to have entries is a chart of the entries. Two bars side by side said "you worked
    /// two days" whether those were Monday and Tuesday or Monday and Friday; the shape of the period
    /// — which is the whole reason to look at a chart rather than the total above it — was missing.
    ///
    /// Filled here rather than in ``ElephruitCore/TimeReporting``, which the export and the log's
    /// summary also read. A row of zero belongs in a picture of a week and does not belong in a
    /// spreadsheet of what was tracked.
    private var dailyBars: [DailyBar] {
        guard let services else { return [] }

        let calendar = services.dateProvider.calendar

        // Keyed by the start of the day rather than by the report's own string key, so the lookup
        // below compares the same kind of thing the loop is producing. Resolving each row's key back
        // to a date once is cheaper than formatting a key per day, and it cannot disagree about what
        // "the 3rd" means in a calendar that is not Gregorian.
        var totals: [Date: TimeInterval] = [:]
        for row in TimeReporting.report(
            entries: entries,
            grouping: .day,
            range: range,
            calendar: calendar,
            now: services.dateProvider.now,
            rounding: rounding
        ).rows {
            guard let date = DayKey.date(from: row.key, in: calendar) else { continue }
            totals[calendar.startOfDay(for: date)] = row.total
        }

        var bars: [DailyBar] = []
        var day = calendar.startOfDay(for: range.lowerBound)

        // Bounded, so a custom period of ten years cannot ask for four thousand bars. Past this the
        // chart is a smear anyway and the breakdown below is the surface that answers.
        while day < range.upperBound, bars.count < 400 {
            bars.append(DailyBar(day: day, hours: (totals[day] ?? 0) / 3_600))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return bars
    }

    /// How many days the period covers, which is what decides how the axis is laboured.
    private var dayCount: Int { dailyBars.count }

    /// The x-axis's stride and its labels, chosen by how long the period is.
    ///
    /// A week wants weekday names — "Mon", "Tue" — because that is how anybody talks about a week,
    /// and the dates are noise. A month wants dates, weekly. A year wants months. One rule producing
    /// all three, so no period can end up labelled in a unit it does not use.
    private var axis: DailyAxis {
        switch dayCount {
        case ..<10: DailyAxis(unit: .day, count: 1, style: .weekday)
        case ..<32: DailyAxis(unit: .day, count: 7, style: .date)
        case ..<190: DailyAxis(unit: .weekOfYear, count: 2, style: .date)
        default: DailyAxis(unit: .month, count: 1, style: .month)
        }
    }

    /// What the chart says to somebody who cannot see it.
    ///
    /// The busiest day and the count of days with anything on them: a screen reader cannot scan a
    /// row of bars, and reading out thirty durations is not a summary of them.
    private var chartDescription: String {
        let worked = dailyBars.filter { $0.hours > 0 }
        guard let busiest = worked.max(by: { $0.hours < $1.hours }) else {
            return "Nothing tracked in this period"
        }
        let days = worked.count == 1 ? "1 day" : "\(worked.count) days"
        return "\(days) with time on them. Busiest: "
            + "\(busiest.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))), "
            + TimeFormatting.spelled(busiest.hours * 3_600)
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
                // ### Why the columns are labelled now
                // Because a row ended "3 entries · 5.96 · 5:58" and only the first of those said
                // what it was. The other two are the same quantity in two notations, adjacent,
                // unheaded — and the natural reading of two numbers side by side is that they are
                // two different measurements, so the column invited the question "5.96 of what, and
                // why does it disagree with 5:58".
                //
                // Both are worth keeping: a person reads `5:58` and a spreadsheet wants `5.96`, and
                // doing that conversion by hand is where a timesheet acquires its first wrong
                // number. What was missing was two words saying so.
                TimeReportHeaderRow()

                Divider()

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

/// One day of the period, whether or not anything was tracked on it.
struct DailyBar: Identifiable, Hashable {
    var day: Date
    var hours: Double

    var id: Date { day }
}

/// How the daily chart's x-axis is stepped and labelled for a period of a given length.
///
/// A value rather than three branches inside the chart builder, so "what does a quarter's axis look
/// like" is a question with one answer in one place.
struct DailyAxis {
    enum Style {
        /// "Mon", "Tue" — how anybody talks about a week.
        case weekday
        /// "3 Aug" — how anybody talks about a month.
        case date
        /// "Aug" — how anybody talks about a year.
        case month
    }

    var unit: Calendar.Component
    var count: Int
    var style: Style

    func label(for date: Date) -> String {
        switch style {
        case .weekday: date.formatted(.dateTime.weekday(.abbreviated))
        case .date: date.formatted(.dateTime.day().month(.abbreviated))
        case .month: date.formatted(.dateTime.month(.abbreviated))
        }
    }
}

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
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The widths the breakdown's columns share.
///
/// One place, so the heading and the rows cannot drift apart — a header row measured independently
/// of the rows under it is a header that lines up until somebody changes a number.
private enum ReportColumn {
    static let title: CGFloat = 160
    static let entries: CGFloat = 76
    static let decimal: CGFloat = 52
    static let duration: CGFloat = 56
}

/// What each column of the breakdown holds.
struct TimeReportHeaderRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Color.clear
                .frame(width: ReportColumn.title, height: 1)

            Spacer(minLength: 0)

            Text("ENTRIES")
                .frame(width: ReportColumn.entries, alignment: .trailing)

            Text("HOURS")
                .frame(width: ReportColumn.decimal, alignment: .trailing)

            Text("TIME")
                .frame(width: ReportColumn.duration, alignment: .trailing)
        }
        .font(Theme.Text.sectionHeader)
        .kerning(Theme.Text.Tracking.caps)
        .foregroundStyle(Theme.Colors.tertiaryText)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityHidden(true)
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
            .truncationMode(.tail)
            // Fixed rather than a minimum, so every bar in the breakdown starts at the same x. A
            // column that grows to the longest title staggers the bars by however long somebody's
            // project happens to be called, and a bar chart whose bars start in different places
            // cannot be compared by eye — which is the only thing bars are for.
            .frame(width: ReportColumn.title, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.subtleFill)
                    Capsule()
                        .fill(Theme.Colors.selection.opacity(0.5))
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)

            Text("\(row.entryCount)")
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: ReportColumn.entries, alignment: .trailing)

            // Both forms, because the two readers of a report want different ones: a person reads
            // `3:24` and a spreadsheet wants `3.40`, and doing that conversion by hand is where a
            // timesheet acquires its first wrong number. The heading above says which is which —
            // unlabelled and adjacent, they read as two measurements that disagree.
            Text(TimeFormatting.decimalHours(row.total))
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: ReportColumn.decimal, alignment: .trailing)

            Text(TimeFormatting.short(row.total))
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .frame(width: ReportColumn.duration, alignment: .trailing)
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
