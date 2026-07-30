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

    /// Set when the invariant had to be repaired, so the user can be told rather than have their
    /// timers silently rearranged.
    public private(set) var reconciledTimerCount = 0

    public private(set) var lastError: AppError?

    private var tickTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    /// The last heartbeat this process wrote, so ticking does not write on every second.
    private var lastHeartbeatWrite: Date?

    public init(entries: any TimeEntryRepository, dateProvider: any DateProvider) {
        self.entries = entries
        self.dateProvider = dateProvider
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
    public func start(item: Item?, description: String = "", tagSlugs: [String] = []) -> Bool {
        perform { try entries.start(item: item, description: description, tagSlugs: tagSlugs) }
    }

    /// Stops what is running and starts this instead.
    @discardableResult
    public func switchTo(item: Item?, description: String = "", tagSlugs: [String] = []) -> Bool {
        perform { try entries.switchTo(item: item, description: description, tagSlugs: tagSlugs) }
    }

    @discardableResult
    public func stop() -> Bool {
        perform { try entries.stopRunning(at: nil) }
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
        guard let running else {
            elapsed = 0
            return
        }

        let now = dateProvider.now
        elapsed = running.elapsed(at: now)

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
                // The gap is offered rather than absorbed, on exactly the same terms as a crash.
                self.detectStaleTimer()
                self.refresh()
            }
        }
    }
}
