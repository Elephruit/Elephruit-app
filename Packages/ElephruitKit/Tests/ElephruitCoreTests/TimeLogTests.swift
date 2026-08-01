import ElephruitCore
import Foundation
import Testing

@Suite("The time log")
struct TimeLogTests {
    private let clock = FixedDateProvider.reference
    private var calendar: Calendar { clock.calendar }

    private func entry(
        from start: TimeInterval,
        to end: TimeInterval?,
        description: String = "",
        item: (id: UUID, title: String)? = nil,
        tags: [String] = [],
        billable: Bool = false,
        source: TimeEntrySource = .timer
    ) -> TimeEntrySnapshot {
        TimeEntrySnapshot(
            id: UUID(),
            startedAt: clock.startOfToday.addingTimeInterval(start),
            endedAt: end.map { clock.startOfToday.addingTimeInterval($0) },
            entryDescription: description,
            isBillable: billable,
            source: source,
            itemID: item?.id,
            itemTitle: item?.title,
            tagSlugs: tags
        )
    }

    private func sections(
        _ entries: [TimeEntrySnapshot],
        groupSimilar: Bool = true
    ) -> [TimeDaySection] {
        TimeLog.sections(
            entries: entries,
            groupSimilar: groupSimilar,
            calendar: calendar,
            now: clock.now
        )
    }

    // MARK: - Days

    @Test("An empty log has no sections rather than one empty one")
    func emptyLog() {
        #expect(sections([]).isEmpty)
    }

    @Test("Entries are filed under the day they started")
    func oneSectionPerDay() {
        let log = sections([
            entry(from: 3_600, to: 7_200),
            entry(from: -82_800, to: -79_200),
        ])

        #expect(log.count == 2)
        #expect(log[0].title == "Today")
        #expect(log[1].title == "Yesterday")
    }

    @Test("Days come newest first, because that is where you start reading")
    func newestDayFirst() {
        let log = sections([
            entry(from: -172_800, to: -169_200),
            entry(from: 3_600, to: 7_200),
            entry(from: -82_800, to: -79_200),
        ])

        #expect(log.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(log[0].dayKey > log[1].dayKey)
        #expect(log[1].dayKey > log[2].dayKey)
    }

    @Test("A day header totals the day")
    func dayTotals() {
        let log = sections([
            entry(from: 3_600, to: 7_200),
            entry(from: 7_200, to: 9_000, billable: true, source: .manual),
        ])

        #expect(log.count == 1)
        #expect(log[0].total == 5_400)
        #expect(log[0].billable == 1_800)
        #expect(log[0].entryCount == 2)
    }

    @Test("A session across midnight stays one row on the day it began")
    func midnightCrossingIsNotSplit() {
        // The deliberate disagreement with `TimeReporting`, which *does* split it: a list is a list
        // of things you did, and half a stretch on each of two rows is a list nobody can correct.
        let log = sections([entry(from: -3_600, to: 3_600)])

        #expect(log.count == 1)
        #expect(log[0].title == "Yesterday")
        #expect(log[0].total == 7_200)
    }

    // MARK: - Grouping

