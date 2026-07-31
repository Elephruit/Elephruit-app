import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Keeps linked contact details current, and says so when it cannot.
///
/// ### What a refresh is allowed to do
/// Replace a value the app imported and nobody has touched since. That is all. A value the user
/// changed here is never overwritten — the newer system value is recorded *beside* it as a conflict
/// and shown, because silently discarding an edit somebody made deliberately is how an app teaches
/// people not to edit anything.
///
/// ### What it never does
/// Delete a person. A contact that stops resolving is a link that goes ``ContactSyncState/unavailable``
/// and keeps its last known values. "I cannot find this record" and "this person no longer exists" are
/// different claims and only the first one is true.
@MainActor
public final class ContactSyncService {
    private let context: ModelContext
    private let people: any PersonRepository
    private let imports: ContactImportService
    private let dateProvider: any DateProvider

    public init(
        context: ModelContext,
        people: any PersonRepository,
        imports: ContactImportService,
        dateProvider: any DateProvider
    ) {
        self.context = context
        self.people = people
        self.imports = imports
        self.dateProvider = dateProvider
    }

    // MARK: - Refresh

    /// What a refresh did.
    public struct RefreshReport: Sendable, Hashable {
        public var checked: Int
        public var updated: Int
        public var unchanged: Int
        public var wentUnavailable: Int
        public var recovered: Int
        public var conflicts: Int

        public init(
            checked: Int = 0,
            updated: Int = 0,
            unchanged: Int = 0,
            wentUnavailable: Int = 0,
            recovered: Int = 0,
            conflicts: Int = 0
        ) {
            self.checked = checked
            self.updated = updated
            self.unchanged = unchanged
            self.wentUnavailable = wentUnavailable
            self.recovered = recovered
            self.conflicts = conflicts
        }

