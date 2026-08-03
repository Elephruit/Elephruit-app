import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Turns the address book into the CRM's starting population.
///
/// ### The two halves, and why they are separate
/// **Planning** reads every contact, normalises it, and matches it against what the CRM already has.
/// It writes nothing, and it runs against value types, so the expensive part — folding thousands of
/// names and phone numbers — happens away from the main actor and away from the store.
///
/// **Applying** takes the plan the user approved and stages complete people, profiles, links, and
/// provenance on the main actor where `Item` lives, then commits the run together. This avoids
/// turning a few hundred contacts into thousands of disk transactions. Every staged person is
/// complete before the next begins, and its link makes a resumed import idempotent.
///
/// A plan is a snapshot of a moving target. Between building one and applying it the address book can
/// change, so applying re-checks each contact's link before writing — which is also what makes a
/// retry a no-op rather than a second copy.
@MainActor
public final class ContactImportService {
    private let context: ModelContext
    private let people: any PersonRepository
    private let items: any ItemRepository
    private let identity: PersonIdentityService
    private let records: RecordsService
    private let dateProvider: any DateProvider

    private var linkCache: [UUID: SystemContactLink]?
    private var stagedContactIDs: Set<String>?

    public init(
        context: ModelContext,
        people: any PersonRepository,
        items: any ItemRepository,
        identity: PersonIdentityService,
        records: RecordsService,
        dateProvider: any DateProvider
    ) {
        self.context = context
        self.people = people
        self.items = items
        self.identity = identity
        self.records = records
        self.dateProvider = dateProvider
    }

    // MARK: - Planning

    /// Everything the CRM already knows, as value types, so matching can leave the main actor.
    ///
    /// Built once per plan rather than queried per contact: a thousand contacts against four hundred
    /// people is four hundred thousand comparisons, and doing them against `Item` objects on the main
    /// actor is how an import freezes an app.
    public func matchingContext() throws(AppError) -> ContactMatchingContext {
        var candidates: [IdentityCandidate] = []
        var namesByID: [UUID: String] = [:]

        for person in try people.allPeople(includingPlaceholders: true) {
            namesByID[person.id] = person.displayTitle
            if let candidate = person.personProfile?.identityCandidate(calendar: dateProvider.calendar) {
                candidates.append(candidate)
            } else {
                candidates.append(IdentityCandidate(id: person.id, fullName: person.displayTitle))
            }
        }

        var linkedContactIDs: [String: UUID] = [:]
        var signatures: [String: UUID] = [:]

        for link in try allLinks() {
            guard let personID = link.person?.id else { continue }
            linkedContactIDs[link.contactIdentifier] = personID
            if !link.identitySignature.isEmpty { signatures[link.identitySignature] = personID }
        }

        return ContactMatchingContext(
            candidates: candidates,
            namesByID: namesByID,
            linkedContactIDs: linkedContactIDs,
            signaturesByStorageKey: signatures
        )
    }

    // MARK: - Applying

    /// Writes one approved proposal.
    ///
    /// Returns what it did, so the caller can count without re-reading. Every path is idempotent: a
    /// contact that already has a link is reported as already-linked and nothing is written, which is
    /// what makes a retry, a resume, and a second run of the whole import all safe.
    @discardableResult
    public func apply(
        _ proposal: ContactImportProposal,
        sessionID: UUID?
    ) throws(AppError) -> ContactImportOutcome {
        // Re-checked at write time rather than trusted from the plan: the address book may have moved
        // since, and this is the check that makes a duplicate impossible rather than unlikely.
        if let existing = try link(forContactIdentifier: proposal.contact.id), existing.person != nil {
            return .alreadyLinked
        }

        switch proposal.outcome {
        case .createPerson:
            let person = try people.createPerson(draft(from: proposal.contact))
            try attachLink(proposal.contact, to: person, sessionID: sessionID)
            return .createPerson

        case .linkToExisting:
            guard let personID = proposal.matchedPersonID,
                  let person = try people.person(id: personID)
            else {
                // The match went away between planning and applying — trashed, or merged into
                // somebody else. Creating the person is the safe reading: it loses nothing, and the
                // duplicate screen will offer the merge if one is warranted.
                let person = try people.createPerson(draft(from: proposal.contact))
                try attachLink(proposal.contact, to: person, sessionID: sessionID)
                return .createPerson
            }

            try people.addDetails(to: person, from: draft(from: proposal.contact))
            try attachLink(proposal.contact, to: person, sessionID: sessionID)
            return .linkToExisting

        case .alreadyLinked, .needsReview, .skipped, .unusable:
            return proposal.outcome
        }
    }

    /// Prepares the existing-link set once so a bulk import does not issue one fetch per contact.
    public func beginStagedImport() throws(AppError) {
        stagedContactIDs = Set(try allLinks().map(\.contactIdentifier))
    }

