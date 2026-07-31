import Foundation

/// Somebody as they appear in one place — the app's own store, or an account it reads.
///
/// A value type deliberately thinner than a person: identity resolution needs names and contact
/// details and nothing else, and giving the matcher access to reflections and relationship history
/// would let it start scoring people on things it has no business weighing.
public struct IdentityCandidate: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var fullName: String
    public var emails: [String]
    public var phones: [String]

    /// The system Contacts record this came from, when it came from one.
    public var contactsIdentifier: String?

    /// Which account holds it — "iCloud", "Google", "On My Mac".
    public var accountName: String?

    public var organization: String?
    public var birthday: PartialDate?

    public init(
        id: UUID,
        fullName: String,
        emails: [String] = [],
        phones: [String] = [],
        contactsIdentifier: String? = nil,
        accountName: String? = nil,
        organization: String? = nil,
        birthday: PartialDate? = nil
    ) {
        self.id = id
        self.fullName = fullName
        self.emails = emails
        self.phones = phones
        self.contactsIdentifier = contactsIdentifier
        self.accountName = accountName
        self.organization = organization
        self.birthday = birthday
    }

    var normalizedEmails: Set<String> {
        Set(emails.map(ContactDetailRecognizer.normalizedEmail).filter { !$0.isEmpty })
    }

    var normalizedPhones: Set<String> {
        Set(phones.map(ContactDetailRecognizer.normalizedPhone).filter { $0.count >= 7 })
    }

    var nameKey: String {
        TextNormalizer.foldedForMatching(fullName)
    }

    /// Family name plus first initial — "chen m".
    ///
    /// The key that catches "Maya Chen" against "M. Chen" without catching "Maya Chen" against
    /// "Maya Chandra".
    var initialKey: String? {
        let parts = nameKey.split(separator: " ").map(String.init)
        guard parts.count >= 2, let first = parts.first?.first, let last = parts.last else { return nil }
        return "\(last) \(first)"
    }
}

/// Why the matcher thinks two records are the same person.
///
/// Reasons rather than a bare number, because the user is shown these. "They share an email address"
/// is something somebody can agree or disagree with; "0.82" is not.
public enum IdentityEvidence: String, Sendable, Hashable, CaseIterable {
    case sharedEmail
    case sharedPhone
    case sameContactsRecord
    case identicalName
    case nameAndInitial
    case sameBirthday
    case sameOrganization

    /// How much this contributes. Contact details outweigh names because two people genuinely can
    /// share a name and cannot share a phone number.
    var weight: Int {
        switch self {
        case .sameContactsRecord: 100
        case .sharedEmail: 60
        case .sharedPhone: 55
        case .identicalName: 30
        case .sameBirthday: 25
        case .nameAndInitial: 12
        case .sameOrganization: 8
        }
    }

    public var explanation: String {
        switch self {
        case .sharedEmail: "Same email address"
        case .sharedPhone: "Same phone number"
        case .sameContactsRecord: "Same Contacts record"
        case .identicalName: "Same name"
        case .nameAndInitial: "Same surname and first initial"
        case .sameBirthday: "Same birthday"
        case .sameOrganization: "Same organisation"
        }
    }
}

/// How likely two records are the same person.
public struct IdentityMatch: Sendable, Hashable, Identifiable {
    public var leftID: UUID
    public var rightID: UUID
    public var score: Int
    public var evidence: [IdentityEvidence]

    public var id: String { "\(leftID)-\(rightID)" }

    public init(leftID: UUID, rightID: UUID, score: Int, evidence: [IdentityEvidence]) {
        self.leftID = leftID
        self.rightID = rightID
        self.score = score
        self.evidence = evidence
    }

    /// Strong enough to link without asking.
    ///
    /// Only ever a shared Contacts identifier: the same record in the same store *is* the same
    /// person, by definition. Everything else — even a shared email — is offered, because a shared
    /// address can be a couple's, a family's, or a support alias.
    public var isCertain: Bool {
        evidence.contains(.sameContactsRecord)
    }

    /// Worth showing the user as a possible duplicate.
    public var isWorthOffering: Bool {
        score >= IdentityMatcher.offerThreshold
    }

    /// The sentence shown beside a merge offer.
    public var explanation: String {
        evidence.map(\.explanation).joined(separator: " · ")
    }
}

/// Decides whether two records describe the same person.
///
/// ### Why this is not automatic
/// One person appearing as three profiles is the failure this exists to prevent. The opposite
/// failure — two people silently merged into one — is far worse and far harder to undo, because it
/// destroys the boundary between two sets of private notes. So the matcher *offers*, with its
/// reasoning attached, and the only case it acts on alone is the one where the two records are
/// provably the same row in the same system store.
public enum IdentityMatcher {
    /// The score at which a possible duplicate is worth mentioning.
    public static let offerThreshold = 55

