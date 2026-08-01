import Foundation

/// What a day is made of, and the rules that decide it.
///
/// ### Why this is a model rather than a view
/// Everything here answers a question a reader has at nine in the morning — *is that a meeting or is
/// it my dentist, how much of the afternoon is actually mine, why is this person on my screen* — and
/// every one of those questions has a right answer that does not depend on how wide the window is.
/// Keeping them here means each is decided once, tested against a fixed clock, and cannot be
/// re-decided differently by the next surface that needs it.
///
/// Nothing in this file reads the store. The types are built from values the rest of the app already
/// produces — ``CalendarEventSummary``, ``TaskFacts``, ``UpcomingCelebration``, ``FollowUpSuggestion``
/// — so a day can be assembled in a test in a dozen lines.

// MARK: - What an entry in the calendar actually is

/// What a calendar entry is, as a day's plan reads it.
///
/// ### Why not simply "meeting"
/// Because most calendars are not made of meetings. A dentist appointment, a school pickup, a block
/// of time somebody defended for themselves, and a week of leave are all events, and calling any of
/// them a meeting is both wrong and unhelpful — it invites the interface to offer a guest list for a
/// haircut, and it inflates "you have six meetings today" into a number nobody can act on.
///
/// The distinction is drawn from what the event *says about itself*, never from its title. Title
/// matching would read "Lunch with Sam" as a meal and "Travel to Berlin" as a journey, and would read
/// them wrongly in every language the app is not written in.
public enum DayEventKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// Somebody other than you is on the invitation. This, and only this, is a meeting.
    case meeting

    /// A timed entry with nobody else on it. The dentist, the haircut, the pickup.
    case appointment

    /// Time claimed on the calendar and left showing as free — which is what a defended block is.
    case focusBlock

    /// Marked unavailable: leave, travel, out of office.
    case away

    /// An all-day or multi-day entry with nobody else on it.
    case allDay

    public var displayName: String {
        switch self {
        case .meeting: "Meeting"
        case .appointment: "Appointment"
        case .focusBlock: "Focus"
        case .away: "Away"
        case .allDay: "All day"
        }
    }

    public var symbolName: String {
        switch self {
        case .meeting: "person.2"
        case .appointment: "calendar"
        case .focusBlock: "shield.lefthalf.filled"
        case .away: "airplane"
        case .allDay: "sun.horizon"
        }
    }

    /// Whether this kind has people to say something about.
    ///
    /// The whole preparation surface — attendees, the brief, who to follow up — hangs off this, and
    /// hangs off nothing else. An appointment has no guest list to show and offering one is how a
    /// dashboard starts inventing.
    public var hasAttendees: Bool { self == .meeting }

    /// Whether the entry belongs in the counted total of the day's meetings.
    public var countsAsMeeting: Bool { self == .meeting }
}

/// One calendar entry, classified, with everything a day's plan needs to draw it.
public struct DayEvent: Sendable, Hashable, Identifiable {
    public var event: CalendarEventSummary
    public var kind: DayEventKind

    /// Other entries on the same day whose time this one overlaps.
    ///
    /// Held as identifiers rather than as a Boolean so a row can say *what* it clashes with. "Two
    /// things at once" is a fact; "this clashes with the board review" is an instruction.
    public var conflictingEventIDs: [String]

    /// The people on the invitation who are not you, resolved against the library where possible.
    ///
    /// Empty for everything that is not a ``DayEventKind/meeting``.
    public var participants: [DayParticipant]

    /// Whether anything has been recorded about this meeting already — a note, a linked person, a
    /// preparation line.
    public var preparation: MeetingPreparation

    public var id: String { event.id }

    public init(
        event: CalendarEventSummary,
        kind: DayEventKind,
        conflictingEventIDs: [String] = [],
        participants: [DayParticipant] = [],
        preparation: MeetingPreparation = MeetingPreparation()
    ) {
        self.event = event
        self.kind = kind
        self.conflictingEventIDs = conflictingEventIDs
        self.participants = participants
        self.preparation = preparation
    }

    public var hasConflict: Bool { !conflictingEventIDs.isEmpty }

    /// How long until it begins, or `nil` once it has started.
    public func timeUntilStart(from now: Date) -> TimeInterval? {
        let interval = event.startAt.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }

    public func isInProgress(at now: Date) -> Bool {
        !event.isAllDay && event.startAt <= now && event.endAt > now
    }

    public func hasFinished(by now: Date) -> Bool {
        !event.isAllDay && event.endAt <= now
    }
}

/// Somebody on an invitation, joined to the library where the library knows them.
///
/// ### Why the identifier is optional
/// Most attendees are addresses on somebody else's invitation, and the app has no record of them.
/// Making that representable is what stops the alternative: inventing a person record for every
/// address that appears in a calendar, which turns a curated set of people the user cares about into
/// a mailing list.
public struct DayParticipant: Sendable, Hashable, Identifiable {
    /// The library's person, when this attendee resolved to one.
    public var personID: UUID?

    /// Stable within a day even when unresolved — the address, or the folded name.
    public var key: String

    public var name: String
    public var emailAddress: String?
    public var participation: EventParticipation
    public var isOrganizer: Bool

    public var id: String { key }

    public init(
        personID: UUID? = nil,
        key: String,
        name: String,
        emailAddress: String? = nil,
        participation: EventParticipation = .unknown,
        isOrganizer: Bool = false
    ) {
        self.personID = personID
        self.key = key
        self.name = name
        self.emailAddress = emailAddress
        self.participation = participation
        self.isOrganizer = isOrganizer
    }

