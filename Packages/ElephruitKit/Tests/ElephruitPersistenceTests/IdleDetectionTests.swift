import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

@MainActor
private struct IdleFixture {
    let store: StoreFixture
    let time: SwiftDataTimeEntryRepository

    init() throws {
        store = try StoreFixture()
        time = SwiftDataTimeEntryRepository(
            context: store.context,
            dateProvider: store.dateProvider,
            tags: store.tags
        )
    }

    var now: Date { store.dateProvider.now }

    func makeTask(_ title: String) throws -> Item {
        try store.items.create(ItemDraft(kind: .task, title: title))
    }

    /// A running timer that began `interval` ago.
    ///
    /// The clock is frozen, so a timer started in the ordinary way begins at `now` — and a gap that
    /// ended at `now` would be clipped away to nothing against it. Back-dating with `setDuration`
    /// is the same call the duration field makes, so these tests exercise a state the app can
    /// genuinely be in.
    func startedAgo(
        _ interval: TimeInterval,
        item: Item? = nil,
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) throws -> TimeEntry {
        let entry = try time.start(
            item: item,
            description: description,
            tagSlugs: tagSlugs,
            isBillable: isBillable
        )
        try time.setDuration(interval, for: entry)
        return entry
    }
}

/// The rule about when a gap in input becomes a question.
@Suite("Idle detection")
struct IdleDetectorTests {
    private let clock = FixedDateProvider.reference
    private var now: Date { clock.now }
    private var timerStart: Date { clock.now.addingTimeInterval(-7_200) }

    private func detector(threshold: TimeInterval = 300) -> IdleDetector {
        IdleDetector(threshold: threshold)
    }

    @Test("Somebody at the machine is never a question")
    func activeIsSilent() {
        var detector = detector()
        let gap = detector.observe(secondsSinceInput: 3, now: now, timerStartedAt: timerStart)

        #expect(gap == nil)
        #expect(detector.isIdle == false)
    }

    @Test("A gap under the threshold is not a gap")
    func shortGapIsIgnored() {
        var detector = detector()
        #expect(detector.observe(secondsSinceInput: 120, now: now, timerStartedAt: timerStart) == nil)
        #expect(detector.isIdle == false)
    }

    @Test("A gap is only reported once it has ended")
    func openGapIsNotReported() {
        // Reporting it while it is still open would ask about minutes that are still accumulating,
        // and the user is not there to answer.
        var detector = detector()
        #expect(detector.observe(secondsSinceInput: 600, now: now, timerStartedAt: timerStart) == nil)
        #expect(detector.isIdle)
    }

    @Test("Input coming back closes the gap and reports it")
    func returningReportsTheGap() {
        var detector = detector()
        let awayAt = now.addingTimeInterval(-600)

        _ = detector.observe(secondsSinceInput: 600, now: now, timerStartedAt: timerStart)
        let gap = detector.observe(
            secondsSinceInput: 1,
            now: now.addingTimeInterval(60),
            timerStartedAt: timerStart
        )

        #expect(gap?.from == awayAt)
        #expect(gap?.to == now.addingTimeInterval(60))
        #expect(detector.isIdle == false)
    }

    @Test("The gap is dated from when input stopped, not from when it was noticed")
    func gapStartIsTheFirstTick() {
        // A gap spanning many ticks must report the instant typing stopped. Taking the latest tick
        // instead would shorten every gap by however long the user stayed away.
        var detector = detector()
        let awayAt = now.addingTimeInterval(-600)

        _ = detector.observe(secondsSinceInput: 600, now: now, timerStartedAt: timerStart)
        _ = detector.observe(secondsSinceInput: 900, now: now.addingTimeInterval(300), timerStartedAt: timerStart)
        let gap = detector.observe(
            secondsSinceInput: 1,
            now: now.addingTimeInterval(600),
            timerStartedAt: timerStart
        )

        #expect(gap?.from == awayAt)
    }

    @Test("A gap cannot begin before the timer it belongs to")
    func gapIsClippedToTheTimer() {
        var detector = detector()
        let startedAt = now.addingTimeInterval(-60)

        _ = detector.observe(secondsSinceInput: 3_600, now: now, timerStartedAt: startedAt)
        let gap = detector.observe(
            secondsSinceInput: 1,
            now: now.addingTimeInterval(600),
            timerStartedAt: startedAt
        )

        #expect(gap?.from == startedAt)
    }

    @Test("Starting a timer and walking away immediately asks nothing")
    func gapShorterThanThresholdAfterClipping() {
        // Clipped to the timer's own start, this gap is a minute long — under the threshold, so
        // there is nothing worth interrupting anybody about.
        var detector = detector()
        let startedAt = now.addingTimeInterval(-60)

        _ = detector.observe(secondsSinceInput: 3_600, now: now, timerStartedAt: startedAt)
        let gap = detector.observe(secondsSinceInput: 1, now: now, timerStartedAt: startedAt)

        #expect(gap == nil)
    }

    @Test("With nothing running there is nothing to ask about")
    func noTimerMeansNoQuestion() {
        var detector = detector()
        _ = detector.observe(secondsSinceInput: 600, now: now, timerStartedAt: timerStart)

        #expect(detector.observe(secondsSinceInput: 1, now: now, timerStartedAt: nil) == nil)
        #expect(detector.isIdle == false)
    }

    @Test("A reset forgets an open gap without reporting it")
    func resetDropsTheGap() {
        // What waking from sleep does, so the same minutes are not queried by two banners.
        var detector = detector()
        _ = detector.observe(secondsSinceInput: 600, now: now, timerStartedAt: timerStart)
        detector.reset()

        #expect(detector.isIdle == false)
        #expect(detector.observe(secondsSinceInput: 1, now: now, timerStartedAt: timerStart) == nil)
    }
}

