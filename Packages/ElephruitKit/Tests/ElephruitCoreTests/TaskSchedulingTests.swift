import ElephruitCore
import Foundation
import Testing

/// A fixed Monday, in GMT, so every assertion below means the same thing wherever it runs.
private let clock = FixedDateProvider.reference  // 2026-06-15 09:00 GMT, a Monday
private var calendar: Calendar { clock.calendar }
private var now: Date { clock.now }

private func day(_ offset: Int) -> Date {
    clock.startOfDay(daysFromToday: offset)
}

private func instant(_ dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(dayOffset)) ?? day(dayOffset)
}

private func task(
    _ configure: (inout TaskFacts) -> Void = { _ in }
) -> TaskFacts {
    var facts = TaskFacts(title: "A task", hasHome: true, createdAt: now, updatedAt: now)
    configure(&facts)
    return facts
}

// MARK: - Start dates

@Suite("A start date is availability, never a deadline")
struct StartDateTests {
    @Test("A future start date makes a task unavailable until it arrives")
    func futureStartIsNotAvailable() {
        let facts = task { $0.startAt = day(3) }

        #expect(facts.availability(on: now, calendar: calendar) == .scheduled(day(3)))
        #expect(!TaskViewRules.isInAnytime(facts, now: now, calendar: calendar))
    }

    @Test("A start date arriving today makes the task available and puts it in Today")
    func startTodayIsAvailable() {
        let facts = task { $0.startAt = day(0) }

        #expect(facts.availability(on: now, calendar: calendar).isAvailable)
        #expect(TaskViewRules.isInAnytime(facts, now: now, calendar: calendar))
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .today)
    }

    @Test("A start date that has passed leaves the task available and unremarkable")
    func pastStartIsMerelyAvailable() {
        let facts = task { $0.startAt = day(-5) }

        #expect(facts.availability(on: now, calendar: calendar).isAvailable)
        #expect(TaskViewRules.isInAnytime(facts, now: now, calendar: calendar))
        // The crux: a start date in the past is not lateness.
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .none)
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
    }

    @Test("A start date later today still counts as today, not tomorrow")
    func startLaterTodayCountsAsToday() {
        let facts = task { $0.startAt = instant(0, hour: 23, minute: 59) }
        #expect(facts.availability(on: now, calendar: calendar).isAvailable)
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .today)
    }
}

// MARK: - Deadlines

@Suite("Deadline urgency")
struct DeadlineTests {
    @Test("A deadline today reads as today, not as overdue")
    func deadlineToday() {
        let facts = task { $0.deadlineAt = instant(0, hour: 17) }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .today)
    }

    @Test("A deadline earlier today is still today until the day ends")
    func deadlineEarlierToday() {
        // 08:00 against a 09:00 clock. The deadline has passed as an instant and not as a day, and
        // a task manager that reddens at one minute past the hour is one nobody keeps deadlines in.
        let facts = task { $0.deadlineAt = instant(0, hour: 8) }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .today)
    }

    @Test("Yesterday's deadline is one day late", arguments: [1, 2, 30])
    func overdueCountsWholeDays(daysLate: Int) {
        let facts = task { $0.deadlineAt = day(-daysLate) }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .overdue(days: daysLate))
    }

    @Test("Beyond the horizon a deadline is distant rather than soon")
    func distantDeadline() {
        let facts = task { $0.deadlineAt = day(30) }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .distant)
        #expect(facts.deadlineUrgency(on: now, calendar: calendar, horizon: 45) == .soon(days: 30))
    }

    @Test("A completed task has no urgency, however late it was")
    func resolvedTaskIsNotOverdue() {
        let facts = task {
            $0.deadlineAt = day(-10)
            $0.status = .completed
            $0.completedAt = now
        }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .none)
    }

    @Test("A start date alone never produces urgency")
    func startDateProducesNoUrgency() {
        let facts = task { $0.startAt = day(-10) }
        #expect(facts.deadlineUrgency(on: now, calendar: calendar) == .none)
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
    }
}

// MARK: - Today

@Suite("Today is a plan, not a pile")
struct TodayMembershipTests {
    @Test("An ordinary available task is not in Today merely for being available")
    func availableWorkIsNotAutomaticallyToday() {
        let facts = task()
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
        #expect(TaskViewRules.isInAnytime(facts, now: now, calendar: calendar))
    }