    public var isKnown: Bool { personID != nil }

    public var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "@" }).prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// What has already been recorded about a meeting.
///
/// Deliberately a count of *things that exist* rather than a judgement about readiness. An app that
/// decides you are unprepared for a conversation with your own colleague, and says so in orange, is
/// an app people learn to distrust.
public struct MeetingPreparation: Sendable, Hashable {
    public var hasNote: Bool
    public var noteID: UUID?
    public var openPreparationTaskIDs: [UUID]
    public var completedPreparationTaskCount: Int
    public var hasPreparationNotes: Bool
    public var linkedPersonCount: Int

    public init(
        hasNote: Bool = false,
        noteID: UUID? = nil,
        openPreparationTaskIDs: [UUID] = [],
        completedPreparationTaskCount: Int = 0,
        hasPreparationNotes: Bool = false,
        linkedPersonCount: Int = 0
    ) {
        self.hasNote = hasNote
        self.noteID = noteID
        self.openPreparationTaskIDs = openPreparationTaskIDs
        self.completedPreparationTaskCount = completedPreparationTaskCount
        self.hasPreparationNotes = hasPreparationNotes
        self.linkedPersonCount = linkedPersonCount
    }

    /// Whether anything at all has been written down about this meeting.
    public var isEmpty: Bool {
        !hasNote && openPreparationTaskIDs.isEmpty && completedPreparationTaskCount == 0
            && !hasPreparationNotes && linkedPersonCount == 0
    }

