import Foundation

/// How a time entry came to exist.
///
/// Kept because it changes what the app may do with an entry. A timer entry can be recovered after a
/// crash; a manual one cannot be, because there is nothing to recover — the user typed it.
public enum TimeEntrySource: String, Codable, Sendable, Hashable, CaseIterable {
    /// Started and stopped with the timer.
    case timer

    /// Typed in after the fact.
    case manual

    /// Brought in from another tool.
    case imported

    public var displayName: String {
        switch self {
        case .timer: "Timer"
        case .manual: "Added by hand"
        case .imported: "Imported"
        }
    }
}

/// Somebody a stretch of time was spent with.
///
/// A pair rather than an `Item`, for the reason every other value here is one: a view holds this
/// while drawing and a `PersistentModel` cannot safely be held across a store change. The name is
/// carried alongside the id so a row can be written without a second fetch per person.
public struct TimeParticipant: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A running timer, as a value.
///
/// The menu bar, the toolbar, and the detail pane all need to know what is running and for how long.
/// Passing a snapshot rather than the model object means none of them holds a `PersistentModel`, and
/// the elapsed time can be recomputed on a tick without touching the store at all.
public struct RunningTimer: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var entryDescription: String

    /// What the timer is against, if anything.
    public var itemID: UUID?
    public var itemTitle: String?
    public var itemKind: ItemKind?

    /// The project this is billed to when the subject's own parent chain is not the answer.
    ///
    /// Usually `nil`, and usually right to be: an entry against a task belongs to that task's
    /// project, which is what makes *time by project* answerable without filing anything twice. This
    /// exists for the case that derivation cannot reach — a note, a meeting, or nothing at all,
    /// worked on for a project it does not sit inside.
    public var projectID: UUID?
    public var projectTitle: String?

    /// Who the time was spent with.
    public var people: [TimeParticipant]

    public var tagSlugs: [String]
    public var isBillable: Bool

    public init(
        id: UUID,
        startedAt: Date,
        entryDescription: String = "",
        itemID: UUID? = nil,
        itemTitle: String? = nil,
        itemKind: ItemKind? = nil,
        projectID: UUID? = nil,
        projectTitle: String? = nil,
        people: [TimeParticipant] = [],
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.entryDescription = entryDescription
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.itemKind = itemKind
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.people = people
        self.tagSlugs = tagSlugs
        self.isBillable = isBillable
    }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// What to call this timer in the menu bar.
    ///
    /// The item's title wins over the typed description: if a timer is running against *Draft the
    /// brief*, that is what it is, and the description is a note about this particular stretch of it.
    public var displayTitle: String {
        if let itemTitle, !itemTitle.isEmpty { return itemTitle }
        if !entryDescription.isEmpty { return entryDescription }
        return "Untitled"
    }
}

/// A stretch somebody stopped meaning to carry on with.
///
/// ### Why pausing is not a third state of the timer
/// Because a time entry is a *span* — a start and an end — and a paused span is not one span with a
/// hole in it. It is two spans with a gap between them. Modelling pause any other way means either
/// storing an entry whose recorded length disagrees with its own clock times, or subtracting the gap
/// afterwards from a number nobody can check.
///
/// So pausing stops the entry and keeps this: what it was, and how much has been worked so far.
/// Resuming starts a fresh entry with the same filing. Two rows, which the log then collapses back
/// into one — the grouping that already exists for exactly this shape of day, eight goes at one
/// task. The clock in the floating timer keeps counting from ``accumulated`` so the *person* sees
/// one continuous stretch, while the store keeps the two honest halves it actually observed.
public struct PausedTimer: Sendable, Hashable, Identifiable {
    /// The entry that was stopped, so it can be continued with everything it was filed under.
    public var id: UUID

    public var displayTitle: String

    /// How much has been worked across every stretch of this sitting, before the current pause.
    public var accumulated: TimeInterval

    public init(id: UUID, displayTitle: String, accumulated: TimeInterval) {
        self.id = id
        self.displayTitle = displayTitle
        self.accumulated = accumulated
    }
}