    /// Stages one approved proposal without saving. The caller commits the completed batch.
    @discardableResult
    public func stage(
        _ proposal: ContactImportProposal,
        sessionID: UUID?
    ) throws(AppError) -> ContactImportOutcome {
        guard var stagedContactIDs else {
            throw .writeFailed(path: "contacts", reason: "The import batch was not prepared.")
        }
        guard stagedContactIDs.insert(proposal.contact.id).inserted else { return .alreadyLinked }
        self.stagedContactIDs = stagedContactIDs

        switch proposal.outcome {
        case .createPerson:
            let person = try people.stageImportedPerson(draft(from: proposal.contact))
            try attachLink(proposal.contact, to: person, sessionID: sessionID, stagingImport: true)
            return .createPerson

        case .linkToExisting:
            guard let personID = proposal.matchedPersonID,
                  let person = try people.person(id: personID)
            else {
                let person = try people.stageImportedPerson(draft(from: proposal.contact))
                try attachLink(proposal.contact, to: person, sessionID: sessionID, stagingImport: true)
                return .createPerson
            }

            try people.stageImportedDetails(to: person, from: draft(from: proposal.contact))
            try attachLink(proposal.contact, to: person, sessionID: sessionID, stagingImport: true)
            return .linkToExisting

        case .alreadyLinked, .needsReview, .skipped, .unusable:
            return proposal.outcome
        }
    }

    /// Saves the staged contacts in one SwiftData transaction.
    public func commitStagedImport() throws(AppError) {
        defer { stagedContactIDs = nil }
        try save()
    }

    /// Creates the link and records where every imported value came from.
    func attachLink(
        _ contact: SystemContact,
        to person: Item,
        sessionID: UUID?,
        marksRecordAsImported: Bool = true,
        stagingImport: Bool = false
    ) throws(AppError) {
        let now = dateProvider.now
        let signature = ContactIdentitySignature(contact: contact)

        let link = SystemContactLink(
            contactIdentifier: contact.id,
            containerIdentifier: contact.containerIdentifier,
            containerName: contact.containerName,
            identitySignature: signature.storageKey,
            state: .linked,
            person: person,
            linkedAt: now,
            importSessionID: sessionID
        )
        context.insert(link)

        for value in Self.importedValues(from: contact, observedAt: now) {
            value.link = link
            context.insert(value)
        }

        // Mirrored onto the profile so every view written before this slice keeps working unchanged.
        let updateProfile: (PersonProfile) -> Void = { profile in
            profile.contactsIdentifier = contact.id
            profile.contactsAccountName = contact.containerName
            profile.contactsRefreshedAt = now
            // A record that arrived from the address book is not a placeholder somebody sketched.
            profile.isPlaceholder = false
        }
        if stagingImport {
            try people.stageImportedProfile(of: person, updateProfile)
        } else {
            try people.updateProfile(of: person, updateProfile)
        }

        if marksRecordAsImported {
            if stagingImport { records.stageImported(person) }
            else { try records.markImported(person) }
        }

        if !stagingImport { try save() }
    }

    /// Links a locally-created person to the Apple contact created from that same record.
    public func attachCreatedContact(_ contact: SystemContact, to person: Item) throws(AppError) {
        try attachLink(contact, to: person, sessionID: nil, marksRecordAsImported: false)
    }

    /// Every field worth recording provenance for.
    ///
    /// Labelled values get one row each, keyed by field *and* label, because changing a work number
    /// is a different event from adding a home one and a ledger that could not tell them apart would
    /// be useless for exactly the case it exists for.
    static func importedValues(from contact: SystemContact, observedAt: Date) -> [ImportedContactValue] {
        var values: [ImportedContactValue] = []

        func add(_ field: String, _ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            values.append(
                ImportedContactValue(fieldKey: field, label: label, value: trimmed, observedAt: observedAt)
            )
        }

        add(ContactField.givenName, "", contact.givenName)
        add(ContactField.middleName, "", contact.middleName)
        add(ContactField.familyName, "", contact.familyName)
        add(ContactField.namePrefix, "", contact.namePrefix)
        add(ContactField.nameSuffix, "", contact.nameSuffix)
        add(ContactField.nickname, "", contact.nickname)
        add(ContactField.pronunciation, "", contact.phoneticName ?? "")
        add(ContactField.organization, "", contact.organizationName)
        add(ContactField.role, "", contact.roleTitle ?? "")

        for email in contact.emailAddresses { add(ContactField.email, email.label, email.value) }
        for phone in contact.phoneNumbers { add(ContactField.phone, phone.label, phone.value) }
        for address in contact.postalAddresses { add(ContactField.address, address.label, address.value) }
        for url in contact.urlAddresses { add(ContactField.url, url.label, url.value) }

        if let birthday = contact.birthday?.partialDate {
            add(ContactField.birthday, "", birthday.displayText)
        }
        for date in contact.dates {
            if let partial = date.partialDate { add(ContactField.date, date.label, partial.displayText) }
        }

        return values
    }

