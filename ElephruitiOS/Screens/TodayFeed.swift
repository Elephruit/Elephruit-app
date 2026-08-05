import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// The days after the one you are standing on, on the same thread.
///
/// ### Why a day ahead is not drawn like the day you are on
/// Because it answers a different question. Today is for *doing* — a row you tick, swipe and open.
/// Thursday is for knowing whether Thursday is full, which is what is booked and what is owed, one
/// line each, in the order the day will happen. Everything the full day carries and this does not —
/// the briefing, the people, the note, the completed line — is a sentence about a day nobody has
/// reached yet, and a feed made of those is a feed nobody scrolls.
///
/// Tapping the day opens it out in place and it becomes the full thing, drawn by the same builder
/// that draws today.
///
/// ### The thread continues through all of it
/// Same rail, same gutter, same badge column as the day above. A future day is not a card pinned
/// below today; it is further along the same line, which is the whole reason the page can be
/// scrolled from this morning to next month without ever changing what a row means.

// MARK: - A day's marker

/// The line that names a day in the feed, and the control that opens it.
struct TodayFeedDayHeader: View {
    @Environment(\.services) private var services

    let plan: DayPlan
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        // The whole row is the control, not just the text column. A `Button` around the content
        // alone leaves the date, the marker and the rail inert — and a tap aimed at the middle of a
        // row that is visibly one thing has no reason to know that. The first run of
        // `testADayInTheFeedOpensOutInPlace` tapped the row's centre and nothing opened.
        Button(action: toggle) {
            row
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dayName), \(subtitle)")
        .accessibilityHint(isExpanded ? "Closes this day" : "Opens this day in full")
        .accessibilityIdentifier(AccessibilityID.Today.day(dayKey))
    }

    private var row: some View {
        TimelineRow(
            // Quiet, and the same grey whatever the day holds. The marker's job is to say *a new
            // day starts here*, and a dark disc every few rows turns a page of thirty days into a
            // column of blobs with the schedule arranged around them.
            badge: Timeline.Badge(
                tint: Theme.Colors.tertiaryText,
                isHollow: !plan.hasContent
            ),
            showsDivider: false
        ) {
            Text(dayNumber)
                .font(Theme.Text.rowTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(dayName)
                        .font(Theme.Text.rowTitle.weight(.semibold))
                        .foregroundStyle(Theme.Colors.primaryText)

                    Text(subtitle)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(Theme.Text.metadata.weight(.semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    // Turned rather than swapped, so the control is visibly the same control in
                    // both states and the change reads as one thing moving.
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var calendar: Calendar {
        (services?.dateProvider ?? SystemDateProvider()).calendar
    }

    private var dayKey: String {
        (services?.dateProvider ?? SystemDateProvider()).dayKey(for: plan.date)
    }

    /// The date, in the column that always says *when*.
    private var dayNumber: String {
        plan.date.formatted(.dateTime.day())
    }

    /// "Tomorrow" once, and the weekday every day after.
    ///
    /// Deliberately not "In 3 days" or "Next Thursday". A weekday is the name somebody already
    /// plans in — a meeting is on Thursday, not on day four — and relative counting past tomorrow
    /// makes the reader do arithmetic to find the day they were looking for. The month underneath
    /// carries the rest, which is what keeps a bare weekday unambiguous ninety days out.
    private var dayName: String {
        guard let today = services?.dateProvider.startOfToday,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              calendar.isDate(plan.date, inSameDayAs: tomorrow)
        else { return plan.date.formatted(.dateTime.weekday(.wide)) }
        return "Tomorrow"
    }

    /// The month, and the one word a glance needs when there is nothing under it.
    ///
    /// No counts. Everything the day holds is drawn immediately below, so "3 meetings" above three
    /// meetings is the interface reading itself back to you.
    private var subtitle: String {
        let month = plan.date.formatted(.dateTime.month(.wide))
        return plan.hasContent ? month : "\(month) · Clear"
    }
}

// MARK: - The lines under it

/// One entry from the calendar, on one line: when, what kind, and what.
struct TodayFeedEventLine: View {
    @Environment(\.services) private var services

    let dayEvent: DayEvent

    var body: some View {
        TimelineRow(
            badge: Timeline.Badge(
                symbolName: dayEvent.kind.symbolName,
                tint: Theme.Palette.color(named: dayEvent.event.calendarColorName),
                isCompact: true
            )
        ) {
            Text(timeText)
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.secondaryText)
        } content: {
            Text(dayEvent.event.displayTitle)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.primaryText)
                .strikethrough(dayEvent.event.isCancelled, color: Theme.Colors.tertiaryText)
                .lineLimit(1)
        }
        .opacity(dayEvent.event.isCancelled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeText), \(dayEvent.event.displayTitle)")
    }

    private var timeText: String {
        let calendar = (services?.dateProvider ?? SystemDateProvider()).calendar
        return dayEvent.event.occupiesAllDayRow(calendar: calendar)
            ? "All day"
            : dayEvent.event.startAt.formatted(date: .omitted, time: .shortened)
    }
}

/// One piece of work the day is owed, on one line: why it is here, and what it is.
struct TodayFeedTaskLine: View {
    let task: DayTask
    let item: Item

    var body: some View {
        TimelineRow(
            badge: Timeline.Badge(
                symbolName: task.primaryReason?.symbolName ?? "circle",
                tint: tint,
                isCompact: true
            )
        ) {
            // A reminder with a time of its own belongs on the clock beside the meetings. One
            // without has nothing to put here, and an empty column is honest where a glyph
            // repeating the badge would not be.
            if let pinned = task.pinnedAt {
                Text(pinned.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        } content: {
            Text(item.displayTitle)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tint: Color {
        switch task.primaryReason {
        case .overdue?: Theme.Colors.overdue
        case .due?: Theme.Colors.dueToday
        default: Theme.Colors.tertiaryText
        }
    }

    private var accessibilityLabel: String {
        guard let reason = task.primaryReason else { return item.displayTitle }
        return "\(item.displayTitle), \(reason.label)"
    }
}

// MARK: - The end of the run

/// What sits below the last day: the next week arriving, or the horizon.
struct TodayFeedFooter: View {
    let isExtending: Bool
    let canLoadMore: Bool

    var body: some View {
        TimelineRow(railStyle: canLoadMore ? .solid : .tail, showsDivider: false) {
            HStack {
                Spacer()
                if canLoadMore {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading more days")
                } else {
                    // Said, rather than left as a feed that silently stops. A scroll that meets
                    // nothing is indistinguishable from one that is still loading.
                    Text("Three months ahead is as far as this looks.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
        .accessibilityIdentifier(AccessibilityID.Today.loadMoreDays)
        // Kept in the layout while idle so the row's height does not change under the thumb that is
        // scrolling towards it, which is what would make the feed judder as it pages.
        .opacity(isExtending || !canLoadMore ? 1 : 0.4)
    }
}
