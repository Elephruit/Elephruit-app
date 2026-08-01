import AppKit
import ElephruitCore
import ElephruitModel
import Foundation
import Observation

/// The running timer, as the rest of the app sees it.
///
/// Owns three things the repository deliberately does not: the tick that makes a clock move, the
/// heartbeat that makes a crash survivable, and the recovery the user has not answered yet.
///
/// ### Why the heartbeat exists
/// Without one, a timer found running after a crash leaves only two honest options — count the whole
/// gap, or throw it away — and both are usually wrong. A heartbeat every thirty seconds means the app
/// can say *"it was definitely running until 14:22"*, which is the only version of this that lets
/// someone answer without guessing.
@Observable
@MainActor
public final class TimerService {
    /// How often the running timer records that it is still alive.
    ///
    /// Thirty seconds: fine-grained enough that a crash loses at most half a minute of certainty,
    /// coarse enough to be one small write per half minute rather than a background job worth
    /// worrying about.
    public static let heartbeatInterval: TimeInterval = 30

    /// How stale a heartbeat has to be before the timer is offered for recovery.
    ///
    /// Ten times the interval. A missed beat or two means the machine was busy; five minutes of
    /// silence means the app was not running.
    public static let stalenessTolerance: TimeInterval = 5 * 60

    private let entries: any TimeEntryRepository
    private let dateProvider: any DateProvider

    /// What the machine says about whether anybody is here.
    private let idleClock: any IdleClock

    /// The rule about when a gap in input becomes a question. See ``IdleDetector``.
    private var idleDetector: IdleDetector

    /// The running timer, or `nil`. A value, so views can read it while drawing.
    public private(set) var running: RunningTimer?

    /// Recomputed on every tick, so a clock face moves without touching the store.
    public private(set) var elapsed: TimeInterval = 0

    /// A timer found running at launch that the user has not decided about yet.
    ///
    /// Presented, never resolved: the app does not pick one of the three choices on the user's
    /// behalf, because each destroys something different and which of those matters is not something
    /// the app can know.
    public private(set) var pendingRecovery: TimerRecovery?

    /// A stretch the timer ran through with nobody at the machine, waiting to be answered for.
    ///
    /// The sibling of ``pendingRecovery`` and a different question: that one asks what happened
    /// while the app was not running, this one asks what happened while it was running and watching
    /// nothing. Presented on the same terms — never resolved by the app, because no heuristic can
    /// tell reading a document from being at lunch.
    public private(set) var pendingIdle: IdleObservation?

    /// Set when the invariant had to be repaired, so the user can be told rather than have their
    /// timers silently rearranged.
    public private(set) var reconciledTimerCount = 0

    // MARK: Focus

    /// The focus cycle currently running, or `nil`.
    ///
    /// Deliberately **not** persisted. A pomodoro is a fact about the next twenty-five minutes of
    /// your attention, and restoring one an hour after the app quit would resume a block nobody is
    /// working. The *time* it produced is durable, because that is written to entries as it happens;
    /// the intention behind it is not, and pretending otherwise would put a bell on the app that
    /// rings for something the user has forgotten they started.
    public private(set) var pomodoro: PomodoroSession?

    /// The lengths a new cycle runs to. Owned by settings and pushed in here.
    public var pomodoroPlan: PomodoroPlan = .standard

    /// Whether a finished phase makes a sound.
    public var playsPomodoroSound = true

    /// A phase that has just ended and has not been acknowledged.
    ///
    /// The banner's content. A value rather than a callback so the same fact can be shown in the
    /// Time view, in the menu bar, and asserted in a test.
    public private(set) var finishedPhase: PomodoroPhase?

    /// Told whenever an entry stops being the running one.
    ///
    /// ### Why a callback rather than the service doing the work
    /// Because what wants to know lives *above* this layer — the calendar mirror is a feature, and
    /// persistence cannot see it without the dependency graph pointing backwards. A closure keeps
    /// the arrow the right way round and keeps this object testable with no calendar at all.
    ///
    /// Fired for every path that closes an entry: stopping, discarding, switching away, a break
    /// beginning, and resolving an idle gap. Missing one of those means an entry that is finished in
    /// the store and still open in whatever is mirroring it.
    public var onEntryFinished: ((UUID) -> Void)?

    /// What to time again when the break ends.
    ///
    /// Held as an id rather than as the entry, because a break can outlive a store change and a
    /// `PersistentModel` cannot be kept across one. Resolved back into an entry at the moment the
    /// next focus block begins, and if it has gone by then the block simply starts untethered rather
    /// than refusing to start.
    private var focusSubjectEntryID: UUID?

