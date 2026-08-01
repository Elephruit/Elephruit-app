import ElephruitCore
import ElephruitPersistence
import Foundation
import Observation

/// Runs the Reminders sync when something has happened, rather than only when asked.
///
/// ### Why this type has to exist
/// Before it, every path to a sync was a control somebody had to press: a button in Settings, a
/// button in the task workspace, and a swipe action on a row. Nothing ran a pass at launch, nothing
/// ran one when the app came back to the front, and nothing watched `EKEventStoreChanged` — so a
/// reminder added on a phone never arrived, a reminder ticked off in Apple's own app stayed open
/// here, and linking the integration imported nothing until the user went looking for a control they
/// had no reason to know existed.
///
/// The engine was also being handed an inert adapter, which is fixed separately. Both had to be true
/// for reminders to appear, and either alone is enough to make the feature look broken.
///
/// ### Why the notification is coalesced
/// `EKEventStoreChanged` is posted generously, and — unlike the address book — it is posted for
/// *this app's own writes* as well as for other devices'. A pass that ran on each notification would
/// push a change, be told the store changed, push again, and never settle. The debounce collapses a
/// burst into one run; `RemindersService.sync(using:)` refuses to re-enter, which closes the loop
/// properly. The debounce alone would only make it slower.
///
/// ### Why it is safe to run on every activation
/// `reconcile()` is idempotent: a pass that finds nothing to do writes nothing and reports nothing.
/// The fingerprint it compares against is taken from the reminder as it came back from the store, so
/// an unchanged task does not look changed on the next pass. Running it often is therefore cheap,
/// and it is the only way a change made elsewhere arrives without being asked for.
@Observable
@MainActor
public final class ReminderRefreshCoordinator {
    /// The last pass that finished, whether or not it changed anything.
    public private(set) var lastReport: ReminderSyncReport?

    /// When the last pass completed without failures. `nil` until one has.
    public private(set) var lastSuccessAt: Date?

    /// Why the last pass could not run or could not finish. `nil` when the last one was clean.
    public private(set) var lastFailure: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Long enough to swallow the burst that follows one edit — including the notifications caused
    /// by this app's own writes — and short enough that a reminder ticked off on a phone appears
    /// while the user is still looking at the window.
    static let coalescingDelay = Duration.seconds(2)

    public init(services: AppServices) {
        self.services = services
    }

    deinit {
        observationTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Observation

    /// Starts watching the store, and runs the pass that should have happened at launch.
    ///
    /// Safe to call repeatedly — the previous observation is replaced — which is what makes it the
    /// right thing to call again after the user links the integration, since the adapter it needs to
    /// watch did not exist until then.
    public func start() {
        observationTask?.cancel()
        observationTask = nil

        guard services.reminders.isEnabled else { return }

        let stream = services.reminders.changes
        observationTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.scheduleCoalescedSync()
            }
        }

        Task { [weak self] in await self?.sync(reason: "launch") }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// The app came back to the front. Anything that happened on another device while it was away
    /// arrives now.
    public func applicationDidBecomeActive() {
        guard services.reminders.isEnabled else { return }
        Task { [weak self] in await self?.sync(reason: "activation") }
    }

    private func scheduleCoalescedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard !Task.isCancelled else { return }
            await self?.sync(reason: "store change")
        }
    }

    // MARK: - Syncing

    /// Runs a pass and records what happened, for the status line in Settings.
    ///
    /// The reason is logged, never the content: which lists a person keeps and what is on them is
    /// exactly the sort of thing that should not end up in a system log. Counts and outcomes are
    /// safe and are what a support question actually needs.
    @discardableResult
    public func sync(reason: String) async -> ReminderSyncReport? {
        guard services.reminders.isEnabled else { return nil }

        await services.reminders.refresh()

        guard services.reminders.authorization.canRead else {
            lastFailure = services.reminders.authorization.explanation
                ?? "Reminders access has not been granted."
            Diagnostics.integrations.info(
                "Reminders sync skipped (\(reason, privacy: .public)): no read access"
            )
            return nil
        }

        guard let report = await services.reminders.sync(using: services.reminderSync) else {
            // Another pass is already in flight. Not a failure, and not something to report as one.
            return nil
        }

        lastReport = report
        if report.failures.isEmpty {
            lastSuccessAt = services.dateProvider.now
            lastFailure = nil
        } else {
            lastFailure = report.failures.first
        }

        Diagnostics.integrations.info(
            """
            Reminders sync (\(reason, privacy: .public)): \
            examined \(report.examined, privacy: .public), \
            imported \(report.imported, privacy: .public), \
            adopted \(report.adopted, privacy: .public), \
            pushed \(report.pushed, privacy: .public), \
            conflicted \(report.conflicted, privacy: .public), \
            missing \(report.missing, privacy: .public), \
            failures \(report.failures.count, privacy: .public)
            """
        )

        if report.changedAnything {
            services.refreshDerivedState()
        }

        return report
    }
}
