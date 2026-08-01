import ElephruitCore
import Foundation
import Testing

@Suite("Time reporting")
struct TimeReportingTests {
    private let clock = FixedDateProvider.reference
    private var calendar: Calendar { clock.calendar }

    private func entry(
        from start: TimeInterval,
        to end: TimeInterval?,
        item: (id: UUID, title: String)? = nil,
        kind: ItemKind? = nil,
        project: (id: UUID, title: String)? = nil,
        tags: [String] = [],
        people: [TimeParticipant] = [],
        billable: Bool = false
    ) -> TimeEntrySnapshot {
        TimeEntrySnapshot(
            id: UUID(),
            startedAt: clock.startOfToday.addingTimeInterval(start),
            endedAt: end.map { clock.startOfToday.addingTimeInterval($0) },
            isBillable: billable,
            itemID: item?.id,
            itemTitle: item?.title,
            itemKind: kind,
            projectID: project?.id,
            projectTitle: project?.title,
            tagSlugs: tags,
            people: people
        )
    }

    private func person(_ name: String) -> TimeParticipant {
        TimeParticipant(id: UUID(), name: name)
    }

    private var today: Range<Date> {
        clock.startOfToday..<clock.startOfToday.addingTimeInterval(86_400)
    }

    // MARK: - Totals

    @Test("An empty week is empty rather than wrong")
    func emptyReport() {
        let report = TimeReporting.report(
            entries: [], grouping: .day, range: today, calendar: calendar, now: clock.now
        )
        #expect(report.isEmpty)
        #expect(report.total == 0)
        #expect(report.entryCount == 0)
    }

    @Test("Totals add up")
    func totalsAddUp() {
        let report = TimeReporting.report(
            entries: [
                entry(from: 3_600, to: 7_200),
                entry(from: 7_200, to: 9_000, billable: true),
            ],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.total == 5_400)
        #expect(report.billable == 1_800)
        #expect(report.entryCount == 2)
    }

    // MARK: - Clipping

    @Test("Only the part inside the window counts")
    func clippingToTheWindow() {
        // Started three hours before today began, ended two hours into it.
        let report = TimeReporting.report(
            entries: [entry(from: -10_800, to: 7_200)],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.total == 7_200, "A report for today shows today's share, not the whole session")
    }

    @Test("An entry entirely outside the window contributes nothing")
    func outsideTheWindow() {
        let report = TimeReporting.report(
            entries: [entry(from: -10_800, to: -7_200)],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now
        )
        #expect(report.total == 0)
        #expect(report.entryCount == 0)
    }

    @Test("A running entry is measured to now, not to nothing")
    func runningEntryCounts() {
        let now = clock.startOfToday.addingTimeInterval(7_200)
        let report = TimeReporting.report(
            entries: [entry(from: 3_600, to: nil)],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: now
        )
        #expect(report.total == 3_600)
    }

    // MARK: - Grouping by day

    @Test("A session across midnight is split between the two days")
    func midnightIsSplit() {
        let twoDays = clock.startOfToday.addingTimeInterval(-86_400) ..<
            clock.startOfToday.addingTimeInterval(86_400)

        // 23:00 yesterday to 01:00 today.
        let report = TimeReporting.report(
            entries: [entry(from: -3_600, to: 3_600)],
            grouping: .day,
            range: twoDays,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.count == 2, "A late night belongs to both days it touches")
        #expect(report.rows[0].total == 3_600)
        #expect(report.rows[1].total == 3_600)
        #expect(report.total == 7_200, "…and is still only two hours in total")
    }

    @Test("Days come out in date order")
    func daysAreChronological() {
        let week = clock.startOfToday.addingTimeInterval(-3 * 86_400) ..<
            clock.startOfToday.addingTimeInterval(86_400)

        let report = TimeReporting.report(
            entries: [
                entry(from: -3_600, to: -1_800),
                entry(from: -3 * 86_400 + 3_600, to: -3 * 86_400 + 7_200),
                entry(from: 3_600, to: 7_200),
            ],
            grouping: .day,
            range: week,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.map(\.key) == report.rows.map(\.key).sorted(),
                "A daily chart out of date order is not a chart")
    }

    // MARK: - Grouping by item, project, tag

    @Test("Items are ordered by how much time they took")
    func itemsOrderedByTime() {
        let small = (id: UUID(), title: "Small")
        let large = (id: UUID(), title: "Large")

        let report = TimeReporting.report(
            entries: [
                entry(from: 0, to: 1_800, item: small),
                entry(from: 1_800, to: 9_000, item: large),
            ],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.first?.title == "Large", "The question is where the time went")
        #expect(report.rows.first?.itemID == large.id, "…and the answer has to be clickable")
    }

