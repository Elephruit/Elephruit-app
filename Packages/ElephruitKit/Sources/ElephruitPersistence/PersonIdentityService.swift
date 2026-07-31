import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Keeping one person from becoming three profiles — and two people from becoming one.
///
/// ### The asymmetry this is built around
/// Duplicate profiles are untidy and completely recoverable: merge them and everything is in one
/// place. A wrong merge destroys the boundary between two people's private notes and cannot be
/// undone by hand. So every operation here is *offered* with its reasoning attached, and the only
/// thing done without asking is linking two records that are provably the same row in the same
/// system store.
@MainActor
public final class PersonIdentityService {
    private let context: ModelContext
    private let people: any PersonRepository
    private let items: any ItemRepository
    private let dateProvider: any DateProvider

    public init(
        context: ModelContext,
        people: any PersonRepository,
        items: any ItemRepository,
        dateProvider: any DateProvider
    ) {
        self.context = context
        self.people = people
        self.items = items
        self.dateProvider = dateProvider
    }

    /// Every person in the library, as the matcher sees them.
    public func candidates() throws(AppError) -> [IdentityCandidate] {
        try people.allPeople(includingPlaceholders: true).compactMap { person in
            person.personProfile?.identityCandidate(calendar: dateProvider.calendar)
                ?? IdentityCandidate(id: person.id, fullName: person.displayTitle)
        }
    }

    /// Possible duplicates, strongest first.
    public func duplicates() throws(AppError) -> [IdentityMatch] {
        IdentityMatcher.duplicates(among: try candidates())
    }

    /// Whether an incoming record already exists in the library.
    ///
    /// Used at the moment of import, so linking an Apple Contacts record offers to attach it to
    /// somebody already known rather than making a second profile beside them.
    public func existingMatch(for candidate: IdentityCandidate) throws(AppError) -> IdentityMatch? {
        IdentityMatcher.bestMatch(for: candidate, among: try candidates())
    }

    // MARK: - Merging

    /// What merging two people would do.
    ///
    /// Writes nothing. Every count in the plan is what the apply step will actually move, so the
    /// sentence the user reads is the operation they get.
    public func plan(merging secondary: Item, into primary: Item) throws(AppError) -> MergePlan {
        guard primary.id != secondary.id else {
            throw .validation(ValidationFailure(reason: .containmentCycle, field: "merge"))
        }

        let primaryProfile = primary.personProfile
        let secondaryProfile = secondary.personProfile

        let primaryEmails = Set((primaryProfile?.emails ?? []).map { ContactDetailRecognizer.normalizedEmail($0.value) })
        let primaryPhones = Set((primaryProfile?.phones ?? []).map { ContactDetailRecognizer.normalizedPhone($0.value) })

        let addedEmails = (secondaryProfile?.emails ?? [])
            .filter { !primaryEmails.contains(ContactDetailRecognizer.normalizedEmail($0.value)) }
            .map(\.value)
        let addedPhones = (secondaryProfile?.phones ?? [])
            .filter { !primaryPhones.contains(ContactDetailRecognizer.normalizedPhone($0.value)) }
            .map(\.value)

        var conflicts: [MergeConflict] = []
        func compare(_ field: String, _ left: String?, _ right: String?) {
            guard let left, let right, !left.isEmpty, !right.isEmpty, left != right else { return }
            conflicts.append(MergeConflict(field: field, primaryValue: left, secondaryValue: right))
        }
        compare("Role", primaryProfile?.roleTitle, secondaryProfile?.roleTitle)
        compare("Organisation", primaryProfile?.organizationName, secondaryProfile?.organizationName)
        compare("Location", primaryProfile?.locationText, secondaryProfile?.locationText)
        compare("Pronouns", primaryProfile?.pronouns, secondaryProfile?.pronouns)

        return MergePlan(
            primaryID: primary.id,
            secondaryID: secondary.id,
            primaryName: primary.displayTitle,
            secondaryName: secondary.displayTitle,
            addedEmails: addedEmails,
            addedPhones: addedPhones,
            conflicts: conflicts,
            movedObservations: try people.observations(for: secondary).count,
            movedLinks: secondary.incomingLinks.count + secondary.outgoingLinks.count,
            movedRelationships: try people.relationships(of: secondary).count
        )
    }

