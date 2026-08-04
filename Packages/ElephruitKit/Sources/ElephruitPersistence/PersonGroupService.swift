import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// A group of people, however it is defined.
public struct PersonGroup: Sendable, Hashable, Identifiable {
    public enum Definition: Sendable, Hashable {
        /// Explicit membership, in an order the user chose.
        case fixed
        /// Everybody a query matches, recomputed every time it is asked.
        case smart(query: String)
    }

    public var id: UUID
    public var name: String
    public var symbolName: String
    public var definition: Definition
    public var memberIDs: [UUID]

    public init(id: UUID, name: String, symbolName: String, definition: Definition, memberIDs: [UUID]) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.definition = definition
        self.memberIDs = memberIDs
    }

    public var memberCount: Int { memberIDs.count }

    public var isSmart: Bool {
        if case .smart = definition { return true }
        return false
    }
}

/// The metadata needed to draw a group in navigation.
///
/// Deliberately excludes membership. Loading a sidebar label must not resolve every fixed-group
/// relationship or execute every smart-group search before the user has opened either one.
public struct PersonGroupSummary: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbolName: String

    public init(id: UUID, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }
}

/// What a batch action will do, shown before it does it.
///
/// ### Why a preview is mandatory rather than a courtesy
/// A group action addresses people who are not in the room. Sending to the wrong nine of them is not
/// recoverable by pressing undo, and the most common way it happens is a smart group whose
/// membership changed since the user last looked. So the recipients are named, counted, and — for
/// email — the disclosure behaviour is stated in the same box as the send button.
public struct GroupActionPreview: Sendable {
    public var action: GroupAction
    public var groupName: String

    /// Everybody who will receive it.
    public var recipients: [GroupRecipient]

    /// People in the group who cannot receive it, and why.
    public var excluded: [GroupExclusion]

    /// Whether addresses are hidden from each other.
    public var usesBlindCopy: Bool

    public var url: URL?

    public init(
        action: GroupAction,
        groupName: String,
        recipients: [GroupRecipient],
        excluded: [GroupExclusion],
        usesBlindCopy: Bool,
        url: URL?
    ) {
        self.action = action
        self.groupName = groupName
        self.recipients = recipients
        self.excluded = excluded
        self.usesBlindCopy = usesBlindCopy
        self.url = url
    }

    public var isRunnable: Bool { url != nil && !recipients.isEmpty }

    /// The sentence above the send button.
    public var summary: String {
        guard !recipients.isEmpty else { return "Nobody in \(groupName) can be reached this way." }

        var text = "\(action.displayName) — \(recipients.count) recipient\(recipients.count == 1 ? "" : "s")"
        if !excluded.isEmpty { text += ", \(excluded.count) skipped" }
        return text
    }

    /// The privacy note, when there is one worth making.
    public var privacyNote: String? {
        guard case .email = action, recipients.count > 1 else { return nil }
        return usesBlindCopy
            ? "Addresses are hidden from each other. Everyone will see the message came from you and nobody else's address."
            : "Everyone will see every other recipient's address."
    }
}

public struct GroupRecipient: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var destination: String

    public init(id: UUID, name: String, destination: String) {
        self.id = id
        self.name = name
        self.destination = destination
    }
}

public struct GroupExclusion: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var reason: String

    public init(id: UUID, name: String, reason: String) {
        self.id = id
        self.name = name
        self.reason = reason
    }
}

/// Groups of people, and what can be done to all of them at once.
///
/// ### Why no new entity
/// A fixed group is an ``ItemCollection``: explicit membership, an order the user controls, already
/// built and already tested. A smart group is a ``SavedSearch``: a query string that survives
/// version changes and exports as readable text. `docs/18` standing rule R5 asks for proof that the
/// existing shape cannot do the job before a stored one is added, and here there is none to offer.
@MainActor
public final class PersonGroupService {
    private let context: ModelContext
    private let items: any ItemRepository
    private let people: any PersonRepository
    private let search: PersonSearchService
    private let dateProvider: any DateProvider

    /// The prefix that marks a collection or saved search as belonging to People.
    ///
    /// A naming convention rather than a column, so a group is an ordinary collection everywhere else
    /// in the app — exportable, trashable, restorable — with no People-specific handling anywhere but
    /// here.
    public static let groupPrefix = "people:"