/// A stretch of tracked time, as a value.
public struct TimeEntrySnapshot: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var entryDescription: String
    public var isBillable: Bool
    public var source: TimeEntrySource
    public var itemID: UUID?
    public var itemTitle: String?
    public var itemKind: ItemKind?
    public var projectID: UUID?
    public var projectTitle: String?

    /// Whether the project was chosen by the user rather than walked up to from the subject.
    ///
    /// ### Why an editor needs to know
    /// Because filling a project chip from a *derived* answer and then saving would pin it. An entry
    /// against a task that was silently pinned to that task's project stops following the task if it
    /// is ever moved — and it would happen to every entry anybody so much as corrects a typo on.
    public var isProjectExplicit: Bool

    public var tagSlugs: [String]

    /// Who this stretch was spent with.
    ///
    /// Empty for solo work, which is most of it. What earns the field is that *"how much of my week
    /// went on other people"* is not derivable from anything else here: the subject of an hour spent
    /// pairing is the task, not the person, and tagging every such entry `with-sarah` by hand is the
    /// friction that stops anybody answering the question at all.
    public var people: [TimeParticipant]

    /// How many finished pomodoros this stretch contains. Zero unless it was run as focus rounds.
    public var focusRounds: Int

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        entryDescription: String = "",
        isBillable: Bool = false,
        source: TimeEntrySource = .timer,
        itemID: UUID? = nil,
        itemTitle: String? = nil,
        itemKind: ItemKind? = nil,
        projectID: UUID? = nil,
        projectTitle: String? = nil,
        isProjectExplicit: Bool = false,
        tagSlugs: [String] = [],
        people: [TimeParticipant] = [],
        focusRounds: Int = 0
    ) {
        self.isProjectExplicit = isProjectExplicit
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.entryDescription = entryDescription
        self.isBillable = isBillable
        self.source = source
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.itemKind = itemKind
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.tagSlugs = tagSlugs
        self.people = people
        self.focusRounds = focusRounds
    }

    public var isRunning: Bool { endedAt == nil }

    /// Duration, measured to `now` while still running.
    public func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public var displayTitle: String {
        if let itemTitle, !itemTitle.isEmpty { return itemTitle }
        if !entryDescription.isEmpty { return entryDescription }
        return "Untitled"
    }
}

// MARK: - Formatting

/// How durations are written, in one place.
///
/// Two forms, and the distinction matters. A running timer counts in seconds because a clock that
/// does not move looks broken. A total does not: nobody wants to read "7:32:09" as a day's work, and
/// the seconds are noise at that scale.
public enum TimeFormatting {
    /// `1:04:09` — for a running timer.
    public static func stopwatch(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if hours > 0 {
            return "\(hours):\(DayKey.padded(minutes)):\(DayKey.padded(seconds))"
        }
        return "\(minutes):\(DayKey.padded(seconds))"
    }