    @Test("Committing a task to today puts it in Today")
    func commitment() {
        let facts = task { $0.todayCommittedOn = day(0) }
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .today)
    }

    @Test("A commitment made on an earlier day carries forward")
    func commitmentCarriesForward() {
        let facts = task { $0.todayCommittedOn = day(-4) }
        #expect(facts.isCommittedToToday(on: now, calendar: calendar))
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .today)
    }

    @Test("A commitment made for a future day is not today's problem yet")
    func futureCommitmentIsNotToday() {
        let facts = task { $0.todayCommittedOn = day(2) }
        #expect(!facts.isCommittedToToday(on: now, calendar: calendar))
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
    }

    @Test("Later Today applies only to a commitment made for today itself")
    func laterTodayNeedsACommitmentForToday() {
        let fresh = task {
            $0.todayCommittedOn = day(0)
            $0.isLaterToday = true
        }
        #expect(TaskViewRules.todaySection(for: fresh, now: now, calendar: calendar) == .laterToday)

        let carried = task {
            $0.todayCommittedOn = day(-1)
            $0.isLaterToday = true
        }
        // Yesterday has no back half left to sit in.
        #expect(TaskViewRules.todaySection(for: carried, now: now, calendar: calendar) == .today)
    }

    @Test("Overdue work is its own section, above the plan")
    func overdueSection() {
        let facts = task { $0.deadlineAt = day(-2) }
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .overdue)
        #expect(TodaySection.overdue.rank < TodaySection.today.rank)
    }

    @Test("Overdue beats Later Today: lateness is not something to push to this evening")
    func overdueBeatsLaterToday() {
        let facts = task {
            $0.deadlineAt = day(-1)
            $0.todayCommittedOn = day(0)
            $0.isLaterToday = true
        }
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == .overdue)
    }

    @Test("Someday work never reaches Today, however it is dated")
    func somedayIsNeverToday() {
        let facts = task {
            $0.isSomeday = true
            $0.deadlineAt = day(-3)
            $0.startAt = day(0)
        }
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
        #expect(!TaskViewRules.isInAnytime(facts, now: now, calendar: calendar))
        #expect(!facts.lifecycle.competesForAttention)
    }

    @Test("A waiting task reaches Today only on its follow-up day")
    func waitingSurfacesOnFollowUp() {
        let quiet = task {
            $0.waitingSince = day(-7)
            $0.followUpAt = day(3)
        }
        #expect(TaskViewRules.todaySection(for: quiet, now: now, calendar: calendar) == nil)

        let due = task {
            $0.waitingSince = day(-7)
            $0.followUpAt = day(0)
        }
        #expect(TaskViewRules.todaySection(for: due, now: now, calendar: calendar) == .today)
    }

    @Test("A finished task is in no section at all")
    func resolvedIsNowhere() {
        let facts = task {
            $0.todayCommittedOn = day(0)
            $0.status = .completed
            $0.completedAt = now
        }
        #expect(TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) == nil)
        #expect(TaskViewRules.isInCompleted(facts))
    }
}

// MARK: - Lifecycle

@Suite("Lifecycle is derived, and the precedence is deliberate")
struct LifecycleTests {
    @Test("An unfiled open task is in the Inbox")
    func unfiledIsInbox() {
        let facts = task { $0.hasHome = false }
        #expect(facts.lifecycle == .inbox)
        #expect(TaskViewRules.isInInbox(facts))
    }

    @Test("A tag is a home, so a tagged capture leaves the Inbox")
    func filedLeavesInbox() {
        let facts = task { $0.hasHome = true }
        #expect(facts.lifecycle == .active)
    }

    @Test("Someday beats waiting: a parked task is parked, not blocked")
    func somedayBeatsWaiting() {
        let facts = task {
            $0.isSomeday = true
            $0.waitingSince = day(-1)
        }
        #expect(facts.lifecycle == .someday)
    }

    @Test("Waiting beats the Inbox: chasing somebody is processing")
    func waitingBeatsInbox() {
        let facts = task {
            $0.hasHome = false
            $0.waitingSince = day(-1)
        }
        #expect(facts.lifecycle == .waiting)
    }

    @Test("Completion beats every mark")
    func completionWins() {
        let facts = task {
            $0.isSomeday = true
            $0.waitingSince = day(-1)
            $0.status = .completed
            $0.completedAt = now
        }
        #expect(facts.lifecycle == .completed)
    }

