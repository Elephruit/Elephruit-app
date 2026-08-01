import Foundation

/// Several entries the log shows as one row.
///
/// ### Why entries collapse
/// Tracking the same thing in bursts is the normal shape of a working day: eight goes at *Draft the
/// brief*, interrupted seven times. Listed one per row, that day is a wall of near-identical lines
/// and the one thing you wanted from it — how long the brief actually took — has to be added up by
/// eye. Collapsed, it is a single row reading `Draft the brief · 8 · 3:41`, and the individual
/// stretches are still there when you open it.
///
/// Nothing is merged in the store. A group is a *view* of entries that remain separate rows, which
/// is what lets one of them be corrected without disturbing the other seven.
public struct TimeEntryGroup: Sendable, Hashable, Identifiable {
    /// Stable across reloads, because it is built from what made these entries alike rather than
    /// from their positions. A row that keeps its identity is a row that stays open when the list
    /// behind it reloads.
    public let id: String

    /// The entries, newest first — the order the log reads in.
    public let entries: [TimeEntrySnapshot]

    public let total: TimeInterval
    public let billable: TimeInterval

    public init(id: String, entries: [TimeEntrySnapshot], total: TimeInterval, billable: TimeInterval) {
        self.id = id
        self.entries = entries
        self.total = total
        self.billable = billable
    }

    public var count: Int { entries.count }

    /// Whether this is one entry rather than several, which is what decides if a row can expand.
    public var isSingle: Bool { entries.count == 1 }

    /// The entry whose fields stand for the whole group.
    ///
    /// The newest, so *Continue* continues the most recent stretch and an edit to the group's shared
    /// fields starts from the values most recently in use. Never optional in practice — a group with
    /// no entries is not constructed — but this type cannot promise that, so it falls back rather
    /// than force-unwrapping.
    public var lead: TimeEntrySnapshot? { entries.first }

    /// A group containing the running timer, which is never more than one entry.
    public var isRunning: Bool { entries.contains(where: \.isRunning) }

    /// When the earliest stretch began and the latest one ended — what the row's `9:04 – 11:32`
    /// covers. `nil` while anything in the group is still running.
    public var startedAt: Date? { entries.map(\.startedAt).min() }

    public var endedAt: Date? {
        guard !isRunning else { return nil }
        return entries.compactMap(\.endedAt).max()
    }

    public var displayTitle: String { lead?.displayTitle ?? "Untitled" }
}

/// One day of the log, and what it came to.
public struct TimeDaySection: Sendable, Hashable, Identifiable {
    /// `yyyy-MM-dd`, so sections sort chronologically by sorting lexicographically.
    public let dayKey: String

    /// What the header says — `Today`, `Yesterday`, or the date.
    public let title: String

    public let startOfDay: Date
    public let groups: [TimeEntryGroup]
    public let total: TimeInterval
    public let billable: TimeInterval

    /// Individual entries, not groups: the number the header reports is how much was tracked, not
    /// how many rows the grouping happened to produce.
    public let entryCount: Int

    public var id: String { dayKey }

    public init(
        dayKey: String,
        title: String,
        startOfDay: Date,
        groups: [TimeEntryGroup],
        total: TimeInterval,
        billable: TimeInterval,
        entryCount: Int
    ) {
        self.dayKey = dayKey
        self.title = title
        self.startOfDay = startOfDay
        self.groups = groups
        self.total = total
        self.billable = billable
        self.entryCount = entryCount
    }
}