    /// The one line a row can afford, or `nil` when there is nothing to say.
    public var summary: String? {
        var parts: [String] = []
        if !openPreparationTaskIDs.isEmpty {
            let count = openPreparationTaskIDs.count
            parts.append(count == 1 ? "1 thing to prepare" : "\(count) things to prepare")
        } else if completedPreparationTaskCount > 0 {
            parts.append("Prepared")
        }
        if hasNote { parts.append("Notes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Classifying and colliding

/// The rules that turn a calendar into a day.
public enum DayEventRules {
    /// What an event is.
    ///
    /// Order matters, and the order is the argument. Attendees win over everything: a week-long
    /// offsite with eleven people is a meeting that happens to be all day, and burying it in the
    /// all-day band with no guest list would hide the only thing about it worth preparing for.
    /// Availability comes next, because "I marked myself free" and "I marked myself away" are
    /// statements the user actually made. Shape — all-day or not — is what is left.
    public static func kind(of event: CalendarEventSummary) -> DayEventKind {
        if event.attendees.contains(where: { !$0.isCurrentUser }) { return .meeting }

        switch event.availability {
        case .free:
            return .focusBlock
        case .unavailable:
            return .away
        case .busy, .tentative, .notSupported:
            break
        }

        return event.isAllDay ? .allDay : .appointment
    }

    /// Whether an event belongs in the day at all.
    ///
    /// Declined invitations do not: somebody else's meeting that you said no to is not part of your
    /// day. Cancelled ones **do**, because a meeting cancelled an hour beforehand is information, and
    /// an app that silently removes it looks broken to somebody who remembers it being there.
    public static func appearsInPlan(_ event: CalendarEventSummary) -> Bool {
        event.appearsInPlan
    }

    /// Which events clash, keyed by identifier.
    ///
    /// ### What counts as a clash
    /// Only entries that genuinely occupy time. A focus block overlapping a meeting is not a
    /// double booking — it is the meeting eating the block, which is ordinary and not worth an
    /// alarm — and an all-day entry overlaps everything by construction. Marking either as a
    /// conflict would put a warning on most days of most calendars, which is the fastest way to
    /// teach somebody to ignore warnings.
    public static func conflicts(
        among events: [CalendarEventSummary],
        calendar: Calendar
    ) -> [String: [String]] {
        let contenders = events.filter { event in
            appearsInPlan(event)
                && !event.isCancelled
                && !event.occupiesAllDayRow(calendar: calendar)
                && event.availability.occupiesTime
                && event.endAt > event.startAt
        }
        guard contenders.count > 1 else { return [:] }

        let ordered = contenders.sorted { $0.startAt < $1.startAt }
        var clashes: [String: [String]] = [:]

        for (index, event) in ordered.enumerated() {
            for other in ordered[(index + 1)...] {
                // Sorted by start, so once a later event begins after this one ends, so does
                // everything after it.
                guard other.startAt < event.endAt else { break }
                clashes[event.id, default: []].append(other.id)
                clashes[other.id, default: []].append(event.id)
            }
        }

        return clashes
    }
}

// MARK: - Joining the call

/// Finding the link to the room, when the room is not a room.
///
/// ### Why this reads three fields and guesses at none
/// A conferencing link arrives wherever the organiser's tooling put it — the URL field, the
/// location, or halfway down the notes. So all three are read, in that order of trust. What is
/// deliberately absent is any attempt to *infer* a call from a title: "Zoom with Priya" is a
/// sentence, not a link, and a Join button that opens a search results page is worse than no button.
///
/// The host list is a recognition aid, not a gate. A link in the URL field is offered whatever its
/// host, because the organiser put it in the field that means "this is where the meeting is"; a link
/// found loose in the notes is offered only when its host is one of the known conferencing services,
/// because notes are full of links to documents nobody wants to open by pressing Join.
public enum MeetingLink {
    static let knownHosts: Set<String> = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "chime.aws", "gotomeeting.com", "bluejeans.com", "around.co",
        "meet.jit.si", "discord.gg", "slack.com", "facetime.apple.com", "riverside.fm",
    ]

    /// The link to join, if there is one.
    public static func url(in event: CalendarEventSummary) -> URL? {
        if let url = event.url, url.scheme != nil { return url }

        if let location = event.locationName, let found = firstURL(in: location) { return found }

        if let notes = event.notes {
            for candidate in urls(in: notes) where isKnownConferencing(candidate) {
                return candidate
            }
        }

        return nil
    }

    /// Whether the host is a conferencing service this recognises.
    public static func isKnownConferencing(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func firstURL(in text: String) -> URL? {
        urls(in: text).first
    }

    private static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        }
    }
}

// MARK: - How much of the day is actually yours

extension WorkingHours {
    /// The stretch of one day this describes, in the user's own calendar.
    ///
    /// ### Why this reuses the calendar set's hours rather than inventing its own
    /// Because the user has already said when they work — it is part of ``CalendarSetDefinition``,
    /// and it is what shades the time grid. A second, private idea of "the working day" would let
    /// the grid and the briefing disagree about the same afternoon, and the user would have no way
    /// to tell which one to believe.
    ///
    /// `nil` on a day the user does not work. Free time on a Sunday is not a figure anybody needs;
    /// it is the whole day, and saying so in hours is noise dressed as insight.
    public func window(on day: Date, calendar: Calendar) -> Range<Date>? {
        let weekday = calendar.component(.weekday, from: day)
        guard includes(weekday: weekday) else { return nil }

        let start = calendar.startOfDay(for: day)
        guard let opening = calendar.date(byAdding: .minute, value: startMinutes, to: start),
              let closing = calendar.date(byAdding: .minute, value: endMinutes, to: start),
              opening < closing
        else { return nil }
        return opening..<closing
    }
}

/// What is left of a day once the calendar has had its share.
public struct DayFocusTime: Sendable, Hashable {
    /// Total unclaimed time inside the working window.
    public var available: TimeInterval

    /// The longest single unbroken stretch, which is the number that actually decides what can be
    /// attempted. Four separate twenty-minute gaps are not eighty minutes of work.
    public var longestStretch: Range<Date>?

    /// Whether the window has already closed — the working day is over, or the date is in the past.
    public var isClosed: Bool

    public init(available: TimeInterval = 0, longestStretch: Range<Date>? = nil, isClosed: Bool = false) {
        self.available = available
        self.longestStretch = longestStretch
        self.isClosed = isClosed
    }

    public var hasAny: Bool { available >= 60 }

    /// "3h 20m free" — rounded down to five minutes, because a dashboard claiming three hours and
    /// seventeen minutes is claiming a precision it does not have.
    public var summary: String {
        guard hasAny else { return isClosed ? "Day's done" : "Nothing free" }
        return DurationPhrase.rounded(available) + " free"
    }

    public var longestStretchSummary: String? {
        guard let longestStretch else { return nil }
        let length = longestStretch.upperBound.timeIntervalSince(longestStretch.lowerBound)
        guard length >= 15 * 60 else { return nil }
        return DurationPhrase.rounded(length) + " from "
            + longestStretch.lowerBound.formatted(date: .omitted, time: .shortened)
    }
}

/// Durations said the way somebody would say them.
public enum DurationPhrase {
    /// Rounded down to the nearest five minutes, then spoken.
    public static func rounded(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60) / 5 * 5
        return exact(TimeInterval(minutes * 60))
    }

    public static func exact(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}

public enum FocusTimeRules {
    /// What is left of the working window once the calendar has taken its share.
    ///
    /// For today the window starts *now* rather than at nine, because time already spent is not
    /// available and saying otherwise is the single easiest way for this number to be wrong.
    public static func focusTime(
        on day: Date,
        events: [CalendarEventSummary],
        workingHours: WorkingHours = .standard,
        now: Date,
        calendar: Calendar
    ) -> DayFocusTime {
        guard let window = workingHours.window(on: day, calendar: calendar) else {
            return DayFocusTime(isClosed: true)
        }

        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = calendar.startOfDay(for: day) < calendar.startOfDay(for: now)

        let lowerBound = isToday ? max(window.lowerBound, now) : window.lowerBound
        guard !isPast, lowerBound < window.upperBound else {
            return DayFocusTime(isClosed: true)
        }
        let remaining = lowerBound..<window.upperBound

        let busy = events
            .filter { event in
                DayEventRules.appearsInPlan(event)
                    && !event.isCancelled
                    && event.availability.occupiesTime
                    && !event.occupiesAllDayRow(calendar: calendar)
            }
            .compactMap { event -> Range<Date>? in
                let start = max(event.startAt, remaining.lowerBound)
                let end = min(event.endAt, remaining.upperBound)
                return start < end ? start..<end : nil
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        var gaps: [Range<Date>] = []
        var cursor = remaining.lowerBound

        for interval in busy {
            if interval.lowerBound > cursor { gaps.append(cursor..<interval.lowerBound) }
            cursor = max(cursor, interval.upperBound)
        }
        if cursor < remaining.upperBound { gaps.append(cursor..<remaining.upperBound) }

        let total = gaps.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
        let longest = gaps.max {
            $0.upperBound.timeIntervalSince($0.lowerBound) < $1.upperBound.timeIntervalSince($1.lowerBound)
        }

        return DayFocusTime(available: total, longestStretch: longest, isClosed: false)
    }
}

// MARK: - Why a task is here today

/// Why a task has earned a place in a day.
///
/// Every task on the page carries one of these, and the page will say it on request. A planner that
/// cannot explain why something is in front of you is a planner you end up re-checking by hand.
public enum DayTaskReason: Sendable, Hashable {
    /// Past its deadline, by this many days.
    case overdue(days: Int)

    /// Its deadline is this day.
    case due

    /// Its start date is this day — it becomes workable now.
    case starts

    /// The user put it here.
    case committed

    /// Flagged, and workable. Present only on today, and only when the day has room for it.
    case flagged

    /// Attached to one of the day's meetings.
    case meetingPrep(eventID: String, eventTitle: String)

    /// A waiting task whose chase date has arrived.
    case followUp(personName: String?)

    /// Reminder set for this day.
    case reminder(at: Date)

    /// How loudly it should be read. Lower is more urgent.
    public var rank: Int {
        switch self {
        case .overdue: 0
        case .due: 1
        case .followUp: 2
        case .meetingPrep: 3
        case .committed: 4
        case .reminder: 5
        case .starts: 6
        case .flagged: 7
        }
    }

    /// Whether this reason makes the task part of what genuinely *needs* attention, as opposed to
    /// what is merely available. The distinction is what keeps "needs attention" small enough to
    /// read.
    public var needsAttention: Bool {
        switch self {
        case .overdue, .due, .followUp: true
        case .starts, .committed, .flagged, .meetingPrep, .reminder: false
        }
    }

    public var symbolName: String {
        switch self {
        case .overdue, .due: "flag.pattern.checkered"
        case .starts: "play.circle"
        case .committed: "circle.circle"
        case .flagged: "flag"
        case .meetingPrep: "person.2"
        case .followUp: "arrow.turn.up.right"
        case .reminder: "bell"
        }
    }

    public var label: String {
        switch self {
        case .overdue(let days): days == 1 ? "1 day late" : "\(days) days late"
        case .due: "Due"
        case .starts: "Starts today"
        case .committed: "On your list"
        case .flagged: "Flagged"
        case .meetingPrep(_, let title): "For \(title)"
        case .followUp(let name): name.map { "Chase \($0)" } ?? "Follow up"
        case .reminder(let at): "Reminder " + at.formatted(date: .omitted, time: .shortened)
        }
    }
}

/// One task's appearance on one day.
public struct DayTask: Sendable, Hashable, Identifiable {
    public var taskID: UUID
    public var reasons: [DayTaskReason]

    /// The time of day it is pinned to, when it has one. Only a timed reminder or a timed deadline
    /// gives a task a place in a chronological agenda; everything else is undated within the day and
    /// belongs in the list, not the timeline.
    public var pinnedAt: Date?

    public var id: UUID { taskID }

    public init(taskID: UUID, reasons: [DayTaskReason], pinnedAt: Date? = nil) {
        self.taskID = taskID
        self.reasons = reasons.sorted { $0.rank < $1.rank }
        self.pinnedAt = pinnedAt
    }

    /// The reason worth showing, which is the most urgent one.
    public var primaryReason: DayTaskReason? { reasons.first }

    public var needsAttention: Bool { reasons.contains(where: \.needsAttention) }
}

public enum DayTaskRules {
    /// Everything a given day has to say about one task.
    ///
    /// Returns an empty array when the task has no business on that day, which is what makes this
    /// usable as a filter as well as a classifier.
    ///
    /// Completed and cancelled work is deliberately excluded here and gathered separately: history
    /// belongs at the bottom of a day in a line, not mixed into the work that is left.
    public static func reasons(
        for facts: TaskFacts,
        on day: Date,
        now: Date,
        calendar: Calendar,
        meetingTaskIDs: [UUID: (id: String, title: String)] = [:],
        includesFlagged: Bool = true
    ) -> [DayTaskReason] {
        guard facts.lifecycle.isOpen, !facts.isSomeday else { return [] }

        let dayStart = calendar.startOfDay(for: day)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        var reasons: [DayTaskReason] = []

        // Overdue work belongs to today and to no other day. Repeating it on tomorrow and the day
        // after would make every future day look like a crisis before it has begun.
        if isToday, let deadline = facts.deadlineAt, calendar.startOfDay(for: deadline) < dayStart {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: deadline), to: dayStart
            ).day ?? 1
            reasons.append(.overdue(days: max(1, days)))
        } else if let deadline = facts.deadlineAt, calendar.isDate(deadline, inSameDayAs: day) {
            reasons.append(.due)
        }

        if let start = facts.startAt, calendar.isDate(start, inSameDayAs: day) {
            reasons.append(.starts)
        }

        if facts.isCommittedForExactly(day, calendar: calendar) {
            reasons.append(.committed)
        } else if isToday, facts.isCommittedToToday(on: now, calendar: calendar) {
            // Carried forward from an earlier day. Still today's work — that is what committing to a
            // day means — and still worth showing as such.
            reasons.append(.committed)
        }

        if let reminder = facts.reminderAt, calendar.isDate(reminder, inSameDayAs: day) {
            reasons.append(.reminder(at: reminder))
        }

        if facts.lifecycle == .waiting {
            if let followUp = facts.followUpAt, calendar.startOfDay(for: followUp) <= dayStart, isToday {
                reasons.append(.followUp(personName: nil))
            } else if let followUp = facts.followUpAt, calendar.isDate(followUp, inSameDayAs: day) {
                reasons.append(.followUp(personName: nil))
            }
        }

        if let meeting = meetingTaskIDs[facts.id] {
            reasons.append(.meetingPrep(eventID: meeting.id, eventTitle: meeting.title))
        }

        // A flag is a bookmark the user set, so it earns a place on today — but only today, and only
        // when nothing else already put the task there. A flag is not a date and must not behave
        // like one.
        if includesFlagged, isToday, reasons.isEmpty, facts.isFlagged,
           facts.availability(on: now, calendar: calendar).isAvailable {
            reasons.append(.flagged)
        }

        return reasons.sorted { $0.rank < $1.rank }
    }

    /// The moment a task claims in a chronological agenda, if it claims one.
    ///
    /// Only a *timed* reminder does. A deadline is a date, and drawing "finish the report by
    /// Thursday" as a nine-o'clock appointment is how an agenda starts lying about how full a day is
    /// — the same argument ``UpcomingReason/occupiesTime`` makes.
    public static func pinnedTime(for facts: TaskFacts, on day: Date, calendar: Calendar) -> Date? {
        guard facts.reminderIsTimed,
              let reminder = facts.reminderAt,
              calendar.isDate(reminder, inSameDayAs: day)
        else { return nil }
        return reminder
    }
}

// MARK: - Why a person is here today

/// Why somebody is on today's page.
///
/// People appear because the day put them there, never because they exist. This enum is the whole of
/// that promise: if nothing here is true of somebody, they are not shown.
public enum DayPersonReason: Sendable, Hashable {
    /// On the invitation to one of the day's meetings.
    case meeting(eventID: String, title: String, startAt: Date, isAllDay: Bool)