        public var summary: String {
            var parts: [String] = []
            if updated > 0 { parts.append("\(updated) updated") }
            if conflicts > 0 { parts.append("\(conflicts) need\(conflicts == 1 ? "s" : "") a decision") }
            if wentUnavailable > 0 { parts.append("\(wentUnavailable) no longer in Contacts") }
            if recovered > 0 { parts.append("\(recovered) found again") }

            guard !parts.isEmpty else {
                return checked == 0 ? "Nothing linked yet." : "Everything is up to date."
            }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Applies one freshly-read contact to its link.
    ///
    /// The whole refresh rule lives here, and it is short on purpose:
    ///
    /// - a value the app imported and nobody touched is replaced, and the old row is superseded
    ///   rather than deleted, so *what did this used to say* stays answerable;
    /// - a value the user overrode is left alone, and the newer system value is recorded on it as a
    ///   conflict for the interface to raise;
    /// - a value that is simply new is added.
    @discardableResult
    public func apply(
        _ contact: SystemContact,
        to link: SystemContactLink
    ) throws(AppError) -> (didChange: Bool, newConflicts: Int) {
        guard let person = link.person else { return (false, 0) }

        let now = dateProvider.now
        var didChange = false
        var newConflicts = 0

        let incoming = ContactImportService.importedValues(from: contact, observedAt: now)
        let existing = link.currentValues

        for candidate in incoming {
            let match = existing.first { $0.fieldKey == candidate.fieldKey && $0.label == candidate.label }

            guard let match else {
                // A field the contact did not have before.
                candidate.link = link
                context.insert(candidate)
                didChange = true
                continue
            }

            guard match.value != candidate.value else {
                // Unchanged. Recording that it was seen again is what makes staleness meaningful.
                match.lastObservedAt = now
                continue
            }

            if match.origin.isRefreshable {
                // Superseded, not overwritten, so the previous value survives as history.
                match.supersededAt = now
                candidate.link = link
                context.insert(candidate)
                didChange = true
            } else {
                // The user changed this here. Their value stands; the disagreement is recorded.
                if match.conflictingSystemValue != candidate.value {
                    match.conflictingSystemValue = candidate.value
                    match.conflictObservedAt = now
                    newConflicts += 1
                }
            }
        }

        // Values the contact no longer has are superseded rather than deleted: a number that was
        // removed from the address book is still a number this person had, and the timeline of that
        // is worth more than the tidiness of dropping it.
        let incomingKeys = Set(incoming.map { "\($0.fieldKey)|\($0.label)|\($0.value)" })
        for value in existing where value.origin == .imported {
            let key = "\(value.fieldKey)|\(value.label)|\(value.value)"
            if !incomingKeys.contains(key),
               !incoming.contains(where: { $0.fieldKey == value.fieldKey && $0.label == value.label }) {
                value.supersededAt = now
                didChange = true
            }
        }

        // The effective values on the profile, which is what every existing view reads. Additive, so
        // a refresh never removes a detail somebody may have come to rely on.
        if didChange {
            try people.addDetails(to: person, from: imports.draft(from: contact))
        }

        link.state = .linked
        link.unavailableSince = nil
        link.lastRefreshedAt = now
        link.containerIdentifier = contact.containerIdentifier ?? link.containerIdentifier
        link.containerName = contact.containerName ?? link.containerName
        // Re-derived on every read, so it tracks the contact rather than freezing at import time.
        link.identitySignature = ContactIdentitySignature(contact: contact).storageKey

        try people.updateProfile(of: person) { $0.contactsRefreshedAt = now }
        try save()

        return (didChange, newConflicts)
    }

    /// Records that a link's contact could not be found.
    ///
    /// Deliberately gentle: the state changes, the values stay, and the person is untouched. The
    /// interface explains it without alarm and offers to relink or to keep the profile local-only.
    public func markUnavailable(_ link: SystemContactLink) throws(AppError) {
        guard link.state != .unavailable else { return }

        link.state = .unavailable
        link.unavailableSince = dateProvider.now
        try save()

        Diagnostics.persistence.info("A linked contact could not be found; the person and their details are kept")
    }

    /// Records that nothing can be read at all, because access is off.
    ///
    /// Distinct from unavailable, and the distinction matters to the user: one is about a contact,
    /// the other is about a permission, and only the second has a button that fixes it.
    public func markAllUnreadable() throws(AppError) {
        for link in try imports.allLinks() where link.state == .linked {
            link.state = .unreadable
        }
        try save()
    }

    /// Restores links from unreadable once access comes back.
    ///
    /// Only the ones this made unreadable: a contact that had genuinely gone missing stays missing
    /// until a refresh actually finds it.
    public func markAllReadable() throws(AppError) {
        for link in try imports.allLinks() where link.state == .unreadable {
            link.state = .linked
        }
        try save()
    }

    // MARK: - Conflicts

    /// Every disagreement between a value the user kept and a newer one from Contacts.
    ///
    /// Computed from the rows rather than stored, so it cannot go stale or outlive either side.
    public func conflicts() throws(AppError) -> [ContactSyncConflict] {
        var result: [ContactSyncConflict] = []

        for link in try imports.allLinks() {
            guard let person = link.person else { continue }

            for value in link.currentValues where value.hasConflict {
                guard let systemValue = value.conflictingSystemValue else { continue }
                result.append(
                    ContactSyncConflict(
                        id: value.id,
                        personID: person.id,
                        personName: person.displayTitle,
                        field: value.displayField,
                        localValue: value.value,
                        systemValue: systemValue,
                        observedAt: value.conflictObservedAt ?? value.lastObservedAt
                    )
                )
            }
        }

        return result.sorted { $0.observedAt > $1.observedAt }
    }

    /// Takes the system's value after all, superseding the local one.
    public func resolveConflictTakingSystemValue(_ conflictID: UUID) throws(AppError) {
        guard let value = try importedValue(id: conflictID),
              let systemValue = value.conflictingSystemValue,
              let link = value.link,
              let person = link.person
        else { return }

        let now = dateProvider.now

        let replacement = ImportedContactValue(
            fieldKey: value.fieldKey,
            label: value.label,
            value: systemValue,
            origin: .imported,
            observedAt: now,
            link: link
        )
        context.insert(replacement)

        value.supersededAt = now
        value.conflictingSystemValue = nil
        value.conflictObservedAt = nil

        // The profile has to follow, or the page would still show the value the user just retired.
        try replaceProfileValue(on: person, field: value.fieldKey, label: value.label, with: systemValue)
        try save()
    }

    /// Keeps the local value and stops mentioning the disagreement.
    public func resolveConflictKeepingLocalValue(_ conflictID: UUID) throws(AppError) {
        guard let value = try importedValue(id: conflictID) else { return }

        value.conflictingSystemValue = nil
        value.conflictObservedAt = nil
        value.lastObservedAt = dateProvider.now
        try save()
    }

    /// Marks a value as deliberately local, so refreshes stop replacing it.
    ///
    /// What "edit only the CRM copy" does underneath: the value stops being refreshable and starts
    /// collecting conflicts instead.
    public func markOverridden(
        person: Item,
        field: String,
        label: String,
        newValue: String
    ) throws(AppError) {
        guard let link = try imports.link(for: person) else { return }
        let now = dateProvider.now

        if let existing = link.currentValues.first(where: { $0.fieldKey == field && $0.label == label }) {
            existing.value = newValue
            existing.origin = .overridden
            existing.lastObservedAt = now
            existing.conflictingSystemValue = nil
            existing.conflictObservedAt = nil
        } else {
            let value = ImportedContactValue(
                fieldKey: field, label: label, value: newValue,
                origin: .overridden, observedAt: now, link: link
            )
            context.insert(value)
        }

        try replaceProfileValue(on: person, field: field, label: label, with: newValue)
        try save()
    }

    /// Writes an effective value onto the profile.
    private func replaceProfileValue(
        on person: Item,
        field: String,
        label: String,
        with newValue: String
    ) throws(AppError) {
        try people.updateProfile(of: person) { profile in
            func replace(_ values: [LabelledValue]) -> [LabelledValue] {
                var updated = values
                if let index = updated.firstIndex(where: { $0.label == label }) {
                    updated[index] = LabelledValue(label: label, value: newValue)
                } else {
                    updated.append(LabelledValue(label: label, value: newValue))
                }
                return updated
            }

            switch field {
            case ContactField.email: profile.emails = replace(profile.emails)
            case ContactField.phone: profile.phones = replace(profile.phones)
            case ContactField.address: profile.addresses = replace(profile.addresses)
            case ContactField.url: profile.websites = replace(profile.websites)
            case ContactField.organization: profile.organizationName = newValue
            case ContactField.role: profile.roleTitle = newValue
            case ContactField.nickname: profile.nickname = newValue
            case ContactField.pronunciation: profile.pronunciation = newValue
            default: break
            }
        }
    }

    private func importedValue(id: UUID) throws(AppError) -> ImportedContactValue? {
        let descriptor = FetchDescriptor<ImportedContactValue>(predicate: #Predicate { $0.id == id })
        return try fetch(descriptor).first
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
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
