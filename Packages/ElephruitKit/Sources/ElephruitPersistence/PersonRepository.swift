import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Everything needed to make a person.
public struct PersonDraft: Sendable, Hashable {
    public var id: UUID
    public var fullName: String
    public var givenName: String?
    public var familyName: String?

    /// The parts of a name Contacts keeps separately.
    ///
    /// Read on import for the same reason they are writable: **anything a write can clear, a read has
    /// to learn.** Without these the app would import somebody as "Dr Maya Lin Chen PhD", store only
    /// "Maya" and "Chen", and then offer the address book a write that blanked the three parts it
    /// never knew about. `contactWriteCanOnlyClearWhatImportReads` asserts the pairing.
    public var middleName: String?
    public var namePrefix: String?
    public var nameSuffix: String?
    public var departmentName: String?
    public var nickname: String?
    public var pronouns: String?
    public var pronunciation: String?
    public var roleTitle: String?
    public var organizationName: String?
    public var locationText: String?
    public var timeZoneIdentifier: String?
    public var emails: [LabelledValue]
    public var phones: [LabelledValue]
    public var addresses: [LabelledValue]
    public var websites: [LabelledValue]
    public var birthday: PartialDate?
    public var contactsIdentifier: String?
    public var contactsAccountName: String?

    /// A record made only so somebody could be mentioned. See ``PersonProfile/isPlaceholder``.
    public var isPlaceholder: Bool

    public var source: ItemSource

    public init(
        id: UUID = UUID(),
        fullName: String,
        givenName: String? = nil,
        familyName: String? = nil,
        middleName: String? = nil,
        namePrefix: String? = nil,
        nameSuffix: String? = nil,
        departmentName: String? = nil,
        nickname: String? = nil,
        pronouns: String? = nil,
        pronunciation: String? = nil,
        roleTitle: String? = nil,
        organizationName: String? = nil,
        locationText: String? = nil,
        timeZoneIdentifier: String? = nil,
        emails: [LabelledValue] = [],
        phones: [LabelledValue] = [],
        addresses: [LabelledValue] = [],
        websites: [LabelledValue] = [],
        birthday: PartialDate? = nil,
        contactsIdentifier: String? = nil,
        contactsAccountName: String? = nil,
        isPlaceholder: Bool = false,
        source: ItemSource = .manual
    ) {
        self.id = id
        self.fullName = fullName
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.namePrefix = namePrefix
        self.nameSuffix = nameSuffix
        self.departmentName = departmentName
        self.nickname = nickname
        self.pronouns = pronouns
        self.pronunciation = pronunciation
        self.roleTitle = roleTitle
        self.organizationName = organizationName
        self.locationText = locationText
        self.timeZoneIdentifier = timeZoneIdentifier
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.websites = websites
        self.birthday = birthday
        self.contactsIdentifier = contactsIdentifier
        self.contactsAccountName = contactsAccountName
        self.isPlaceholder = isPlaceholder
        self.source = source
    }

    /// Splits a written name into its parts.
    ///
    /// Naive on purpose — first word given, last word family, everything else in the middle. Name
    /// structure is not universal and guessing harder gets it wrong more confidently; both parts stay
    /// editable, and ``fullName`` is what the app actually displays.
    public static func nameParts(from fullName: String) -> (given: String, family: String) {
        let parts = fullName.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return (parts.first ?? "", "") }
        return (parts[0], parts[parts.count - 1])
    }
}

/// Reading and writing people, their facts, their relationships, and their celebrations.
///
/// `@MainActor` for the reason given on ``ItemRepository``: it hands out `Item` objects, which are
/// not `Sendable`. A protocol so the People features can be tested against a double and so the
/// SwiftData dependency stops here.
@MainActor
public protocol PersonRepository: AnyObject {
    // MARK: People

    func person(id: UUID) throws(AppError) -> Item?
    func allPeople(includingPlaceholders: Bool) throws(AppError) -> [Item]

