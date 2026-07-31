import ElephruitCore
import Foundation
import SwiftData

/// What the task-date migration did, or would do.
///
/// Produced by both the dry run and the real thing, on the same terms as ``MigrationReport``, so the
/// outcome can be read before it is committed to.
public struct TaskDateMigrationReport: Codable, Sendable, Hashable {
    /// A legacy defer date folded into the start date. Lossless — the two mean the same thing.
    public struct Fold: Codable, Sendable, Hashable {
        public var itemID: UUID
        public var itemTitle: String
        public var date: Date

        public init(itemID: UUID, itemTitle: String, date: Date) {
            self.itemID = itemID
            self.itemTitle = itemTitle
            self.date = date
        }
    }

    /// A date left exactly where it was, with a marker asking the user to look at it.
    public struct Flag: Codable, Sendable, Hashable {
        public var itemID: UUID
        public var itemTitle: String
        public var reason: DateReviewReason

        public init(itemID: UUID, itemTitle: String, reason: DateReviewReason) {
            self.itemID = itemID
            self.itemTitle = itemTitle
            self.reason = reason
        }
    }

    public var isDryRun: Bool
    public var tasksExamined: Int
    public var folds: [Fold]
    public var flags: [Flag]

    public init(
        isDryRun: Bool,
        tasksExamined: Int = 0,
        folds: [Fold] = [],
        flags: [Flag] = []
    ) {
        self.isDryRun = isDryRun
        self.tasksExamined = tasksExamined
        self.folds = folds
        self.flags = flags
    }

    public var hasWork: Bool { !folds.isEmpty || !flags.isEmpty }

    public var summary: String {
        var lines: [String] = []
        lines.append(isDryRun ? "Dry run — nothing was written." : "Dates brought up to date.")
        lines.append("Examined \(tasksExamined) task\(tasksExamined == 1 ? "" : "s").")

        if folds.isEmpty {
            lines.append("No start dates needed moving.")
        } else {
            lines.append("Moved \(folds.count) hold-until date\(folds.count == 1 ? "" : "s") to Start.")
        }

        if !flags.isEmpty {
            lines.append("Marked \(flags.count) task\(flags.count == 1 ? "" : "s") for you to check:")
            for flag in flags.prefix(20) {
                lines.append("  · “\(flag.itemTitle)” — \(flag.reason.summary)")
            }
            if flags.count > 20 {
                lines.append("  · …and \(flags.count - 20) more.")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Brings a library written before the scheduling model onto it.
///
/// ### The posture: convert what is certain, flag what is not, change nothing else
/// Before this slice a task had `dueAt`, `startAt`, and `deferUntil`, and no reminder field at all.
/// Two of those three map onto the new model without a guess:
///
/// - **`deferUntil` is the start date.** It already meant "hidden until this date" and was never
///   able to make anything overdue, which is exactly what availability is. Folding it into `startAt`
///   loses nothing, so it is done without asking.
/// - **`dueAt` is the deadline.** It is the only date that ever produced overdue behaviour, and the
///   capture grammar has documented `due:` as a deadline since it was written.
///
/// What is *not* certain is the third case: a `dueAt` carrying a time of day. Before reminders
/// existed as a field, a time on a deadline was the only way to express "at five o'clock", so it may
/// have meant "finish by 5pm" or "tell me at 5pm". Those are different requests and there is no way
/// to tell them apart from the data.
///
/// **So it converts nothing there.** The value stays where it is, as a deadline, and the task is
/// marked so the interface can offer the choice with the task in front of the user. A migration that
/// guessed would silently manufacture notifications, or silently remove them, on somebody's real
/// library.
///
/// ### Why this is a repair rather than a migration stage
/// It changes *data* under shapes that a lightweight migration has already added, which is the rule
/// established on ``SchemaV2``: a `VersionedSchema` earns its number by changing a shape, and a
/// change to data under unchanged shapes is a repair. Repairs live outside the plan, run after the
/// store is open, and are offered rather than performed — the same arrangement as
/// ``ContainmentRepair``.
public enum TaskDateMigration {
    /// Works out what needs doing. Writes nothing.
    ///
    /// - Parameter calendar: The calendar these dates were written in. Defaults to the user's own,
    ///   which is the only correct answer in production — a stored midnight is midnight *where they
    ///   are*, and reading the library in a different zone would find a time of day on every date in
    ///   it. Injected so a test can fix the zone rather than depending on the machine's.
    public static func plan(
        in context: ModelContext,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> TaskDateMigrationReport {
        try run(in: context, calendar: calendar, dryRun: true)
    }

    /// Performs the conversion and saves.
    @discardableResult
    public static func apply(
        in context: ModelContext,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> TaskDateMigrationReport {
        let report = try run(in: context, calendar: calendar, dryRun: false)
        try context.save()
        return report
    }

    private static func run(
        in context: ModelContext,
        calendar: Calendar,
        dryRun: Bool
    ) throws -> TaskDateMigrationReport {
        // Every kind that can hold these dates, including trashed and archived rows: a task restored
        // from the Trash after the migration must not come back with the old meaning.
        let descriptor = FetchDescriptor<Item>()
        let all = try context.fetch(descriptor)
        let candidates = all.filter { $0.kind.supportedFields.contains(.deferDate) }

        var report = TaskDateMigrationReport(isDryRun: dryRun, tasksExamined: candidates.count)

        for item in candidates {
            if let deferUntil = item.deferUntil {
                if item.startAt == nil {
                    report.folds.append(
                        .init(itemID: item.id, itemTitle: item.displayTitle, date: deferUntil)
                    )
                    if !dryRun {
                        item.startAt = deferUntil
                        item.deferUntil = nil
                    }
                } else if item.startAt != deferUntil {
                    // Two different answers to "when does this become available". Keeping the
                    // earlier one is the conservative choice — the task becomes visible sooner
                    // rather than disappearing — and the flag says a decision was made.
                    let earlier = min(item.startAt ?? deferUntil, deferUntil)
                    report.flags.append(
                        .init(
                            itemID: item.id,
                            itemTitle: item.displayTitle,
                            reason: .startAndDeferDisagreed
                        )
                    )
                    if !dryRun {
                        item.startAt = earlier
                        item.deferUntil = nil
                        item.dateReview = .startAndDeferDisagreed
                    }
                } else if !dryRun {
                    // Same value in both columns. Nothing to decide; drop the legacy one.
                    item.deferUntil = nil
                }
            }

            if let dueAt = item.dueAt, carriesTimeOfDay(dueAt, calendar: calendar), item.reminderAt == nil {
                report.flags.append(
                    .init(
                        itemID: item.id,
                        itemTitle: item.displayTitle,
                        reason: .deadlineMayHaveBeenAReminder
                    )
                )
                if !dryRun {
                    // The value is **not** touched. Only the marker is written.
                    item.dateReview = .deadlineMayHaveBeenAReminder
                }
            }
        }

        return report
    }

    /// Whether a stored date names a time rather than a day.
    ///
    /// Midnight in the *store's* calendar is what "a day with no time" looks like on every date this
    /// app has ever written, because both the capture parser and the date picker resolve to the
    /// start of the day. Anything else was typed.
    ///
    /// Uses the autoupdating calendar deliberately: these values were written in the user's own
    /// calendar, and reading them in a different one would find a time of day on every date in the
    /// library.
    public static func carriesTimeOfDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0 || (components.second ?? 0) != 0
    }
}
