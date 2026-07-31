import Foundation

/// What importing one system contact would do.
///
/// Six outcomes, and the interface shows all of them. A summary that only said "412 contacts" would
/// be hiding the two numbers that actually matter: how many are already here, and how many the app
/// is unsure about.
public enum ContactImportOutcome: String, Sendable, Hashable, CaseIterable, Codable {
    /// Nothing in the CRM resembles this contact.
    case createPerson

    /// An existing person matches beyond reasonable doubt — a shared email or phone plus a
    /// consistent name — so the link is proposed rather than a second person.
    case linkToExisting

    /// This contact is already linked to somebody. Re-running an import finds these and does nothing,
    /// which is what makes a retry safe.
    case alreadyLinked

    /// Something matches, but not well enough to act on. Goes to review; never decided automatically.
    case needsReview

    /// The user deselected it.
    case skipped

    /// Nothing usable to import — no name of any kind.
    case unusable

    public var displayName: String {
        switch self {
        case .createPerson: "New person"
        case .linkToExisting: "Link to existing"
        case .alreadyLinked: "Already linked"
        case .needsReview: "Needs review"
        case .skipped: "Skipped"
        case .unusable: "Cannot import"
        }
    }

    public var symbolName: String {
        switch self {
        case .createPerson: "person.badge.plus"
        case .linkToExisting: "link"
        case .alreadyLinked: "checkmark.circle"
        case .needsReview: "questionmark.circle"
        case .skipped: "minus.circle"
        case .unusable: "exclamationmark.triangle"
        }
    }

    /// Whether this outcome writes anything when the import runs.
    public var changesTheDatabase: Bool {
        switch self {
        case .createPerson, .linkToExisting: true
        case .alreadyLinked, .skipped, .needsReview, .unusable: false
        }
    }

    /// Whether the user is expected to do something about it.
    public var needsAttention: Bool {
        self == .needsReview
    }

    /// The order outcomes are listed in the summary — what will happen first, what needs the user
    /// second, what needs nothing last.
    public var sortRank: Int {
        switch self {
        case .createPerson: 0
        case .linkToExisting: 1
        case .needsReview: 2
        case .alreadyLinked: 3
        case .skipped: 4
        case .unusable: 5
        }
    }
}

/// One contact, and what the app proposes to do with it.
public struct ContactImportProposal: Sendable, Hashable, Identifiable {
    public var contact: SystemContact
    public var outcome: ContactImportOutcome

    /// The CRM person this would link to or merge with.
    public var matchedPersonID: UUID?
    public var matchedPersonName: String?

    /// Why the app thinks they are the same, in words. Shown on the review row and in the duplicate
    /// screen; never a score.
    public var evidence: [IdentityEvidence]

    /// Whether the user has this row selected. Defaults to whatever the outcome implies.
    public var isSelected: Bool

    public var id: String { contact.id }

    public init(
        contact: SystemContact,
        outcome: ContactImportOutcome,
        matchedPersonID: UUID? = nil,
        matchedPersonName: String? = nil,
        evidence: [IdentityEvidence] = [],
        isSelected: Bool? = nil
    ) {
        self.contact = contact
        self.outcome = outcome
        self.matchedPersonID = matchedPersonID
        self.matchedPersonName = matchedPersonName
        self.evidence = evidence
        // Selected by default when there is something to do and the app is sure enough to do it.
        // An ambiguous match starts unselected, so pressing the primary button never resolves an
        // ambiguity by accident.
        self.isSelected = isSelected ?? (outcome == .createPerson || outcome == .linkToExisting)
    }

    public var explanation: String? {
        guard !evidence.isEmpty else { return nil }
        return evidence.map(\.explanation).joined(separator: " · ")
    }

    /// The line under the name on a review row.
    public var subtitle: String {
        var parts: [String] = []
        if !contact.organizationName.isEmpty { parts.append(contact.organizationName) }
        if let email = contact.emailAddresses.first?.value { parts.append(email) }
        else if let phone = contact.phoneNumbers.first?.value { parts.append(phone) }
        if let container = contact.containerName { parts.append(container) }
        return parts.joined(separator: " · ")
    }
}

/// Everything the review screen shows, computed before anything is written.
///
/// Built off the main actor from value types, so a library of several thousand contacts is normalised
/// and matched without the interface stopping.
public struct ContactImportPlan: Sendable {
    public var proposals: [ContactImportProposal]

    /// The containers the scan saw, with their system-provided names.
    public var containers: [ContactAccount]

    /// When the plan was built. A plan is a snapshot, and a stale one is worth re-scanning.
    public var builtAt: Date

