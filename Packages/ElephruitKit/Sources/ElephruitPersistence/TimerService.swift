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
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) -> Bool {
        perform {
            try entries.start(
                item: item,
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
        description: String = "",
        tagSlugs: [String] = [],
        isBillable: Bool = false
    ) -> Bool {
        perform {
            try entries.switchTo(
                item: item,
                description: description,
                tagSlugs: tagSlugs,
                isBillable: isBillable
            )
        }
    }

    @discardableResult
    public func stop() -> Bool {
        perform { try entries.stopRunning(at: nil) }
    }

    /// Throws the running timer away rather than recording it.
    ///
    /// The button next to Stop, and a different answer to a different question: Stop says the work
    /// happened, this says the timer should never have been running.
    @discardableResult
    public func discard() -> Bool {
        perform { try entries.discardRunning() }
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