    @Test("Cancelled work is history, and the log keeps it")
    func cancelledIsHistory() {
        let facts = task {
            $0.status = .cancelled
            $0.cancelledAt = now
        }
        #expect(facts.lifecycle == .cancelled)
        #expect(TaskViewRules.isInCompleted(facts))
        #expect(!facts.lifecycle.competesForAttention)
    }
}

// MARK: - Invariants

@Suite("Contradictory marks are corrected, not refused")
struct InvariantTests {
    @Test("Completing a waiting task stops it waiting")
    func completionClearsWaiting() {
        var facts = task {
            $0.waitingSince = day(-3)
            $0.waitingOnPersonID = UUID()
            $0.followUpAt = day(2)
            $0.status = .completed
            $0.completedAt = now
        }
        let corrections = TaskInvariants.normalise(&facts)

        #expect(facts.waitingSince == nil)
        #expect(facts.waitingOnPersonID == nil)
        #expect(facts.followUpAt == nil)
        #expect(corrections.contains { $0.field == "waiting" })
    }

    @Test("Completing a task takes it off today's plan")
    func completionClearsToday() {
        var facts = task {
            $0.todayCommittedOn = day(0)
            $0.isLaterToday = true
            $0.status = .completed
            $0.completedAt = now
        }
        TaskInvariants.normalise(&facts)

        #expect(facts.todayCommittedOn == nil)
        #expect(!facts.isLaterToday)
    }

    @Test("A cancelled task sends no notifications")
    func cancelledSendsNothing() {
        var facts = task {
            $0.reminderAt = instant(1, hour: 9)
            $0.reminderOwner = .app
            $0.status = .cancelled
            $0.cancelledAt = now
        }
        let corrections = TaskInvariants.normalise(&facts)

        #expect(facts.reminderAt == nil)
        #expect(facts.reminderOwner == .none)
        #expect(corrections.contains { $0.field == "reminder" })
    }

    @Test("Parking a task takes it off today")
    func somedayClearsToday() {
        var facts = task {
            $0.todayCommittedOn = day(0)
            $0.isSomeday = true
        }
        TaskInvariants.normalise(&facts)

        #expect(facts.todayCommittedOn == nil)
        #expect(!facts.isLaterToday)
    }

    @Test("Later Today without a commitment is dropped")
    func strandedLaterToday() {
        var facts = task { $0.isLaterToday = true }
        TaskInvariants.normalise(&facts)
        #expect(!facts.isLaterToday)
    }

    @Test("A follow-up date needs somebody to chase")
    func strandedFollowUp() {
        var facts = task { $0.followUpAt = day(4) }
        TaskInvariants.normalise(&facts)
        #expect(facts.followUpAt == nil)
    }

    @Test("A reminder always has an owner, and an owner always has a reminder")
    func reminderOwnership() {
        var withoutOwner = task { $0.reminderAt = instant(1, hour: 9) }
        TaskInvariants.normalise(&withoutOwner)
        #expect(withoutOwner.reminderOwner == .app)

        var withoutReminder = task { $0.reminderOwner = .system }
        TaskInvariants.normalise(&withoutReminder)
        #expect(withoutReminder.reminderOwner == .none)
    }

    @Test("A completion date and a completed status are one fact")
    func completionStampIsKeptHonest() {
        var missing = task { $0.status = .completed }
        TaskInvariants.normalise(&missing)
        #expect(missing.completedAt != nil)

        var stale = task { $0.completedAt = day(-1) }
        TaskInvariants.normalise(&stale)
        #expect(stale.completedAt == nil)
    }

    @Test("Dates the wrong way round are reported rather than silently rewritten")
    func dateOrderIsReported() {
        let backwards = task {
            $0.startAt = day(5)
            $0.deadlineAt = day(2)
        }
        #expect(!TaskInvariants.datesAreOrdered(backwards))

        var copy = backwards
        TaskInvariants.normalise(&copy)
        // Which of the two the user meant to move is not knowable here, so neither is touched.
        #expect(copy.startAt == day(5))
        #expect(copy.deadlineAt == day(2))
    }

    @Test("Normalising an ordinary task changes nothing")
    func normalisationIsQuietWhenItShouldBe() {
        var facts = task {
            $0.startAt = day(1)
            $0.deadlineAt = day(4)
            $0.isFlagged = true
        }
        let before = facts
        let corrections = TaskInvariants.normalise(&facts)

        #expect(corrections.isEmpty)
        #expect(facts == before)
    }
}

// MARK: - Upcoming