    /// A birthday, anniversary or milestone falling today or very soon.
    case celebration(UpcomingCelebration)

    /// You have not spoken in a while, and follow-up suggestions are switched on.
    case followUpDue(days: Int)

    /// A task on today's page is waiting on them.
    case waitingOn(taskID: UUID, title: String)

    /// A task on today's page is about them, or was promised to them.
    case taskAbout(taskID: UUID, title: String)

    /// Ordering, most consequential first: somebody you are about to sit down with outranks somebody
    /// you have not emailed in six weeks.
    public var rank: Int {
        switch self {
        case .meeting: 0
        case .celebration: 1
        case .waitingOn: 2
        case .taskAbout: 3
        case .followUpDue: 4
        }
    }

    public var symbolName: String {
        switch self {
        case .meeting: "person.2"
        case .celebration(let upcoming): upcoming.celebration.kind.symbolName
        case .followUpDue: "clock.arrow.circlepath"
        case .waitingOn: "hourglass"
        case .taskAbout: "checkmark.circle"
        }
    }

    /// The sentence that says why, in the user's terms.
    public func sentence(calendar: Calendar) -> String {
        switch self {
        case .meeting(_, let title, let startAt, let isAllDay):
            isAllDay
                ? "All day · \(title)"
                : "\(startAt.formatted(date: .omitted, time: .shortened)) · \(title)"

        case .celebration(let upcoming):
            if let years = upcoming.milestoneYears {
                "\(upcoming.celebration.kind.milestonePhrase(years: years)) \(upcoming.relativeText)"
            } else {
                "\(upcoming.celebration.displayTitle) \(upcoming.relativeText)"
            }

        case .followUpDue(let days):
            "No contact in \(days) days"

        case .waitingOn(_, let title):
            "Waiting on them: \(title)"

        case .taskAbout(_, let title):
            title
        }
    }
}

/// One person, once, with every reason the day has for showing them.
///
/// ### Why the reasons are a list
/// Because somebody who is in your ten o'clock, has a birthday today, and owes you an answer is one
/// person and one row. Showing them three times — in a meetings list, a celebrations list, and a
/// waiting list — is how a page stops being a briefing and becomes three reports stapled together.
public struct DayPerson: Sendable, Hashable, Identifiable {
    /// The library's record, when the person is in it.
    public var personID: UUID?