/// What each of the four answers does to the store.
@Suite("Resolving idle time")
@MainActor
struct IdleResolutionTests {
    private func observation(
        for entry: TimeEntry,
        idleSince: Date,
        idleUntil: Date
    ) -> IdleObservation {
        IdleObservation(
            id: entry.id,
            entryDescription: entry.entryDescription,
            itemTitle: entry.item?.displayTitle,
            idleSince: idleSince,
            idleUntil: idleUntil
        )
    }

    @Test("Keeping the gap changes nothing at all")
    func keepIsANoOp() throws {
        let fixture = try IdleFixture()
        let task = try fixture.makeTask("Draft the brief")
        let entry = try fixture.time.start(item: task, description: "", tagSlugs: [], isBillable: false)
        let startedAt = entry.startedAt

        try fixture.time.resolveIdle(
            .keep,
            for: observation(
                for: entry,
                idleSince: fixture.now.addingTimeInterval(-600),
                idleUntil: fixture.now
            )
        )

        #expect(entry.endedAt == nil)
        #expect(entry.startedAt == startedAt)
        #expect(try fixture.time.runningEntry()?.id == entry.id)
    }

    @Test("Discarding stops the timer where the typing stopped")
    func discardStopsAtIdleStart() throws {
        let fixture = try IdleFixture()
        let entry = try fixture.time.start(item: nil, description: "Reading", tagSlugs: [], isBillable: false)
        let awayAt = fixture.now.addingTimeInterval(-600)

        try fixture.time.resolveIdle(
            .discard,
            for: observation(for: entry, idleSince: awayAt, idleUntil: fixture.now)
        )

        #expect(entry.endedAt == max(entry.startedAt, awayAt))
        #expect(try fixture.time.runningEntry() == nil)
    }

    @Test("Discarding and continuing leaves the same work running")
    func discardAndContinueRestartsTheSameWork() throws {
        let fixture = try IdleFixture()
        let task = try fixture.makeTask("Draft the brief")
        let entry = try fixture.startedAgo(
            7_200,
            item: task,
            description: "outline",
            tagSlugs: ["deep"],
            isBillable: true
        )
        let awayAt = fixture.now.addingTimeInterval(-600)

        try fixture.time.resolveIdle(
            .discardAndContinue,
            for: observation(for: entry, idleSince: awayAt, idleUntil: fixture.now)
        )

        let running = try #require(try fixture.time.runningEntry())
        #expect(running.id != entry.id)
        #expect(running.item?.id == task.id)
        #expect(running.entryDescription == "outline")
        #expect(running.tagSlugs == ["deep"])
        #expect(running.isBillable)
        #expect(entry.endedAt == awayAt)
    }

    @Test("Keeping the gap separately splits it out and carries on timing")
    func keepSeparatelyProducesThreeRecords() throws {
        let fixture = try IdleFixture()
        let task = try fixture.makeTask("Draft the brief")
        let entry = try fixture.startedAgo(
            7_200,
            item: task,
            description: "outline",
            tagSlugs: ["deep"],
            isBillable: true
        )
        let awayAt = fixture.now.addingTimeInterval(-600)

        try fixture.time.resolveIdle(
            .keepAsSeparateEntry,
            for: observation(for: entry, idleSince: awayAt, idleUntil: fixture.now)
        )

        let all = try fixture.time.entries(in: Date.distantPast..<Date.distantFuture, limit: nil)
        #expect(all.count == 3)

        let away = try #require(all.first { $0.entryDescription == idleEntryDescription })
        #expect(away.startedAt == awayAt)
        #expect(away.endedAt == fixture.now)
        #expect(away.item?.id == task.id)

        // Not billable, and that is the point: charging for time the machine saw nobody for is the
        // one direction of this that cannot be undone by noticing later.
        #expect(away.isBillable == false)

        let running = try #require(try fixture.time.runningEntry())
        #expect(running.entryDescription == "outline")
        #expect(running.isBillable)
    }

    @Test("The split-out gap does not collapse back into the work it came from")
    func awayEntryDoesNotRegroup() throws {
        // The log collapses rows matching on description, subject and tags. An idle stretch that
        // matched would fold straight back into the work it was just separated from.
        let fixture = try IdleFixture()
        let task = try fixture.makeTask("Draft the brief")
        let entry = try fixture.startedAgo(7_200, item: task, description: "outline")

        try fixture.time.resolveIdle(
            .keepAsSeparateEntry,
            for: observation(
                for: entry,
                idleSince: fixture.now.addingTimeInterval(-600),
                idleUntil: fixture.now
            )
        )

        let snapshots = try fixture.time.snapshots(in: Date.distantPast..<Date.distantFuture, limit: nil)
        let sections = TimeLog.sections(
            entries: snapshots,
            groupSimilar: true,
            calendar: fixture.store.dateProvider.calendar,
            now: fixture.now
        )

        let descriptions = Set(sections.flatMap { $0.groups.map { $0.lead?.entryDescription ?? "" } })
        #expect(descriptions.contains(idleEntryDescription))
        #expect(sections.flatMap(\.groups).count == 3)
    }

    @Test("An answer about an entry that has since gone is dropped rather than crashing")
    func missingEntryIsHarmless() throws {
        let fixture = try IdleFixture()
        let stale = IdleObservation(
            id: UUID(),
            entryDescription: "gone",
            itemTitle: nil,
            idleSince: fixture.now.addingTimeInterval(-600),
            idleUntil: fixture.now
        )

        try fixture.time.resolveIdle(.discard, for: stale)
        #expect(try fixture.time.runningEntry() == nil)
    }
}
