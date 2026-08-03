import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The timeline view: the project's work on a shared time axis, grouped by milestone.
///
/// Each dated item draws a bar from its start to its deadline — a dot when it only has one of the
/// two — against month ticks that every group shares, so "what lands when" is read across the
/// screen rather than computed from a date column. Undated work is listed under its group rather
/// than dropped, for the same reason the calendar keeps a "No deadline" section: a timeline that
/// hides unscheduled work is quietly lying about how much is left.
struct ProjectTimelineView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if let span = axisSpan {
                    TimelineAxisHeader(span: span, calendar: calendar)
                        .padding(.leading, Self.titleColumnWidth + Theme.Spacing.medium)
                        .padding(.horizontal, Theme.Spacing.medium)
                }

                ForEach(model.groups) { group in
                    groupSection(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
        }
        .background(Theme.Colors.subtleFill.opacity(0.45))
        .accessibilityIdentifier("project.timeline")
    }

    /// The width every row reserves for its title, so the bars to the right of it share an origin.
    static let titleColumnWidth: CGFloat = 220

    // MARK: - Groups

    private func groupSection(_ group: WorkItemArrangement.Group) -> some View {
        VStack(spacing: 0) {
            if !group.title.isEmpty {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: group.symbolName ?? "flag")
                        .frame(width: Theme.Size.rowGlyph)
                        .foregroundStyle(groupTint(group))
                    Text(group.title)
                        .font(Theme.Text.rowTitleEmphasised)
                    Text("\(group.count)")
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Spacer(minLength: 0)

                    if let due = groupDeadline(group) {
                        DueDateLabel(date: due, dateProvider: dateProvider)
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(groupTint(group))
                        .frame(width: 3)
                        .padding(.vertical, Theme.Spacing.small)
                }

                Divider()
            }

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, facts in
                TimelineWorkItemRow(
                    facts: facts,
                    span: axisSpan,
                    model: model,
                    dateProvider: dateProvider
                )

                if index < group.items.count - 1 {
                    Divider().padding(.leading, Self.titleColumnWidth + Theme.Spacing.medium)
                }
            }
        }
        .background(
            Theme.Colors.contentBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.large)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.Colors.separator, lineWidth: 0.5)
        )
    }

    /// A milestone group's own date, when the group is a milestone with one.
    private func groupDeadline(_ group: WorkItemArrangement.Group) -> Date? {
        guard group.key.hasPrefix("milestone."),
              let id = UUID(uuidString: String(group.key.dropFirst("milestone.".count)))
        else { return nil }
        return model.markers.first { $0.id == id }?.dueAt
    }

    private func groupTint(_ group: WorkItemArrangement.Group) -> Color {
        Theme.Palette.color(named: group.colorName, neutral: Theme.Colors.secondaryText)
    }

    // MARK: - The axis

    /// The whole span the timeline covers: every date anything carries, padded to whole months so
    /// the first tick is a month's name rather than an arbitrary Tuesday.
    private var axisSpan: ClosedRange<Date>? {
        let dates = model.groups.flatMap(\.items).flatMap { [$0.startAt, $0.deadlineAt].compactMap { $0 } }
            + model.markers.compactMap(\.dueAt)
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }

        let start = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
        let endMonth = calendar.dateInterval(of: .month, for: latest)?.end ?? latest
        // At least two months of axis, so a project whose dates all land in one week still gets a
        // scale rather than a bar filling the screen.
        let end = max(endMonth, calendar.date(byAdding: .month, value: 2, to: start) ?? endMonth)
        return start...end
    }

    private var calendar: Calendar {
        dateProvider.calendar
    }

    private var dateProvider: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }
}

