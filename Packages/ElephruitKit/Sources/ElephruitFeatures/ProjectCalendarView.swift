import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The calendar view: the project's work, on the month its deadlines land in.
///
/// A month of full-width day cells rather than the grouped list wearing a date sort. Work sits on
/// the day of its **deadline** — the only date that can make something overdue, which is what a
/// calendar of work is for. Whatever has no deadline is listed beneath the grid rather than
/// silently dropped: a calendar that hides the unscheduled work reads as a project with less in
/// it than there is.
struct ProjectCalendarView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    /// The month on screen. Starts on today's month, not the earliest deadline — the question a
    /// calendar answers first is "what is due around now".
    @State private var displayedMonth: Date?

    var body: some View {
        let month = displayedMonth ?? dateProvider.now
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                monthBar(month)
                grid(month: month)

                if !undated.isEmpty {
                    undatedSection
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
        }
        .accessibilityIdentifier("project.calendar")
    }

    // MARK: - Month navigation

    private func monthBar(_ month: Date) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(Theme.Text.title)
                .tracking(Theme.Text.Tracking.title)

            Spacer(minLength: 0)

            Button {
                step(month, by: -1)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Previous month")

            Button("Today") { displayedMonth = nil }
                .disabled(calendar.isDate(month, equalTo: dateProvider.now, toGranularity: .month))

            Button {
                step(month, by: 1)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
    }

    private func step(_ month: Date, by value: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: value, to: month)
    }

    // MARK: - The grid

    private func grid(month: Date) -> some View {
        let days = MonthGrid<EmptyView>.days(of: month, calendar: calendar)
        let blanks = MonthGrid<EmptyView>.leadingBlanks(of: month, calendar: calendar)
        let byDay = workByDay

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, Theme.Spacing.tight)

            let cells: [MonthCell] = Array(repeating: MonthCell.blank, count: blanks)
                + days.map { MonthCell.day($0) }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7),
                spacing: 1
            ) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    switch cell {
                    case .blank:
                        Color.clear.frame(minHeight: Self.dayHeight)
                    case .day(let day):
                        dayCell(day, work: byDay[calendar.startOfDay(for: day)] ?? [])
                    }
                }
            }
            .background(Theme.Colors.separator)
            .border(Theme.Colors.separator, width: 1)
        }
    }

    private enum MonthCell {
        case blank
        case day(Date)
    }

    private static let dayHeight: CGFloat = 96
    private static let visibleItemsPerDay = 3

    private func dayCell(_ day: Date, work: [TaskFacts]) -> some View {
        let isToday = dateProvider.isToday(day)

        return VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text("\(calendar.component(.day, from: day))")
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(isToday ? Theme.Colors.onAccent : Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.tight)
                .padding(.vertical, Theme.Spacing.hairline)
                .background(
                    Capsule().fill(isToday ? Theme.Colors.selection : .clear)
                )

            ForEach(work.prefix(Self.visibleItemsPerDay), id: \.id) { facts in
                dayItem(facts)
            }

            if work.count > Self.visibleItemsPerDay {
                Text("+\(work.count - Self.visibleItemsPerDay) more")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.leading, Theme.Spacing.tight)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.tight)
        .frame(maxWidth: .infinity, minHeight: Self.dayHeight, alignment: .topLeading)
        .background(Theme.Colors.contentBackground)
    }

    private func dayItem(_ facts: TaskFacts) -> some View {
        let isSelected = model.selectedItemIDs.contains(facts.id)
        let isLate = facts.status.isActionable && dateProvider.isOverdue(facts.deadlineAt ?? dateProvider.now)

        return Button {
            model.select(facts.id)
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                WorkItemKindGlyph(kind: facts.kind, severity: facts.severity)
                    .font(Theme.Text.metadata)

                Text(facts.title.isEmpty ? "Untitled" : facts.title)
                    .font(Theme.Text.metadata)
                    .lineLimit(1)
                    .foregroundStyle(
                        facts.status.isResolved
                            ? Theme.Colors.tertiaryText
                            : (isLate ? Theme.Colors.overdue : Theme.Colors.primaryText)
                    )
                    .strikethrough(facts.status == .completed)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.tight)
            .padding(.vertical, Theme.Spacing.hairline)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(isSelected ? Theme.Colors.selectionFill : Theme.Colors.subtleFill)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.present(facts.id) })
        .contextMenu { WorkItemMenu(facts: facts, model: model, services: services) }
        .help(facts.title)
    }

    // MARK: - Undated work

    private var undatedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("No deadline")

            ForEach(undated, id: \.id) { facts in
                WorkItemRowView(facts: facts, groupSeverity: nil, model: model)
                    .padding(.horizontal, -Theme.Spacing.large)
            }
        }
    }

    // MARK: - Data

    /// Everything the view is showing, keyed by the start of its deadline day.
    private var workByDay: [Date: [TaskFacts]] {
        Dictionary(grouping: visible.filter { $0.deadlineAt != nil }) {
            calendar.startOfDay(for: $0.deadlineAt ?? .distantPast)
        }
    }

    private var undated: [TaskFacts] {
        visible.filter { $0.deadlineAt == nil }
    }

    /// The arrangement's output, so the view's own filter and the toolbar search both apply here
    /// exactly as they do to the list.
    private var visible: [TaskFacts] {
        model.groups.flatMap(\.items)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }

    private var calendar: Calendar {
        dateProvider.calendar
    }

    private var dateProvider: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }
}