    @discardableResult
    func createPerson(_ draft: PersonDraft) throws(AppError) -> Item

    /// Adds details to somebody who already exists, without removing any.
    ///
    /// Additive by design: a command bar line adding a phone number must never silently drop the
    /// email that was already there.
    func addDetails(to person: Item, from draft: PersonDraft) throws(AppError)

    func updateProfile(of person: Item, _ mutate: (PersonProfile) -> Void) throws(AppError)

    /// The user's own card, if one has been chosen.
    func myCard() throws(AppError) -> Item?
    func setMyCard(_ person: Item) throws(AppError)

    // MARK: Observations

    func observations(for person: Item) throws(AppError) -> [PersonObservationRecord]
    func ledger(for person: Item) throws(AppError) -> FactLedger

    @discardableResult
    func record(
        _ draft: ObservationDraft,
        about person: Item,
        observedOn: Date,
        confidence: FactConfidence,
        sensitivity: FactSensitivity,
        source: Item?
    ) throws(AppError) -> PersonObservationRecord

    /// Says the fact still holds, without changing it.
    func confirm(_ observation: PersonObservationRecord) throws(AppError)

    /// Removes one observation. Superseded history remains unless it is explicitly removed too.
    func remove(_ observation: PersonObservationRecord) throws(AppError)

    /// Replaces a fact, keeping the original as history.
    @discardableResult
    func correct(
        _ observation: PersonObservationRecord,
        to value: String,
        note: String?
    ) throws(AppError) -> PersonObservationRecord

    // MARK: Relationships

    func relationships(of person: Item) throws(AppError) -> [PersonRelationship]

    /// Records a relationship and its reciprocal as one unit.
    @discardableResult
    func relate(
        _ subject: Item,
        to other: Item,
        as kind: RelationshipKind,
        label: String?
    ) throws(AppError) -> PersonRelationship

    /// Removes a relationship and its reciprocal.
    func unrelate(_ relationship: PersonRelationship) throws(AppError)

    /// Changes a relationship and keeps its reciprocal in agreement.
    func update(
        _ relationship: PersonRelationship,
        kind: RelationshipKind,
        label: String?
    ) throws(AppError)

    /// Finds somebody by name, or makes a placeholder for them.
    func resolveOrCreatePlaceholder(named name: String) throws(AppError) -> Item

    // MARK: Celebrations

    func celebrations(of person: Item) throws(AppError) -> [PersonCelebration]
    func allCelebrations() throws(AppError) -> [Celebration]

    /// Records a celebration. Returns `nil` for a birthday, which lives on the profile rather than
    /// in a row of its own — see the implementation for why.
    @discardableResult
    func addCelebration(
        to person: Item,
        kind: CelebrationKind,
        title: String?,
        date: PartialDate
    ) throws(AppError) -> PersonCelebration?

    func removeCelebration(_ celebration: PersonCelebration) throws(AppError)

    /// Clears somebody's birthday.
    func removeBirthday(from person: Item) throws(AppError)
}

/// The SwiftData implementation.
@MainActor
public final class SwiftDataPersonRepository: PersonRepository {
    private let context: ModelContext
    private let items: any ItemRepository
    private let dateProvider: any DateProvider
    private let audit: FetchAudit?

    public init(
        context: ModelContext,
        items: any ItemRepository,
        dateProvider: any DateProvider,
        audit: FetchAudit? = nil
    ) {
        self.context = context
        self.items = items
        self.dateProvider = dateProvider
        self.audit = audit
    }

    // MARK: - People

    public func person(id: UUID) throws(AppError) -> Item? {
        guard let item = try items.item(id: id), item.kind == .person else { return nil }
        return item
    }

    public func allPeople(includingPlaceholders: Bool = true) throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.kinds = [.person]
        query.scope = .active
        query.sort = .titleAscending
        query.limit = nil
        query.prefetches = [.personProfile]

