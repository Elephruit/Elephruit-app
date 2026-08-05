import Foundation

/// Turning a gap in the day into a decision: what could go there, and how long it would take.
///
/// ### Why this is arithmetic and not a view
/// Because the numbers are the whole feature. A gap of forty minutes, a task estimated at two hours
/// and a task with no estimate at all are three different offers, and the difference between them is
/// where a scheduling assistant is either useful or quietly wrong. Deciding it in a sheet's body
/// means the rule is re-derived by every surface that grows one — the slot, the task's swipe action,
/// the context menu — and the three drift within a release.
///
/// Nothing here writes anything. A proposal is a sentence the interface can show before anybody
/// commits to it, which is the point: the block is never guessed silently.
public enum TimeBlockRules {
    /// What a block lasts when nothing is known about the work.
    ///
    /// Half an hour, because it is the smallest span most people treat as a real appointment and
    /// because a block that is wrong is easier to lengthen than to notice.
    public static let fallbackLength: TimeInterval = 30 * 60

    /// The longest a block gets without the user having estimated anything.
    ///
    /// A three-hour gap is not an invitation to book three hours of unspecified work. One hour is
    /// the largest amount of somebody's afternoon this feature will claim on its own initiative.
    public static let unestimatedCap: TimeInterval = 60 * 60

    /// How long a block should be, in the order the answer is actually known.
    ///
    /// 1. The task's own estimate, capped by the gap it is going into — a two-hour task dropped into
    ///    forty minutes books forty minutes, because the alternative is writing an event that
    ///    overlaps the meeting after it.
    /// 2. No estimate but a gap: the gap, capped at ``unestimatedCap``.
    /// 3. Neither: ``fallbackLength``.
    ///
    /// - Parameters:
    ///   - estimateMinutes: The task's estimate, when it has one.
    ///   - slot: The gap this is going into, when it is going into one.
    public static func length(forEstimate estimateMinutes: Int?, in slot: DayFreeSlot?) -> TimeInterval {
        let room = slot?.duration

        guard let estimateMinutes, estimateMinutes > 0 else {
            guard let room else { return fallbackLength }
            return max(60, min(room, unestimatedCap))
        }

        let estimated = TimeInterval(estimateMinutes * 60)
        guard let room else { return estimated }
        return max(60, min(estimated, room))
    }

    /// Whether a task's estimate fits in a gap whole.
    ///
    /// A task with no estimate always "fits": the app has no basis for saying otherwise, and
    /// pretending it does would be inventing a fact about somebody's work.
    public static func fits(estimateMinutes: Int?, in slot: DayFreeSlot) -> Bool {
        guard let estimateMinutes, estimateMinutes > 0 else { return true }
        return TimeInterval(estimateMinutes * 60) <= slot.duration
    }

    /// The day's unscheduled work, in the order it should be offered for one gap.
    ///
    /// Longest-fitting first. The interesting offer for a two-hour stretch is the two-hour job, and
    /// putting the five-minute ones at the top of a list of eleven means scrolling past everything
    /// the gap was good for.
    ///
    /// Work that does not fit is kept and sorted below what does, rather than hidden. A person who
    /// wants to spend forty minutes starting a two-hour job is doing something perfectly sensible,
    /// and a list that silently omits their largest task looks broken from the outside.
    public static func candidates(
        in slot: DayFreeSlot,
        from work: [TimeBlockCandidate]
    ) -> [TimeBlockCandidate] {
        work
            .map { candidate in
                var ranked = candidate
                ranked.fitsWholly = fits(estimateMinutes: candidate.estimateMinutes, in: slot)
                return ranked
            }
            .enumerated()
            .sorted { left, right in
                if left.element.fitsWholly != right.element.fitsWholly { return left.element.fitsWholly }
                let leftLength = left.element.estimateMinutes ?? 0
                let rightLength = right.element.estimateMinutes ?? 0
                if leftLength != rightLength { return leftLength > rightLength }
                // Whatever order the day already put them in, for everything the estimates cannot
                // separate — which, in a library where most tasks carry no estimate, is most of them.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Where a block for this task should go, given what is free on the day.
    ///
    /// The earliest gap it fits in whole, because the reason to block time is to get the work done
    /// and the soonest opportunity is the one most likely to survive the rest of the day. Failing
    /// that, the largest gap: if nothing is big enough, the most useful answer is the most room.
    ///
    /// Returns `nil` when the day has no room at all, which is a real answer and not a failure — the
    /// caller offers a time of its own choosing and says so.
    public static func slot(forEstimate estimateMinutes: Int?, among slots: [DayFreeSlot]) -> DayFreeSlot? {
        guard !slots.isEmpty else { return nil }

        let inOrder = slots.sorted { $0.range.lowerBound < $1.range.lowerBound }
        if let fitting = inOrder.first(where: { fits(estimateMinutes: estimateMinutes, in: $0) }) {
            return fitting
        }
        return inOrder.max { $0.duration < $1.duration }
    }

    /// Where a block inside a gap begins.
    ///
    /// The start of the gap, except for one already under way. A stretch that opened when the last
    /// meeting overran begins at 11:07, and 11:07 is a timestamp rather than a plan — so a gap in
    /// progress rounds up to the next quarter. Unless that would eat it: rounding a twelve-minute
    /// gap forward leaves a block nobody wants, and the ragged start is the lesser evil.
    public static func start(in slot: DayFreeSlot, calendar: Calendar) -> Date {
        guard slot.isCurrent else { return slot.range.lowerBound }
        let rounded = nextRoundStart(after: slot.range.lowerBound, calendar: calendar)
        guard slot.range.upperBound.timeIntervalSince(rounded) >= 5 * 60 else { return slot.range.lowerBound }
        return rounded
    }

    /// The next time worth starting something, when there is no gap to start it in.
    ///
    /// Rounded up to the next quarter hour: an event beginning at 2:07 PM is a timestamp rather than
    /// a plan, and nobody has ever meant one.
    public static func nextRoundStart(after moment: Date, calendar: Calendar) -> Date {
        let fields = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: moment)
        // The same moment with its seconds dropped, which is what "the minute it is now" means.
        guard let onTheMinute = calendar.date(from: fields) else { return moment }

        let past = (fields.minute ?? 0) % 15
        // Already exactly on a quarter: that is the answer, not a reason to wait fifteen minutes.
        if past == 0, onTheMinute == moment { return moment }
        return calendar.date(byAdding: .minute, value: past == 0 ? 15 : 15 - past, to: onTheMinute) ?? moment
    }
}

/// A piece of work being considered for a gap in the day.
///
/// Deliberately not an `Item`: the rules live in `ElephruitCore`, which cannot see the store, and
/// the arithmetic needs three facts. Keeping it to three also keeps the tests honest — a rule that
/// can only be exercised by building a task with a project, a tag and a checklist is a rule nobody
/// will exercise.
public struct TimeBlockCandidate: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String