@Suite("Upcoming distinguishes what kind of date it is showing")
struct UpcomingTests {
    private var horizon: Range<Date> { day(0)..<day(60) }

    @Test("A task with a start date and a deadline appears twice, once for each")
    func twoDatesTwoEntries() {
        let facts = task {
            $0.startAt = day(3)
            $0.deadlineAt = day(10)
        }
        let entries = TaskViewRules.upcomingEntries(for: facts, in: horizon, calendar: calendar)

        #expect(entries.count == 2)
        #expect(entries.contains { $0.day == day(3) && $0.reason == .becomesAvailable })
        #expect(entries.contains { $0.day == day(10) && $0.reason == .deadline })
    }

    @Test("A reminder carries its time, so an agenda can show it")
    func reminderCarriesTime() {
        let fireAt = instant(2, hour: 14, minute: 30)
        let facts = task { $0.reminderAt = fireAt }
        let entries = TaskViewRules.upcomingEntries(for: facts, in: horizon, calendar: calendar)

        #expect(entries == [UpcomingEntry(taskID: facts.id, day: day(2), reason: .reminder(fireAt))])
    }

    @Test("Nothing in an agenda claims to occupy time")
    func nothingOccupiesTime() {
        // An undated obligation drawn as though it filled a slot is an agenda lying about how much
        // of the day is spoken for.
        for reason in [UpcomingReason.becomesAvailable, .deadline, .reminder(now), .followUp] {
            #expect(!reason.occupiesTime)
        }
    }

    @Test("Someday and finished work contribute nothing")
    func parkedAndDoneAreAbsent() {
        let parked = task {
            $0.isSomeday = true
            $0.deadlineAt = day(4)
        }
        let done = task {
            $0.status = .completed
            $0.completedAt = now
            $0.deadlineAt = day(4)
        }
        #expect(TaskViewRules.upcomingEntries(for: parked, in: horizon, calendar: calendar).isEmpty)
        #expect(TaskViewRules.upcomingEntries(for: done, in: horizon, calendar: calendar).isEmpty)
    }

    @Test("Dates outside the window are left out")
    func windowIsRespected() {
        let facts = task { $0.deadlineAt = day(100) }
        #expect(TaskViewRules.upcomingEntries(for: facts, in: horizon, calendar: calendar).isEmpty)
    }
}

@Suite("The agenda shows near days one at a time and collapses the rest")
struct AgendaTests {
    private func entry(_ dayOffset: Int) -> UpcomingEntry {
        UpcomingEntry(taskID: UUID(), day: day(dayOffset), reason: .deadline)
    }

    @Test("Near days are emitted even when empty, because an empty day is where the next thing goes")
    func nearDaysAreAlwaysShown() {
        let groups = UpcomingAgenda.groups(
            from: [entry(2)],
            startingAt: now,
            horizon: AgendaHorizon(dayCount: 5, weekCount: 0, collapsesRemainderIntoMonths: false),
            calendar: calendar
        )

        #expect(groups.count == 5)
        #expect(groups.allSatisfy { if case .day = $0.span { true } else { false } })
        #expect(groups[2].entries.count == 1)
        #expect(groups[0].entries.isEmpty)
    }

    @Test("Far bands appear only when they hold something")
    func farBandsAreSuppressedWhenEmpty() {
        let groups = UpcomingAgenda.groups(
            from: [entry(1), entry(40)],
            startingAt: now,
            horizon: AgendaHorizon(dayCount: 3, weekCount: 2),
            calendar: calendar
        )

        let months = groups.filter { if case .month = $0.span { true } else { false } }
        #expect(months.count == 1)
        #expect(months.first?.entries.count == 1)
        // No empty week bands between the days and the month.
        #expect(groups.filter { if case .week = $0.span { true } else { false } }.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("Every entry lands in exactly one band")
    func nothingIsLostOrDuplicated() {
        let entries = (0..<90).map { entry($0) }
        let groups = UpcomingAgenda.groups(from: entries, startingAt: now, calendar: calendar)
        let placed = groups.flatMap(\.entries)

        #expect(placed.count == entries.count)
        #expect(Set(placed.map(\.id)).count == entries.count)
    }

    @Test("Bands come out in date order")
    func bandsAreOrdered() {
        let groups = UpcomingAgenda.groups(
            from: (0..<120).map { entry($0) },
            startingAt: now,
            calendar: calendar
        )
        #expect(groups.map(\.start) == groups.map(\.start).sorted())
    }
}