    /// Stable within a day, resolved or not.
    public var key: String

    public var name: String
    public var colorName: String?

    /// Role and organisation, when known — "Head of Design, Northwind".
    public var roleLine: String?

    public var reasons: [DayPersonReason]

    /// When you last actually spoke. Notes and tasks are not contact — see ``PersonContext``.
    public var lastContact: ContactMoment?

    /// Open work that mentions them, whether or not it is on today's page.
    public var openTaskIDs: [UUID]

    /// A few stated facts worth having in mind. Never inferred, never sensitive — the assembler
    /// filters those out before they reach here.
    public var quickFacts: [String]

    public var id: String { key }

    public init(
        personID: UUID? = nil,
        key: String,
        name: String,
        colorName: String? = nil,
        roleLine: String? = nil,
        reasons: [DayPersonReason] = [],
        lastContact: ContactMoment? = nil,
        openTaskIDs: [UUID] = [],
        quickFacts: [String] = []
    ) {
        self.personID = personID
        self.key = key
        self.name = name
        self.colorName = colorName
        self.roleLine = roleLine
        self.reasons = reasons.sorted { $0.rank < $1.rank }
        self.lastContact = lastContact
        self.openTaskIDs = openTaskIDs
        self.quickFacts = quickFacts
    }

    public var primaryReason: DayPersonReason? { reasons.first }

    public var isMeetingToday: Bool {
        reasons.contains { if case .meeting = $0 { return true } else { return false } }
    }

    public var celebration: UpcomingCelebration? {
        for reason in reasons {
            if case .celebration(let upcoming) = reason { return upcoming }
        }
        return nil
    }