    @Test("Time with no item is reported as such rather than dropped")
    func unassignedTimeIsVisible() {
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600)],
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.count == 1)
        #expect(report.rows.first?.title == "No item")
        #expect(report.total == 3_600, "Untracked-against time is still time")
    }

    @Test("Time on a task rolls up to its project")
    func projectRollup() {
        let project = (id: UUID(), title: "Q3 Launch")
        let report = TimeReporting.report(
            entries: [
                entry(from: 0, to: 3_600, item: (UUID(), "Book the venue"), project: project),
                entry(from: 3_600, to: 5_400, item: (UUID(), "Draft the invite"), project: project),
            ],
            grouping: .project,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.count == 1)
        #expect(report.rows.first?.total == 5_400)
        #expect(report.rows.first?.entryCount == 2)
    }

    @Test("An entry with two tags counts in full under each, and the total does not double")
    func tagsCanOverlap() {
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600, tags: ["work", "writing"])],
            grouping: .tag,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.count == 2)
        #expect(report.rows.allSatisfy { $0.total == 3_600 },
                "“How much time carried this tag” is answered per tag")
        #expect(report.total == 3_600,
                "…but only an hour actually passed, which is why the total is not the sum of rows")
    }

    @Test("Untagged time is a row, not a gap")
    func untaggedIsARow() {
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600)],
            grouping: .tag,
            range: today,
            calendar: calendar,
            now: clock.now
        )
        #expect(report.rows.map(\.title) == ["Untagged"])
    }

    // MARK: - People

    @Test("An hour with two people is an hour with each of them")
    func peopleCountInFull() {
        let sarah = person("Sarah")
        let tom = person("Tom")

        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600, people: [sarah, tom])],
            grouping: .person,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        // Both rows carry the whole hour — splitting it would make one-to-one time look smaller
        // than time in a crowd — and the report's own total is still one hour.
        #expect(report.rows.count == 2)
        #expect(report.rows.allSatisfy { $0.total == 3_600 })
        #expect(report.total == 3_600)
    }

    @Test("Time on your own is a row rather than a gap")
    func soloTimeIsReported() {
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600)],
            grouping: .person,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.map(\.title) == ["On your own"])
    }

    @Test("A person row can be clicked through to the person")
    func personRowsCarryAnIdentity() {
        let sarah = person("Sarah")
        let report = TimeReporting.report(
            entries: [entry(from: 0, to: 3_600, people: [sarah])],
            grouping: .person,
            range: today,
            calendar: calendar,
            now: clock.now
        )

        #expect(report.rows.first?.itemID == sarah.id)
    }

    // MARK: - Rounding

    @Test("Rounding up lands on the next unit, and exact leaves everything alone")
    func roundingWorksOnDurations() {
        #expect(TimeRounding.exact.apply(3_061) == 3_061)
        #expect(TimeRounding.nearestMinute.apply(3_061) == 3_060)
        #expect(TimeRounding.upSixMinutes.apply(3_061) == 3_240)
        #expect(TimeRounding.upFifteenMinutes.apply(3_061) == 3_600)
    }

    @Test("Nothing rounds up to something")
    func zeroStaysZero() {
        // An empty day must not acquire six minutes, or a report of one bills for an hour.
        for rule in TimeRounding.allCases {
            #expect(rule.apply(0) == 0)
        }
    }

    @Test("The total rounds once rather than by adding rounded rows")
    func totalRoundsIndependently() throws {
        // Eight two-minute interruptions on the same task — sixteen minutes of work. Rounded per
        // entry at a tenth of an hour they would bill as forty-eight minutes; rounded as the one row
        // they actually are, they bill as eighteen.
        let task = (id: UUID(), title: "Fix the header")
        let entries = (0..<8).map { index in
            entry(from: Double(index) * 600, to: Double(index) * 600 + 120, item: task)
        }

        let report = TimeReporting.report(
            entries: entries,
            grouping: .item,
            range: today,
            calendar: calendar,
            now: clock.now,
            rounding: .upSixMinutes
        )

        #expect(report.rows.count == 1)
        let row = try #require(report.rows.first)
        #expect(row.total == 18 * 60)
        #expect(report.total == 18 * 60)
    }
}

@Suite("Time windows")
struct TimeWindowTests {
    private let clock = FixedDateProvider.reference

    @Test("Today is one day beginning at midnight")
    func todayIsADay() {
        let range = TimeWindow.today.range(using: clock)
        #expect(range.lowerBound == clock.startOfToday)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == 86_400)
    }