/// Turns entries into the log the Time view shows.
///
/// ### Why this is not `TimeReporting`
/// Both put time into days and both are pure, and they disagree on purpose about what a day is.
///
/// `TimeReporting` **splits** an entry that crosses midnight: a session from 23:00 to 01:00 is an
/// hour on each day, because a chart of daily totals that credited both hours to Tuesday would lie
/// about Monday night.
///
/// The log **does not**. An entry belongs to the day it *started*, whole, and appears exactly once.
/// A list is a list of things you did, and a stretch of work shown twice — half on one row, half on
/// another, neither matching the clock times printed beside it — is a list nobody can correct from.
/// The day header therefore sums whole entries and can exceed twenty-four hours in the rare case
/// somebody works through one; that is the honest reading of "what I started on Monday".
///
/// Keeping both is the point. Asking *how much time went on Tuesday* and asking *what did I do on
/// Tuesday* are different questions, and one answer cannot serve both without being wrong for one.
public enum TimeLog {
    /// Builds the log.
    ///
    /// - Parameters:
    ///   - entries: everything to show, in any order.
    ///   - groupSimilar: whether alike entries collapse into one row. Off gives a strict
    ///     one-row-per-entry log, which is what someone reconstructing an exact sequence wants.
    ///   - now: how a still-running entry is measured.
    public static func sections(
        entries: [TimeEntrySnapshot],
        groupSimilar: Bool,
        calendar: Calendar,
        now: Date
    ) -> [TimeDaySection] {
        guard !entries.isEmpty else { return [] }

        var byDay: [String: [TimeEntrySnapshot]] = [:]
        var startOfDayByKey: [String: Date] = [:]

        for entry in entries {
            let startOfDay = calendar.startOfDay(for: entry.startedAt)
            let components = calendar.dateComponents([.year, .month, .day], from: startOfDay)
            let key = DayKey.string(
                year: components.year ?? 0,
                month: components.month ?? 0,
                day: components.day ?? 0
            )
            byDay[key, default: []].append(entry)
            startOfDayByKey[key] = startOfDay
        }

        return byDay.keys.sorted(by: >).compactMap { key in
            guard let dayEntries = byDay[key], let startOfDay = startOfDayByKey[key] else { return nil }

            let groups = group(dayEntries, groupSimilar: groupSimilar, dayKey: key, now: now)

            return TimeDaySection(
                dayKey: key,
                title: title(for: startOfDay, calendar: calendar, now: now),
                startOfDay: startOfDay,
                groups: groups,
                total: groups.reduce(0) { $0 + $1.total },
                billable: groups.reduce(0) { $0 + $1.billable },
                entryCount: dayEntries.count
            )
        }
    }

    // MARK: - Grouping

    private static func group(
        _ entries: [TimeEntrySnapshot],
        groupSimilar: Bool,
        dayKey: String,
        now: Date
    ) -> [TimeEntryGroup] {
        // Newest first before grouping, so each group's `lead` is its most recent stretch and the
        // groups themselves come out in the order their newest member started.
        let ordered = entries.sorted { $0.startedAt > $1.startedAt }

        var groups: [TimeEntryGroup] = []
        var indexByKey: [String: Int] = [:]

        for entry in ordered {
            let key = groupSimilar ? similarityKey(for: entry, dayKey: dayKey) : entry.id.uuidString
            let duration = entry.duration(at: now)

            if let index = indexByKey[key] {
                let existing = groups[index]
                groups[index] = TimeEntryGroup(
                    id: existing.id,
                    entries: existing.entries + [entry],
                    total: existing.total + duration,
                    billable: existing.billable + (entry.isBillable ? duration : 0)
                )
            } else {
                indexByKey[key] = groups.count
                groups.append(TimeEntryGroup(
                    id: key,
                    entries: [entry],
                    total: duration,
                    billable: entry.isBillable ? duration : 0
                ))
            }
        }

        return groups
    }

    /// What makes two entries the same thing done twice.
    ///
    /// Description, subject, tags and billability — every field a row displays. That is the test the
    /// key has to pass: two rows that collapse into one must be indistinguishable on screen, or the
    /// collapse looks like data going missing. Which is also why the *source* is excluded from the
    /// key but shown on the row only when it is not the timer: an hour typed in by hand and an hour
    /// timed are the same hour of the same work.
    ///
    /// The running entry is keyed by its own identity so it never collapses into anything. Its
    /// duration is still moving, and a row whose total is partly live and partly settled cannot say
    /// what it means.
    ///
    /// The day key is part of this because grouping happens within a day and never across one — the
    /// same task on Monday and Tuesday is two rows, in two sections, as it should be.
    private static func similarityKey(for entry: TimeEntrySnapshot, dayKey: String) -> String {
        guard !entry.isRunning else { return "\u{1}running-\(entry.id.uuidString)" }

        // A unit separator between fields, so a description ending in the text of an item's ID
        // cannot collide with an entry that genuinely has one.
        let fields = [
            dayKey,
            entry.entryDescription,
            entry.itemID?.uuidString ?? "",
            entry.tagSlugs.sorted().joined(separator: ","),
            entry.isBillable ? "billable" : "",
        ]
        return fields.joined(separator: "\u{1f}")
    }

    // MARK: - Titles

    /// `Today`, `Yesterday`, or the date.
    ///
    /// Named days rather than dates for the two that have names, because the log is read from the
    /// top and those are the two sections anyone is actually looking at. The rest are dated, since
    /// "three days ago" is a phrase you have to do arithmetic on.
    static func title(for startOfDay: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(startOfDay, inSameDayAs: now) { return "Today" }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(startOfDay, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        // Weekday included: within the last week or so it is the part that locates the day, and it
        // costs nothing on an older one.
        return startOfDay.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
