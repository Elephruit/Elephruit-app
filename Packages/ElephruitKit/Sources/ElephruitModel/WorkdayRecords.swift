import ElephruitCore
import Foundation
import SwiftData

/// The app-wide working day, as it lives in the store.
///
/// ### Why this is in the store rather than in preferences
/// The same argument ``CalendarSetRecord`` makes, and more plainly. The storage matrix sends display
/// state to `UserDefaults` — which view is selected, how wide the sidebar is — and keeps in the
/// store anything a person composed and would be sorry to retype. When somebody works is a statement
/// about their life, not about this Mac, and a phone that had to be told again is a phone that will
/// quietly measure "how much of the day is free" against hours nobody gave it.
///
/// Which calendar set is *active* stays a per-device preference, as it always was. That is the
/// difference between a context somebody switched into on one machine and a fact about them.
///
/// **A singleton, softly.** There is no unique constraint — CloudKit does not allow one — so two
/// devices that both write before either syncs will produce two rows. ``asValue`` and the service
/// that owns it resolve that by reading the most recently updated and folding the rest away, which
/// converges without ever refusing to answer.
///
/// **CloudKit compliance** on the same terms as every other entity here: every attribute defaulted,
/// no unique constraints, no relationships at all.
@Model
public final class WorkdaySettingsRecord {
    public var id: UUID = UUID()

    /// Minutes from midnight, the same units ``ElephruitCore/WorkingHours`` uses.
    public var startMinutes: Int = 9 * 60
    public var endMinutes: Int = 17 * 60

    /// Working weekdays as a sorted, comma-separated list — "2,3,4,5,6".
    ///
    /// A string for the reason `CalendarSetRecord.workingWeekdaysRaw` is one: SwiftData stores a
    /// `Set` as an opaque archive nothing else can read, and seven small integers are more useful as
    /// something an export or a person can see.
    public var weekdaysRaw: String = "2,3,4,5,6"

    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func asValue() -> WorkingHours {
        WorkingHours(
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            weekdays: Set(weekdaysRaw.split(separator: ",").compactMap { Int($0) })
        )
    }

    public func absorb(_ hours: WorkingHours, at now: Date) {
        startMinutes = hours.startMinutes
        endMinutes = hours.endMinutes
        weekdaysRaw = hours.weekdays.sorted().map(String.init).joined(separator: ",")
        updatedAt = now
    }
}