    /// A system contact as a person draft.
    ///
    /// The CRM's own layer — observations, reflections, relationship history, timeline — is never
    /// populated from here. Contacts has no such fields, and inventing them from an organisation name
    /// would be fabrication. `contactRelations` are read and deliberately **not** turned into
    /// relationships: a relation is a name somebody typed in another app, not a link, and resolving
    /// it without asking would be the app inventing a family from a string.
    public func draft(from contact: SystemContact) -> PersonDraft {
        PersonDraft(
            fullName: contact.displayName,
            givenName: contact.givenName.isEmpty ? nil : contact.givenName,
            familyName: contact.familyName.isEmpty ? nil : contact.familyName,
            // Read because they are writable. A field the app can clear and cannot learn is a field
            // it silently deletes the first time somebody edits an imported person.
            middleName: contact.middleName.isEmpty ? nil : contact.middleName,
            namePrefix: contact.namePrefix.isEmpty ? nil : contact.namePrefix,
            nameSuffix: contact.nameSuffix.isEmpty ? nil : contact.nameSuffix,
            departmentName: contact.departmentName.isEmpty ? nil : contact.departmentName,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            pronunciation: contact.phoneticName,
            roleTitle: contact.roleTitle,
            organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
            emails: contact.emailAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            phones: contact.phoneNumbers.map { LabelledValue(label: $0.label, value: $0.value) },
            addresses: contact.postalAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            websites: contact.urlAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            birthday: contact.birthday?.partialDate,
            contactsIdentifier: contact.id,
            contactsAccountName: contact.containerName,
            source: ItemSource(kind: .systemStore, identifier: contact.id)
        )
    }

    // MARK: - Sessions

    @discardableResult
    public func beginSession() throws(AppError) -> ContactImportSession {
        let session = ContactImportSession(startedAt: dateProvider.now)
        context.insert(session)
        try save()
        return session
    }

    public func finish(
        _ session: ContactImportSession,
        report: ContactImportReport,
        totalConsidered: Int
    ) throws(AppError) {
        session.finishedAt = dateProvider.now
        session.totalConsidered = totalConsidered
        session.createdCount = report.created
        session.linkedCount = report.linked
        session.skippedCount = report.skipped
        session.failures = report.failures
        session.wasCancelled = report.wasCancelled
        try save()
    }

