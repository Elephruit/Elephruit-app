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

    /// The day the pointer is over, and so the day the tooltip is about.
    @State private var hoveredDay: Date?

    /// What colour each breakdown row is drawn in. Resolved off the render path — see
    /// ``resolveSeriesColors()``.
    @State private var seriesColors: [String: Color] = [:]

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
        // Keyed on the grouping as well as the entries, because which rows exist — and therefore
        // which ranks they hold and what colour each takes — changes the moment somebody switches
        // from Project to Person.
        .task(id: "\(reloadToken)|\(grouping.rawValue)") { resolveSeriesColors() }
        .alert("The report could not be written", isPresented: exportProblemBinding) {
            Button("OK") { exportProblem = nil }
        } message: {
            Text(exportProblem ?? "")
        }
        .accessibilityIdentifier(AccessibilityID.Time.reportRoot)
    }

    // MARK: - Controls

    /// The period and grouping rail, shared with the Log — see ``TimeFilterBar``.
    ///
    /// Reports offers every window and a custom range; the Log offers the short ones and none. That
    /// difference is a parameter rather than a second component.
    private var controls: some View {
        TimeFilterBar(
            windows: TimeWindow.allCases,
            selectedWindow: period.window,
            onSelectWindow: { period = .window($0) },
            custom: TimeFilterBar.CustomRange(
                isActive: period.isCustom,
                from: Binding(get: { customFrom }, set: { customFrom = $0; syncCustomPeriod() }),
                through: Binding(get: { customThrough }, set: { customThrough = $0; syncCustomPeriod() }),
                onActivate: syncCustomPeriod
            ),
            groupings: TimeGrouping.allCases,
            grouping: grouping,
            onSelectGrouping: { storedGrouping = $0.rawValue }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        TimeSurfaceSwitcher(navigation: navigation)

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
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("By day")

                Spacer()

                if isStacked {
                    Text("Coloured by \(grouping.displayName.lowercased())")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Chart {
                bars
                hoverMark
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
            // ### Why the whole plot is the target and not each bar
            // Because a day with nothing on it has no bar to hover, and "what did I do on Wednesday"
            // is a question whose answer is sometimes *nothing*. Hit-testing the plot and resolving
            // the pointer's x to a calendar day means every day in the period answers, including the
            // empty ones — and it means the pointer does not have to find a three-point-tall bar on
            // a quiet Tuesday.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(.rect)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredDay = day(at: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredDay = nil
                            }
                        }
                }
            }
            .calmAnimation(Theme.Motion.appearance, value: hoveredDay)
            .accessibilityIdentifier(AccessibilityID.Time.reportChart)
            .accessibilityLabel("Daily totals across \(period.displayName)")
            .accessibilityValue(chartDescription)
        }
    }

    /// The bars themselves.
    ///
    /// Its own `@ChartContentBuilder` rather than inline, and not for tidiness: with the marks, the
    /// rule mark, the annotation and six chart modifiers in one expression, the type checker gave up
    /// — "unable to type-check this expression in reasonable time". Charts builders nest generic
    /// types deeply enough that splitting them is a practical requirement rather than a style
    /// preference.
    @ChartContentBuilder
    private var bars: some ChartContent {
        ForEach(dailyBars) { bar in
            ForEach(bar.segments) { segment in
                BarMark(
                    // `unit: .day` is what makes this a bar per day rather than a hairline at an
                    // instant. Without it a `BarMark` on a continuous date axis has no width of its
                    // own and gets a default one, which in a week-wide plot is a thread.
                    x: .value("Day", bar.day, unit: .day),
                    y: .value("Hours", segment.hours)
                )
                .foregroundStyle(segment.color)
                // Dimmed rather than hidden while another day is hovered: the shape of the week has
                // to stay readable, and a chart that empties as the pointer crosses it is answering
                // a question nobody asked.
                .opacity(hoveredDay == nil || hoveredDay == bar.day ? 1 : 0.35)
                .cornerRadius(Theme.Radius.small)
                .accessibilityLabel(bar.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(bar.accessibilityValue)
            }
        }
    }

    /// The line and the tooltip under the pointer, when there is one.
    @ChartContentBuilder
    private var hoverMark: some ChartContent {
        if let hoveredDay, let bar = dailyBars.first(where: { $0.day == hoveredDay }) {
            RuleMark(x: .value("Day", hoveredDay, unit: .day))
                .foregroundStyle(Theme.Colors.separator)
                .annotation(
                    position: .top,
                    alignment: .center,
                    spacing: Theme.Spacing.small,
                    // Kept inside the plot, so hovering the first or last day of a period does not
                    // put the tooltip half off the side of the window.
                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                    DayTooltip(bar: bar)
                }
        }
    }

    /// The calendar day under the pointer, or `nil` when it is outside the plot.
    private func day(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let services, let plotFrame = proxy.plotFrame else { return nil }

        let plot = geometry[plotFrame]
        guard plot.contains(location) else { return nil }

        guard let date: Date = proxy.value(atX: location.x - plot.origin.x) else { return nil }
        let day = services.dateProvider.calendar.startOfDay(for: date)

        // Only a day the period actually holds. Charts will happily resolve an x just past the last
        // bar into the day after the period ends, and a tooltip for a day that is not on screen is
        // a tooltip about nothing.
        return dailyBars.contains { $0.day == day } ? day : nil
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
    /// Whether the bars are cut into coloured segments, or drawn as one block each.
    ///
    /// ### The two cases where they are not
    /// Grouping *by day* would colour a day's bar by the day it is, which is a colour that says the
    /// x-axis again. And under `.tag` or `.person` an hour counts in full under each — see
    /// ``ElephruitCore/TimeReporting/dailyBreakdown(entries:grouping:range:calendar:now:)`` — so
    /// stacking the cells would build a Tuesday taller than Tuesday. The table below says so in
    /// words; the chart cannot, so it declines to stack rather than draw a bar that is wrong.
    private var isStacked: Bool {
        grouping != .day && !grouping.rowsCanOverlap
    }

    private var dailyBars: [DailyBar] {
        guard let services else { return [] }

        let calendar = services.dateProvider.calendar

        // Keyed by the start of the day rather than by the report's own string key, so the lookup
        // below compares the same kind of thing the loop is producing. Resolving each row's key back
        // to a date once is cheaper than formatting a key per day, and it cannot disagree about what
        // "the 3rd" means in a calendar that is not Gregorian.
        //
        // The whole row rather than its total: the day's entry count and its billable share are
        // already computed here by the same rules the table uses, and the tooltip wants both. Taking
        // only the total meant the tooltip had to either go without them or count them again.
        let daily = TimeReporting.report(
            entries: entries,
            grouping: .day,
            range: range,
            calendar: calendar,
            now: services.dateProvider.now,
            rounding: rounding
        )

        var dayRows: [Date: TimeSummaryRow] = [:]
        for row in daily.rows {
            guard let date = DayKey.date(from: row.key, in: calendar) else { continue }
            dayRows[calendar.startOfDay(for: date)] = row
        }

        // The cells, gathered per day and largest first, so the tallest segment of every bar sits at
        // the bottom and the eye can compare across days without re-reading the legend.
        var cellsByDay: [String: [TimeDayCell]] = [:]
        if isStacked {
            for cell in TimeReporting.dailyBreakdown(
                entries: entries,
                grouping: grouping,
                range: range,
                calendar: calendar,
                now: services.dateProvider.now
            ) {
                cellsByDay[cell.dayKey, default: []].append(cell)
            }
        }

        var bars: [DailyBar] = []
        var day = calendar.startOfDay(for: range.lowerBound)

        // Bounded, so a custom period of ten years cannot ask for four thousand bars. Past this the
        // chart is a smear anyway and the breakdown below is the surface that answers.
        while day < range.upperBound, bars.count < 400 {
            let row = dayRows[day]
            let total = row?.total ?? 0
            bars.append(
                DailyBar(
                    day: day,
                    hours: total / 3_600,
                    entryCount: row?.entryCount ?? 0,
                    billableHours: (row?.billable ?? 0) / 3_600,
                    // What proportion of the period landed here. The one fact a bar cannot carry:
                    // the y-axis says how many hours, and nothing on screen says whether that was a
                    // fifth of the week or most of it.
                    shareOfPeriod: daily.total > 0 ? total / daily.total : 0,
                    segments: segments(forDayStarting: day, total: total, cells: cellsByDay, calendar: calendar)
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return bars
    }

    /// One day's bar, cut into the coloured pieces it is made of.
    ///
    /// ### Why the pieces are scaled to the day's rounded total
    /// Because the bar's height has to be the same number the tile above it and the table below it
    /// report, and those are rounded — see the note on `TimeReporting.report`. The cells are exact,
    /// deliberately: rounding a cell would round the same minute once for every day it touched. So
    /// the shares come from the exact cells and the height comes from the rounded total, and under
    /// the default *exact* rounding the two are simply equal.
    private func segments(
        forDayStarting day: Date,
        total: TimeInterval,
        cells: [String: [TimeDayCell]],
        calendar: Calendar
    ) -> [DailySegment] {
        guard total > 0 else { return [] }

        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let key = DayKey.string(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )

        let dayCells = (cells[key] ?? []).sorted { $0.total > $1.total }
        let exact = dayCells.reduce(0) { $0 + $1.total }

        guard isStacked, !dayCells.isEmpty, exact > 0 else {
            return [
                DailySegment(
                    rowKey: "\u{1}total",
                    title: "Tracked",
                    hours: total / 3_600,
                    color: Theme.Colors.selection,
                    // Nothing to name — this is the whole day drawn as one block, and a tooltip line
                    // reading "Tracked 5:57" under a header reading "5:57" is the same number twice.
                    isWorthListing: false
                )
            ]
        }

        return dayCells.map { cell in
            DailySegment(
                rowKey: cell.rowKey,
                title: cell.title,
                hours: (cell.total / exact) * total / 3_600,
                color: seriesColors[cell.rowKey] ?? Theme.Colors.selection,
                // ### Why a segment can be listed in the bar and not in the tooltip
                // Because a timer that has been running for eleven seconds is real time and belongs
                // in the day's total, and a tooltip line reading "No project — 0:00" is a line that
                // says nothing while looking like a bug. The screenshot that prompted this had
                // exactly that: an untitled running timer contributing eleven seconds to Saturday,
                // listed under the three hours of real work beside it.
                //
                // Half a minute is the threshold because the tooltip reports minutes: below it there
                // is no number to show. The time stays in the bar and in the header total, where it
                // is accounted for; what it loses is a line of its own at a precision that cannot
                // express it.
                isWorthListing: cell.total >= 30
            )
        }
    }

    /// The colour each breakdown row is drawn in, resolved once per reload.
    ///
    /// ### Why this is stored rather than computed in `body`
    /// Because a project's own tint lives on the item, and reading it means touching the store —
    /// which a view may not do while rendering. That is criterion A1-1 and `FetchAudit` is what
    /// proves it. Resolved when the entries or the grouping change, which is exactly when the answer
    /// can differ, and read from a dictionary while drawing.
    private func resolveSeriesColors() {
        guard let services, isStacked else {
            seriesColors = [:]
            return
        }

        // Ranked by the report's own ordering — largest first — so the biggest slice of the chart is
        // the same colour as the top row of the table under it.
        var resolved: [String: Color] = [:]
        for (rank, row) in report.rows.enumerated() {
            let colorName = row.itemID.flatMap { id in
                (try? services.items.item(id: id))??.colorName
            }
            resolved[row.key] = ReportSeriesPalette.color(
                colorName: colorName,
                rank: rank,
                isUnassigned: ReportSeriesPalette.isUnassignedKey(row.key)
            )
        }
        seriesColors = resolved
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

    /// The day's total, which is what the bar's height is.
    var hours: Double

    /// How many entries touched this day. An entry crossing midnight counts on both, because it
    /// happened on both.
    var entryCount: Int = 0

    var billableHours: Double = 0

    /// What proportion of the whole period landed on this day, from 0 to 1.
    var shareOfPeriod: Double = 0

    /// The coloured pieces it is made of. One piece when the grouping cannot be stacked, and none at
    /// all on a day with nothing on it.
    var segments: [DailySegment] = []

    var id: Date { day }

    var isEmpty: Bool { hours <= 0 }

    /// The pieces worth naming in a tooltip — see ``DailySegment/isWorthListing``.
    var listedSegments: [DailySegment] {
        segments.filter(\.isWorthListing)
    }

    /// The facts that are true of the day whatever it was spent on.
    ///
    /// This is what makes a one-project day worth hovering. The breakdown answers "what", and on a
    /// day with a single project it answers it in one line; these answer "how much of my week was
    /// this, and how many goes did it take", which the chart cannot show and the table below does
    /// not break down by day.
    var facts: [String] {
        guard !isEmpty else { return [] }

        var parts: [String] = []
        if entryCount > 0 {
            parts.append(entryCount == 1 ? "1 entry" : "\(entryCount) entries")
        }
        if shareOfPeriod > 0 {
            parts.append("\(Int((shareOfPeriod * 100).rounded()))% of the period")
        }
        if billableHours > 0 {
            parts.append("\(TimeFormatting.short(billableHours * 3_600)) billable")
        }
        return parts
    }

    /// What VoiceOver reads for this bar, so a day is answerable without a pointer.
    ///
    /// The tooltip is a hover affordance and hover is not available to everybody. This carries the
    /// same facts through the accessibility tree, which is where a keyboard or a screen reader can
    /// reach them.
    var accessibilityValue: String {
        guard !isEmpty else { return "Nothing tracked" }

        var parts = [TimeFormatting.spelled(hours * 3_600)]
        parts.append(contentsOf: listedSegments.prefix(3).map {
            "\($0.title), \(TimeFormatting.short($0.hours * 3_600))"
        })
        parts.append(contentsOf: facts)
        return parts.joined(separator: ", ")
    }
}

/// One coloured piece of a day's bar.
struct DailySegment: Identifiable, Hashable {
    var rowKey: String
    var title: String
    var hours: Double
    var color: Color

    /// Whether this piece earns a line in the tooltip.
    ///
    /// A piece can be worth drawing and not worth naming: a running timer's first few seconds are
    /// real time and belong in the day's total, but a line reading `0:00` is a line that says
    /// nothing while looking like a fault. See where this is decided, in
    /// `TimeReportView.segments(forDayStarting:total:cells:calendar:)`.
    var isWorthListing: Bool = true

    var id: String { rowKey }
}

/// What one day held, shown while the pointer is over it.
///
/// ### Why every day gets the same three parts
/// The first version showed the breakdown only when there was more than one row in it, on the
/// reasoning that naming the single thing a day was spent on repeats the total above it. Pointing at
/// a real week disproved that twice over.
///
/// A day with one project produced a tooltip holding a date and a number — and the number was
/// already the height of the bar being pointed at, so the whole gesture returned nothing. That is
/// the standard this app holds its own sidebar tooltips to, and it failed it. The single row is
/// worth its line precisely because it *names* something: `5:57` is the bar; "No project — 5:57" is
/// the answer to why.
///
/// And a total is not the only thing true of a day. How many goes it took, what share of the period
/// it was, how much of it was billable — none of those is on the chart, none is broken down by day
/// in the table underneath, and all three are things somebody hovers a bar to find out. They are the
/// part that makes a one-project day worth pointing at.
///
/// So: the date and the total, then what it went to, then what else is true of it. The same shape
/// every day, because a tooltip that changes shape as the pointer crosses the chart cannot be read
/// at a glance — the eye has to find each fact again on every day.
struct DayTooltip: View {
    let bar: DailyBar

    /// Enough to answer the question, few enough that the tooltip does not become the chart.
    private static let visibleSegments = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            headline

            if bar.isEmpty {
                Text("Nothing tracked")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                if !listed.isEmpty {
                    Divider()
                    breakdown
                }

                if !bar.facts.isEmpty {
                    Divider()
                    Text(bar.facts.joined(separator: " · "))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(minWidth: 180, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Colors.separator)
        }
        // The pointer is the thing asking; the tooltip must never be the thing it hits, or moving
        // one pixel further would dismiss the tooltip it just summoned.
        .allowsHitTesting(false)
        // Read through the bars' own accessibility values instead — see `DailyBar`.
        .accessibilityHidden(true)
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Text(bar.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer(minLength: Theme.Spacing.medium)

            Text(bar.isEmpty ? "—" : TimeFormatting.short(bar.hours * 3_600))
                .font(Theme.Text.rowTitleEmphasised)
                .monospacedDigit()
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            ForEach(listed.prefix(Self.visibleSegments)) { segment in
                HStack(spacing: Theme.Spacing.tight) {
                    // The same colour the segment is drawn in, which is the whole point: the swatch
                    // is what joins the name to the piece of the bar under the pointer.
                    Circle()
                        .fill(segment.color)
                        .frame(width: 7, height: 7)

                    Text(segment.title)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)

                    Spacer(minLength: Theme.Spacing.medium)

                    Text(TimeFormatting.short(segment.hours * 3_600))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            if listed.count > Self.visibleSegments {
                Text("and \(listed.count - Self.visibleSegments) more")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private var listed: [DailySegment] { bar.listedSegments }
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
