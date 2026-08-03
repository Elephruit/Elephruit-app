import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The onboarding and import flow, as one state machine.
///
/// ### Why the states are an enum rather than a handful of booleans
/// There are eleven of them, and several are only distinguishable by *why* — access denied and access
/// restricted look identical to a boolean and need different sentences and different buttons. An enum
/// makes the interface a `switch` with no default, so a state added later cannot be silently
/// unhandled.
@Observable
@MainActor
public final class ContactImportModel {
    /// Where the flow currently is.
    public enum Phase: Sendable, Hashable {
        /// Nothing has been asked yet. The explanation is on screen and no prompt has appeared.
        case explaining

        /// Waiting on the system's permission dialogue.
        case requestingAccess

        /// Refused. Recoverable only through System Settings, and the interface says so.
        case accessDenied

        /// Managed by a profile or a parental control. Not the user's to change.
        case accessRestricted

        /// Reading the address book.
        case scanning(ContactImportProgress)

        /// Access is granted and there is genuinely nothing there.
        case empty

        /// The plan is built and awaiting a decision.
        case reviewing

        /// Writing.
        case importing(ContactImportProgress)

        /// Finished, with counts.
        case finished(ContactImportReport)

        /// Access was on and has gone away since.
        case accessRevoked

        /// Something went wrong that is not one of the above.
        case failed(String)
    }

    public private(set) var phase: Phase = .explaining

    /// The plan, once it exists. Held so selection can be edited without re-scanning.
    public private(set) var plan: ContactImportPlan?

    /// The rows the interface shows, after search and sorting.
    public private(set) var visibleProposals: [ContactImportProposal] = []

    public var searchText = "" {
        didSet { refreshVisible() }
    }

    public var sortOrder: SortOrder = .name {
        didSet { refreshVisible() }
    }

    /// Which containers to scan. Empty means all of them.
    public var selectedContainerIDs: Set<String> = [] {
        didSet { refreshVisible() }
    }

