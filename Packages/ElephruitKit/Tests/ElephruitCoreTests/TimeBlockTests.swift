import ElephruitCore
import Foundation
import Testing

/// What the app offers to put in a gap, and how long it offers to take.
///
/// These are the numbers behind a button that writes to somebody's calendar. Every one of them is a
/// claim about their afternoon — *this will take two hours, this fits, this is the soonest you
/// could* — and a claim that is wrong writes an appointment they now have to find and delete. So the
/// arithmetic is a value over a fixed clock, and the sheet only draws what it says.
@Suite("Blocking time")
struct TimeBlockTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static let day = Date(timeIntervalSinceReferenceDate: 757_382_400)

    static func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3_600) }

    static func slot(_ from: Double, _ to: Double) -> DayFreeSlot {
        DayFreeSlot(range: at(from)..<at(to))
    }

    // MARK: - How long a block lasts

    @Test("An estimate is honored when the gap can hold it")
    func estimateFitsInsideTheGap() {
        let length = TimeBlockRules.length(forEstimate: 45, in: Self.slot(9, 11))
        #expect(length == 45 * 60)
    }

    @Test("An estimate longer than the gap books the gap, not an overlap")
    func estimateIsCappedByTheGap() {
        // The alternative is writing an event that runs into the meeting after it — the app creating
        // the conflict it exists to warn about.
        let length = TimeBlockRules.length(forEstimate: 120, in: Self.slot(9, 9.5))
        #expect(length == 30 * 60)
    }

    @Test("Unestimated work takes the gap, up to an hour")
    func unestimatedWorkIsCappedAtAnHour() {
        #expect(TimeBlockRules.length(forEstimate: nil, in: Self.slot(9, 12)) == TimeBlockRules.unestimatedCap)
        // A gap smaller than the cap is taken whole: there is nothing else in it to protect.
        #expect(TimeBlockRules.length(forEstimate: nil, in: Self.slot(9, 9.5)) == 30 * 60)
    }

    @Test("With no gap at all, a block is half an hour")
    func fallbackLengthWithNoSlot() {
        #expect(TimeBlockRules.length(forEstimate: nil, in: nil) == TimeBlockRules.fallbackLength)
        // An estimate still wins: there is no gap constraining it.
        #expect(TimeBlockRules.length(forEstimate: 90, in: nil) == 90 * 60)
    }

    @Test("A block is never zero-length, whatever it was asked for")
    func lengthHasAFloor() {
        #expect(TimeBlockRules.length(forEstimate: 0, in: Self.slot(9, 10)) == TimeBlockRules.unestimatedCap)
        #expect(TimeBlockRules.length(forEstimate: -30, in: nil) == TimeBlockRules.fallbackLength)
    }

    // MARK: - What is offered for a gap

    @Test("The work offered for a gap is longest-fitting first")
    func candidatesAreLongestFittingFirst() {
        let short = TimeBlockCandidate(id: UUID(), title: "Reply to Anna", estimateMinutes: 10)
        let medium = TimeBlockCandidate(id: UUID(), title: "Draft the brief", estimateMinutes: 50)
        let huge = TimeBlockCandidate(id: UUID(), title: "Rewrite the deck", estimateMinutes: 240)

        let ranked = TimeBlockRules.candidates(in: Self.slot(9, 10), from: [short, medium, huge])

        #expect(ranked.map(\.title) == ["Draft the brief", "Reply to Anna", "Rewrite the deck"])
        // What does not fit is kept and marked, not hidden: starting a four-hour job in an hour is a
        // perfectly sensible thing to do, and a list missing somebody's largest task looks broken.
        #expect(ranked.last?.fitsWholly == false)
        #expect(ranked.first?.fitsWholly == true)
    }

    @Test("Work nobody has estimated is offered, and never called a bad fit")
    func unestimatedWorkAlwaysFits() {
        let unestimated = TimeBlockCandidate(id: UUID(), title: "Think about pricing")
        let ranked = TimeBlockRules.candidates(in: Self.slot(9, 9.25), from: [unestimated])

        #expect(ranked.count == 1)
        // The app has no basis for saying this does not fit, and inventing one would be inventing a
        // fact about somebody's work.
        #expect(ranked[0].fitsWholly)
    }

    @Test("Ties keep the order the day already put them in")
    func tiesKeepTheDaysOrder() {
        let first = TimeBlockCandidate(id: UUID(), title: "First")
        let second = TimeBlockCandidate(id: UUID(), title: "Second")
        let ranked = TimeBlockRules.candidates(in: Self.slot(9, 11), from: [first, second])
        #expect(ranked.map(\.title) == ["First", "Second"])
    }

    // MARK: - Where a block goes

    @Test("A task goes in the earliest gap that holds it whole")
    func earliestFittingSlotWins() {
        let chosen = TimeBlockRules.slot(
            forEstimate: 60,
            among: [Self.slot(14, 17), Self.slot(9, 9.5), Self.slot(11, 12)]
        )
        #expect(chosen?.range.lowerBound == Self.at(11))
    }

    @Test("When nothing holds it whole, the largest gap is the honest answer")
    func largestSlotIsTheFallback() {
        let chosen = TimeBlockRules.slot(
            forEstimate: 300,
            among: [Self.slot(9, 9.5), Self.slot(14, 16), Self.slot(11, 12)]
        )
        #expect(chosen?.range.lowerBound == Self.at(14))
    }

    @Test("A day with no room at all says so, rather than inventing a gap")
    func noSlotsMeansNoSlot() {
        #expect(TimeBlockRules.slot(forEstimate: 30, among: []) == nil)
    }

    @Test("A start with no gap behind it lands on the next quarter hour")
    func startsAreRounded() {
        let rounded = TimeBlockRules.nextRoundStart(
            after: Self.at(9).addingTimeInterval(7 * 60 + 20), calendar: Self.calendar
        )
        #expect(rounded == Self.at(9.25))

        // Already on a quarter: that is the answer, not a reason to wait fifteen minutes.
        #expect(TimeBlockRules.nextRoundStart(after: Self.at(9.5), calendar: Self.calendar) == Self.at(9.5))
        // Seconds past a quarter are still past it.
        #expect(
            TimeBlockRules.nextRoundStart(after: Self.at(9.5).addingTimeInterval(1), calendar: Self.calendar)
                == Self.at(9.75)
        )
    }

    // MARK: - What gets written

    @Test("A block carries the task's title and nothing else about it")
    func proposalDraftCarriesOnlyTheTitle() {
        let proposal = TimeBlockProposal(
            taskID: UUID(),
            title: "Draft the brief",
            startAt: Self.at(11),
            length: 45 * 60,
            calendarIdentifier: "work",
            availability: .free
        )

        let draft = proposal.draft(timeZoneIdentifier: "UTC")

        #expect(draft.title == "Draft the brief")
        #expect(draft.startAt == Self.at(11))
        #expect(draft.endAt == Self.at(11.75))
        #expect(draft.calendarIdentifier == "work")
        #expect(draft.availability == .free)
        // The task's private context stays in the library. A calendar event syncs to an account
        // other people may be able to read; the link between the two is written locally instead.
        #expect(draft.notes.isEmpty)
        #expect(draft.location.isEmpty)
        #expect(draft.url == nil)
        #expect(draft.alarms.isEmpty)
        #expect(draft.recurrence == nil)
        #expect(!draft.isAllDay)
    }

    @Test("A proposal never describes a zero-length event")
    func proposalsHaveALength() {
        let proposal = TimeBlockProposal(
            title: "Focus", startAt: Self.at(11), length: 0, calendarIdentifier: "work"
        )
        #expect(proposal.length >= 60)
        #expect(proposal.endAt > proposal.startAt)
    }

    @Test("A proposal says its own hours, for the sheet to show before anybody agrees")
    func proposalsDescribeThemselves() {
        let proposal = TimeBlockProposal(
            title: "Focus", startAt: Self.at(11.5), length: 90 * 60, calendarIdentifier: "work"
        )
        #expect(proposal.lengthSummary == "1h 30m")
        #expect(proposal.rangeSummary.contains("–"))
    }
}
