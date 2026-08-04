import ElephruitCore
import Foundation
import SwiftData

/// A dated statement about a person, as it lives in the store.
///
/// ### Why an entity rather than more columns on `PersonProfile`
/// The whole point of ``ElephruitCore/PersonObservation`` is that a fact has a history, and history
/// is rows. A column holds one value and destroys the one before it; a row per observation means
/// "what did I believe last year, and who told me" is a query rather than an archaeology project.
///
/// The value type in Core is the one everything reasons about. This is its storage, and
/// ``PersonObservationRecord/asValue()`` is the only bridge — so no rule about superseding, staleness,
/// or confidence is implemented twice.
///
/// **CloudKit compliance**, on the same terms as every other entity here: every attribute has a
/// default, no unique constraints, every to-one relationship optional with a declared inverse, and
/// no `.deny` delete rule.
@Model
public final class PersonObservationRecord {
    /// A person's facts are always fetched together and always in date order.
    #Index<PersonObservationRecord>([\.observedOn])

    public var id: UUID = UUID()

    /// ``ElephruitCore/FactAttribute`` raw value.
    ///
    /// A string, like ``Item/kindRaw``, so an attribute written by a newer build reads back without
    /// loss rather than collapsing into a catch-all.
    public var attributeRaw: String = FactAttribute.lifeEvent.rawValue

    public var value: String = ""

    public var observedOn: Date = Date()
    public var effectiveOn: Date?
    public var lastConfirmedOn: Date = Date()

    /// ``ElephruitCore/FactConfidence`` raw value.
    public var confidenceRaw: String = FactConfidence.stated.rawValue

    /// ``ElephruitCore/FactSensitivity`` raw value.
    public var sensitivityRaw: String = FactSensitivity.normal.rawValue

    /// The observation this one replaced, by identifier rather than by relationship.
    ///
    /// A relationship would need an inverse, a delete rule, and a cycle guard, and would buy
    /// nothing: the chain is walked in memory over one person's observations, which are already
    /// loaded. An identifier that points at a deleted row simply reads as "no predecessor", which is
    /// the correct behaviour.
    public var supersedesID: UUID?

    public var supersededOn: Date?
    public var correctionNote: String?

    /// The school year a grade referred to, as its starting year. See
    /// ``ElephruitCore/PersonObservation/schoolYearStart``.
    public var schoolYearStart: Int?

    // MARK: Relationships

    /// The person this is about.
    @Relationship(deleteRule: .nullify, inverse: \Item.observationsAbout)
    public var subject: Item?

    /// The note, interaction, or meeting this came out of.
    ///
    /// `.nullify` by omission — deleting the note that mentioned somebody's new job must not delete
    /// the fact that they changed job. The fact survives having lost its source, which is worse than
    /// keeping both and far better than losing both.
    @Relationship(deleteRule: .nullify, inverse: \Item.observationsSourced)
    public var sourceItem: Item?

    public init(
        id: UUID = UUID(),
        attribute: FactAttribute = .lifeEvent,
        value: String = "",
        observedOn: Date = Date(),
        effectiveOn: Date? = nil,
        lastConfirmedOn: Date? = nil,
        confidence: FactConfidence = .stated,
        sensitivity: FactSensitivity = .normal,
        subject: Item? = nil,
        sourceItem: Item? = nil,
        supersedesID: UUID? = nil,
        schoolYearStart: Int? = nil
    ) {
        self.id = id
        self.attributeRaw = attribute.rawValue
        self.value = value
        self.observedOn = observedOn
        self.effectiveOn = effectiveOn
        self.lastConfirmedOn = lastConfirmedOn ?? observedOn
        self.confidenceRaw = confidence.rawValue
        self.sensitivityRaw = sensitivity.rawValue
        self.subject = subject
        self.sourceItem = sourceItem
        self.supersedesID = supersedesID
        self.schoolYearStart = schoolYearStart
    }
}

extension PersonObservationRecord {
    public var attribute: FactAttribute {
        get { FactAttribute(rawValue: attributeRaw) }
        set { attributeRaw = newValue.rawValue }
    }

    public var confidence: FactConfidence {
        get { FactConfidence(rawValue: confidenceRaw) ?? .uncertain }
        set { confidenceRaw = newValue.rawValue }
    }

    public var sensitivity: FactSensitivity {
        get { FactSensitivity(rawValue: sensitivityRaw) ?? .normal }
        set { sensitivityRaw = newValue.rawValue }
    }

    public var isCurrent: Bool { supersededOn == nil }

    /// The `Sendable` value every rule is written against.
    ///
    /// A record whose subject has gone returns `nil` rather than inventing an identifier: an
    /// observation about nobody is not an observation, and dropping it here is what keeps the ledger
    /// from having to know about orphans.
    public func asValue() -> PersonObservation? {
        guard let subjectID = subject?.id else { return nil }

        return PersonObservation(
            id: id,
            subjectID: subjectID,
            attribute: attribute,
            value: value,
            observedOn: observedOn,
            effectiveOn: effectiveOn,
            lastConfirmedOn: lastConfirmedOn,
            confidence: confidence,
            sensitivity: sensitivity,
            sourceItemID: sourceItem?.id,
            supersedesID: supersedesID,
            supersededOn: supersededOn,
            correctionNote: correctionNote,
            schoolYearStart: schoolYearStart
        )
    }

