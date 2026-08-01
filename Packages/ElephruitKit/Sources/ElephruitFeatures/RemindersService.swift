import ElephruitCore
import ElephruitIntegrations
import ElephruitPersistence
import Foundation
import Observation

/// The Reminders integration's on/off switch, its permission state, and which lists take part.
///
/// ### Nothing happens until the user says so
/// The adapter is built **lazily**, and only once the feature is enabled. An app that never turns
/// Reminders on never constructs an `EKEventStore`, never triggers a TCC prompt, and holds an inert
/// `NoRemindersProvider` through which every code path still runs — so the denied case is exercised
/// from the first launch rather than being an untested branch.
///
/// ### Why the lists are opt-in rather than all-in
/// Somebody with a shared house list, a work list, and a list of birthday ideas does not
/// necessarily want all three in their task manager, and the cost of guessing wrong is that private
/// context leaks into a workspace they show at a desk. So no list participates until it is chosen,
/// and the choice is per-device — it is a statement about this Mac's behaviour, not about the data.
@Observable
@MainActor
public final class RemindersService {
    /// The one provider, built on first enable and kept.
    ///
    /// Held as the protocol so nothing downstream can reach the EventKit store, and so a test can
    /// hand in the in-memory fixture.
    public private(set) var provider: any RemindersProviding

    public private(set) var authorization: IntegrationAuthorization = .notRequested

    /// The user's lists, once access has been granted. Empty otherwise, which is a legitimate state
    /// with nothing in it rather than an error to handle at every call site.
    public private(set) var lists: [ReminderListSummary] = []

    /// The outcome of the last reconciliation, shown once and then left alone.
    public private(set) var lastReport: ReminderSyncReport?

    public private(set) var isSyncing = false

    @ObservationIgnored private let dateProvider: any DateProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeProvider: @Sendable () -> any RemindersProviding

    public init(
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard,
        makeProvider: @escaping @Sendable () -> any RemindersProviding
    ) {
        self.dateProvider = dateProvider
        self.defaults = defaults
        self.makeProvider = makeProvider
        self.provider = NoRemindersProvider()

        // A previously-enabled integration is reconnected on the next launch, but the *adapter* is
        // still only built when something asks for it — see `activate()`.
        if isEnabled { provider = makeProvider() }
    }

    // MARK: - Preferences

    private static let enabledKey = "reminders.enabled"
    private static let listsKey = "reminders.participatingLists"
    private static let defaultListKey = "reminders.defaultList"

    /// Whether the user has turned the integration on.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Which lists take part. Empty means none — never "all", which would be the app deciding.
    public var participatingListIDs: [String] {
        get { defaults.stringArray(forKey: Self.listsKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.listsKey) }
    }

    /// Where a task exported from here goes by default. `nil` until the user picks one, at which
    /// point exporting stops asking every time.
    public var defaultListID: String? {
        get { defaults.string(forKey: Self.defaultListKey) }
        set { defaults.set(newValue, forKey: Self.defaultListKey) }
    }

    public func setParticipating(_ isParticipating: Bool, listID: String) {
        var current = participatingListIDs
        if isParticipating {
            guard !current.contains(listID) else { return }
            current.append(listID)
        } else {
            current.removeAll { $0 == listID }
        }
        participatingListIDs = current
    }

    // MARK: - Permission

    /// Turns the integration on, prompting if the user has never been asked.
    ///
    /// The explanation is shown **before** this is called — see `RemindersOnboardingView`. macOS
    /// records a decision permanently, so a prompt that arrives before the user knows what it is for
    /// is a decision they cannot revisit inside the app.
    @discardableResult
    public func enable() async -> IntegrationAuthorization {
        if !isEnabled || provider is NoRemindersProvider {
            provider = makeProvider()
            isEnabled = true
        }

        authorization = await provider.requestAccess()
        await refreshLists()
        return authorization
    }

    /// Turns it off. Links are left in place: switching the feature off is not consent to unpick
    /// every task that was ever linked, and turning it back on should find them still there.
    public func disable() {
        isEnabled = false
        provider = NoRemindersProvider()
        authorization = .notRequested
        lists = []
    }

    /// Reads the current state without prompting.
    public func refresh() async {
        authorization = await provider.authorization
        await refreshLists()
    }

    private func refreshLists() async {
        lists = authorization.canRead ? await provider.lists() : []
    }

    // MARK: - Reconciling

    /// Runs a pass and keeps its report.
    ///
    /// Guarded against overlapping runs. The store-change notification fires for the app's own
    /// writes as well as for other devices', so a pass that could re-enter itself would push, be
    /// notified, push again, and never settle.
    @discardableResult
    public func sync(using engine: ReminderSyncEngine) async -> ReminderSyncReport? {
        guard isEnabled, authorization.canRead, !isSyncing else { return nil }

        isSyncing = true
        defer { isSyncing = false }

        // The lists the user ticked, and only those. The engine has no opinion about which lists
        // participate and must not acquire one: that choice is the whole of the promise that nothing
        // is copied out of Reminders without being asked for.
        let report = await engine.reconcile(importingFrom: participatingListIDs)
        lastReport = report
        return report
    }

    public func clearReport() {
        lastReport = nil
    }

    /// A stream of store changes, for a coordinator to watch.
    public var changes: AsyncStream<Void> { provider.changes }

    // MARK: - Explaining

    /// What the user is told before the permission prompt appears.
    ///
    /// Written out here rather than in the view so it can be read in one place and asserted in a
    /// test: the promise about what stays private is the part somebody cannot verify for themselves,
    /// and it must not drift from what the code does.
    public static let explanation: [(headline: String, detail: String)] = [
        (
            "Your reminders, beside your work",
            "Elephruit can show the Reminders lists already on this Mac alongside its own tasks."
        ),
        (
            "Changes travel both ways",
            """
            Ticking a linked reminder here ticks it in Reminders, and changes made on your phone \
            arrive here. Your reminders sync through whichever account you set up in Reminders; \
            Elephruit never asks for your Apple Account and never connects to iCloud itself.
            """
        ),
        (
            "You choose which lists take part",
            "No list is included until you say so, and you can change your mind at any time."
        ),
        (
            "Private things stay private",
            """
            Areas, projects, people, notes, waiting-for, and everything else Reminders has no field \
            for stay in Elephruit. They are never written into a reminder's title or notes.
            """
        ),
        (
            "Local tasks stay local",
            "Anything you do not link is never sent anywhere."
        ),
    ]

    /// What macOS will and will not let the app do about the current state.
    public var permissionAdvice: String {
        switch authorization {
        case .notRequested:
            "Elephruit has not asked for access to Reminders yet."
        case .authorized:
            "Elephruit can read and update the lists you choose."
        case .denied:
            "Access was declined. macOS remembers that, so it can only be changed in System Settings ▸ Privacy & Security ▸ Reminders."
        case .restricted:
            "Access to Reminders is restricted on this Mac, which is usually a device-management setting."
        case .unavailable:
            "Reminders is not available on this Mac."
        }
    }
}