    /// What the person said it would take, in minutes. `nil` for the majority of work, which nobody
    /// has estimated and which the app must not estimate on their behalf.
    public var estimateMinutes: Int?

    /// Whether the whole estimate fits the gap being considered. Set by
    /// ``TimeBlockRules/candidates(in:from:)``; meaningless before that, which is why it is not an
    /// initialiser argument.
    public var fitsWholly: Bool = true

    public init(id: UUID, title: String, estimateMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.estimateMinutes = estimateMinutes
    }
}

/// A block of time the app is offering to write, before anybody has agreed to it.
///
/// Holds the whole offer — when, how long, on which calendar, and whether it defends the time or
/// merely records it — so that the sheet showing it and the action writing it are looking at one
/// value rather than at five pieces of state that can disagree.
public struct TimeBlockProposal: Sendable, Hashable {
    /// The work this block is for, when it is for work. `nil` is a plain focus block.
    public var taskID: UUID?

    /// What the event will be called. For a task, its own title and nothing else — see
    /// ``TimeBlockProposal/draft(calendarIdentifier:timeZoneIdentifier:)``.
    public var title: String

    public var startAt: Date
    public var length: TimeInterval

    /// Which calendar it lands on. Resolved by the caller from the calendar service, never guessed
    /// here, because "the default calendar" is a decision with an audience attached to it.
    public var calendarIdentifier: String

    /// Whether the block defends the time or merely records it.
    ///
    /// ### Why this is asked rather than defaulted
    /// A block that shows as busy is the point for somebody protecting an afternoon from their
    /// colleagues' scheduling assistants, and it is an unwelcome surprise for somebody who blocks
    /// time as a note to self and still expects to be invited to things. There is no default that is
    /// right for both, so the sheet asks, per block.
    public var availability: EventAvailability

    public init(
        taskID: UUID? = nil,
        title: String,
        startAt: Date,
        length: TimeInterval,
        calendarIdentifier: String,
        availability: EventAvailability = .busy
    ) {
        self.taskID = taskID
        self.title = title
        self.startAt = startAt
        self.length = max(60, length)
        self.calendarIdentifier = calendarIdentifier
        self.availability = availability
    }

    public var endAt: Date { startAt.addingTimeInterval(length) }

    public var range: Range<Date> { startAt..<endAt }

    /// "11:30 AM – 12:30 PM", for the sheet's own heading.
    public var rangeSummary: String {
        startAt.formatted(date: .omitted, time: .shortened)
            + " – " + endAt.formatted(date: .omitted, time: .shortened)
    }

    public var lengthSummary: String { DurationPhrase.exact(length) }

    /// The event this becomes.
    ///
    /// ### What is deliberately absent
    /// Everything about the task except its title. No notes, no project, no people, no link back to
    /// the record — a calendar event syncs to an account somebody else may be able to read, and the
    /// task it came from is the app's private context. The link between the two is written locally,
    /// on an `EventAnnotation`, which the calendar adapter cannot see.
    ///
    /// `EventDraft`'s field list is guarded by `CalendarWriteSafetyTests.draftCarriesNothingPrivate`.
    /// This adds nothing to it.
    public func draft(timeZoneIdentifier: String? = nil) -> EventDraft {
        EventDraft(
            calendarIdentifier: calendarIdentifier,
            title: title,
            startAt: startAt,
            endAt: endAt,
            timeZoneIdentifier: timeZoneIdentifier,
            availability: availability
        )
    }
}
