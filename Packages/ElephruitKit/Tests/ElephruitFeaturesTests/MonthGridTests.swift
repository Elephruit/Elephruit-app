@testable import ElephruitDesign
import Foundation
import SwiftUI
import Testing

@Suite("Month grid")
struct MonthGridTests {
    @Test("Weekday, blank, and day cells have unique identities")
    @MainActor
    func uniqueCellIdentities() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))

        let elements = MonthGrid<EmptyView>.gridElements(
            of: month,
            calendar: calendar,
            showsWeekdayHeader: true
        )

        #expect(elements.count == 7 + 6 + 31)
        #expect(Set(elements).count == elements.count)
    }
}