    @Test("Yesterday ends where today starts, with no gap and no overlap")
    func yesterdayAbutsToday() {
        #expect(TimeWindow.yesterday.range(using: clock).upperBound == TimeWindow.today.range(using: clock).lowerBound)
    }

    @Test("A week is seven days and honours the calendar's first weekday")
    func weekIsSevenDays() {
        let week = TimeWindow.thisWeek.range(using: clock)
        #expect(week.upperBound.timeIntervalSince(week.lowerBound) == 7 * 86_400)

        let weekday = clock.calendar.component(.weekday, from: week.lowerBound)
        #expect(weekday == clock.calendar.firstWeekday,
                "A week that starts on the wrong day makes every weekly total wrong")
    }

    @Test("Last week abuts this week")
    func weeksAbut() {
        #expect(TimeWindow.lastWeek.range(using: clock).upperBound ==
            TimeWindow.thisWeek.range(using: clock).lowerBound)
    }

    @Test("This week contains today")
    func weekContainsToday() {
        #expect(TimeWindow.thisWeek.range(using: clock).contains(clock.startOfToday))
    }

    @Test("This month starts on the first")
    func monthStartsOnTheFirst() {
        let month = TimeWindow.thisMonth.range(using: clock)
        #expect(clock.calendar.component(.day, from: month.lowerBound) == 1)
        #expect(month.contains(clock.startOfToday))
    }

    // MARK: - Windows

    @Test("A rolling week is seven days including today, not six")
    func rollingWindowsIncludeToday() {
        let range = TimeWindow.last7Days.range(using: clock)
        let days = clock.calendar
            .dateComponents([.day], from: range.lowerBound, to: range.upperBound)
            .day

        #expect(days == 7)
        #expect(range.contains(clock.startOfToday))
    }

    @Test("A custom period covers whole days at both ends")
    func customPeriodsCoverWholeDays() {
        // Two dates picked mid-afternoon must still report the whole of both days, or half an
        // afternoon falls outside a report of the day it happened on.
        let from = clock.startOfToday.addingTimeInterval(15 * 3_600)
        let through = clock.startOfToday.addingTimeInterval(86_400 + 9 * 3_600)
        let range = TimePeriod.custom(from: from, through: through).range(using: clock)

        #expect(range.lowerBound == clock.startOfToday)
        #expect(range.upperBound == clock.startOfToday.addingTimeInterval(2 * 86_400))
    }

    @Test("A backwards custom period is read forwards rather than refused")
    func customPeriodsAreOrderIndependent() {
        let early = clock.startOfToday
        let late = clock.startOfToday.addingTimeInterval(3 * 86_400)

        #expect(
            TimePeriod.custom(from: late, through: early).range(using: clock)
                == TimePeriod.custom(from: early, through: late).range(using: clock)
        )
    }
}

@Suite("Duration formatting")
struct TimeFormattingTests {
    @Test("A running clock shows seconds, because a clock that does not move looks broken")
    func stopwatchShowsSeconds() {
        #expect(TimeFormatting.stopwatch(0) == "0:00")
        #expect(TimeFormatting.stopwatch(65) == "1:05")
        #expect(TimeFormatting.stopwatch(3_600) == "1:00:00")
        #expect(TimeFormatting.stopwatch(3_849) == "1:04:09")
    }

    @Test("A total does not show seconds, because at that scale they are noise")
    func totalsAreHoursAndMinutes() {
        #expect(TimeFormatting.short(3_849) == "1:04")
        #expect(TimeFormatting.short(0) == "0:00")
        #expect(TimeFormatting.short(27_129) == "7:32")
    }

    @Test("Spelled durations read as English")
    func spelledDurations() {
        #expect(TimeFormatting.spelled(240) == "4m")
        #expect(TimeFormatting.spelled(3_600) == "1h")
        #expect(TimeFormatting.spelled(3_849) == "1h 04m")
    }

    @Test("Decimal hours are what an invoice wants")
    func decimalHours() {
        #expect(TimeFormatting.decimalHours(3_600) == "1.00")
        #expect(TimeFormatting.decimalHours(5_400) == "1.50")
        #expect(TimeFormatting.decimalHours(3_849) == "1.07")
    }

    @Test("A negative interval never renders as one")
    func negativesAreClamped() {
        #expect(TimeFormatting.stopwatch(-60) == "0:00")
        #expect(TimeFormatting.short(-60) == "0:00")
        #expect(TimeFormatting.spelled(-60) == "0m")
    }
}
