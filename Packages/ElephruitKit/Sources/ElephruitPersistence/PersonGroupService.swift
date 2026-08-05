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

    /// A ``ElephruitDesign/Theme/Palette`` raw value, and the group's whole identity in a list.
    ///
    /// Optional because the column is, and because a group written by an older build has none. A
    /// group without one is drawn in the neutral its surroundings use rather than in the accent —
    /// see ``PersonGroupService/assignableColorName(existing:)`` for why every group made here gets
    /// one anyway.
    public var colorName: String?

    public var definition: Definition
    public var memberIDs: [UUID]

    public init(
        id: UUID,
        name: String,
        symbolName: String,
        colorName: String? = nil,
        definition: Definition,
        memberIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
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
    public var colorName: String?

    public init(id: UUID, name: String, symbolName: String, colorName: String? = nil) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
    }
}

/// Which groups each person belongs to, worked out once for a whole list.
///
/// ### Why this is not a property of a person
/// Membership lives on the group — a fixed group owns its `CollectionMembership` rows, and a smart
/// group owns nothing at all, because its membership is the result of running a search. Asking a
/// person "which groups are you in" therefore means asking every group in turn, and asking it once
/// per row means asking it once per row *per frame*: the People list draws two hundred of them.
///
/// So the question is answered in one pass, for everybody, and the rows read a dictionary. The same
/// reasoning — and the same measurement — that took the store out of the list's scroll path in the
/// first place; see ``ElephruitCore/PersonListEntry``.
public struct PersonGroupMembership: Sendable {
    /// Person ID to the groups they are in, in the order the groups are listed.
    public var groupsByPerson: [UUID: [PersonGroupSummary]]

    public init(groupsByPerson: [UUID: [PersonGroupSummary]] = [:]) {
        self.groupsByPerson = groupsByPerson
    }

    public func groups(for personID: UUID) -> [PersonGroupSummary] {
        groupsByPerson[personID] ?? []
    }

