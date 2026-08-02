import Foundation
import SwiftData

/// Converges ``Item/dayRelevanceKey`` on rows written before the column existed.
///
/// ### Why this exists when the default is already correct
/// A pre-existing row carries the `.distantPast` sentinel, which means *fetch me for every window*
/// — safe, but it makes the windowed read degenerate to the full scan it replaced until each row
/// happens to be saved. One pass computes the real key for everything still carrying the sentinel,
/// after which the sentinel query returns nothing and the pass costs one empty fetch.
///
/// ### Why it writes directly rather than through the repository
/// `ItemRepository.update` stamps `updatedAt`, and this is not an edit — it is a derived column
/// catching up. Stamping would make every task in the library look locally modified to the
/// reminder sync engine, which compares `updatedAt` against its last pass. So the key alone is
/// written, and nothing an observer of content could notice changes.
public enum DayRelevanceBackfill {
    /// Recomputes every sentinel-carrying row. Returns how many it converged.
    @discardableResult
    public static func apply(in context: ModelContext) throws -> Int {
        let sentinel = Date.distantPast
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.dayRelevanceKey == sentinel }
        )

        let stale = try context.fetch(descriptor)
        guard !stale.isEmpty else { return 0 }

        for item in stale {
            item.dayRelevanceKey = Item.projectedDayRelevance(
                dueAt: item.dueAt,
                startAt: item.startAt,
                deferUntil: item.deferUntil,
                todayCommittedOn: item.todayCommittedOn,
                reminderAt: item.reminderAt,
                followUpAt: item.followUpAt,
                isSomeday: item.isSomeday
            )
        }

        try context.save()
        return stale.count
    }
}
