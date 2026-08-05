import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// When the user works, and which of the three possible answers is being given.
///
/// The rule this suite exists to hold is the one the phone got wrong for a release: an app that has
/// never been told when somebody works must not present its own assumption as their decision. So
/// "nobody has said" is a distinct answer from "nine to five", even though the hours are the same.
@Suite("The working day")
@MainActor
struct WorkdayTests {
    private func makeService(_ fixture: StoreFixture) -> WorkdayService {
        WorkdayService(context: fixture.context, dateProvider: FixedDateProvider.reference)
    }

    @Test("An untouched library has no working day of its own, and says so")
    func nothingSaidIsItsOwnAnswer() throws {
        let service = makeService(try StoreFixture())

        #expect(service.appDefault() == nil)

        let resolved = service.resolved(activeSet: nil)
        #expect(resolved.source == .assumed)
        #expect(!resolved.source.isChosen)
        #expect(resolved.hours == .standard)
    }

    @Test("Hours survive being stored and read back")
    func hoursRoundTrip() throws {
        let service = makeService(try StoreFixture())
        let chosen = WorkingHours(startMinutes: 8 * 60, endMinutes: 16 * 60, weekdays: [2, 3, 4, 5])

        try service.setAppDefault(chosen)

        #expect(service.appDefault() == chosen)

        let resolved = service.resolved(activeSet: nil)
        #expect(resolved.source == .appDefault)
        #expect(resolved.source.isChosen)
        #expect(resolved.hours == chosen)
    }

    @Test("The same hours chosen deliberately are a different answer from the same hours assumed")
    func choosingTheAssumptionIsStillChoosing() throws {
        let service = makeService(try StoreFixture())
        try service.setAppDefault(.standard)

        let resolved = service.resolved(activeSet: nil)
        #expect(resolved.hours == .standard)
        #expect(resolved.source == .appDefault, "they said it, so the interface must not hedge")
    }

    @Test("An active calendar set overrides the app's own default while it is active")
    func aSetWinsWhileItIsActive() throws {
        let service = makeService(try StoreFixture())
        try service.setAppDefault(WorkingHours(startMinutes: 8 * 60, endMinutes: 16 * 60))

        let family = CalendarSetDefinition(
            name: "Family",
            workingHours: WorkingHours(startMinutes: 10 * 60, endMinutes: 14 * 60, weekdays: [7])
        )

        let resolved = service.resolved(activeSet: family)
        #expect(resolved.source == .calendarSet(name: "Family"))
        #expect(resolved.hours.startMinutes == 10 * 60)

        // And the default is still there underneath, for when the set is switched away from.
        #expect(service.resolved(activeSet: nil).hours.startMinutes == 8 * 60)
    }

    @Test("Clearing the default returns the app to admitting it does not know")
    func clearingRestoresTheAssumption() throws {
        let service = makeService(try StoreFixture())
        try service.setAppDefault(WorkingHours(startMinutes: 7 * 60, endMinutes: 15 * 60))
        try service.clearAppDefault()

        #expect(service.appDefault() == nil)
        #expect(service.resolved(activeSet: nil).source == .assumed)
    }

    /// Two devices that each write before either has seen the other leave two rows behind, because
    /// CloudKit permits no unique constraint to stop them. The read has to be deterministic and the
    /// next write has to heal it.
    @Test("Two rows resolve to the most recent, and the next write folds the loser away")
    func duplicateRowsConverge() throws {
        let fixture = try StoreFixture()
        let service = makeService(fixture)

        let older = WorkdaySettingsRecord()
        older.absorb(WorkingHours(startMinutes: 6 * 60, endMinutes: 14 * 60), at: .distantPast)
        fixture.context.insert(older)

        let newer = WorkdaySettingsRecord()
        newer.absorb(WorkingHours(startMinutes: 9 * 60, endMinutes: 18 * 60), at: Date())
        fixture.context.insert(newer)

        #expect(service.appDefault()?.startMinutes == 9 * 60, "the last decision wins")

        try service.setAppDefault(WorkingHours(startMinutes: 10 * 60, endMinutes: 19 * 60))

        let remaining = try fixture.context.fetch(FetchDescriptor<WorkdaySettingsRecord>())
        #expect(remaining.count == 1, "a write leaves one row behind")
        #expect(remaining.first?.startMinutes == 10 * 60)
    }

    @Test("A day is only as long as the working window, and weekends have no length at all")
    func theWindowIsTheDenominator() throws {
        let calendar = Calendar(identifier: .gregorian)
        let workday = WorkdayHours(
            hours: WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60, weekdays: [2, 3, 4, 5, 6]),
            source: .appDefault
        )

        // 2025-08-05 is a Tuesday; the 9th is a Saturday.
        let tuesday = try #require(
            calendar.date(from: DateComponents(year: 2_025, month: 8, day: 5, hour: 12))
        )
        let saturday = try #require(
            calendar.date(from: DateComponents(year: 2_025, month: 8, day: 9, hour: 12))
        )

        let length = try #require(workday.length(on: tuesday, calendar: calendar))
        #expect(length == 8 * 3_600)
        #expect(workday.length(on: saturday, calendar: calendar) == nil)
    }

    @Test("A working week is said the way somebody would say it")
    func weekdaysReadAsPhrases() {
        #expect(WorkdayHours.weekdaySummary([2, 3, 4, 5, 6]).contains("–"), "a run contracts")
        #expect(!WorkdayHours.weekdaySummary([2, 4, 6]).contains("–"), "gaps are not a range")
        #expect(WorkdayHours.weekdaySummary([1, 2, 3, 4, 5, 6, 7]) == "Every day")
        #expect(WorkdayHours.weekdaySummary([]) == "No days")
    }
}
