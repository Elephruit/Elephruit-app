import Foundation
import Testing

@testable import ElephruitCore

/// The focus cycle, asserted rather than watched.
///
/// Every rule here is one somebody would otherwise have to sit through twenty-five minutes to check,
/// which is exactly why the state machine has no clock of its own.
@Suite("Pomodoro")
struct PomodoroTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private var plan: PomodoroPlan {
        PomodoroPlan(focus: 25 * 60, shortBreak: 5 * 60, longBreak: 15 * 60, roundsBeforeLongBreak: 4)
    }

    // MARK: - Lengths

    @Test("A phase shorter than a minute is refused, not honoured")
    func phasesAreClamped() {
        let silly = PomodoroPlan(focus: 0, shortBreak: -30, longBreak: 99 * 3_600, roundsBeforeLongBreak: 0)

        // A zero-length focus phase would end the instant it began, forever.
        #expect(silly.focus == PomodoroPlan.minimumPhase)
        #expect(silly.shortBreak == PomodoroPlan.minimumPhase)
        #expect(silly.longBreak == PomodoroPlan.maximumPhase)
        #expect(silly.roundsBeforeLongBreak == 1)
    }

    @Test("A set is the blocks, the breaks between them, and the long one at the end")
    func setLengthAddsUp() {
        // 4 × 25 + 3 × 5 + 15 = 130 minutes.
        #expect(plan.setLength == 130 * 60)
    }

    // MARK: - Running

    @Test("Remaining time counts down and floors at zero")
    func remainingCountsDown() {
        let session = PomodoroSession.starting(plan, at: start)

        #expect(session.remaining(at: start) == 25 * 60)
        #expect(session.remaining(at: start.addingTimeInterval(600)) == 15 * 60)
        // Past the end it is zero rather than negative: a clock that counts backwards past nought is
        // a clock that renders "-3:00" in the menu bar.
        #expect(session.remaining(at: start.addingTimeInterval(30 * 60)) == 0)
    }

    @Test("Progress is clamped to nought and one")
    func progressIsClamped() {
        let session = PomodoroSession.starting(plan, at: start)

        #expect(session.progress(at: start) == 0)
        #expect(abs(session.progress(at: start.addingTimeInterval(750)) - 0.5) < 0.0001)
        #expect(session.progress(at: start.addingTimeInterval(9_999)) == 1)
    }

    @Test("A phase is finished only once its whole length has run")
    func phaseFinishesOnLength() {
        let session = PomodoroSession.starting(plan, at: start)

        #expect(!session.hasFinishedPhase(at: start.addingTimeInterval(25 * 60 - 1)))
        #expect(session.hasFinishedPhase(at: start.addingTimeInterval(25 * 60)))
    }

    // MARK: - Pausing

    @Test("A pause keeps the time already run and stops the clock")
    func pauseHoldsElapsed() {
        let session = PomodoroSession.starting(plan, at: start)
        let paused = session.paused(at: start.addingTimeInterval(600))

        #expect(paused.isPaused)
        #expect(paused.elapsed(at: start.addingTimeInterval(6_000)) == 600)

        // Resuming an hour later does not charge the hour to the phase, which is the whole reason a
        // pause forgets when it started rather than moving the start date.
        let resumed = paused.resumed(at: start.addingTimeInterval(6_000))
        #expect(resumed.elapsed(at: start.addingTimeInterval(6_060)) == 660)
    }

    @Test("Pausing twice does not restart the accounting")
    func pauseIsIdempotent() {
        let paused = PomodoroSession.starting(plan, at: start).paused(at: start.addingTimeInterval(300))
        #expect(paused.paused(at: start.addingTimeInterval(900)).elapsedBeforePause == 300)
    }

    // MARK: - The cycle

    @Test("A short break follows every block but the last of the set")
    func shortBreakFollowsOrdinaryBlocks() {
        var session = PomodoroSession.starting(plan, at: start)

        #expect(session.nextPhase == .shortBreak)

        session = session.advanced(at: start, running: true)
        #expect(session.phase == .shortBreak)
        #expect(session.completedFocusRounds == 1)
        #expect(session.nextPhase == .focus)
    }

    @Test("The long break comes after the last block of the set, not before it")
    func longBreakClosesTheSet() {
        var session = PomodoroSession.starting(plan, at: start)

        // Three whole rounds of focus-then-break.
        for _ in 0..<3 {
            session = session.advanced(at: start, running: true)  // into a short break
            session = session.advanced(at: start, running: true)  // back into focus
        }

        #expect(session.completedFocusRounds == 3)
        #expect(session.phase == .focus)
        #expect(session.nextPhase == .longBreak)

        session = session.advanced(at: start, running: true)
        #expect(session.phase == .longBreak)
        #expect(session.completedFocusRounds == 4)
    }

    @Test("Focus follows a long break, because stopping is the user's decision")
    func aLongBreakStartsTheNextSet() {
        let session = PomodoroSession(plan: plan, phase: .longBreak, runningSince: start, completedFocusRounds: 4)
        #expect(session.nextPhase == .focus)
        #expect(session.advanced(at: start, running: true).completedFocusRounds == 4)
    }

    @Test("Only a finished block moves the counter, so four phases are not four rounds")
    func breaksDoNotEarnRounds() {
        var session = PomodoroSession(plan: plan, phase: .shortBreak, runningSince: start)

        // Four advances from a break is break → focus → break → focus → break: two blocks worked,
        // not four. A counter that moved on every phase would hand out a completed set for sitting
        // through two coffees.
        for _ in 0..<4 {
            session = session.advanced(at: start, running: true)
        }

        #expect(session.completedFocusRounds == 2)
    }

    @Test("Breaks start themselves; work does not")
    func onlyBreaksAreAutomatic() {
        // The asymmetry is the point: an ignored break costs nothing, and work that starts by itself
        // begins a timer against your name while you are still in the kitchen.
        let focus = PomodoroSession.starting(plan, at: start)
        #expect(focus.nextPhaseStartsAutomatically)

        let onBreak = focus.advanced(at: start, running: true)
        #expect(!onBreak.nextPhaseStartsAutomatically)
    }

    @Test("Restarting a phase keeps the rounds already worked")
    func restartKeepsRounds() {
        let session = PomodoroSession(plan: plan, phase: .focus, runningSince: start, completedFocusRounds: 2)
        let restarted = session.restartedPhase(at: start.addingTimeInterval(300))

        #expect(restarted.completedFocusRounds == 2)
        #expect(restarted.elapsed(at: start.addingTimeInterval(300)) == 0)
    }

    // MARK: - What it says

    @Test("The round line counts from one and never runs past the set")
    func roundDescriptionStaysInRange() {
        #expect(PomodoroSession.starting(plan, at: start).roundDescription == "Round 1 of 4")

        let third = PomodoroSession(plan: plan, phase: .focus, runningSince: start, completedFocusRounds: 2)
        #expect(third.roundDescription == "Round 3 of 4")

        // A break belongs to the round it follows: resting after the fourth block is round four, not
        // a congratulation for a fifth nobody has started.
        let done = PomodoroSession(plan: plan, phase: .longBreak, runningSince: start, completedFocusRounds: 4)
        #expect(done.roundDescription == "Round 4 of 4")
    }
}