/// One selectable timeline row, styled like the bug tracker's dense triage rows.
struct TimelineWorkItemRow: View {
    @Environment(\.services) private var services
    let facts: TaskFacts
    let span: ClosedRange<Date>?
    let model: ProjectWorkspaceModel
    let dateProvider: any DateProvider

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedItemIDs.contains(facts.id) }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                WorkItemKindGlyph(kind: facts.kind, severity: facts.severity)
                    .frame(width: Theme.Size.rowGlyph)

                Text(facts.title.isEmpty ? "Untitled" : facts.title)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)
                    .foregroundStyle(
                        facts.status.isResolved ? Theme.Colors.tertiaryText : Theme.Colors.primaryText
                    )
                    .strikethrough(facts.status == .completed)

                Spacer(minLength: 0)
            }
            .frame(width: ProjectTimelineView.titleColumnWidth, alignment: .leading)

            if let span {
                TimelineLane(facts: facts, span: span, dateProvider: dateProvider)
            } else {
                Text("Unscheduled")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: 38)
        .background(rowBackground)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { model.select(facts.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.present(facts.id) })
        .contextMenu { WorkItemMenu(facts: facts, model: model, services: services) }
        .accessibilityIdentifier("timeline.row.\(facts.id.uuidString)")
    }

    private var rowBackground: Color {
        if isSelected { return Theme.Colors.selectionFill }
        if isHovering { return Theme.Colors.hoverFill }
        return .clear
    }
}

/// The month ticks every lane lines up against.
struct TimelineAxisHeader: View {
    let span: ClosedRange<Date>
    let calendar: Calendar

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(monthStarts.enumerated()), id: \.offset) { _, month in
                let x = TimelineLane.position(of: month, in: span) * proxy.size.width
                Text(month.formatted(.dateTime.month(.abbreviated)))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .offset(x: x)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var monthStarts: [Date] {
        var months: [Date] = []
        var cursor = calendar.dateInterval(of: .month, for: span.lowerBound)?.start ?? span.lowerBound
        while cursor < span.upperBound, months.count < 36 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }
}

/// One item's stretch of the axis: a bar from start to deadline, or a dot for a single date.
struct TimelineLane: View {
    let facts: TaskFacts
    let span: ClosedRange<Date>
    let dateProvider: any DateProvider

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(Array(monthStarts.enumerated()), id: \.offset) { _, month in
                    let x = Self.position(of: month, in: span) * proxy.size.width
                    Rectangle()
                        .fill(Theme.Colors.separator.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: x)
                }

                // The faint rule the bars sit on, so a lane with a short bar still reads as a lane.
                Rectangle()
                    .fill(Theme.Colors.separator.opacity(0.5))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)

                if let start = barStart, let end = barEnd, end > start {
                    let x = Self.position(of: start, in: span) * proxy.size.width
                    let width = max(
                        Self.minimumBarWidth,
                        (Self.position(of: end, in: span) - Self.position(of: start, in: span)) * proxy.size.width
                    )
                    Capsule()
                        .fill(barColor)
                        .frame(width: width, height: 6)
                        .offset(x: x)
                } else if let date = barStart ?? barEnd {
                    let x = Self.position(of: date, in: span) * proxy.size.width
                    Circle()
                        .fill(barColor)
                        .frame(width: 7, height: 7)
                        .offset(x: x - 3.5)
                } else {
                    Text("Unscheduled")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(.trailing, Theme.Spacing.tight)
                        .background(Theme.Colors.contentBackground)
                }
            }
        }
        .frame(height: 16)
        .accessibilityLabel(accessibilityText)
    }

    static let minimumBarWidth: CGFloat = 6

    /// Where a date falls along the axis, 0...1.
    static func position(of date: Date, in span: ClosedRange<Date>) -> CGFloat {
        let whole = span.upperBound.timeIntervalSince(span.lowerBound)
        guard whole > 0 else { return 0 }
        let offset = date.timeIntervalSince(span.lowerBound)
        return CGFloat(min(1, max(0, offset / whole)))
    }

    private var barStart: Date? { facts.startAt }
    private var barEnd: Date? { facts.deadlineAt }

    private var monthStarts: [Date] {
        let calendar = dateProvider.calendar
        var months: [Date] = []
        var cursor = calendar.dateInterval(of: .month, for: span.lowerBound)?.start ?? span.lowerBound
        while cursor < span.upperBound, months.count < 36 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    private var barColor: Color {
        if facts.status.isResolved { return Theme.Colors.completed }
        if let due = facts.deadlineAt, dateProvider.isOverdue(due) { return Theme.Colors.overdue }
        return Theme.Colors.selection
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let start = facts.startAt {
            parts.append("starts \(start.formatted(date: .abbreviated, time: .omitted))")
        }
        if let due = facts.deadlineAt {
            parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? "No dates" : parts.joined(separator: ", ")
    }
}