    public var isKnown: Bool { personID != nil }
}

/// Collects people from every direction and hands back one entry each.
///
/// A builder rather than a function because the sources arrive separately — the calendar, the
/// celebrations calendar, the follow-up policy, the day's tasks — and merging them as they arrive is
/// what makes deduplication automatic rather than a step somebody has to remember.
public struct DayPeopleRoster: Sendable {
    private var byKey: [String: DayPerson] = [:]
    private var order: [String] = []

    public init() {}

    /// Adds a reason for somebody, merging into an existing entry when one is already present.
    ///
    /// Resolution wins: an attendee first seen as an unmatched address and later resolved to a
    /// library record is *one* person, and the resolved identity is the one that survives.
    public mutating func add(
        personID: UUID?,
        key: String,
        name: String,
        colorName: String? = nil,
        roleLine: String? = nil,
        reason: DayPersonReason,
        lastContact: ContactMoment? = nil,
        openTaskIDs: [UUID] = [],
        quickFacts: [String] = []
    ) {
        // Keyed by the library identifier wherever there is one, so the same person reached through
        // an invitation and through a task collapses into one entry.
        let identity = personID.map { "person:\($0.uuidString)" } ?? key

        if var existing = byKey[identity] {
            if !existing.reasons.contains(reason) {
                existing.reasons = (existing.reasons + [reason]).sorted { $0.rank < $1.rank }
            }
            if existing.personID == nil { existing.personID = personID }
            if existing.roleLine == nil { existing.roleLine = roleLine }
            if existing.colorName == nil { existing.colorName = colorName }
            if existing.lastContact == nil { existing.lastContact = lastContact }
            if existing.quickFacts.isEmpty { existing.quickFacts = quickFacts }
            existing.openTaskIDs = Array(Set(existing.openTaskIDs + openTaskIDs))
            byKey[identity] = existing
            return
        }

        byKey[identity] = DayPerson(
            personID: personID,
            key: identity,
            name: name,
            colorName: colorName,
            roleLine: roleLine,
            reasons: [reason],
            lastContact: lastContact,
            openTaskIDs: openTaskIDs,
            quickFacts: quickFacts
        )
        order.append(identity)
    }

    /// Everybody, most consequential first, then by the earliest meeting, then by name.
    public func people() -> [DayPerson] {
        order.compactMap { byKey[$0] }.sorted { left, right in
            let leftRank = left.primaryReason?.rank ?? Int.max
            let rightRank = right.primaryReason?.rank ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }

            switch (left.earliestMeeting, right.earliestMeeting) {
            case (let a?, let b?) where a != b: return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }

            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    public var isEmpty: Bool { byKey.isEmpty }
}

extension DayPerson {
    /// The start of the earliest meeting this person is in today, if any.
    var earliestMeeting: Date? {
        reasons.compactMap { reason -> Date? in
            if case .meeting(_, _, let startAt, _) = reason { return startAt }
            return nil
        }
        .min()
    }
}

// MARK: - The briefing

/// The next thing with a time on it.
public struct NextCommitment: Sendable, Hashable {
    public enum Subject: Sendable, Hashable {
        case event(id: String, kind: DayEventKind)
        case task(id: UUID)
    }

    public var subject: Subject
    public var title: String
    public var startAt: Date
    public var isInProgress: Bool

    public init(subject: Subject, title: String, startAt: Date, isInProgress: Bool = false) {
        self.subject = subject
        self.title = title
        self.startAt = startAt
        self.isInProgress = isInProgress
    }

    /// "in 20 minutes" · "now" · "at 14:00" once it is more than four hours off, where a countdown
    /// stops being a useful way to say it.
    public func relativeText(from now: Date) -> String {
        if isInProgress { return "now" }
        let interval = startAt.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        if interval > 4 * 3600 { return "at " + startAt.formatted(date: .omitted, time: .shortened) }
        return "in " + DurationPhrase.exact(interval)
    }
}

/// The few sentences at the top of a day.
///
/// ### Why these numbers and not others
/// Each one changes what somebody does next. "Three meetings" decides whether the afternoon is worth
/// planning; "two overdue" decides what happens first; "four hours free" decides what can be
/// attempted at all. A count of notes written this week decides nothing, which is why it is not here.
public struct DayBriefing: Sendable, Hashable {
    public var date: Date
    public var isToday: Bool

    public var overdueCount: Int
    public var taskCount: Int
    public var completedTaskCount: Int
    public var meetingCount: Int
    public var otherEventCount: Int
    public var focus: DayFocusTime
    public var next: NextCommitment?
    public var celebrations: [UpcomingCelebration]
    public var followUpCount: Int

    public init(
        date: Date,
        isToday: Bool,
        overdueCount: Int = 0,
        taskCount: Int = 0,
        completedTaskCount: Int = 0,
        meetingCount: Int = 0,
        otherEventCount: Int = 0,
        focus: DayFocusTime = DayFocusTime(),
        next: NextCommitment? = nil,
        celebrations: [UpcomingCelebration] = [],
        followUpCount: Int = 0
    ) {
        self.date = date
        self.isToday = isToday
        self.overdueCount = overdueCount
        self.taskCount = taskCount
        self.completedTaskCount = completedTaskCount
        self.meetingCount = meetingCount
        self.otherEventCount = otherEventCount
        self.focus = focus
        self.next = next
        self.celebrations = celebrations
        self.followUpCount = followUpCount
    }

    /// Whether the day has anything in it at all.
    public var isClear: Bool {
        overdueCount == 0 && taskCount == 0 && meetingCount == 0 && otherEventCount == 0
    }