    public static func match(_ left: IdentityCandidate, _ right: IdentityCandidate) -> IdentityMatch {
        var evidence: [IdentityEvidence] = []

        if let leftContact = left.contactsIdentifier,
           let rightContact = right.contactsIdentifier,
           leftContact == rightContact {
            evidence.append(.sameContactsRecord)
        }

        if !left.normalizedEmails.isDisjoint(with: right.normalizedEmails) {
            evidence.append(.sharedEmail)
        }

        if !left.normalizedPhones.isDisjoint(with: right.normalizedPhones) {
            evidence.append(.sharedPhone)
        }

        if !left.nameKey.isEmpty, left.nameKey == right.nameKey {
            evidence.append(.identicalName)
        } else if let leftInitial = left.initialKey, leftInitial == right.initialKey {
            evidence.append(.nameAndInitial)
        }

        if let leftBirthday = left.birthday, let rightBirthday = right.birthday,
           leftBirthday.month == rightBirthday.month, leftBirthday.day == rightBirthday.day {
            evidence.append(.sameBirthday)
        }

        if let leftOrg = left.organization?.lowercased(), let rightOrg = right.organization?.lowercased(),
           !leftOrg.isEmpty, leftOrg == rightOrg {
            evidence.append(.sameOrganization)
        }

        let score = min(100, evidence.reduce(0) { $0 + $1.weight })
        return IdentityMatch(leftID: left.id, rightID: right.id, score: score, evidence: evidence)
    }

    /// Every pair worth offering, strongest first.
    ///
    /// Each unordered pair is considered once. Quadratic, which is correct at the scale this runs
    /// at — a personal library, not a corporate directory — and bounded so a pathological import
    /// cannot lock the interface up.
    public static func duplicates(
        among candidates: [IdentityCandidate],
        limit: Int = 200
    ) -> [IdentityMatch] {
        var matches: [IdentityMatch] = []

        outer: for (index, left) in candidates.enumerated() {
            for right in candidates.dropFirst(index + 1) {
                let match = match(left, right)
                guard match.isWorthOffering else { continue }
                matches.append(match)
                if matches.count >= limit { break outer }
            }
        }

        return matches.sorted { $0.score > $1.score }
    }

    /// The best match for one record among many.
    public static func bestMatch(
        for candidate: IdentityCandidate,
        among others: [IdentityCandidate]
    ) -> IdentityMatch? {
        others
            .filter { $0.id != candidate.id }
            .map { match(candidate, $0) }
            .filter(\.isWorthOffering)
            .max { $0.score < $1.score }
    }
}

// MARK: - Merging

/// What a merge would do, before it does it.
///
/// ### Why a merge is described before it runs
/// Merging is the one operation in this module that destroys structure — two timelines become one
/// and cannot be pulled apart again by hand. So it is planned, shown, and only then applied, and the
/// plan names every field that would change and every fact that would be kept.
public struct MergePlan: Sendable, Hashable, Identifiable {
    /// The pair, which is what a sheet is presented for.
    public var id: String { "\(primaryID)-\(secondaryID)" }

    /// The record that survives.
    public var primaryID: UUID

    /// The record folded into it.
    public var secondaryID: UUID

    public var primaryName: String
    public var secondaryName: String

    /// Details present on the secondary and missing from the primary, which the merge adds.
    public var addedEmails: [String]
    public var addedPhones: [String]

    /// Details that differ and are both kept, labelled, rather than one overwriting the other.
    public var conflicts: [MergeConflict]

    /// How many observations, notes, and relationships move across.
    public var movedObservations: Int
    public var movedLinks: Int
    public var movedRelationships: Int

    public init(
        primaryID: UUID,
        secondaryID: UUID,
        primaryName: String,
        secondaryName: String,
        addedEmails: [String] = [],
        addedPhones: [String] = [],
        conflicts: [MergeConflict] = [],
        movedObservations: Int = 0,
        movedLinks: Int = 0,
        movedRelationships: Int = 0
    ) {
        self.primaryID = primaryID
        self.secondaryID = secondaryID
        self.primaryName = primaryName
        self.secondaryName = secondaryName
        self.addedEmails = addedEmails
        self.addedPhones = addedPhones
        self.conflicts = conflicts
        self.movedObservations = movedObservations
        self.movedLinks = movedLinks
        self.movedRelationships = movedRelationships
    }

    /// A plain-language description of everything that will happen.
    public var summary: String {
        var lines = ["“\(secondaryName)” will be folded into “\(primaryName)”."]

        if !addedEmails.isEmpty {
            lines.append("Adds \(addedEmails.count) email address\(addedEmails.count == 1 ? "" : "es").")
        }
        if !addedPhones.isEmpty {
            lines.append("Adds \(addedPhones.count) phone number\(addedPhones.count == 1 ? "" : "s").")
        }
        if movedObservations > 0 { lines.append("Moves \(movedObservations) recorded fact\(movedObservations == 1 ? "" : "s").") }
        if movedLinks > 0 { lines.append("Moves \(movedLinks) linked note\(movedLinks == 1 ? "" : "s").") }
        if movedRelationships > 0 {
            lines.append("Moves \(movedRelationships) relationship\(movedRelationships == 1 ? "" : "s").")
        }
        if !conflicts.isEmpty {
            lines.append("Keeps both values for \(conflicts.count) field\(conflicts.count == 1 ? "" : "s") — nothing is overwritten.")
        }

        return lines.joined(separator: " ")
    }

    /// Whether merging would change anything at all.
    public var isEmpty: Bool {
        addedEmails.isEmpty && addedPhones.isEmpty && conflicts.isEmpty
            && movedObservations == 0 && movedLinks == 0 && movedRelationships == 0
    }
}

/// A field where the two records disagree.
///
/// Both values are kept. Choosing between two things somebody wrote down is a decision the app is
/// not qualified to make, and losing one of them to a merge is exactly the "data loss" the
/// requirement forbids.
public struct MergeConflict: Sendable, Hashable {
    public var field: String
    public var primaryValue: String
    public var secondaryValue: String

    public init(field: String, primaryValue: String, secondaryValue: String) {
        self.field = field
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
    }
}