    /// Performs the merge the user approved.
    ///
    /// The secondary record is **trashed, not destroyed**. Everything moves first, and what is left
    /// behind is an empty profile in the Trash that can be restored — which is the difference between
    /// a merge somebody can walk back and one they cannot.
    ///
    /// Conflicting single-value fields are kept as observations on the surviving record rather than
    /// being resolved. Choosing between two things the user wrote down is not the app's decision, and
    /// discarding one of them is precisely the data loss the requirement forbids.
    public func merge(_ plan: MergePlan) throws(AppError) {
        guard let primary = try people.person(id: plan.primaryID),
              let secondary = try people.person(id: plan.secondaryID)
        else { throw .itemNotFound(id: plan.secondaryID) }

        let now = dateProvider.now

        // Contact details.
        var draft = PersonDraft(fullName: primary.displayTitle)
        draft.emails = (secondary.personProfile?.emails ?? [])
        draft.phones = (secondary.personProfile?.phones ?? [])
        draft.addresses = (secondary.personProfile?.addresses ?? [])
        draft.websites = (secondary.personProfile?.websites ?? [])
        // `addDetails` merges rather than replaces and de-duplicates on a normalised form.
        try people.addDetails(to: primary, from: draft)

        try people.updateProfile(of: primary) { profile in
            profile.nickname = profile.nickname ?? secondary.personProfile?.nickname
            profile.pronunciation = profile.pronunciation ?? secondary.personProfile?.pronunciation
            profile.pronouns = profile.pronouns ?? secondary.personProfile?.pronouns
            profile.timeZoneIdentifier = profile.timeZoneIdentifier ?? secondary.personProfile?.timeZoneIdentifier
            profile.contactsIdentifier = profile.contactsIdentifier ?? secondary.personProfile?.contactsIdentifier
            profile.contactsAccountName = profile.contactsAccountName ?? secondary.personProfile?.contactsAccountName
            if profile.birthday == nil {
                profile.birthday = secondary.personProfile?.birthday
                profile.birthdayHasYear = secondary.personProfile?.birthdayHasYear ?? false
            }
            // The survivor stops being a placeholder the moment it absorbs a real record.
            if secondary.personProfile?.isPlaceholder == false { profile.isPlaceholder = false }
        }

        // A conflict becomes a dated observation on the survivor, so both answers are kept and the
        // user can retire whichever is wrong without either having been silently dropped.
        for conflict in plan.conflicts {
            try people.record(
                ObservationDraft(attribute: FactAttribute(conflict.field.lowercased()), value: conflict.secondaryValue),
                about: primary,
                observedOn: now,
                confidence: .uncertain,
                sensitivity: .normal,
                source: nil
            )
        }

        // Observations, relationships, and links follow the person.
        for observation in try people.observations(for: secondary) {
            observation.subject = primary
        }

        for relationship in try people.relationships(of: secondary) {
            guard let other = relationship.other else { continue }
            if other.id == primary.id {
                // A relationship between the two records being merged is meaningless afterwards.
                try people.unrelate(relationship)
                continue
            }
            try people.relate(primary, to: other, as: relationship.kind, label: relationship.customLabel)
            try people.unrelate(relationship)
        }

        for celebration in try people.celebrations(of: secondary) {
            celebration.person = primary
        }

        for link in secondary.incomingLinks {
            link.target = primary
        }
        for link in secondary.outgoingLinks {
            link.source = primary
        }

        try save()

        // Trashed rather than deleted, and only once everything has moved.
        try items.moveToTrash(secondary)
        try items.update(primary) { $0.refreshSearchText() }

        Diagnostics.persistence.info("Merged two people; the absorbed record is in the Trash")
    }

    /// Links a person to a system Contacts record without copying anything into it.
    public func link(_ person: Item, toContactsIdentifier identifier: String, accountName: String?) throws(AppError) {
        try people.updateProfile(of: person) { profile in
            profile.contactsIdentifier = identifier
            profile.contactsAccountName = accountName
            profile.contactsRefreshedAt = self.dateProvider.now
        }
    }

    public func unlinkFromContacts(_ person: Item) throws(AppError) {
        try people.updateProfile(of: person) { profile in
            profile.contactsIdentifier = nil
            profile.contactsAccountName = nil
            profile.contactsRefreshedAt = nil
        }
    }

    private func save() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