    /// Text folded into the subject's ``Item/searchText`` so a person is findable by what is known
    /// about them — "likes natural wine" finds Maya.
    ///
    /// Restricted facts are excluded. A private reflection must not be reachable by typing a word
    /// from it into a search field that also searches everything else.
    public var searchableText: String? {
        guard sensitivity != .restricted, attribute != .reflection else { return nil }
        return "\(attribute.rawValue) \(value)"
    }
}

// MARK: - Relationships

/// A typed edge between two people.
///
/// ### Why not an `ItemLink`
/// `ItemLink` is the general association between any two items and carries a ``LinkKind`` that
/// describes *how the link was made* — written in text, filed deliberately, mentioned. A
/// relationship describes *what two people are to each other*, needs a reciprocal that the store
/// maintains as a pair, and carries the word the user actually used. Overloading `ItemLink` with
/// fourteen more kinds would put family structure in the same bucket as a wiki link and make
/// "everything Maya is mentioned in" return her own son.
///
/// The pair is maintained by ``ElephruitPersistence/PersonRepository``, which writes both rows in
/// one save. `ReciprocalRelationshipTests` asserts that no single-sided relationship can survive a
/// round trip through the store.
@Model
public final class PersonRelationship {
    public var id: UUID = UUID()

    /// ``ElephruitCore/RelationshipKind`` raw value, read from the subject's side.
    public var kindRaw: String = RelationshipKind.friend.rawValue

    /// The word the user typed — "son", "step-mother", "boss".
    ///
    /// Kept beside the kind rather than replacing it, so the chart can group by kind while the page
    /// still says what the user said. The app never infers one of these; it only remembers.
    public var customLabel: String?

    public var createdAt: Date = Date()

    /// When the relationship began, if the user recorded it.
    public var startedOn: Date?

    /// When it ended. A past relationship is history rather than an error, and deleting it would
    /// lose the fact that two people used to be related — which is often the point.
    public var endedOn: Date?

    public var notes: String?

    /// The identifier of the row holding the other half.
    ///
    /// By identifier rather than a relationship for the same reason ``PersonObservationRecord``
    /// supersedes by identifier: a self-referencing to-one on top of two `Item` relationships is
    /// exactly the inverse-bookkeeping shape `docs/08-risks.md` flags as R3, and the pair is only
    /// ever resolved with both rows already in hand.
    public var reciprocalID: UUID?

    // MARK: Relationships

    /// Whose page this reads from.
    @Relationship(deleteRule: .nullify, inverse: \Item.relationshipsAsSubject)
    public var subject: Item?

    /// The other person.
    @Relationship(deleteRule: .nullify, inverse: \Item.relationshipsAsOther)
    public var other: Item?

    public init(
        id: UUID = UUID(),
        kind: RelationshipKind = .friend,
        customLabel: String? = nil,
        subject: Item? = nil,
        other: Item? = nil,
        createdAt: Date = Date(),
        reciprocalID: UUID? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.customLabel = customLabel
        self.subject = subject
        self.other = other
        self.createdAt = createdAt
        self.reciprocalID = reciprocalID
    }
}

extension PersonRelationship {
    public var kind: RelationshipKind {
        get { RelationshipKind(rawValue: kindRaw) ?? .friend }
        set { kindRaw = newValue.rawValue }
    }

    /// Whether this is still true today.
    public var isCurrent: Bool { endedOn == nil }

    /// The label to show — the user's own word first.
    public var displayLabel: String {
        customLabel ?? kind.displayName
    }
}

// MARK: - Celebrations

/// A dated thing worth noticing about somebody.
///
/// Separate from ``PersonProfile/birthday`` rather than replacing it: a birthday is a property of a
/// person and stays where Contacts can be reconciled against it, whereas an anniversary, a memorial,
/// and "sober since" are user-created and unbounded in number. Both feed one
/// ``ElephruitCore/Celebration`` list.
///
/// The year is optional in the same way and for the same reason as everywhere else in this module —
/// see ``ElephruitCore/PartialDate``.
@Model
public final class PersonCelebration {
    public var id: UUID = UUID()

    /// ``ElephruitCore/CelebrationKind`` raw value.
    public var kindRaw: String = CelebrationKind.birthday.rawValue

    /// The user's own name for it, when the kind is not enough.
    public var title: String?

    public var month: Int = 1
    public var day: Int = 1

    /// Absent when the year is not known, which for a birthday is the ordinary case.
    public var year: Int?

    public var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Item.celebrations)
    public var person: Item?

    public init(
        id: UUID = UUID(),
        kind: CelebrationKind = .birthday,
        title: String? = nil,
        date: PartialDate,
        person: Item? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.month = date.month
        self.day = date.day
        self.year = date.year
        self.person = person
        self.createdAt = createdAt
    }
}

extension PersonCelebration {
    public var kind: CelebrationKind {
        get { CelebrationKind(rawValue: kindRaw) ?? .milestone }
        set { kindRaw = newValue.rawValue }
    }

    public var date: PartialDate? {
        PartialDate(year: year, month: month, day: day)
    }

    public func asValue() -> Celebration? {
        guard let person, let date else { return nil }
        return Celebration(
            id: id,
            personID: person.id,
            personName: person.displayTitle,
            kind: kind,
            title: title,
            date: date
        )
    }
}
