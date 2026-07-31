import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// Keeps linked contacts current, on a change notification or on request.
///
/// ### Why the notification is coalesced
/// `CNContactStoreDidChange` is posted generously — several times for one edit, and once per record
/// during a sync. Reconciling on each would run the whole pass a dozen times for one changed phone
/// number. A short debounce collapses a burst into one run, which is the difference between a
/// background refresh nobody notices and a machine that heats up when Contacts syncs.
///
/// ### Why full reconciliation is the normal path, not the fallback
/// The Contacts change-history API is annotated `NS_SWIFT_UNAVAILABLE` in the macOS SDK — see
/// `SystemContactsProvider.currentHistoryToken()` — so the live provider has no token to offer and
/// the incremental branch never runs in production today. The branch is written, and
/// `FixtureContactsProvider` issues real tokens, so the logic is exercised by tests and is ready the
/// day the API becomes reachable. Until then every refresh walks the *linked* contacts, which is a
/// few hundred rather than the whole address book.
@Observable
@MainActor
public final class ContactRefreshCoordinator {
    public private(set) var isRunning = false
    public private(set) var lastReport: ContactSyncService.RefreshReport?

    /// Unresolved disagreements between a local value and a newer system one.
    public private(set) var conflicts: [ContactSyncConflict] = []

    public private(set) var linkedCount = 0

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Long enough to swallow a sync burst, short enough that an edit made in Contacts shows up
    /// while the user is still thinking about it.
    static let coalescingDelay = Duration.seconds(2)

    public init(services: AppServices) {
        self.services = services
    }

