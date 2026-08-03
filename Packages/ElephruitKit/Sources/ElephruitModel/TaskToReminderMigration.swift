import ElephruitCore
import Foundation
import SwiftData

/// Reclassifies legacy task rows as first-class reminders without replacing the row.
///
/// Identity is the preservation mechanism. A copied record would need to rebuild every inverse
/// relationship and would inevitably miss one; changing only `kindRaw` leaves the UUID, containment,
/// links, tags, attachments, comments, activity, time, and external Reminders metadata attached to
/// the exact same object.
public enum TaskToReminderMigration {
    public static let legacyKindRaw = "task"

    /// The rows a run would change. Exposed so the caller can take a backup before applying it.
    public static func plan(in context: ModelContext) throws -> [UUID] {
        try legacyItems(in: context).map(\.id)
    }

    /// Applies the in-place rewrite and returns the number of reminders promoted.
    ///
    /// The predicate makes this idempotent: after a successful save no row still carries the legacy
    /// raw value, so a second pass performs no writes.
    @discardableResult
    public static func apply(in context: ModelContext) throws -> Int {
        let legacy = try legacyItems(in: context)
        guard !legacy.isEmpty else { return 0 }

        for item in legacy {
            item.kindRaw = ItemKind.reminder.rawValue
        }

        try context.save()
        return legacy.count
    }

    private static func legacyItems(in context: ModelContext) throws -> [Item] {
        let legacyRaw = legacyKindRaw
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.kindRaw == legacyRaw },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        return try context.fetch(descriptor)
    }
}