    /// The salutation, which depends on the hour and on nothing else.
    ///
    /// Only ever shown for today. "Good morning" above Thursday of next week is a greeting addressed
    /// to nobody.
    public static func greeting(at now: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: now) {
        case 0..<5: "Still up"
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good evening"
        }
    }
}

/// The counted facts a briefing line is built from, and the order they are read in.
///
/// Kept as data rather than as a formatted string so the interface can drop the ones that do not fit
/// a narrow window without re-deriving what they said.
public struct BriefingFigure: Sendable, Hashable, Identifiable {
    public enum Tone: Sendable, Hashable {
        /// Genuinely late or genuinely wrong. The only tone entitled to red.
        case urgent
        /// Worth noticing today.
        case notable
        /// Ordinary.
        case plain
    }

    public var id: String
    public var value: String
    public var label: String
    public var symbolName: String
    public var tone: Tone

    public init(id: String, value: String, label: String, symbolName: String, tone: Tone = .plain) {
        self.id = id
        self.value = value
        self.label = label
        self.symbolName = symbolName
        self.tone = tone
    }
}

extension DayBriefing {
    /// The figures worth stating, most decision-changing first, with the empty ones dropped.
    public var figures: [BriefingFigure] {
        var figures: [BriefingFigure] = []

        if overdueCount > 0 {
            figures.append(
                BriefingFigure(
                    id: "overdue",
                    value: "\(overdueCount)",
                    label: overdueCount == 1 ? "overdue" : "overdue",
                    symbolName: "exclamationmark.circle",
                    tone: .urgent
                )
            )
        }

        if taskCount > 0 {
            figures.append(
                BriefingFigure(
                    id: "tasks",
                    value: "\(taskCount)",
                    label: taskCount == 1 ? "task" : "tasks",
                    symbolName: "checkmark.circle"
                )
            )
        }

        if meetingCount > 0 {
            figures.append(
                BriefingFigure(
                    id: "meetings",
                    value: "\(meetingCount)",
                    label: meetingCount == 1 ? "meeting" : "meetings",
                    symbolName: "person.2"
                )
            )
        }

        if focus.hasAny, !focus.isClosed {
            figures.append(
                BriefingFigure(
                    id: "focus",
                    value: DurationPhrase.rounded(focus.available),
                    label: "free",
                    symbolName: "shield.lefthalf.filled"
                )
            )
        }

        if !celebrations.isEmpty {
            let today = celebrations.filter { $0.daysAway == 0 }
            if !today.isEmpty {
                figures.append(
                    BriefingFigure(
                        id: "celebrations",
                        value: "\(today.count)",
                        label: today.count == 1 ? "celebration" : "celebrations",
                        symbolName: "birthday.cake",
                        tone: .notable
                    )
                )
            }
        }

        return figures
    }
}

// MARK: - A day, whole

/// One date's worth of everything.
///
/// The single value the interface renders. Assembling it in one place is what makes deduplication
/// possible at all: the people roster can only merge a meeting attendee with a task's subject if
/// something has seen both, and this is that something.
public struct DayPlan: Sendable, Identifiable {
    public var date: Date
    public var isToday: Bool
    public var isPast: Bool

    public var briefing: DayBriefing

    /// Everything from the calendar, in start order, all-day entries first.
    public var events: [DayEvent]

    /// Open work, most urgent first.
    public var tasks: [DayTask]

    /// Finished or abandoned on this day. Collapsed into a line by the interface.
    public var completedTaskIDs: [UUID]

    /// Everybody the day has a reason to show.
    public var people: [DayPerson]

    /// The day's own note, when one exists.
    public var dailyNoteID: UUID?
    public var dailyNoteExcerpt: String?

    public var id: Date { date }

    public init(
        date: Date,
        isToday: Bool,
        isPast: Bool = false,
        briefing: DayBriefing,
        events: [DayEvent] = [],
        tasks: [DayTask] = [],
        completedTaskIDs: [UUID] = [],
        people: [DayPerson] = [],
        dailyNoteID: UUID? = nil,
        dailyNoteExcerpt: String? = nil
    ) {
        self.date = date
        self.isToday = isToday
        self.isPast = isPast
        self.briefing = briefing
        self.events = events
        self.tasks = tasks
        self.completedTaskIDs = completedTaskIDs
        self.people = people
        self.dailyNoteID = dailyNoteID
        self.dailyNoteExcerpt = dailyNoteExcerpt
    }

    /// Entries that sit above the timeline: all-day, multi-day, away.
    public func allDayEvents(calendar: Calendar) -> [DayEvent] {
        events.filter { $0.event.occupiesAllDayRow(calendar: calendar) }
    }

    /// Entries with a place on the clock, in order.
    public func timedEvents(calendar: Calendar) -> [DayEvent] {
        events
            .filter { !$0.event.occupiesAllDayRow(calendar: calendar) }
            .sorted { $0.event.startAt < $1.event.startAt }
    }

    /// The work that genuinely needs attention, as opposed to what is merely available today.
    public var needsAttention: [DayTask] {
        tasks.filter(\.needsAttention)
    }

    /// Work with no time of its own — which is most work.
    public var untimedTasks: [DayTask] {
        tasks.filter { $0.pinnedAt == nil }
    }

    public var isEmpty: Bool {
        events.isEmpty && tasks.isEmpty && people.isEmpty && completedTaskIDs.isEmpty
    }