    deinit {
        observationTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Observation

    /// Starts watching for address-book changes.
    ///
    /// Safe to call repeatedly; the previous observation is replaced.
    public func start() {
        observationTask?.cancel()

        guard services.contacts.isEnabled else { return }

        observationTask = Task { [weak self] in
            guard let stream = self?.services.contacts.changeStream else { return }

            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.scheduleCoalescedRefresh()
            }
        }

        refreshCounts()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleCoalescedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Refreshing

    /// Re-reads every linked contact and applies what changed.
    ///
    /// Runs one link at a time with a yield between, so a few hundred links do not block the window.
    /// Everything it writes goes through ``ContactSyncService``, which is where the rule about not
    /// overwriting a deliberate local edit lives.
    @discardableResult
    public func refresh() async -> ContactSyncService.RefreshReport {
        guard !isRunning else { return lastReport ?? .init() }

        isRunning = true
        services.contacts.beginRefreshing()
        defer {
            isRunning = false
            services.contacts.endRefreshing()
        }

        await services.contacts.refreshAuthorization()

        // Access is off or gone. Nothing is read, nothing is deleted, and every link says why it
        // cannot refresh rather than looking broken.
        guard services.contacts.authorization.canRead else {
            try? services.contactSync.markAllUnreadable()
            refreshCounts()

            let report = ContactSyncService.RefreshReport()
            lastReport = report
            return report
        }

        try? services.contactSync.markAllReadable()

        let links = (try? services.contactImports.allLinks()) ?? []
        var report = ContactSyncService.RefreshReport(checked: links.count)

        // The incremental path, when a token is available. `nil` means reconcile fully, which is
        // what a missing, expired, or unsupported token all produce.
        let delta = await services.contacts.changesSinceStoredToken()

        for link in links {
            guard !Task.isCancelled else { break }
            guard link.person != nil else { continue }

            // With a usable delta, a contact nobody touched is skipped entirely.
            if let delta,
               !delta.changedIdentifiers.contains(link.contactIdentifier),
               !delta.deletedIdentifiers.contains(link.contactIdentifier),
               link.state == .linked {
                report.unchanged += 1
                continue
            }

            let outcome = await refresh(link)
            switch outcome {
            case .updated(let conflictCount):
                report.updated += 1
                report.conflicts += conflictCount
            case .unchanged:
                report.unchanged += 1
            case .wentUnavailable:
                report.wentUnavailable += 1
            case .recovered:
                report.recovered += 1
            }

            await Task.yield()
        }

        // `??` takes an autoclosure, which cannot be `async`, so the fallback is spelled out.
        let freshToken: Data?
        if let token = delta?.newToken {
            freshToken = token
        } else {
            freshToken = await services.contacts.currentHistoryToken()
        }
        if let freshToken { services.contacts.storeHistoryToken(freshToken) }

        conflicts = (try? services.contactSync.conflicts()) ?? []
        refreshCounts()

        let now = services.dateProvider.now
        services.contacts.noteRefreshed(at: now, summary: report.summary)
        services.refreshDerivedState()

        lastReport = report
        return report
    }

    /// What re-reading one link did.
    ///
    /// Public because the person page refreshes a single link from its own button and reports the
    /// outcome — "found again", "no longer in Contacts" — rather than silently doing nothing.
    public enum LinkOutcome: Sendable, Hashable {
        case updated(conflicts: Int)
        case unchanged
        case wentUnavailable
        case recovered

        public var message: String {
            switch self {
            case .updated(let conflicts) where conflicts > 0:
                "Updated. \(conflicts) value\(conflicts == 1 ? "" : "s") need\(conflicts == 1 ? "s" : "") a decision."
            case .updated:
                "Updated from Contacts."
            case .unchanged:
                "Already up to date."
            case .wentUnavailable:
                "This contact is no longer in your address book. Everything here is kept."
            case .recovered:
                "Found again in your address book."
            }
        }
    }

    /// Re-reads one link.
    ///
    /// The identifier is tried first, then the stored signature — which is what lets a link survive
    /// an account being removed and re-added, where the identifier changes but the person does not.
    public func refresh(_ link: SystemContactLink) async -> LinkOutcome {
        let wasUnavailable = link.state == .unavailable

        if let contact = await services.contacts.systemContact(withIdentifier: link.contactIdentifier) {
            // `try?` on a function returning a labelled tuple erases the labels, so the result is
            // destructured rather than named through.
            let (didChange, newConflicts) = (try? services.contactSync.apply(contact, to: link)) ?? (false, 0)
            if wasUnavailable { return .recovered }
            return didChange ? .updated(conflicts: newConflicts) : .unchanged
        }

        // The identifier stopped resolving. Before concluding anything, look for the same person by
        // their normalized email and phone — the ordinary outcome after an account is re-added.
        if let signature = link.signature,
           let contact = await services.contacts.systemContact(matching: signature) {
            // A new identifier for the same person. Adopt it and carry on.
            link.contactIdentifier = contact.id
            _ = try? services.contactSync.apply(contact, to: link)
            Diagnostics.features.info("A linked contact was re-found under a new identifier")
            return wasUnavailable ? .recovered : .updated(conflicts: 0)
        }

        guard !wasUnavailable else { return .unchanged }

        // Genuinely not findable. The person stays, the values stay, the link says so.
        try? services.contactSync.markUnavailable(link)
        return .wentUnavailable
    }

    // MARK: - Conflicts

    public func reloadConflicts() {
        conflicts = (try? services.contactSync.conflicts()) ?? []
    }

    public func takeSystemValue(for conflictID: UUID) {
        services.perform { try services.contactSync.resolveConflictTakingSystemValue(conflictID) }
        reloadConflicts()
    }

    public func keepLocalValue(for conflictID: UUID) {
        services.perform { try services.contactSync.resolveConflictKeepingLocalValue(conflictID) }
        reloadConflicts()
    }

    // MARK: - Counts

    public func refreshCounts() {
        linkedCount = (try? services.contactImports.linkedCount()) ?? 0
        conflicts = (try? services.contactSync.conflicts()) ?? []
    }

    /// The line Settings shows about the state of the integration.
    public var statusSummary: String {
        guard services.contacts.isEnabled else { return "Not using your address book." }

        guard services.contacts.authorization.canRead else {
            return "Contacts access is off. \(linkedCount) linked \(linkedCount == 1 ? "person" : "people") kept, no longer refreshing."
        }

        var parts = ["\(linkedCount) linked"]
        if let last = services.contacts.lastRefreshedAt {
            parts.append("refreshed \(last.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("not refreshed yet")
        }
        if !conflicts.isEmpty {
            parts.append("\(conflicts.count) need\(conflicts.count == 1 ? "s" : "") a decision")
        }
        return parts.joined(separator: " · ")
    }
}