    @Test("The same work tracked in bursts is one row")
    func similarEntriesCollapse() {
        let brief = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: brief),
            entry(from: 7_200, to: 9_000, item: brief),
            entry(from: 10_800, to: 12_600, item: brief),
        ])

        #expect(log[0].groups.count == 1)
        #expect(log[0].groups[0].count == 3)
        #expect(log[0].groups[0].total == 5_400)
        #expect(log[0].groups[0].isSingle == false)
    }

    @Test("A group spans from its earliest start to its latest end")
    func groupSpan() {
        let brief = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: brief),
            entry(from: 10_800, to: 12_600, item: brief),
        ])
        let group = log[0].groups[0]

        #expect(group.startedAt == clock.startOfToday.addingTimeInterval(3_600))
        #expect(group.endedAt == clock.startOfToday.addingTimeInterval(12_600))
    }

    @Test("The newest stretch stands for the group, so Continue continues the latest")
    func groupLeadIsNewest() {
        let brief = (id: UUID(), title: "Draft the brief")
        let newest = entry(from: 10_800, to: 12_600, item: brief)
        let log = sections([
            entry(from: 3_600, to: 5_400, item: brief),
            newest,
        ])

        #expect(log[0].groups[0].lead?.id == newest.id)
    }

    @Test(
        "Anything that shows differently on a row keeps the rows apart",
        arguments: [
            "description",
            "item",
            "tags",
            "billable",
        ]
    )
    func differingFieldsDoNotCollapse(field: String) {
        // The rule the key has to satisfy: two rows that collapse must be indistinguishable on
        // screen, or the collapse reads as data going missing.
        let shared = (id: UUID(), title: "Draft the brief")
        let first = entry(from: 3_600, to: 5_400, description: "outline", item: shared, tags: ["deep"])

        let second: TimeEntrySnapshot = switch field {
        case "description":
            entry(from: 7_200, to: 9_000, description: "revise", item: shared, tags: ["deep"])
        case "item":
            entry(
                from: 7_200,
                to: 9_000,
                description: "outline",
                item: (id: UUID(), title: "Something else"),
                tags: ["deep"]
            )
        case "tags":
            entry(from: 7_200, to: 9_000, description: "outline", item: shared, tags: ["shallow"])
        default:
            entry(from: 7_200, to: 9_000, description: "outline", item: shared, tags: ["deep"], billable: true)
        }

        #expect(sections([first, second])[0].groups.count == 2)
    }

    @Test("Tag order is not a difference")
    func tagOrderIsNotADifference() {
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: shared, tags: ["deep", "writing"]),
            entry(from: 7_200, to: 9_000, item: shared, tags: ["writing", "deep"]),
        ])

        #expect(log[0].groups.count == 1)
    }

    @Test("Time typed in by hand joins the hour it repeats")
    func sourceIsNotADifference() {
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: shared),
            entry(from: 7_200, to: 9_000, item: shared, source: .manual),
        ])

        #expect(log[0].groups.count == 1)
    }

    @Test("The same task on two days is two rows in two sections")
    func groupingNeverCrossesADay() {
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: shared),
            entry(from: -82_800, to: -79_200, item: shared),
        ])

        #expect(log.count == 2)
        #expect(log[0].groups.count == 1)
        #expect(log[1].groups.count == 1)
    }

    @Test("The running timer never collapses into a settled row")
    func runningEntryStandsAlone() {
        // Its duration is still moving; a total that is partly live and partly settled cannot say
        // what it means.
        // The clock stands at 09:00; the running entry began an hour ago and the settled one ran
        // from 06:00 to 07:00 against the same subject.
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections([
            entry(from: 28_800, to: nil, item: shared),
            entry(from: 21_600, to: 25_200, item: shared),
        ])

        #expect(log[0].groups.count == 2)
        #expect(log[0].groups[0].isRunning)
        #expect(log[0].groups[0].endedAt == nil)
        #expect(log[0].groups[0].total == 3_600)
    }

    @Test("Grouping off gives one row per entry")
    func groupingCanBeTurnedOff() {
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections(
            [
                entry(from: 3_600, to: 5_400, item: shared),
                entry(from: 7_200, to: 9_000, item: shared),
            ],
            groupSimilar: false
        )

        let everyRowIsOneEntry = log[0].groups.allSatisfy(\.isSingle)
        #expect(log[0].groups.count == 2)
        #expect(everyRowIsOneEntry)
        #expect(log[0].total == 3_600)
    }

    @Test("Grouped rows come out newest first")
    func groupOrdering() {
        let first = (id: UUID(), title: "Morning")
        let second = (id: UUID(), title: "Afternoon")
        let log = sections([
            entry(from: 3_600, to: 5_400, item: first),
            entry(from: 50_400, to: 54_000, item: second),
        ])

        #expect(log[0].groups.map(\.displayTitle) == ["Afternoon", "Morning"])
    }

    @Test("A group's billable total counts only its billable stretches")
    func groupBillable() {
        let shared = (id: UUID(), title: "Draft the brief")
        let log = sections(
            [
                entry(from: 3_600, to: 5_400, item: shared, billable: true),
                entry(from: 7_200, to: 9_000, item: shared, billable: true),
            ],
            groupSimilar: true
        )

        #expect(log[0].groups[0].billable == 3_600)
        #expect(log[0].billable == 3_600)
    }

    // MARK: - Identity

    @Test("A group keeps its identity across a reload")
    func stableGroupIdentity() {
        // Built from what made the entries alike rather than from their positions, so a row stays
        // open when the list behind it reloads.
        let shared = (id: UUID(), title: "Draft the brief")
        let entries = [
            entry(from: 3_600, to: 5_400, item: shared),
            entry(from: 7_200, to: 9_000, item: shared),
        ]

        let forwards = sections(entries)[0].groups[0].id
        let backwards = sections(Array(entries.reversed()))[0].groups[0].id
        #expect(forwards == backwards)
    }
}