    public init(
        context: ModelContext,
        items: any ItemRepository,
        people: any PersonRepository,
        search: PersonSearchService,
        dateProvider: any DateProvider
    ) {
        self.context = context
        self.items = items
        self.people = people
        self.search = search
        self.dateProvider = dateProvider
    }

    // MARK: - Reading

    public func allGroups() throws(AppError) -> [PersonGroup] {
        try fixedGroups() + smartGroups()
    }

    /// Every group label, without resolving membership or running smart searches.
    public func allGroupSummaries() throws(AppError) -> [PersonGroupSummary] {
        let fixedDescriptor = FetchDescriptor<ItemCollection>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        let smartDescriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )

        let fixed = try fetch(fixedDescriptor).compactMap { collection -> PersonGroupSummary? in
            guard collection.name.hasPrefix(Self.groupPrefix) else { return nil }
            return PersonGroupSummary(
                id: collection.id,
                name: String(collection.name.dropFirst(Self.groupPrefix.count)),
                symbolName: collection.effectiveSymbolName
            )
        }
        let smart = try fetch(smartDescriptor).compactMap { saved -> PersonGroupSummary? in
            guard saved.name.hasPrefix(Self.groupPrefix) else { return nil }
            return PersonGroupSummary(
                id: saved.id,
                name: String(saved.name.dropFirst(Self.groupPrefix.count)),
                symbolName: saved.effectiveSymbolName
            )
        }

