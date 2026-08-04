import ElephruitCore
import Foundation
import Observation

/// What the reader has chosen to see on Today, and how far ahead they are looking.
///
/// ### Why this is remembered and the selected date is not
/// Turning meetings off is a statement about how somebody wants this page to work; it should survive
/// a relaunch, and being asked again every morning would make the switch useless. *Which day you
/// were looking at* is the opposite — it is where you happened to be in a session, and restoring it
/// means opening the app on Tuesday and being shown next Friday, which is precisely the failure the
/// page exists to avoid. So the filters persist and the date does not.
///
/// In `UserDefaults` rather than the store, like every other preference about how this machine
/// behaves: it carries no relationship data and must not travel in an archive somebody sends to a
/// colleague.
@Observable
@MainActor
public final class TodayPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    private static let filtersKey = "today.filters"

    public var filters: TodayFilters {
        didSet {
            guard filters != oldValue else { return }
            save()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // A preference written by a build with a different shape decodes to nothing and the standard
        // arrangement is used. Losing a switch is a smaller failure than refusing to draw the page.
        if let data = defaults.data(forKey: Self.filtersKey),
           let decoded = try? JSONDecoder().decode(TodayFilters.self, from: data) {
            self.filters = decoded
        } else {
            self.filters = .standard
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(filters) else { return }
        defaults.set(data, forKey: Self.filtersKey)
    }

    /// Puts every switch back, which is the one control a filter menu owes the person using it.
    public func reset() {
        filters = .standard
    }

    // MARK: - Individual switches
    //
    // Written as methods rather than left to callers mutating `filters` so that a toggle is one
    // change and therefore one write, rather than a read, a mutation and a hope.

    public func toggleTasks() { filters.showsTasks.toggle() }
    public func toggleMeetings() { filters.showsMeetings.toggle() }
    public func togglePeople() { filters.showsPeople.toggle() }
    public func toggleDailyNote() { filters.showsDailyNote.toggle() }
    public func toggleCompleted() { filters.showsCompleted.toggle() }

    public func setIntegratedAgenda(_ isIntegrated: Bool) {
        filters.usesIntegratedAgenda = isIntegrated
    }

    public func toggleCalendar(_ identifier: String) {
        if filters.hiddenCalendarIdentifiers.contains(identifier) {
            filters.hiddenCalendarIdentifiers.remove(identifier)
        } else {
            filters.hiddenCalendarIdentifiers.insert(identifier)
        }
    }

    public func isCalendarShown(_ identifier: String) -> Bool {
        !filters.hiddenCalendarIdentifiers.contains(identifier)
    }

    public func toggleContainer(_ id: UUID) {
        if filters.hiddenContainerIDs.contains(id) {
            filters.hiddenContainerIDs.remove(id)
        } else {
            filters.hiddenContainerIDs.insert(id)
        }
    }

    public func isContainerShown(_ id: UUID) -> Bool {
        !filters.hiddenContainerIDs.contains(id)
    }
}