    public var isEmpty: Bool { groupsByPerson.isEmpty }
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
                symbolName: collection.effectiveSymbolName,
                colorName: collection.colorName
            )
        }
        let smart = try fetch(smartDescriptor).compactMap { saved -> PersonGroupSummary? in
            guard saved.name.hasPrefix(Self.groupPrefix) else { return nil }
            return PersonGroupSummary(
                id: saved.id,
                name: String(saved.name.dropFirst(Self.groupPrefix.count)),
                symbolName: saved.effectiveSymbolName,
                colorName: saved.colorName
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
                colorName: collection.colorName,
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
                    colorName: saved.colorName,
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
    public func createFixedGroup(
        named name: String,
        symbolName: String = "person.2",
        colorName: String? = nil
    ) throws(AppError) -> PersonGroup {
        // Spelled out rather than `colorName ?? (try …)`: a throwing right-hand side erases the
        // typed throw back to `any Error`, the same way a throwing closure does — see `members(of:)`.
        let color: String
        if let colorName {
            color = colorName
        } else {
            color = try assignableColorName()
        }

        let collection = ItemCollection(name: Self.groupPrefix + name)
        collection.symbolName = symbolName
        collection.colorName = color
        collection.createdAt = dateProvider.now
        context.insert(collection)
        try save()

        return PersonGroup(
            id: collection.id, name: name, symbolName: symbolName, colorName: color,
            definition: .fixed, memberIDs: []
        )
    }

    @discardableResult
    public func createSmartGroup(
        named name: String,
        query: String,
        symbolName: String = "person.2.badge.gearshape",
        colorName: String? = nil
    ) throws(AppError) -> PersonGroup {
        // Spelled out rather than `colorName ?? (try …)`: a throwing right-hand side erases the
        // typed throw back to `any Error`, the same way a throwing closure does — see `members(of:)`.
        let color: String
        if let colorName {
            color = colorName
        } else {
            color = try assignableColorName()
        }

        let saved = SavedSearch(name: Self.groupPrefix + name, queryString: query)
        saved.symbolName = symbolName
        saved.colorName = color
        saved.createdAt = dateProvider.now
        // People groups have their own section; showing them in the general sidebar too would list
        // them twice.
        saved.showsInSidebar = false
        context.insert(saved)
        try save()

        return PersonGroup(
            id: saved.id, name: name, symbolName: symbolName, colorName: color,
            definition: .smart(query: query),
            memberIDs: try search.search(query, limit: 500).map(\.id)
        )
    }

    /// Renames a group, keeping the prefix that marks it as one.
    public func rename(groupID: UUID, to name: String) throws(AppError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for collection in try fetch(FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == groupID })) {
            collection.name = Self.groupPrefix + trimmed
            collection.updatedAt = dateProvider.now
        }
        for saved in try fetch(FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == groupID })) {
            saved.name = Self.groupPrefix + trimmed
        }
        try save()
    }

    /// Changes a group's colour. `nil` clears it back to the neutral.
    public func setColor(_ colorName: String?, forGroup groupID: UUID) throws(AppError) {
        for collection in try fetch(FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == groupID })) {
            collection.colorName = colorName
            collection.updatedAt = dateProvider.now
        }
        for saved in try fetch(FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == groupID })) {
            saved.colorName = colorName
        }
        try save()
    }

    public func setSymbol(_ symbolName: String, forGroup groupID: UUID) throws(AppError) {
        for collection in try fetch(FetchDescriptor<ItemCollection>(predicate: #Predicate { $0.id == groupID })) {
            collection.symbolName = symbolName
            collection.updatedAt = dateProvider.now
        }
        for saved in try fetch(FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == groupID })) {
            saved.symbolName = symbolName
        }
        try save()
    }

    // MARK: - Colour

    /// Every colour a group may be given, in the order they are offered.
    ///
    /// The design system's palette, spelled here as raw values so this module keeps its independence
    /// from `ElephruitDesign` — persistence stores a name, and what that name looks like is not its
    /// business. `Theme.Palette` is the enum these correspond to, and its own test asserts the two
    /// lists have not drifted.
    ///
    /// Graphite is deliberately absent: a group's colour has to survive being drawn as a four-point
    /// dot beside a name, and the one grey in the palette is the colour of *no group at all*
    /// everywhere else in the interface.
    public static let groupColorNames = [
        "blue", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "cyan",
        "indigo", "brown",
    ]

    /// The colour a new group should get: the first unused one, else the least used.
    ///
    /// ### Why unique matters and why it cannot be guaranteed
    /// The colour *is* the group in a list of dots — two groups sharing one makes the dots a lie.
    /// So the first twelve groups are all distinct, which is more groups than the circles metaphor
    /// this is modelled on ever asks for.
    ///
    /// Past twelve there is no honest answer, only choices about which lie is smallest. Reusing the
    /// least-used colour keeps collisions as rare and as evenly spread as they can be, and picking
    /// deterministically — palette order breaks the tie — means the same library always produces the
    /// same assignment, so a screenshot is reproducible and a test can assert on it.
    public func assignableColorName() throws(AppError) -> String {
        Self.assignableColorName(existing: try allGroupSummaries().compactMap(\.colorName))
    }

    /// The pure half, so the rule is testable without a store.
    public static func assignableColorName(existing: [String]) -> String {
        var counts: [String: Int] = [:]
        for name in existing where groupColorNames.contains(name) {
            counts[name, default: 0] += 1
        }

        // `min(by:)` over the palette in order: the first colour with the lowest count wins, and an
        // unused colour has a count of zero, so "first unused" falls out of the same expression
        // rather than needing a special case that could disagree with it.
        return groupColorNames.min { left, right in
            let leftCount = counts[left] ?? 0
            let rightCount = counts[right] ?? 0
            if leftCount != rightCount { return leftCount < rightCount }
            return (groupColorNames.firstIndex(of: left) ?? 0) < (groupColorNames.firstIndex(of: right) ?? 0)
        } ?? "blue"
    }

    // MARK: - Membership, inverted

    /// Which groups each person is in, for a whole list at once.
    ///
    /// One pass over the groups rather than one query per row — see ``PersonGroupMembership`` for
    /// what that costs and why the rows cannot ask this question themselves.
    ///
    /// - Parameter includingSmart: smart groups run a search each. Worth it for the People list,
    ///   where the dots are the point; not worth it for a picker that is about to write explicit
    ///   membership, since a smart group has none to write.
    public func membership(includingSmart: Bool = true) throws(AppError) -> PersonGroupMembership {
        let groups = includingSmart ? try allGroups() : try fixedGroups()

        var byPerson: [UUID: [PersonGroupSummary]] = [:]
        for group in groups {
            let summary = PersonGroupSummary(
                id: group.id, name: group.name, symbolName: group.symbolName, colorName: group.colorName
            )
            for personID in group.memberIDs {
                byPerson[personID, default: []].append(summary)
            }
        }
        return PersonGroupMembership(groupsByPerson: byPerson)
    }

    /// The fixed groups this person is explicitly in, for the membership editor.
    ///
    /// Fixed only: a smart group's membership is a consequence of a query, so "add somebody to it"
    /// is not an operation — the honest way in is to change the person until the query matches, and
    /// a checkbox that silently did nothing would be worse than no checkbox.
    public func fixedGroupIDs(containing personID: UUID) throws(AppError) -> Set<UUID> {
        Set(try fixedGroups().filter { $0.memberIDs.contains(personID) }.map(\.id))
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