    /// Whether the day is worth drawing at all in a compact future strip.
    public var hasContent: Bool {
        !events.isEmpty || !tasks.isEmpty
    }
}

// MARK: - What the reader has chosen to see

/// Which of a day's three subjects are on screen, and how they are arranged.
///
/// ### Why this is small
/// Every switch here is one somebody has a real reason to want: a person who does not use the
/// calendar wants their meetings gone, a person mid-week does not want to re-read what they already
/// finished. What is deliberately absent is a control for everything that *could* be configured —
/// the page has one good arrangement, and offering ten before showing any value is how a planner
/// becomes a settings screen with a date on it.
public struct TodayFilters: Sendable, Hashable, Codable {
    public var showsTasks: Bool
    public var showsMeetings: Bool
    public var showsPeople: Bool
    public var showsDailyNote: Bool
    public var showsCompleted: Bool

    /// Whether timed work and meetings share one clock-ordered list, or sit in their own sections.
    ///
    /// The integrated agenda is the default because it is the honest answer to "what happens next".
    /// The grouped arrangement exists because some people plan by category, and telling them they
    /// are wrong is not a feature.
    public var usesIntegratedAgenda: Bool

    /// Calendars the reader has muted here specifically, by identifier.
    ///
    /// Separate from the calendar module's own visibility, and deliberately: hiding the family
    /// calendar while planning a work day should not hide it in the calendar itself, where somebody
    /// went specifically to look at it.
    public var hiddenCalendarIdentifiers: Set<String>

    /// Projects and lists whose work is hidden here, by identifier.
    public var hiddenContainerIDs: Set<UUID>

    public init(
        showsTasks: Bool = true,
        showsMeetings: Bool = true,
        showsPeople: Bool = true,
        showsDailyNote: Bool = true,
        showsCompleted: Bool = true,
        usesIntegratedAgenda: Bool = true,
        hiddenCalendarIdentifiers: Set<String> = [],
        hiddenContainerIDs: Set<UUID> = []
    ) {
        self.showsTasks = showsTasks
        self.showsMeetings = showsMeetings
        self.showsPeople = showsPeople
        self.showsDailyNote = showsDailyNote
        self.showsCompleted = showsCompleted
        self.usesIntegratedAgenda = usesIntegratedAgenda
        self.hiddenCalendarIdentifiers = hiddenCalendarIdentifiers
        self.hiddenContainerIDs = hiddenContainerIDs
    }

    public static let standard = TodayFilters()

    /// Whether anything at all has been switched off, so the interface can say so rather than
    /// letting somebody wonder where their meetings went.
    public var isFiltering: Bool {
        !showsTasks || !showsMeetings || !showsPeople || !showsCompleted
            || !hiddenCalendarIdentifiers.isEmpty || !hiddenContainerIDs.isEmpty
    }

    public var summary: String? {
        guard isFiltering else { return nil }
        var hidden: [String] = []
        if !showsTasks { hidden.append("tasks") }
        if !showsMeetings { hidden.append("meetings") }
        if !showsPeople { hidden.append("people") }
        if !hiddenCalendarIdentifiers.isEmpty {
            let count = hiddenCalendarIdentifiers.count
            hidden.append(count == 1 ? "1 calendar" : "\(count) calendars")
        }
        if !hiddenContainerIDs.isEmpty {
            let count = hiddenContainerIDs.count
            hidden.append(count == 1 ? "1 project" : "\(count) projects")
        }
        guard !hidden.isEmpty else { return nil }
        return "Hiding " + ListPhrase.joined(hidden)
    }
}

/// Lists said the way somebody would say them.
public enum ListPhrase {
    public static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: parts[0] + " and " + parts[1]
        default: parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
    }
}

// MARK: - The chronological agenda

/// One line of a day read against the clock.
public enum DayAgendaSlot: Sendable, Identifiable {
    case event(DayEvent)
    case task(DayTask, at: Date)

    public var id: String {
        switch self {
        case .event(let event): "event:\(event.id)"
        case .task(let task, _): "task:\(task.taskID.uuidString)"
        }
    }

    public var startAt: Date {
        switch self {
        case .event(let event): event.event.startAt
        case .task(_, let at): at
        }
    }
}

public enum DayAgenda {
    /// Timed events and timed tasks, interleaved in clock order.
    ///
    /// ### Why tasks are here at all
    /// Because a reminder set for four o'clock competes for four o'clock, and a plan that shows the
    /// meetings but not the reminder is a plan that will be wrong at four o'clock. What is **not**
    /// here is every other task: work without a time does not belong on a timeline, and stretching
    /// it across one would tell the reader a day is full when it is merely long.
    public static func slots(for plan: DayPlan, calendar: Calendar) -> [DayAgendaSlot] {
        var slots: [DayAgendaSlot] = plan.timedEvents(calendar: calendar).map(DayAgendaSlot.event)

        for task in plan.tasks {
            guard let pinnedAt = task.pinnedAt else { continue }
            slots.append(.task(task, at: pinnedAt))
        }

        return slots.sorted { left, right in
            if left.startAt != right.startAt { return left.startAt < right.startAt }
            // An event and a task at the same minute: the event first, because it is the one with a
            // room and other people in it.
            switch (left, right) {
            case (.event, .task): return true
            case (.task, .event): return false
            default: return left.id < right.id
            }
        }
    }

    /// Where the "now" line goes: the index the marker is drawn *before*, or `nil` when the day is
    /// not today or the day is over.
    public static func nowMarkerIndex(in slots: [DayAgendaSlot], now: Date, isToday: Bool) -> Int? {
        guard isToday else { return nil }
        guard let index = slots.firstIndex(where: { $0.startAt > now }) else { return nil }
        return index
    }
}