    /// The most recent finished session, for the *last import* line.
    public func lastSession() throws(AppError) -> ContactImportSession? {
        var descriptor = FetchDescriptor<ContactImportSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    // MARK: - Links

    public func allLinks() throws(AppError) -> [SystemContactLink] {
        var descriptor = FetchDescriptor<SystemContactLink>()
        descriptor.relationshipKeyPathsForPrefetching = [\.person]
        return try fetch(descriptor)
    }

    public func link(forContactIdentifier identifier: String) throws(AppError) -> SystemContactLink? {
        let descriptor = FetchDescriptor<SystemContactLink>(
            predicate: #Predicate { $0.contactIdentifier == identifier }
        )
        return try fetch(descriptor).first
    }

    public func link(for person: Item) throws(AppError) -> SystemContactLink? {
        guard person.personProfile?.contactsIdentifier != nil else { return nil }
        if let cache = linkCache {
            return cache[person.id]
        }
        let links = try allLinks()
        var cache: [UUID: SystemContactLink] = [:]
        for link in links {
            if let pid = link.person?.id {
                cache[pid] = link
            }
        }
        self.linkCache = cache
        return cache[person.id]
    }

    public func linkedCount() throws(AppError) -> Int {
        try allLinks().count { $0.person != nil }
    }

    /// Whether the People sidebar has a linked-contact scope to show.
    ///
    /// The sidebar needs a Boolean, not every link and its person relationship. A one-row bounded
    /// fetch keeps entering People independent of the size of the imported address book.
    public func hasLinkedPeople() throws(AppError) -> Bool {
        var descriptor = FetchDescriptor<SystemContactLink>(
            predicate: #Predicate { $0.person != nil }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).isEmpty == false
    }

    /// Removes the association, keeping both records.
    ///
    /// The imported values go with the link — they are its provenance, and provenance for a link that
    /// no longer exists is a claim nobody can check. What stays is everything on the profile: an
    /// unlink is not a way to lose somebody's phone number, it is a way to stop refreshing it.
    public func unlink(_ person: Item) throws(AppError) {
        guard let link = try link(for: person) else { return }

        context.delete(link)
        try people.updateProfile(of: person) { profile in
            profile.contactsIdentifier = nil
            profile.contactsAccountName = nil
            profile.contactsRefreshedAt = nil
        }
        try save()

        Diagnostics.persistence.info("Unlinked a person from the address book; both records kept")
    }

    /// Points a person at a different system contact.
    ///
    /// Used when a link goes unavailable and the record turns up again under a new identifier, and
    /// when the user simply linked the wrong one.
    public func relink(_ person: Item, to contact: SystemContact) throws(AppError) {
        try unlink(person)
        try attachLink(contact, to: person, sessionID: nil)
        try people.addDetails(to: person, from: draft(from: contact))
    }

    // MARK: - Store

    private func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws(AppError) -> [Model] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func save() throws(AppError) {
        linkCache = nil
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}

// MARK: - Matching

/// Everything the CRM already knows, flattened into value types.
///
/// `Sendable`, so the matching that uses it genuinely runs off the main actor.
public struct ContactMatchingContext: Sendable {
    public var candidates: [IdentityCandidate]
    public var namesByID: [UUID: String]

    /// Which person each already-linked contact identifier belongs to.
    public var linkedContactIDs: [String: UUID]

    /// Which person each stored identity signature belongs to, for a contact whose identifier changed.
    public var signaturesByStorageKey: [String: UUID]

    public init(
        candidates: [IdentityCandidate],
        namesByID: [UUID: String],
        linkedContactIDs: [String: UUID],
        signaturesByStorageKey: [String: UUID]
    ) {
        self.candidates = candidates
        self.namesByID = namesByID
        self.linkedContactIDs = linkedContactIDs
        self.signaturesByStorageKey = signaturesByStorageKey
    }
}

/// Decides what one system contact should become.
///
/// ### Why this is a free function on value types
/// So it can run anywhere — off the main actor for a whole library, in a test with no store at all,
/// and in the duplicate screen for one contact. The rule it applies is the same in all three, which
/// is the only way a review screen and the thing it previews can be guaranteed to agree.
public enum ContactMatcher {
    /// What to do with one contact.
    ///
    /// The order matters and is deliberate:
    ///
    /// 1. **Already linked by identifier** — nothing to decide.
    /// 2. **Already linked by signature** — the identifier changed; still nothing to decide.
    /// 3. **No usable name** — cannot be imported, and is counted rather than silently dropped.
    /// 4. **Strong match** — a shared email or phone *and* a name that agrees. Proposed as a link.
    /// 5. **Anything else that matched at all** — sent to review, never decided.
    /// 6. **Nothing matched** — a new person.
    public static func propose(
        _ contact: SystemContact,
        in context: ContactMatchingContext
    ) -> ContactImportProposal {
        let signature = ContactIdentitySignature(contact: contact)

        if let personID = context.linkedContactIDs[contact.id] {
            return ContactImportProposal(
                contact: contact,
                outcome: .alreadyLinked,
                matchedPersonID: personID,
                matchedPersonName: context.namesByID[personID],
                evidence: [.sameContactsRecord]
            )
        }

        if let personID = context.signaturesByStorageKey[signature.storageKey] {
            return ContactImportProposal(
                contact: contact,
                outcome: .alreadyLinked,
                matchedPersonID: personID,
                matchedPersonName: context.namesByID[personID],
                evidence: [.sharedEmail]
            )
        }

        guard contact.hasUsableName else {
            return ContactImportProposal(contact: contact, outcome: .unusable)
        }

        // The existing matcher, unchanged. This slice does not weaken the rule that two people
        // sharing only a name are never merged — it consumes it.
        let incoming = IdentityCandidate(
            id: UUID(),
            fullName: contact.displayName,
            emails: contact.emailAddresses.map(\.value),
            phones: contact.phoneNumbers.map(\.value),
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            birthday: contact.birthday?.partialDate
        )

        let matches = context.candidates
            .map { IdentityMatcher.match(incoming, $0) }
            .filter { $0.isWorthOffering }
            .sorted { $0.score > $1.score }

        guard let best = matches.first else {
            return ContactImportProposal(contact: contact, outcome: .createPerson)
        }

        // More than one candidate clears the bar, so the app has no basis for choosing. Straight to
        // review — this is the case where guessing produces the merge nobody can undo.
        let isUnambiguous = matches.count == 1
        let hasContactDetailEvidence =
            best.evidence.contains(.sharedEmail) || best.evidence.contains(.sharedPhone)
        let nameAgrees = best.evidence.contains(.identicalName)

        let outcome: ContactImportOutcome =
            isUnambiguous && hasContactDetailEvidence && nameAgrees ? .linkToExisting : .needsReview

        return ContactImportProposal(
            contact: contact,
            outcome: outcome,
            matchedPersonID: best.rightID,
            matchedPersonName: context.namesByID[best.rightID],
            evidence: best.evidence
        )
    }
}