        return fixed + smart
    }

    public func fixedGroups() throws(AppError) -> [PersonGroup] {
        let descriptor = FetchDescriptor<ItemCollection>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )

        return try fetch(descriptor).compactMap { collection in
            guard collection.name.hasPrefix(Self.groupPrefix) else { return nil }
            return PersonGroup(
                id: collection.id,
                name: String(collection.name.dropFirst(Self.groupPrefix.count)),
                symbolName: collection.effectiveSymbolName,
                definition: .fixed,
                memberIDs: (collection.memberships ?? [])
                    .sorted { $0.position < $1.position }
                    .compactMap { membership in
                        guard let item = membership.item, item.kind == .person, item.deletedAt == nil else {
                            return nil
                        }
                        return item.id
                    }
            )
        }
    }

    public func smartGroups() throws(AppError) -> [PersonGroup] {
        let descriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )

        var groups: [PersonGroup] = []
        for saved in try fetch(descriptor) where saved.name.hasPrefix(Self.groupPrefix) {
            let matches = try search.search(saved.queryString, limit: 500)
            groups.append(
                PersonGroup(
                    id: saved.id,
                    name: String(saved.name.dropFirst(Self.groupPrefix.count)),
                    symbolName: saved.effectiveSymbolName,
                    definition: .smart(query: saved.queryString),
                    memberIDs: matches.map(\.id)
                )
            )
        }
        return groups
    }

    public func group(id: UUID) throws(AppError) -> PersonGroup? {
        try allGroups().first { $0.id == id }
    }

    public func members(of group: PersonGroup) throws(AppError) -> [Item] {
        // A loop rather than `compactMap`, because a throwing closure erases the typed throw back to
        // `any Error` and the signature stops meaning anything.
        var result: [Item] = []
        for id in group.memberIDs {
            if let person = try people.person(id: id) { result.append(person) }
        }
        return result
    }

    // MARK: - Writing

    @discardableResult
    public func createFixedGroup(named name: String, symbolName: String = "person.2") throws(AppError) -> PersonGroup {
        let collection = ItemCollection(name: Self.groupPrefix + name)
        collection.symbolName = symbolName
        collection.createdAt = dateProvider.now
        context.insert(collection)
        try save()

        return PersonGroup(
            id: collection.id, name: name, symbolName: symbolName, definition: .fixed, memberIDs: []
        )
    }

    @discardableResult
    public func createSmartGroup(
        named name: String,
        query: String,
        symbolName: String = "person.2.badge.gearshape"
    ) throws(AppError) -> PersonGroup {
        let saved = SavedSearch(name: Self.groupPrefix + name, queryString: query)
        saved.symbolName = symbolName
        saved.createdAt = dateProvider.now
        // People groups have their own section; showing them in the general sidebar too would list
        // them twice.
        saved.showsInSidebar = false
        context.insert(saved)
        try save()

        return PersonGroup(
            id: saved.id, name: name, symbolName: symbolName,
            definition: .smart(query: query),
            memberIDs: try search.search(query, limit: 500).map(\.id)
        )
    }

    public func add(_ person: Item, to groupID: UUID) throws(AppError) {
        let descriptor = FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == groupID })
        guard let collection = try fetch(descriptor).first else { throw .itemNotFound(id: groupID) }

        guard !(collection.memberships ?? []).contains(where: { $0.item?.id == person.id }) else { return }

        let position = ((collection.memberships ?? []).map(\.position).max() ?? 0) + 1024
        let membership = CollectionMembership()
        membership.position = position
        membership.addedAt = dateProvider.now
        membership.collection = collection
        membership.item = person
        context.insert(membership)
        try save()
    }

    public func remove(_ person: Item, from groupID: UUID) throws(AppError) {
        let descriptor = FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == groupID })
        guard let collection = try fetch(descriptor).first else { return }

        for membership in (collection.memberships ?? []) where membership.item?.id == person.id {
            context.delete(membership)
        }
        try save()
    }

    public func deleteGroup(id: UUID) throws(AppError) {
        let now = dateProvider.now

        for collection in try fetch(FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == id })) {
            collection.deletedAt = now
        }
        for saved in try fetch(FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == id })) {
            saved.deletedAt = now
        }
        try save()
    }

    // MARK: - Batch actions

    /// What a batch action would do. Writes nothing and sends nothing.
    public func preview(_ action: GroupAction, for group: PersonGroup) throws(AppError) -> GroupActionPreview {
        let members = try members(of: group)

        var recipients: [GroupRecipient] = []
        var excluded: [GroupExclusion] = []

        switch action {
        case .email, .invite:
            for person in members {
                if let email = person.personProfile?.emails.first?.value, !email.isEmpty {
                    recipients.append(GroupRecipient(id: person.id, name: person.displayTitle, destination: email))
                } else {
                    excluded.append(
                        GroupExclusion(id: person.id, name: person.displayTitle, reason: "no email address")
                    )
                }
            }

        case .message:
            for person in members {
                if let phone = person.personProfile?.phones.first?.value, !phone.isEmpty {
                    recipients.append(GroupRecipient(id: person.id, name: person.displayTitle, destination: phone))
                } else {
                    excluded.append(
                        GroupExclusion(id: person.id, name: person.displayTitle, reason: "no phone number")
                    )
                }
            }

        case .tag, .export:
            recipients = members.map {
                GroupRecipient(id: $0.id, name: $0.displayTitle, destination: $0.displayTitle)
            }
        }

        // Blind copy for any group of more than one. The default is the safe one, and the preview
        // says what it means in the same box as the button.
        let useBlindCopy = recipients.count > 1

        let url: URL? = switch action {
        case .email:
            ContactActionURL.mailtoURL(recipients: recipients.map(\.destination), useBlindCopy: useBlindCopy)
        case .invite(_, _, let title):
            ContactActionURL.mailtoURL(
                recipients: recipients.map(\.destination),
                useBlindCopy: useBlindCopy,
                subject: title
            )
        case .message:
            ContactActionURL.groupMessageURL(recipients: recipients.map(\.destination))
        case .tag, .export:
            // Local actions have no URL and are run directly.
            URL(string: "elephruit://local")
        }

        return GroupActionPreview(
            action: action,
            groupName: group.name,
            recipients: recipients,
            excluded: excluded,
            usesBlindCopy: useBlindCopy && action.isExternallyVisible,
            url: url
        )
    }

    /// Applies a tag to everybody in a group. The one batch action that writes.
    public func applyTag(_ slug: String, to group: PersonGroup) throws(AppError) {
        for person in try members(of: group) {
            let existing = person.tagSlugs
            guard !existing.contains(slug) else { continue }
            try items.setTags(person, slugs: existing + [slug])
        }
    }

    /// A group as vCards, for export.
    ///
    /// Uses the same emitter and the same field selection as My Card, so app-only data cannot reach
    /// an export by a second route that nobody wrote a test for.
    public func exportVCards(for group: PersonGroup, profile: ShareProfile) throws(AppError) -> String {
        try members(of: group)
            .map { person in
                var card = ShareableCard()
                card[.fullName] = person.displayTitle
                card[.jobTitle] = person.personProfile?.roleTitle
                card[.organization] = person.personProfile?.organizationName
                card[.workEmail] = person.personProfile?.emails.first?.value
                card[.mobilePhone] = person.personProfile?.phones.first?.value
                card[.pronouns] = person.personProfile?.pronouns
                return VCardEmitter.emit(card: card, profile: profile)
            }
            .joined()
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
