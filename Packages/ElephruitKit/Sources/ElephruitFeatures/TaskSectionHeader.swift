import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The line above a group of tasks: a glyph, a name, and a rule out to the edge.
///
/// ### Why this is not the shared `SectionHeader`
/// That one is built for a form — small caps, a count, nothing else — which is right above a group
/// of *fields* and wrong above a group of *things*. A list of tasks under a project wants the
/// project: its icon, its colour, its name at reading weight, because the header is the answer to
/// "what am I looking at" rather than a label on a region.
///
/// ### What the rule is for
/// A header at the left of a wide column leaves a long empty gap to its right, and the reader's eye
/// has to cross that gap unaided to find where the group's rows start. The hairline carries it, and
/// it gives a group an edge without drawing a box around it — which is the other way to say the same
/// thing, at the cost of a box on every group.
///
/// The count is quiet and to the right of the title rather than in the rule, because it answers a
/// question somebody asks occasionally and the title answers one they ask every time.
struct TaskSectionHeader: View {
    let title: String

    /// The container's own symbol, where the group is a container. Absent for Today's three parts
    /// and for a day, both of which are not things with icons.
    var symbolName: String?

    /// The container's colour, carried through from the library so the same project is the same
    /// colour everywhere it appears.
    var tint: Color?

    var count: Int?

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(tint ?? Theme.Colors.secondaryText)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(Theme.Text.rowTitleEmphasised)
                .foregroundStyle(Theme.Colors.primaryText)
                .lineLimit(1)

            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .monospacedDigit()
            }

            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .padding(.top, Theme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
    }
}

/// A day in Upcoming: the number large, the weekday beside it.
///
/// ### Why the number is the big thing
/// Because Upcoming is read by scrolling, and what you are scrolling *for* is a date. A row of
/// uniform small-caps headings — "WEDNESDAY 6 AUGUST" — makes every day look the same on the way
/// past, so finding the 14th means reading rather than scanning. A large numeral is a landmark.
///
/// The weekday keeps its word because "the 14th" and "Thursday" are two different ways people hold a
/// date, and which one somebody is using depends on how far away it is.
struct TaskDayHeader: View {
    let date: Date
    let calendar: Calendar

    /// Whether this is today. Drawn in the accent, because the one day worth picking out of a list
    /// of days is the one you are standing on.
    var isToday: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isToday ? Theme.Colors.selection : Theme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 0) {
                Text(weekday)
                    .font(Theme.Text.rowTitleEmphasised)
                    .foregroundStyle(isToday ? Theme.Colors.selection : Theme.Colors.primaryText)

                Text(month)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .padding(.top, Theme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(accessibilityLabel)
    }

    private var weekday: String {
        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private var month: String {
        var style = Date.FormatStyle().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private var accessibilityLabel: String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        let spoken = date.formatted(style)
        return isToday ? "Today, \(spoken)" : spoken
    }
}