    public private(set) var lastError: AppError?

    private var tickTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    /// The last heartbeat this process wrote, so ticking does not write on every second.
    private var lastHeartbeatWrite: Date?

    public init(
        entries: any TimeEntryRepository,
        dateProvider: any DateProvider,
        idleClock: any IdleClock = SystemIdleClock(),
        idleThreshold: TimeInterval = IdleDetector.defaultThreshold
    ) {
        self.entries = entries
        self.dateProvider = dateProvider
        self.idleClock = idleClock
        self.idleDetector = IdleDetector(threshold: idleThreshold)
    }

    // MARK: - Lifecycle

    /// Called once, after the store opens.
    ///
    /// Repairs the invariant if it is broken, offers a stale timer for recovery, and starts ticking
    /// if something is genuinely running.
    public func start() {
        reconcile()
        detectStaleTimer()
        refresh()
        observeSleep()
        startTicking()
    }

    /// Stops ticking and detaches from the workspace. For window teardown and tests.
    ///
    /// Named `shutDown` rather than `stop` because `stop()` already means "stop the running timer",
    /// and two methods a keystroke apart that do entirely different things is how someone ends a
    /// work session by closing a window.
    ///
    /// Deliberately not mirrored in `deinit`: a `deinit` is nonisolated and cannot touch these
    /// properties. It is safe anyway — the observer blocks capture `self` weakly, so one that
    /// outlives the service does nothing at all — and callers that own a service call this.
    public func shutDown() {
        tickTask?.cancel()
        tickTask = nil

        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func reconcile() {
        do {
            reconciledTimerCount = try entries.reconcileConcurrentTimers()
        } catch {
            lastError = error
        }
    }

    /// Looks for a timer that was running when the app stopped.
    private func detectStaleTimer() {
        do {
            guard let stale = try entries.staleRunningEntry(
                tolerance: Self.stalenessTolerance,
                now: dateProvider.now
            ) else { return }

            pendingRecovery = stale.recovery(at: dateProvider.now)
        } catch {
            lastError = error
        }
    }

    // MARK: - Reading

    /// Re-reads the running timer from the store.
    public func refresh() {
        do {
            running = try entries.runningEntry()?.runningSnapshot()
            elapsed = running?.elapsed(at: dateProvider.now) ?? 0
        } catch {
            lastError = error
            running = nil
            elapsed = 0
        }
    }

    public var isRunning: Bool { running != nil }

    /// The elapsed time as a clock face.
    public var elapsedDisplay: String {
        TimeFormatting.stopwatch(elapsed)
    }

    // MARK: - Commands

    @discardableResult
    public func start(
        item: Item?,
        project: Item? = nil,
        people: [Item] = [],
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) -> Bool {
        perform {
            try entries.start(
                item: item,
                project: project,
                people: people,
                description: description,
                tagSlugs: tagSlugs,
                isBillable: isBillable
            )
        }
    }

    /// Stops what is running and starts this instead.
    @discardableResult
    public func switchTo(
        item: Item?,
        project: Item? = nil,
        people: [Item] = [],
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) -> Bool {
        // Captured before the switch, because the entry that just finished is the one anything
        // downstream cares about and it is no longer the running one afterwards.
        let previous = running?.id
        defer { previous.map { onEntryFinished?($0) } }

        return perform {
            try entries.switchTo(
                item: item,
                project: project,
                people: people,
                description: description,
                tagSlugs: tagSlugs,
                isBillable: isBillable
            )
        }
    }

    /// Stops the timer, and with it any focus cycle riding on it.
    ///
    /// The cycle ends rather than pausing, because a pomodoro is a way of working on *something*,
    /// and a cycle that outlived the thing it was counting would come back on the next unrelated
    /// timer as a half-finished round nobody worked.
    @discardableResult
    public func stop() -> Bool {
        pomodoro = nil
        let stopping = running?.id
        let outcome = perform { try entries.stopRunning(at: nil) }
        stopping.map { onEntryFinished?($0) }
        return outcome
    }

    /// Throws the running timer away rather than recording it.
    ///
    /// The button next to Stop, and a different answer to a different question: Stop says the work
    /// happened, this says the timer should never have been running.
    @discardableResult
    public func discard() -> Bool {
        pomodoro = nil
        let discarding = running?.id
        let outcome = perform { try entries.discardRunning() }
        // Announced like any other ending, because a discarded entry may have a copy elsewhere that
        // now has to be taken back.
        discarding.map { onEntryFinished?($0) }
        return outcome
    }

    // MARK: Editing what is running

    /// Rewrites the running entry's description.
    ///
    /// Called as the field commits rather than on every keystroke. A timer's description is
    /// something you finish typing before you care about it being saved, and a write per character
    /// would be a thousand saves for a sentence.
    @discardableResult
    public func setDescription(_ description: String) -> Bool {
        updateRunning { $0.entryDescription = description.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Points the running entry at an item, or at nothing.
    @discardableResult
    public func setSubject(_ item: Item?) -> Bool {
        updateRunning { $0.item = item }
    }

    @discardableResult
    public func setBillable(_ isBillable: Bool) -> Bool {
        updateRunning { $0.isBillable = isBillable }
    }

    @discardableResult
    public func setTags(_ slugs: [String]) -> Bool {
        perform {
            guard let running = try entries.runningEntry() else { return nil }
            try entries.setTags(slugs, on: running)
            return running
        }
    }

    /// Replaces who is here on the running entry.
    @discardableResult
    public func setPeople(_ people: [Item]) -> Bool {
        perform {
            guard let running = try entries.runningEntry() else { return nil }
            try entries.setPeople(people, on: running)
            return running
        }
    }

    /// Points the running entry at a project, overriding the derived one.
    @discardableResult
    public func setProject(_ project: Item?) -> Bool {
        perform {
            guard let running = try entries.runningEntry() else { return nil }
            try entries.setProject(project, on: running)
            return running
        }
    }

    /// Back-dates the running timer so that it has been going for exactly this long.
    ///
    /// The "I started this at two" correction: there is no end to move on something still running,
    /// so the start moves instead. Refuses a duration that would place the start in the future.
    @discardableResult
    public func setElapsed(_ duration: TimeInterval) -> Bool {
        guard duration >= 0 else { return false }
        return perform {
            guard let running = try entries.runningEntry() else { return nil }
            try entries.setDuration(duration, for: running)
            return running
        }
    }

    private func updateRunning(_ mutate: @escaping (TimeEntry) -> Void) -> Bool {
        perform {
            guard let running = try entries.runningEntry() else { return nil }
            try entries.update(running, mutate)
            return running
        }
    }

    /// Starts, or stops if the same item is already being timed.
    ///
    /// What a single button in a task row does. Timing something else switches rather than refusing,
    /// because a button that reports an error when pressed is not a button anyone presses twice.
    @discardableResult
    public func toggle(item: Item) -> Bool {
        if let running, running.itemID == item.id {
            return stop()
        }
        return switchTo(item: item)
    }

    @discardableResult
    public func resume(_ entry: TimeEntry) -> Bool {
        perform { try entries.resume(entry) }
    }

    /// Runs a command, records any failure, and re-reads.
    ///
    /// The closure is untyped-`throws` rather than `throws(AppError)`: a literal containing several
    /// throwing calls does not reliably infer a typed throw, so the type is restored here instead —
    /// the same pattern used everywhere else in this package.
    private func perform(_ body: () throws -> Any?) -> Bool {
        do {
            _ = try body()
            lastError = nil
            refresh()
            return true
        } catch let error as AppError {
            lastError = error
            refresh()
            return false
        } catch {
            lastError = .writeFailed(path: "store", reason: error.localizedDescription)
            refresh()
            return false
        }
    }

    public func clearError() {
        lastError = nil
    }

    public func acknowledgeReconciliation() {
        reconciledTimerCount = 0
    }

    // MARK: - Focus cycles

    /// Whether a focus cycle is running.
    public var isFocusing: Bool { pomodoro != nil }

    /// Starts a focus cycle over whatever is being timed, starting the timer if nothing is.
    ///
    /// One button rather than two. *Start a pomodoro* and *start a timer* are the same intention
    /// stated at two levels of detail, and a user who has to do both in order has to be told about
    /// both — which is one explanation more than the feature is worth.
    @discardableResult
    public func startFocus(
        item: Item? = nil,
        project: Item? = nil,
        people: [Item] = [],
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) -> Bool {
        if running == nil {
            let started = switchTo(
                item: item,
                project: project,
                people: people,
                description: description,
                tagSlugs: tagSlugs,
                isBillable: isBillable
            )
            guard started else { return false }
        }

        pomodoro = .starting(pomodoroPlan, at: dateProvider.now)
        focusSubjectEntryID = running?.id
        finishedPhase = nil
        return true
    }

    /// Ends the cycle, leaving whatever is being timed alone.
    ///
    /// Two separate things end separately, on purpose: somebody who has finished counting rounds is
    /// usually still working, and a button that stopped their timer as well would be one they press
    /// once.
    public func endFocus() {
        pomodoro = nil
        focusSubjectEntryID = nil
        finishedPhase = nil
    }

    public func pauseFocus() {
        guard let pomodoro else { return }
        self.pomodoro = pomodoro.paused(at: dateProvider.now)
    }

    public func resumeFocus() {
        guard let pomodoro else { return }
        self.pomodoro = pomodoro.resumed(at: dateProvider.now)
    }

    /// Moves to the next phase now, without crediting the one being left.
    ///
    /// Skipping a focus block does **not** count it, for the reason the counter exists: a round is
    /// something you worked, and a streak the app hands out for pressing Skip is not a measurement
    /// of anything.
    public func skipFocusPhase() {
        guard let pomodoro else { return }
        let now = dateProvider.now

        if pomodoro.phase == .focus {
            // The block was not finished, so it is not counted — but the *time* still happened and
            // stays on the entry. Only the intention was abandoned.
            self.pomodoro = PomodoroSession(
                plan: pomodoro.plan,
                phase: pomodoro.nextPhase,
                runningSince: now,
                completedFocusRounds: pomodoro.completedFocusRounds
            )
            stopForBreak(at: now)
        } else {
            self.pomodoro = pomodoro.advanced(at: now, running: true)
            beginFocusBlock()
        }

        finishedPhase = nil
    }

    /// Dismisses the banner about a phase that has ended.
    public func acknowledgeFinishedPhase() {
        finishedPhase = nil
    }

    /// Starts the phase that is waiting, when it was not set to start on its own.
    public func beginWaitingPhase() {
        guard let pomodoro, pomodoro.isPaused else { return }
        self.pomodoro = pomodoro.resumed(at: dateProvider.now)
        finishedPhase = nil

        if pomodoro.phase == .focus { beginFocusBlock() }
    }

    /// Advances the cycle when a phase has run its length.
    private func advanceFocusIfDue(at now: Date) {
        guard let session = pomodoro, !session.isPaused, session.hasFinishedPhase(at: now) else { return }

        if session.phase == .focus {
            creditFocusRound()
        }

        let continues = session.nextPhaseStartsAutomatically
        let next = session.advanced(at: now, running: continues)
        pomodoro = next

        // The timer follows the phase. A break is not work, so it is not tracked — the alternative
        // is a day whose totals include forty minutes of coffee, which makes every number on the
        // screen an estimate.
        if next.phase.isBreak {
            stopForBreak(at: now)
        } else if continues {
            beginFocusBlock()
        }

        announce(session.phase)
    }

    /// Counts the block that has just finished, on the entry it was worked against.
    private func creditFocusRound() {
        do {
            guard let entry = try entries.runningEntry() else { return }
            try entries.noteFocusRound(on: entry)
        } catch {
            // A lost count costs a number on a report, not correctness of any recorded time. Logged
            // rather than surfaced: an alert every twenty-five minutes would be worse than the miss.
            Diagnostics.persistence.error("Focus round not recorded: \(error.summary, privacy: .public)")
        }
    }

    /// Stops the timer for a break, remembering what to resume afterwards.
    private func stopForBreak(at now: Date) {
        guard let stopping = running?.id else { return }
        focusSubjectEntryID = stopping
        _ = perform { try entries.stopRunning(at: now) }
        onEntryFinished?(stopping)
    }

    /// Times the same thing again for the next focus block.
    private func beginFocusBlock() {
        guard running == nil else { return }
        _ = perform {
            guard let id = focusSubjectEntryID, let previous = try entries.entry(id: id) else { return nil }
            let resumed = try entries.resume(previous)
            return resumed
        }
        focusSubjectEntryID = running?.id ?? focusSubjectEntryID
    }

    /// Says a phase has ended, as loudly as an app with no notification permission can.
    ///
    /// ### Why this is not a Notification Center alert
    /// Because that needs a permission prompt, and this app has never shown one. Asking for
    /// notification access is a decision with its own settings row and its own explanation of what
    /// will and will not be sent — not something to acquire as a side effect of a focus timer. Until
    /// that is built, a sound and a bouncing icon reach somebody in another app, which is the case
    /// that matters, and the banner in the Time view says what happened when they come back.
    private func announce(_ phase: PomodoroPhase) {
        finishedPhase = phase
        if playsPomodoroSound { NSSound.beep() }
        NSApp?.requestUserAttention(.informationalRequest)
    }

    // MARK: - Recovery

    /// Applies the user's decision, and only the user's decision.
    public func resolveRecovery(_ choice: TimerRecoveryChoice) {
        guard let pending = pendingRecovery else { return }

        do {
            guard let entry = try entries.entry(id: pending.id) else {
                pendingRecovery = nil
                return
            }
            try entries.resolveRecovery(choice, for: entry)
            pendingRecovery = nil
            refresh()
            onEntryFinished?(pending.id)
        } catch {
            lastError = error
        }
    }

    /// Dismisses the prompt without deciding.
    ///
    /// The timer stays exactly as it was and will be offered again next launch. Not deciding is a
    /// legitimate answer to a question about the past, and forcing a choice to close a banner is how
    /// people end up discarding a day's work by reflex.
    public func deferRecovery() {
        pendingRecovery = nil
    }

    // MARK: - Idle

    /// Applies the user's decision about an idle stretch, and only the user's decision.
    public func resolveIdle(_ choice: IdleChoice) {
        guard let pending = pendingIdle else { return }

        do {
            try entries.resolveIdle(choice, for: pending)
            pendingIdle = nil
            refresh()
            onEntryFinished?(pending.id)
        } catch {
            lastError = error
        }
    }

    /// Dismisses the question without answering it, keeping the gap.
    ///
    /// Unlike a recovered timer this is *not* offered again: the gap has already been counted as
    /// worked by the timer that ran through it, and re-asking about the same minutes every tick
    /// would be nagging rather than care.
    public func deferIdle() {
        pendingIdle = nil
    }

    /// Notices a gap in input that has just ended.
    ///
    /// Skipped entirely while a recovery is pending, because a sleep long enough to produce one has
    /// also produced a gap in input, and asking the same question in two banners with two different
    /// sets of answers is worse than asking it once.
    private func checkIdle(at now: Date) {
        guard pendingRecovery == nil else {
            idleDetector.reset()
            return
        }

        // Nobody is at the machine during a break. That is what a break is, and asking about it
        // afterwards would be the app noticing its own instruction being followed.
        if let pomodoro, pomodoro.phase.isBreak, !pomodoro.isPaused {
            idleDetector.reset()
            return
        }

        let gap = idleDetector.observe(
            secondsSinceInput: idleClock.secondsSinceLastInput,
            now: now,
            timerStartedAt: running?.startedAt
        )

        guard let gap, let running, pendingIdle == nil else { return }

        pendingIdle = IdleObservation(
            id: running.id,
            entryDescription: running.entryDescription,
            itemTitle: running.itemTitle,
            idleSince: gap.from,
            idleUntil: gap.to
        )
    }

    // MARK: - Ticking and heartbeat

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func tick() {
        let now = dateProvider.now

        // Before the early return, because a break is a phase with no timer running and it still has
        // to end. A cycle that only advanced while something was being tracked would sit on the
        // screen at 0:00 until somebody started working again.
        advanceFocusIfDue(at: now)

        guard let running else {
            elapsed = 0
            // Still fed while nothing runs, so an open gap is closed rather than left to be
            // reported against whatever timer starts next.
            checkIdle(at: now)
            return
        }

        elapsed = running.elapsed(at: now)
        checkIdle(at: now)

        // The clock ticks every second; the store is written every thirty. A timer that wrote once a
        // second would be a hundred thousand writes a day for no gain.
        let due = lastHeartbeatWrite.map { now.timeIntervalSince($0) >= Self.heartbeatInterval } ?? true
        guard due else { return }

        writeHeartbeat(at: now)
    }

    private func writeHeartbeat(at date: Date) {
        do {
            try entries.recordHeartbeat(at: date)
            lastHeartbeatWrite = date
        } catch {
            // A failed heartbeat costs accuracy in a future recovery, not correctness now. Logged,
            // not surfaced: an alert every thirty seconds would be worse than the problem.
            Diagnostics.persistence.error("Heartbeat failed: \(error.summary, privacy: .public)")
        }
    }

    // MARK: - Sleep

    /// Writes a heartbeat as the machine goes to sleep, and re-reads on waking.
    ///
    /// Sleep is the ordinary case this has to get right — far more common than a crash. Closing the
    /// lid at 18:00 and opening it at 09:00 should offer the fifteen-hour gap for a decision, not
    /// quietly bill it.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.writeHeartbeat(at: self.dateProvider.now)
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The gap is offered rather than absorbed, on exactly the same terms as a crash —
                // and by crash recovery rather than by idle detection, which is told to forget the
                // sleep so the same minutes are not queried twice.
                self.idleDetector.reset()
                self.detectStaleTimer()
                self.refresh()
            }
        }
    }
}