    /// `0:04:09` — for a field you can type into.
    ///
    /// Always carries the hours, unlike ``stopwatch(_:)``, because this is what a duration field
    /// shows *and* what it accepts back: a field that reads `4:09` and parses its own contents as
    /// four hours nine minutes is a field that lengthens an entry every time it is focused.
    /// ``DurationParser`` reads a colon as `h:mm`, so the written form must never omit the hours.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
        return "\(total / 3_600):\(DayKey.padded((total % 3_600) / 60)):\(DayKey.padded(total % 60))"
    }

    /// `1:04` — for a total. Hours and minutes only.
    public static func short(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((max(0, interval) / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours):\(DayKey.padded(minutes))"
    }

    /// `1h 04m`, or `4m` under an hour — for a summary line that is read rather than scanned.
    public static func spelled(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((max(0, interval) / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(DayKey.padded(minutes))m"
    }

    /// Decimal hours — `1.07` — which is what invoices and spreadsheets want.
    public static func decimalHours(_ interval: TimeInterval) -> String {
        let hours = max(0, interval) / 3_600
        let rounded = (hours * 100).rounded() / 100
        let whole = Int(rounded)
        let hundredths = Int(((rounded - Double(whole)) * 100).rounded())
        return "\(whole).\(DayKey.padded(hundredths))"
    }
}

// MARK: - Reports

/// One row of a time report.
public struct TimeSummaryRow: Sendable, Hashable, Identifiable {
    /// What this row is about — a day, an item, a project, or a tag.
    public var key: String
    public var title: String
    public var total: TimeInterval
    public var billable: TimeInterval
    public var entryCount: Int

    /// The item this row rolls up, when it has one, so a row can be clicked through.
    public var itemID: UUID?

    public var id: String { key }

    public init(
        key: String,
        title: String,
        total: TimeInterval,
        billable: TimeInterval = 0,
        entryCount: Int = 0,
        itemID: UUID? = nil
    ) {
        self.key = key
        self.title = title
        self.total = total
        self.billable = billable
        self.entryCount = entryCount
        self.itemID = itemID
    }
}

/// A whole report: the rows, and what they add up to.
public struct TimeReport: Sendable, Hashable {
    public var rows: [TimeSummaryRow]
    public var total: TimeInterval
    public var billable: TimeInterval
    public var entryCount: Int

    /// The window this covers, so a report can say what it is a report *of*.
    public var range: Range<Date>

    public init(
        rows: [TimeSummaryRow],
        total: TimeInterval,
        billable: TimeInterval,
        entryCount: Int,
        range: Range<Date>
    ) {
        self.rows = rows
        self.total = total
        self.billable = billable
        self.entryCount = entryCount
        self.range = range
    }

    public static func empty(range: Range<Date>) -> TimeReport {
        TimeReport(rows: [], total: 0, billable: 0, entryCount: 0, range: range)
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// The largest row, so a bar chart can scale to it.
    public var peak: TimeInterval {
        rows.map(\.total).max() ?? 0
    }
}

/// How a report groups its rows.
public enum TimeGrouping: String, Sendable, Hashable, CaseIterable {
    case day
    case item
    case project
    case tag
    case person
    case kind

    public var displayName: String {
        switch self {
        case .day: "Day"
        case .item: "Item"
        case .project: "Project"
        case .tag: "Tag"
        case .person: "Person"
        case .kind: "Type"
        }
    }

    public var symbolName: String {
        switch self {
        case .day: "calendar.day.timeline.left"
        case .item: "doc.text"
        case .project: "square.stack.3d.up"
        case .tag: "number"
        case .person: "person.2"
        case .kind: "square.grid.2x2"
        }
    }

    /// What the grouping does, for a tooltip. A rule, never a restatement of the name.
    public var hint: String {
        switch self {
        case .day: "One row per day, in the order the days happened."
        case .item: "One row per thing you tracked against."
        case .project: "Rolled up to the project each item belongs to."
        case .tag: "Rolled up by tag, so one entry can count towards several."
        case .person: "Rolled up by who you were with, so an hour with two people counts under both."
        case .kind: "Rolled up by what the time was against — a task, a meeting, a conversation."
        }
    }

    /// Whether one entry can appear in more than one row of this grouping.
    ///
    /// True for tags and people, and the consequence is the same for both: the rows sum to more than
    /// the report's own total, which is correct — *how much time carried this tag* is a different
    /// question from *how much time was there* — and is why ``TimeReport/total`` is computed
    /// independently of the rows rather than by adding them up. Surfaced here so a view can say so
    /// rather than leaving somebody to find it in a total that does not add.
    public var rowsCanOverlap: Bool {
        switch self {
        case .tag, .person: true
        case .day, .item, .project, .kind: false
        }
    }
}

// MARK: - Rounding

/// How a report rounds the time it reports.
///
/// ### Why nothing here touches the store
/// Rounding is a *presentation* of tracked time, never a rewrite of it. An entry that ran for
/// fifty-one minutes ran for fifty-one minutes, and a store that quietly held fifty-four because
/// somebody once invoiced in six-minute units has lost the only number that could ever settle a
/// dispute. So this applies at the edge — to a report row, an export column, a copied total — and
/// ``TimeEntry`` never sees it.
///
/// The increments are the ones billing actually uses: six minutes is a tenth of an hour, fifteen is
/// a quarter, and both round *up*, because that is what the convention means and a rounding that
/// sometimes went down would not be that convention under a different name.
public enum TimeRounding: String, Sendable, Hashable, CaseIterable, Codable {
    /// No rounding at all. The default, and right for anybody not invoicing.
    case exact

    /// To the nearest minute — tidies the seconds off without changing anything material.
    case nearestMinute

    /// Up to the next five minutes.
    case upFiveMinutes

    /// Up to the next six minutes — a tenth of an hour, the commonest professional unit.
    case upSixMinutes

    /// Up to the next fifteen minutes — a quarter hour.
    case upFifteenMinutes

    /// Up to the next thirty minutes.
    case upThirtyMinutes

    public var displayName: String {
        switch self {
        case .exact: "Exact"
        case .nearestMinute: "Nearest minute"
        case .upFiveMinutes: "Up to 5 minutes"
        case .upSixMinutes: "Up to 6 minutes (0.1 h)"
        case .upFifteenMinutes: "Up to 15 minutes (0.25 h)"
        case .upThirtyMinutes: "Up to 30 minutes"
        }
    }

    /// The unit rounded to, or `nil` when nothing is rounded.
    public var increment: TimeInterval? {
        switch self {
        case .exact: nil
        case .nearestMinute: 60
        case .upFiveMinutes: 5 * 60
        case .upSixMinutes: 6 * 60
        case .upFifteenMinutes: 15 * 60
        case .upThirtyMinutes: 30 * 60
        }
    }

    public var roundsUp: Bool { self != .nearestMinute && self != .exact }

    /// Rounds one duration.
    ///
    /// Zero stays zero under every rule, including the ones that round up: a row with no time in it
    /// must not acquire six minutes, or a report of an empty day would bill for an hour.
    public func apply(_ interval: TimeInterval) -> TimeInterval {
        guard let increment, interval > 0 else { return max(0, interval) }
        let units = interval / increment
        return (roundsUp ? units.rounded(.up) : units.rounded()) * increment
    }
}

// MARK: - Recovery

/// What the app found when it opened and a timer was still running.
///
/// A value rather than a decision. The app never resolves one of these on its own — see
/// ``TimerRecoveryChoice``.
public struct TimerRecovery: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var entryDescription: String
    public var itemTitle: String?
    public var startedAt: Date

    /// The last moment the app is sure the timer was genuinely running.
    ///
    /// This is what "stop it there" means, and it is the whole reason a heartbeat exists: without
    /// one, the only honest options would be "keep the whole gap" or "throw it away".
    public var lastHeartbeatAt: Date

    /// How long the app was not running — the part nobody can vouch for.
    public var unaccountedFor: TimeInterval

    public init(
        id: UUID,
        entryDescription: String,
        itemTitle: String?,
        startedAt: Date,
        lastHeartbeatAt: Date,
        unaccountedFor: TimeInterval
    ) {
        self.id = id
        self.entryDescription = entryDescription
        self.itemTitle = itemTitle
        self.startedAt = startedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.unaccountedFor = unaccountedFor
    }

    public var displayTitle: String {
        if let itemTitle, !itemTitle.isEmpty { return itemTitle }
        if !entryDescription.isEmpty { return entryDescription }
        return "an untitled timer"
    }

    /// How long the entry would be if stopped at the last heartbeat.
    public var confirmedDuration: TimeInterval {
        max(0, lastHeartbeatAt.timeIntervalSince(startedAt))
    }
}

/// The three things a user may do about a recovered timer.
///
/// Three, and no default. Each destroys something different — time, accuracy, or a record — and
/// which of those matters is not a thing the app can know.
public enum TimerRecoveryChoice: String, Sendable, Hashable, CaseIterable {
    /// Close it at the last heartbeat. Keeps the time the app can vouch for.
    case stopAtLastActivity

    /// Leave it running. Correct when the work genuinely continued.
    case keepRunning

    /// Delete the entry. Correct when the timer was left on by mistake.
    case discard

    public var displayName: String {
        switch self {
        case .stopAtLastActivity: "Stop at last activity"
        case .keepRunning: "Keep running"
        case .discard: "Discard"
        }
    }
}