    public init(proposals: [ContactImportProposal], containers: [ContactAccount], builtAt: Date) {
        self.proposals = proposals
        self.containers = containers
        self.builtAt = builtAt
    }

    public var totalAvailable: Int { proposals.count }

    public func count(of outcome: ContactImportOutcome) -> Int {
        proposals.count { $0.outcome == outcome }
    }

    /// How many rows the user has selected that would actually write something.
    public var selectedActionableCount: Int {
        proposals.count { $0.isSelected && $0.outcome.changesTheDatabase }
    }

    public var needsReviewCount: Int { count(of: .needsReview) }
    public var unusableCount: Int { count(of: .unusable) }
    public var alreadyLinkedCount: Int { count(of: .alreadyLinked) }

    /// The counts the summary shows, in a fixed order, with the empty ones dropped.
    public var summaryLines: [(outcome: ContactImportOutcome, count: Int)] {
        ContactImportOutcome.allCases
            .sorted { $0.sortRank < $1.sortRank }
            .map { (outcome: $0, count: count(of: $0)) }
            .filter { $0.count > 0 }
    }

    public var isEmpty: Bool { proposals.isEmpty }

    /// Whether the primary button should do anything.
    public var isRunnable: Bool { selectedActionableCount > 0 }

    /// The one-line summary above the list.
    public var headline: String {
        guard !isEmpty else { return "No contacts found." }

        let new = count(of: .createPerson)
        let linked = count(of: .linkToExisting)

        var parts: [String] = ["\(totalAvailable) contact\(totalAvailable == 1 ? "" : "s") available"]
        if new > 0 { parts.append("\(new) new") }
        if linked > 0 { parts.append("\(linked) matching someone you have") }
        if needsReviewCount > 0 { parts.append("\(needsReviewCount) to review") }
        if alreadyLinkedCount > 0 { parts.append("\(alreadyLinkedCount) already linked") }

        return parts.joined(separator: " · ")
    }
}

/// How an import finished.
///
/// Reported rather than assumed: an import that partly failed has to say which part, because "412
/// imported" when nine of them silently did not is the kind of quiet inaccuracy that makes somebody
/// stop trusting the whole feature.
public struct ContactImportReport: Sendable, Hashable {
    public var created: Int
    public var linked: Int
    public var skipped: Int

    /// Contacts that could not be written, with a reason apiece.
    public var failures: [ContactImportFailure]

    /// Set when the user stopped it part-way. Everything already written stays written and is
    /// already de-duplicated by its link, so resuming is safe.
    public var wasCancelled: Bool

    public init(
        created: Int = 0,
        linked: Int = 0,
        skipped: Int = 0,
        failures: [ContactImportFailure] = [],
        wasCancelled: Bool = false
    ) {
        self.created = created
        self.linked = linked
        self.skipped = skipped
        self.failures = failures
        self.wasCancelled = wasCancelled
    }

    public var changedCount: Int { created + linked }

    public var isCompleteSuccess: Bool { failures.isEmpty && !wasCancelled }

    public var summary: String {
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if linked > 0 { parts.append("\(linked) linked") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) could not be read") }

        if parts.isEmpty { return wasCancelled ? "Stopped before anything changed." : "Nothing to do." }

        let body = parts.joined(separator: ", ")
        return wasCancelled ? "Stopped after \(body)." : body.prefix(1).uppercased() + body.dropFirst() + "."
    }
}

/// One contact that could not be imported.
///
/// The name is carried so the message can be specific, and nothing else is — a failure report is not
/// a place to accumulate contact details.
public struct ContactImportFailure: Sendable, Hashable, Identifiable, Codable {
    public var contactID: String
    public var name: String
    public var reason: String

    public var id: String { contactID }

    public init(contactID: String, name: String, reason: String) {
        self.contactID = contactID
        self.name = name
        self.reason = reason
    }
}

// MARK: - Progress

/// What an import is doing right now.
///
/// A value type published from the service, so the interface can show determinate progress and an
/// accessible announcement without reaching into the work.
public struct ContactImportProgress: Sendable, Hashable {
    public var processed: Int
    public var total: Int
    public var isRunning: Bool

    public init(processed: Int = 0, total: Int = 0, isRunning: Bool = false) {
        self.processed = processed
        self.total = total
        self.isRunning = isRunning
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    /// Spoken by VoiceOver, and short enough to be worth hearing repeatedly.
    public var accessibilityDescription: String {
        guard isRunning else { return "Import finished" }
        return "Importing contact \(processed) of \(total)"
    }
}
