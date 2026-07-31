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

    public var tagSlugs: [String]
    public var isBillable: Bool

    public init(
        id: UUID,
        startedAt: Date,
        entryDescription: String = "",
        itemID: UUID? = nil,
        itemTitle: String? = nil,
        itemKind: ItemKind? = nil,
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.entryDescription = entryDescription
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.itemKind = itemKind
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
    public var tagSlugs: [String]

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
        tagSlugs: [String] = []
    ) {
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

    public var displayName: String {
        switch self {
        case .day: "Day"
        case .item: "Item"
        case .project: "Project"
        case .tag: "Tag"
        }
    }

    public var symbolName: String {
        switch self {
        case .day: "calendar.day.timeline.left"
        case .item: "doc.text"
        case .project: "square.stack.3d.up"
        case .tag: "number"
        }
    }

    /// What the grouping does, for a tooltip. A rule, never a restatement of the name.
    public var hint: String {
        switch self {
        case .day: "One row per day, in the order the days happened."
        case .item: "One row per thing you tracked against."
        case .project: "Rolled up to the project each item belongs to."
        case .tag: "Rolled up by tag, so one entry can count towards several."
        }
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
