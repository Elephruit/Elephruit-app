import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

public struct RecordDraft: Sendable, Hashable {
    public var name: String
    public var type: RecordType
    public var summary: String
    public var notes: String
    public var details: [String: String]
    public var addToContacts: Bool

    public init(
        name: String,
        type: RecordType,
        summary: String = "",
        notes: String = "",
        details: [String: String] = [:],
        addToContacts: Bool = false
    ) {
        self.name = name
        self.type = type
        self.summary = summary
        self.notes = notes
        self.details = details
        self.addToContacts = addToContacts
    }
}

/// The single write boundary for the Records module.
///
/// It deliberately composes the existing item and person repositories. Records is a new way to
/// organise the same graph, not a parallel database of people, notes, tags, and links.
@MainActor
public final class RecordsService {
    private let context: ModelContext
    private let items: any ItemRepository
    private let people: any PersonRepository
    private let dateProvider: any DateProvider

    public init(
        context: ModelContext,
        items: any ItemRepository,
        people: any PersonRepository,
        dateProvider: any DateProvider
    ) {
        self.context = context
        self.items = items
        self.people = people
        self.dateProvider = dateProvider
    }

    /// Active Records, including legacy People rows that have not yet needed a Records profile.
    public func allRecords() throws(AppError) -> [Item] {
        var query = ItemQuery()
        query.scope = .active
        query.sort = .titleAscending
        let candidates = try items.items(matching: query)
        return candidates.filter { $0.recordProfile != nil || $0.kind == .person }
    }

    @discardableResult
    public func create(_ draft: RecordDraft) throws(AppError) -> Item {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidQuery(reason: "A record needs a name.") }
        let cleanedDetails = draft.details.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }

        let item: Item
        switch draft.type {
        case .person:
            item = try people.createPerson(
                PersonDraft(
                    fullName: trimmed,
                    givenName: cleanedDetails["given_name"],
                    familyName: cleanedDetails["family_name"],
                    middleName: cleanedDetails["middle_name"],
                    namePrefix: cleanedDetails["name_prefix"],
                    nameSuffix: cleanedDetails["name_suffix"],
                    departmentName: cleanedDetails["department"],
                    nickname: cleanedDetails["nickname"],
                    roleTitle: cleanedDetails["role"],
                    organizationName: cleanedDetails["organization"],
                    emails: cleanedDetails["email"].map { [LabelledValue(label: "email", value: $0)] } ?? [],
                    phones: cleanedDetails["phone"].map { [LabelledValue(label: "phone", value: $0)] } ?? [],
                    websites: cleanedDetails["website"].map { [LabelledValue(label: "website", value: $0)] } ?? []
                )
            )
            item.body = draft.notes
        case .organization:
            item = try items.create(ItemDraft(kind: .organization, title: trimmed, body: draft.notes))
        case .pet, .vehicle, .other:
            // The real-world type belongs to RecordProfile. `reference` gives the universal item the
            // appropriate content capabilities without widening ItemKind for every future subject.
            item = try items.create(ItemDraft(kind: .reference, title: trimmed, body: draft.notes))
        }

        let profile = RecordProfile(
            type: draft.type,
            origin: .manual,
            details: cleanedDetails.merging(
                draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? [:]
                    : ["summary": draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)],
                uniquingKeysWith: { current, _ in current }
            ),
            createdAt: dateProvider.now,
            updatedAt: dateProvider.now
        )
        profile.item = item
        item.recordProfile = profile
        context.insert(profile)
        try save()
        return item
    }

    public func type(of item: Item) -> RecordType {
        if let profile = item.recordProfile { return profile.type }
        return item.kind == .person ? .person : item.kind == .organization ? .organization : .other
    }

    public func isUnsorted(_ item: Item) -> Bool {
        item.recordProfile?.isUnsorted
            ?? (item.kind == .person && item.personProfile?.contactsIdentifier != nil)
    }

    /// Marks a contact-backed person as a Records import. Called for both newly created and matched
    /// people, so an import always appears in All and Unsorted and nowhere becomes the default view.
    public func markImported(_ person: Item) throws(AppError) {
        let profile = profile(for: person, type: .person, origin: .contacts)
        profile.origin = .contacts
        profile.isUnsorted = true
        profile.updatedAt = dateProvider.now
        try save()
    }

    public func file(_ item: Item) throws(AppError) {
        let profile = profile(
            for: item,
            type: type(of: item),
            origin: item.kind == .person ? .existingPeople : .manual
        )
        profile.isUnsorted = false
        profile.updatedAt = dateProvider.now
        try save()
    }

    public func update(
        _ item: Item,
        summary: String,
        notes: String,
        details: [String: String]
    ) throws(AppError) {
        let profile = profile(for: item, type: type(of: item), origin: .manual)
        var stored = details
        if !summary.isEmpty { stored["summary"] = summary }
        profile.details = stored
        profile.updatedAt = dateProvider.now
        try items.update(item) { $0.body = notes }
        try save()
    }

    private func profile(for item: Item, type: RecordType, origin: RecordOrigin) -> RecordProfile {
        if let profile = item.recordProfile { return profile }
        let profile = RecordProfile(
            type: type,
            origin: origin,
            createdAt: item.createdAt,
            updatedAt: dateProvider.now
        )
        profile.item = item
        item.recordProfile = profile
        context.insert(profile)
        return profile
    }

    private func save() throws(AppError) {
        do { try context.save() }
        catch { throw .storeUnavailable(underlying: error.localizedDescription) }
    }
}
