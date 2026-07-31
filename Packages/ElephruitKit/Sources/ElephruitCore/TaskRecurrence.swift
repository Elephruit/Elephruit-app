import Foundation

/// What completing one occurrence of a repeating task should do.
///
/// ### Why a plan rather than a mutation
/// Rolling a recurrence forward touches four dates and a series identity, and the arithmetic depends
/// on the anchor, on which dates the task actually has, and on whether the series has ended. Doing
/// that inside a repository method means it can only be tested with a store; returning a plan means
/// every case in this file is a struct comparison.
public struct RecurrenceAdvance: Sendable, Hashable {
    /// The next start date, when the task had one.
    public var startAt: Date?

    /// The next deadline, when the task had one.
    public var deadlineAt: Date?

    /// The next reminder, preserving its time of day.
    public var reminderAt: Date?

    /// How many occurrences the series will have produced once this one is counted.
    public var occurrenceCount: Int

    public init(
        startAt: Date? = nil,
        deadlineAt: Date? = nil,
        reminderAt: Date? = nil,
        occurrenceCount: Int
    ) {
        self.startAt = startAt
        self.deadlineAt = deadlineAt
        self.reminderAt = reminderAt
        self.occurrenceCount = occurrenceCount
    }
}

/// How completing a repeating task is turned into its next occurrence.
///
/// ### One row, not a hundred
/// A repeating task is **one** record whose dates move forward, plus a completed record left behind
/// as history. Materialising every future occurrence would mean a daily task producing 365 rows a
/// year, every one of them appearing in counts, in search, and in an export — and every edit to the
/// series then needing to find and rewrite all of them.
///
/// The cost of the one-row model is that "show me every Friday in March" cannot be answered by a
/// fetch. That is the right trade: nobody asks it, and the question people *do* ask — "what is next"
/// — is exactly the one row that exists.
public enum TaskRecurrence {
    /// Where the next occurrence is measured from.
    ///
    /// This is the whole reason ``RecurrenceRule/Anchor`` exists, and getting it wrong is the
    /// commonest recurrence bug in task managers. Rent is due on the 1st whether or not you paid
    /// late; the plants need watering three days after you last watered them, not three days after
    /// some date in the past you have now drifted from.
    static func anchorDate(
        rule: RecurrenceRule,
        scheduledAt: Date?,
        completedAt: Date
    ) -> Date {
        switch rule.anchor {
        case .schedule:
            // Falling back to the completion date is not a compromise: a task with no dates at all
            // that repeats "every week" has nothing else to measure from, and measuring from
            // completion is what the user would expect of it.
            scheduledAt ?? completedAt
        case .completion:
            completedAt
        }
    }

    /// The dates the next occurrence should carry, or `nil` when the series has finished.
    ///
    /// - Parameters:
    ///   - facts: The occurrence being completed.
    ///   - rule: The series rule.
    ///   - completedAt: When the user actually finished it.
    ///   - occurrencesSoFar: How many occurrences the series has already produced.
    ///   - calendar: Injected, so a rule crossing a daylight-saving boundary is testable.
    ///
    /// ### What moves, and what does not
    /// Every date the task **already has** moves by the same interval; a date it does not have is
    /// not invented. A repeating task with a deadline and no start date gets a deadline and no start
    /// date, because adding one would be the app deciding the user meant something they did not say.
    ///
    /// The reminder keeps its time of day. "Every Friday, remind me at 09:00" that drifted to 09:00
    /// plus however late you were last week is a reminder nobody trusts.
    public static func advance(
        _ facts: TaskFacts,
        rule: RecurrenceRule,
        completedAt: Date,
        occurrencesSoFar: Int,
        calendar: Calendar
    ) -> RecurrenceAdvance? {
        // The date the *series* is pinned to. Preferring the deadline over the start date matters
        // for a task carrying both: "starts Monday, due Friday, weekly" is a Friday commitment with
        // a Monday runway, and moving the runway would drag the commitment with it.
        let scheduled = facts.deadlineAt ?? facts.startAt ?? facts.reminderAt
        let anchor = anchorDate(rule: rule, scheduledAt: scheduled, completedAt: completedAt)

        guard let next = rule.nextOccurrence(
            after: anchor,
            occurrencesSoFar: occurrencesSoFar,
            calendar: calendar
        ) else { return nil }

        // How far the anchor moved, applied to every other date so their relative spacing survives.
        // Whole days rather than seconds, so a rule crossing a daylight-saving boundary keeps its
        // *calendar* spacing — a weekly task stays on its weekday rather than sliding by an hour.
        let dayShift = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: anchor),
            to: calendar.startOfDay(for: next)
        ).day ?? 0

        func shifted(_ date: Date?) -> Date? {
            guard let date else { return nil }
            return calendar.date(byAdding: .day, value: dayShift, to: date)
        }

        // The anchored date lands exactly on the computed occurrence; the others move alongside it.
        var advance = RecurrenceAdvance(
            startAt: shifted(facts.startAt),
            deadlineAt: shifted(facts.deadlineAt),
            reminderAt: shifted(facts.reminderAt),
            occurrenceCount: occurrencesSoFar + 1
        )

        if facts.deadlineAt != nil {
            advance.deadlineAt = next
        } else if facts.startAt != nil {
            advance.startAt = next
        } else if facts.reminderAt != nil {
            advance.reminderAt = next
        }

        return advance
    }

    /// Whether completing this occurrence ends the series.
    public static func isFinalOccurrence(
        _ facts: TaskFacts,
        rule: RecurrenceRule,
        completedAt: Date,
        occurrencesSoFar: Int,
        calendar: Calendar
    ) -> Bool {
        advance(
            facts,
            rule: rule,
            completedAt: completedAt,
            occurrencesSoFar: occurrencesSoFar,
            calendar: calendar
        ) == nil
    }
}

/// Which occurrences an edit to a repeating task applies to.
///
/// Asked rather than assumed. Every one of the three is a reasonable thing to want, and picking one
/// silently means either "I changed one Friday and it changed every Friday" or the reverse — both of
/// which destroy something the user had already decided.
public enum RecurrenceEditScope: String, Sendable, Hashable, CaseIterable, Codable {
    /// Just the occurrence in front of you. The series carries on unchanged.
    case thisOccurrence

    /// This one and everything after it. The series rule changes from here.
    case thisAndFuture

    /// Every occurrence, including the history already logged.
    case entireSeries

    public var displayName: String {
        switch self {
        case .thisOccurrence: "This Task"
        case .thisAndFuture: "This and Future Tasks"
        case .entireSeries: "All Tasks in the Series"
        }
    }

    public var explanation: String {
        switch self {
        case .thisOccurrence: "The repeat carries on as it was."
        case .thisAndFuture: "The repeat changes from here on. Completed occurrences are left alone."
        case .entireSeries: "Everything, including what has already been logged."
        }
    }
}
