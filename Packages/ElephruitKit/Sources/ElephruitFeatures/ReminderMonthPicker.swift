import ElephruitDesign
import Foundation
import SwiftUI

/// A month a reminder can page through and pick a day from.
struct ReminderMonthPicker: View {
    let calendar: Calendar
    let today: Date
    var selected: Date?
    let onPick: (Date) -> Void

    @State private var visibleMonth: Date?

    private var month: Date { visibleMonth ?? selected ?? today }

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            HStack {
                Button { page(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")
                Spacer(minLength: 0)
                Text(monthName)
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)
                Spacer(minLength: 0)
                Button { page(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next month")
            }
            .padding(.horizontal, Theme.Spacing.tight)

            MonthGrid(
                month: month,
                calendar: calendar,
                cellSize: CGSize(width: 26, height: 22),
                spacing: 1,
                showsWeekdayHeader: true
            ) { day in
                dayCell(day)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar for \(monthName)")
        .onChange(of: selected) { _, selection in
            guard let selection,
                  !calendar.isDate(selection, equalTo: month, toGranularity: .month)
            else { return }
            visibleMonth = selection
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isChosen = selected.map { calendar.isDate(day, inSameDayAs: $0) } ?? false

        return Button { onPick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isChosen ? Theme.Colors.onAccent : Theme.Colors.primaryText)
                .frame(width: 26, height: 22)
                .background {
                    if isChosen {
                        Circle().fill(Theme.Colors.selection)
                    } else if isToday {
                        Circle().stroke(Theme.Colors.selection, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    private func page(by months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        visibleMonth = next
    }

    private var monthName: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = calendar.timeZone
        return month.formatted(style)
    }
}