        let people = try items.items(matching: query)
        guard !includingPlaceholders else { return people }
        return people.filter { $0.personProfile?.isPlaceholder != true }
    }

    @discardableResult
    public func createPerson(_ draft: PersonDraft) throws(AppError) -> Item {
        var itemDraft = ItemDraft(kind: .person, title: draft.fullName, source: draft.source)
        itemDraft.id = draft.id

        let person = try items.create(itemDraft)
        let profile = PersonProfile()
        profile.item = person
        context.insert(profile)

        apply(draft, to: profile, replacingIdentity: true)

        // The profile's names and role feed the item's search projection, so it has to be refreshed
        // *after* the profile exists — creating the item alone indexes an empty person.
        try items.update(person) { $0.refreshSearchText() }

        if let birthday = draft.birthday {
            try addCelebration(to: person, kind: .birthday, title: nil, date: birthday)
        }

        try save()
        Diagnostics.persistence.debug("Created a person")
        return person
    }

    public func addDetails(to person: Item, from draft: PersonDraft) throws(AppError) {
        let profile = try profile(for: person)
        apply(draft, to: profile, replacingIdentity: false)
        try items.update(person) { $0.refreshSearchText() }
        try save()
    }

    /// Writes a draft onto a profile.
    ///
    /// - Parameter replacingIdentity: `true` when creating, so names and pronouns are set. `false`
    ///   when adding details to somebody who exists, where overwriting a name the user has already
    ///   corrected would be exactly the wrong behaviour — a command bar line adding a phone number
    ///   must not rename anybody.
    private func apply(_ draft: PersonDraft, to profile: PersonProfile, replacingIdentity: Bool) {
        if replacingIdentity {
            let parts = PersonDraft.nameParts(from: draft.fullName)
            profile.givenName = draft.givenName ?? parts.given
            profile.familyName = draft.familyName ?? parts.family
            profile.isPlaceholder = draft.isPlaceholder
        }

        // Everything else fills a gap rather than replacing a value.
        if let middleName = draft.middleName { profile.middleName = middleName }
        if let namePrefix = draft.namePrefix { profile.namePrefix = namePrefix }
        if let nameSuffix = draft.nameSuffix { profile.nameSuffix = nameSuffix }
        if let department = draft.departmentName { profile.departmentName = department }
        if let nickname = draft.nickname { profile.nickname = nickname }
        if let pronouns = draft.pronouns { profile.pronouns = pronouns }
        if let pronunciation = draft.pronunciation { profile.pronunciation = pronunciation }
        if let role = draft.roleTitle { profile.roleTitle = role }
        if let organization = draft.organizationName { profile.organizationName = organization }
        if let location = draft.locationText { profile.locationText = location }
        if let zone = draft.timeZoneIdentifier { profile.timeZoneIdentifier = zone }
        if let identifier = draft.contactsIdentifier { profile.contactsIdentifier = identifier }
        if let account = draft.contactsAccountName { profile.contactsAccountName = account }

        profile.emails = merge(profile.emails, with: draft.emails, normalizing: ContactDetailRecognizer.normalizedEmail)
        profile.phones = merge(profile.phones, with: draft.phones, normalizing: ContactDetailRecognizer.normalizedPhone)
        profile.addresses = merge(profile.addresses, with: draft.addresses) { $0.lowercased() }
        profile.websites = merge(profile.websites, with: draft.websites) { $0.lowercased() }

        if let birthday = draft.birthday, profile.birthday == nil {
            var components = DateComponents()
            components.year = birthday.year ?? 1904
            components.month = birthday.month
            components.day = birthday.day
            profile.birthday = dateProvider.calendar.date(from: components)
            profile.birthdayHasYear = birthday.hasYear
        }
    }

    /// Adds values that are not already present, comparing on a normalised form.
    ///
    /// So `+1 (512) 555-0192` does not join a list that already holds `512-555-0192`. The value that
    /// stays is the one already there — the user typed it that way.
    private func merge(
        _ existing: [LabelledValue],
        with incoming: [LabelledValue],
        normalizing: (String) -> String
    ) -> [LabelledValue] {
        guard !incoming.isEmpty else { return existing }

        var result = existing
        var seen = Set(existing.map { normalizing($0.value) })

        for value in incoming {
            let key = normalizing(value.value)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    public func updateProfile(of person: Item, _ mutate: (PersonProfile) -> Void) throws(AppError) {
        let profile = try profile(for: person)
        mutate(profile)
        try items.update(person) { $0.refreshSearchText() }
        try save()
    }

    /// The profile, created on demand.
    ///
    /// A person without one is a person created before this module or imported from an archive that
    /// predates it. Making one silently is right: the alternative is an error on a page the user just
    /// opened, for a condition they cannot act on.
    private func profile(for person: Item) throws(AppError) -> PersonProfile {
        if let existing = person.personProfile { return existing }

        let profile = PersonProfile()
        profile.item = person
        let parts = PersonDraft.nameParts(from: person.displayTitle)
        profile.givenName = parts.given
        profile.familyName = parts.family
        context.insert(profile)
        try save()
        return profile
    }

    public func myCard() throws(AppError) -> Item? {
        try allPeople(includingPlaceholders: true).first { $0.personProfile?.isMyCard == true }
    }

    public func setMyCard(_ person: Item) throws(AppError) {
        // Exactly one card, enforced here rather than by a unique constraint, which CloudKit forbids.
        for other in try allPeople(includingPlaceholders: true) where other.id != person.id {
            other.personProfile?.isMyCard = false
        }
        try profile(for: person).isMyCard = true
        try save()
    }

    // MARK: - Observations

    public func observations(for person: Item) throws(AppError) -> [PersonObservationRecord] {
        let personID = person.id
        let descriptor = FetchDescriptor<PersonObservationRecord>(
            predicate: #Predicate { $0.subject?.id == personID },
            sortBy: [SortDescriptor(\.observedOn, order: .reverse)]
        )
        return try fetch(descriptor)
    }

    public func ledger(for person: Item) throws(AppError) -> FactLedger {
        FactLedger(observations: try observations(for: person).compactMap { $0.asValue() })
    }

    @discardableResult
    public func record(
        _ draft: ObservationDraft,
        about person: Item,
        observedOn: Date,
        confidence: FactConfidence = .stated,
        sensitivity: FactSensitivity = .normal,
        source: Item? = nil
    ) throws(AppError) -> PersonObservationRecord {
        let record = PersonObservationRecord(
            attribute: draft.attribute,
            value: draft.value,
            observedOn: observedOn,
            effectiveOn: draft.effective?.resolve(using: dateProvider),
            confidence: confidence,
            sensitivity: sensitivity,
            subject: person,
            sourceItem: source,
            schoolYearStart: draft.schoolYearStart ?? Self.schoolYear(for: draft, observedOn: observedOn, calendar: dateProvider.calendar)
        )
        context.insert(record)

        // A single-valued attribute supersedes whatever it replaces, so the page shows one answer
        // and the previous one becomes history rather than a contradiction.
        if !draft.attribute.isMultiValued {
            for previous in try observations(for: person)
            where previous.id != record.id && previous.attribute == draft.attribute && previous.isCurrent {
                previous.supersededOn = observedOn
                record.supersedesID = previous.id
            }
        }

        try items.update(person) { $0.refreshSearchText() }
        try save()
        return record
    }

    /// Which school year a grade observation refers to.
    ///
    /// "Entering" or "starts" means the year about to begin; anything else means the one the
    /// observation date falls in. Parsing has no clock and cannot decide this — see
    /// ``ElephruitCore/GradeEstimator`` for what goes wrong when it is derived from the observation
    /// date alone.
    static func schoolYear(for draft: ObservationDraft, observedOn: Date, calendar: Calendar) -> Int? {
        guard draft.attribute == .schoolGrade else { return nil }

        let current = SchoolYear.containing(observedOn, calendar: calendar)
        // `effective` is set by the parser only for the forward-looking verbs.
        return draft.effective == nil ? current.startYear : current.startYear + 1
    }

    public func confirm(_ observation: PersonObservationRecord) throws(AppError) {
        observation.lastConfirmedOn = dateProvider.now
        try save()
    }

    public func remove(_ observation: PersonObservationRecord) throws(AppError) {
        let person = observation.subject
        context.delete(observation)
        if let person {
            try items.update(person) { $0.refreshSearchText() }
        }
        try save()
    }

    @discardableResult
    public func correct(
        _ observation: PersonObservationRecord,
        to value: String,
        note: String?
    ) throws(AppError) -> PersonObservationRecord {
        guard let person = observation.subject else {
            throw .itemNotFound(id: observation.id)
        }

        let now = dateProvider.now
        let replacement = PersonObservationRecord(
            attribute: observation.attribute,
            value: value,
            // The correction is observed now; what it corrects keeps its own date. Backdating the
            // replacement would make an age estimate advance from a moment nobody spoke.
            observedOn: now,
            effectiveOn: observation.effectiveOn,
            confidence: .stated,
            sensitivity: observation.sensitivity,
            subject: person,
            sourceItem: observation.sourceItem,
            supersedesID: observation.id,
            schoolYearStart: observation.schoolYearStart
        )
        replacement.correctionNote = note
        context.insert(replacement)

        // The original is superseded, never deleted. This is the whole promise of the fact model.
        observation.supersededOn = now

        try items.update(person) { $0.refreshSearchText() }
        try save()
        return replacement
    }

    // MARK: - Relationships

    public func relationships(of person: Item) throws(AppError) -> [PersonRelationship] {
        let personID = person.id
        let descriptor = FetchDescriptor<PersonRelationship>(
            predicate: #Predicate { $0.subject?.id == personID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try fetch(descriptor).filter { $0.other?.deletedAt == nil }
    }

    @discardableResult
    public func relate(
        _ subject: Item,
        to other: Item,
        as kind: RelationshipKind,
        label: String? = nil
    ) throws(AppError) -> PersonRelationship {
        guard subject.id != other.id else {
            throw .validation(ValidationFailure(reason: .containmentCycle, field: "relationship"))
        }

        // Relating twice is a no-op, on the same terms as `ItemRepository.link`: the caller means
        // "these two are related", and saying it again does not make it more true.
        if let existing = try relationships(of: subject).first(where: { $0.kind == kind && $0.other?.id == other.id }) {
            if let label { existing.customLabel = label }
            try save()
            return existing
        }

        let now = dateProvider.now
        let forward = PersonRelationship(kind: kind, customLabel: label, subject: subject, other: other, createdAt: now)
        let backward = PersonRelationship(
            kind: kind.inverse,
            // The user's word describes *this* direction only. "Maya's son Jack" says nothing about
            // what Jack calls Maya, and inventing "mother" from it would be the app guessing at a
            // gender it was never told.
            customLabel: nil,
            subject: other,
            other: subject,
            createdAt: now
        )

        forward.reciprocalID = backward.id
        backward.reciprocalID = forward.id

        context.insert(forward)
        context.insert(backward)
        try save()

        Diagnostics.persistence.debug("Related two people as \(kind.rawValue, privacy: .public)")
        return forward
    }

    public func unrelate(_ relationship: PersonRelationship) throws(AppError) {
        // Both halves go, or the graph is left claiming a relationship from one side only.
        if let reciprocalID = relationship.reciprocalID {
            let descriptor = FetchDescriptor<PersonRelationship>(predicate: #Predicate { $0.id == reciprocalID })
            for match in try fetch(descriptor) {
                context.delete(match)
            }
        }
        context.delete(relationship)
        try save()
    }

    public func update(
        _ relationship: PersonRelationship,
        kind: RelationshipKind,
        label: String?
    ) throws(AppError) {
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        relationship.kind = kind
        relationship.customLabel = trimmedLabel?.isEmpty == false ? trimmedLabel : nil

        if let reciprocalID = relationship.reciprocalID {
            let descriptor = FetchDescriptor<PersonRelationship>(predicate: #Predicate { $0.id == reciprocalID })
            if let reciprocal = try fetch(descriptor).first {
                reciprocal.kind = kind.inverse
                reciprocal.customLabel = nil
            }
        }

        try save()
    }

    public func resolveOrCreatePlaceholder(named name: String) throws(AppError) -> Item {
        let key = TextNormalizer.foldedForMatching(name)
        guard !key.isEmpty else { throw .validation(ValidationFailure(reason: .emptyPersonName, field: "name")) }

        if let existing = try allPeople(includingPlaceholders: true).first(
            where: { TextNormalizer.foldedForMatching($0.displayTitle) == key }
        ) {
            return existing
        }

        return try createPerson(PersonDraft(fullName: name, isPlaceholder: true))
    }

    // MARK: - Celebrations

    public func celebrations(of person: Item) throws(AppError) -> [PersonCelebration] {
        let personID = person.id
        let descriptor = FetchDescriptor<PersonCelebration>(predicate: #Predicate { $0.person?.id == personID })
        return try fetch(descriptor)
    }

    public func allCelebrations() throws(AppError) -> [Celebration] {
        var descriptor = FetchDescriptor<PersonCelebration>()
        descriptor.relationshipKeyPathsForPrefetching = [\.person]
        let storedByPersonID = Dictionary(
            grouping: try fetch(descriptor),
            by: { $0.person?.id }
        )
        var result: [Celebration] = []

        for person in try allPeople(includingPlaceholders: true) {
            // A birthday on the profile is the one Contacts reconciles against, so it stays there
            // and is lifted into the same list rather than being copied into a second row that would
            // then need keeping in step.
            if let birthday = person.personProfile?.birthdayDate(calendar: dateProvider.calendar) {
                result.append(
                    Celebration(
                        id: person.personProfile?.id ?? person.id,
                        personID: person.id,
                        personName: person.displayTitle,
                        kind: .birthday,
                        date: birthday
                    )
                )
            }

            result.append(contentsOf: (storedByPersonID[person.id] ?? []).compactMap { $0.asValue() })
        }

        return result
    }

    /// Records a celebration.
    ///
    /// Returns `nil` for a birthday, which has no row of its own — see below.
    @discardableResult
    public func addCelebration(
        to person: Item,
        kind: CelebrationKind,
        title: String?,
        date: PartialDate
    ) throws(AppError) -> PersonCelebration? {
        // A birthday lives on the profile and **only** there. It is the one celebration Contacts
        // also holds, so it has to sit where a refresh can reconcile against it; writing a row
        // beside it would give one person two birthdays that are free to disagree, and the
        // celebrations list would show both.
        guard kind != .birthday else {
            let profile = try profile(for: person)
            var components = DateComponents()
            // 1904 is the year Contacts itself uses for a birthday with no year. Never displayed —
            // `birthdayHasYear` is what decides that — but using the same convention means a value
            // written here and one read from Contacts are indistinguishable.
            components.year = date.year ?? 1904
            components.month = date.month
            components.day = date.day
            profile.birthday = dateProvider.calendar.date(from: components)
            profile.birthdayHasYear = date.hasYear
            try save()
            return nil
        }

        let celebration = PersonCelebration(
            kind: kind, title: title, date: date, person: person, createdAt: dateProvider.now
        )
        context.insert(celebration)
        try save()
        return celebration
    }

    public func removeCelebration(_ celebration: PersonCelebration) throws(AppError) {
        context.delete(celebration)
        try save()
    }

    public func removeBirthday(from person: Item) throws(AppError) {
        person.personProfile?.birthday = nil
        person.personProfile?.birthdayHasYear = false
        try save()
    }

    // MARK: - Store

    private func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws(AppError) -> [Model] {
        audit?.record(.other)
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    private func save() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            Diagnostics.persistence.error("Person save failed: \(error.localizedDescription, privacy: .public)")
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