    public enum SortOrder: String, Sendable, CaseIterable, Identifiable {
        case name
        case outcome
        case container

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .name: "Name"
            case .outcome: "What will happen"
            case .container: "Account"
            }
        }
    }

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var runningTask: Task<Void, Never>?

    public init(services: AppServices) {
        self.services = services
    }

    deinit {
        runningTask?.cancel()
    }

    // MARK: - Permission

    /// Reads the current authorisation without prompting, and picks the matching state.
    ///
    /// Called when the flow opens. **No prompt appears here** — the explanation is shown first and the
    /// system dialogue only follows a deliberate press, which is the whole reason this is separate
    /// from `requestAccess`.
    public func prepare() async {
        await services.contacts.refreshAuthorization()

        switch services.contacts.authorization {
        case .notRequested, .unavailable:
            phase = .explaining
        case .denied:
            phase = .accessDenied
        case .restricted:
            phase = .accessRestricted
        case .authorized:
            await scan()
        }
    }

    /// Asks the system, after the user has read what it is for.
    public func requestAccess() async {
        phase = .requestingAccess

        let result = await services.contacts.enable()

        switch result {
        case .authorized:
            try? services.contactSync.markAllReadable()
            await scan()
        case .denied:
            phase = .accessDenied
        case .restricted:
            phase = .accessRestricted
        case .notRequested, .unavailable:
            phase = .failed("Contacts is not available on this Mac.")
        }
    }

    // MARK: - Scanning

    /// Reads the address book and builds a plan. Writes nothing.
    public func scan() async {
        runningTask?.cancel()

        phase = .scanning(ContactImportProgress(processed: 0, total: 0, isRunning: true))

        let containers = await services.contacts.allContainers()
        let matching: ContactMatchingContext

        do {
            matching = try services.contactImports.matchingContext()
        } catch {
            // `matchingContext()` is `throws(AppError)`, so the binding is already typed — no cast.
            phase = .failed(error.failureReason ?? "The library could not be read.")
            return
        }

        // Gathered into value types first. The matching then runs over them off the main actor,
        // which is what keeps a library of several thousand from freezing the window.
        //
        // The accumulator is an actor because the batch callback is `@Sendable` and cannot mutate a
        // local — which is the compiler correctly pointing out that batches may arrive from any
        // isolation the provider chooses.
        let collector = ContactCollector()
        let selected = Array(selectedContainerIDs)

        _ = await services.contacts.enumerate(containers: selected) { batch in
            await collector.append(batch)
        }

        let contacts = await collector.contacts

        guard !Task.isCancelled else { return }

        guard !contacts.isEmpty else {
            phase = .empty
            plan = ContactImportPlan(proposals: [], containers: containers, builtAt: services.dateProvider.now)
            refreshVisible()
            return
        }

        // A unified contact can arrive once per container it appears in when several were selected;
        // the identifier is the same each time, so de-duplicating here is what keeps one person one
        // row.
        var seen = Set<String>()
        let unique = contacts.filter { seen.insert($0.id).inserted }

        let proposals = await Self.buildProposals(for: unique, in: matching)

        guard !Task.isCancelled else { return }

        plan = ContactImportPlan(
            proposals: proposals,
            containers: containers,
            builtAt: services.dateProvider.now
        )
        refreshVisible()
        phase = .reviewing
    }

    /// The matching pass, off the main actor.
    ///
    /// `nonisolated` and static over `Sendable` values, so the compiler guarantees what the comment
    /// claims: nothing here touches the store, a view, or the main actor.
    nonisolated static func buildProposals(
        for contacts: [SystemContact],
        in matching: ContactMatchingContext
    ) async -> [ContactImportProposal] {
        await Task.detached(priority: .userInitiated) {
            contacts.map { ContactMatcher.propose($0, in: matching) }
        }.value
    }

    // MARK: - Selection

    public func setSelection(_ isSelected: Bool, for proposalID: String) {
        guard var plan else { return }
        guard let index = plan.proposals.firstIndex(where: { $0.id == proposalID }) else { return }

        plan.proposals[index].isSelected = isSelected
        self.plan = plan
        refreshVisible()
    }

    /// Selects everything currently visible that would actually do something.
    ///
    /// Scoped to the visible rows on purpose: after a search, *Select All* meaning "including the
    /// four hundred you filtered out" is a trap.
    public func selectAllVisible() {
        setSelectionForVisible(true)
    }

    public func deselectAllVisible() {
        setSelectionForVisible(false)
    }

    private func setSelectionForVisible(_ isSelected: Bool) {
        guard var plan else { return }

        let visibleIDs = Set(visibleProposals.map(\.id))
        for index in plan.proposals.indices
        where visibleIDs.contains(plan.proposals[index].id)
            && plan.proposals[index].outcome.changesTheDatabase {
            plan.proposals[index].isSelected = isSelected
        }

        self.plan = plan
        refreshVisible()
    }

    /// Records a decision from the duplicate screen.
    public func resolve(_ proposalID: String, as outcome: ContactImportOutcome, personID: UUID?) {
        guard var plan else { return }
        guard let index = plan.proposals.firstIndex(where: { $0.id == proposalID }) else { return }

        plan.proposals[index].outcome = outcome
        plan.proposals[index].matchedPersonID = personID ?? plan.proposals[index].matchedPersonID
        plan.proposals[index].isSelected = outcome.changesTheDatabase

        self.plan = plan
        refreshVisible()
    }

    private func refreshVisible() {
        guard let plan else {
            visibleProposals = []
            return
        }

        var rows = plan.proposals

        if !selectedContainerIDs.isEmpty {
            rows = rows.filter { proposal in
                proposal.contact.containerIdentifier.map(selectedContainerIDs.contains) ?? false
            }
        }

        let query = TextNormalizer.foldedForMatching(searchText)
        if !query.isEmpty {
            rows = rows.filter { proposal in
                TextNormalizer.foldedForMatching(proposal.contact.displayName).contains(query)
                    || proposal.contact.emailAddresses.contains {
                        $0.value.lowercased().contains(searchText.lowercased())
                    }
            }
        }

        rows.sort { left, right in
            switch sortOrder {
            case .name:
                left.contact.displayName.localizedStandardCompare(right.contact.displayName) == .orderedAscending
            case .outcome:
                left.outcome.sortRank == right.outcome.sortRank
                    ? left.contact.displayName < right.contact.displayName
                    : left.outcome.sortRank < right.outcome.sortRank
            case .container:
                (left.contact.containerName ?? "") == (right.contact.containerName ?? "")
                    ? left.contact.displayName < right.contact.displayName
                    : (left.contact.containerName ?? "") < (right.contact.containerName ?? "")
            }
        }

        visibleProposals = rows
    }

    // MARK: - Importing

    /// Writes the approved proposals.
    ///
    /// Contacts are staged in one context transaction and committed together. Progress is published
    /// in small groups so the window stays responsive without turning 400 rows into 400 render passes.
    public func runImport() async {
        guard let plan else { return }

        let approved = plan.proposals.filter { $0.isSelected && $0.outcome.changesTheDatabase }
        guard !approved.isEmpty else { return }

        let session = try? services.contactImports.beginSession()

        var report = ContactImportReport()
        var processed = 0
        phase = .importing(ContactImportProgress(processed: 0, total: approved.count, isRunning: true))

        do {
            try services.contactImports.beginStagedImport()
        } catch {
            phase = .failed(error.failureReason ?? "The import could not be prepared.")
            return
        }

        for proposal in approved {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }

            do {
                let outcome = try services.contactImports.stage(proposal, sessionID: session?.id)
                switch outcome {
                case .createPerson: report.created += 1
                case .linkToExisting: report.linked += 1
                default: report.skipped += 1
                }
            } catch {
                // A failure is recorded and the run carries on. One unreadable contact must not
                // abandon the other four hundred, and the report names what was missed.
                report.failures.append(
                    ContactImportFailure(
                        contactID: proposal.contact.id,
                        name: proposal.contact.displayName,
                        reason: error.failureReason ?? "It could not be saved."
                    )
                )
            }

            processed += 1
            if processed.isMultiple(of: 20) || processed == approved.count {
                phase = .importing(
                    ContactImportProgress(processed: processed, total: approved.count, isRunning: true)
                )
                // Lets the run loop draw and lets a cancellation be noticed.
                await Task.yield()
            }
        }

        do {
            try services.contactImports.commitStagedImport()
        } catch {
            phase = .failed(error.failureReason ?? "The imported contacts could not be saved.")
            return
        }

        report.skipped += plan.proposals.count { !$0.isSelected && $0.outcome.changesTheDatabase }

        if let session {
            try? services.contactImports.finish(
                session, report: report, totalConsidered: plan.totalAvailable
            )
        }

        services.refreshDerivedState()
        await services.invalidateAndWarmIndex()

        phase = .finished(report)
    }

    public func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    /// Runs the import in a cancellable task, so the interface can stop it.
    public func startImport() {
        runningTask?.cancel()
        runningTask = Task { await self.runImport() }
    }

    public func startScan() {
        runningTask?.cancel()
        runningTask = Task { await self.scan() }
    }

    /// Back to the summary after a finished run, so a second pass is one press away.
    public func reviewAgain() {
        Task { await scan() }
    }
}


/// Accumulates streamed batches.
///
/// An actor rather than a local array, because the provider's batch callback is `@Sendable` and may
/// deliver from any isolation. One `await` per batch of two hundred is not a cost worth avoiding with
/// an unsafe escape.
private actor ContactCollector {
    private(set) var contacts: [SystemContact] = []

    func append(_ batch: [SystemContact]) {
        contacts.append(contentsOf: batch)
    }
}
