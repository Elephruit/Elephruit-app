import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Finding people by more than their name.
///
/// Runs a ``PersonQuery`` against the graph. Deliberately separate from `FTSSearchEngine`: that
/// searches *content*, and "people I met through Nisha" is a traversal rather than a text match.
/// Teaching the FTS compiler about relationships would give it a job it has no business doing, and
/// the two grammars stay independent as a result.
@MainActor
public final class PersonSearchService {
    private let people: any PersonRepository
    private let items: any ItemRepository
    private let dateProvider: any DateProvider

    public init(people: any PersonRepository, items: any ItemRepository, dateProvider: any DateProvider) {
        self.people = people
        self.items = items
        self.dateProvider = dateProvider
    }

    /// Runs a written search.
    public func search(_ text: String, limit: Int = 50) throws(AppError) -> [RankedPerson] {
        try run(PersonQueryParser.parse(text), limit: limit)
    }

    /// Runs a parsed search.
    public func run(_ query: PersonQuery, limit: Int = 50) throws(AppError) -> [RankedPerson] {
        guard !query.isEmpty else { return [] }

        let calendar = dateProvider.calendar
        let now = dateProvider.now
        let contextService = PeopleService(items: items, dateProvider: dateProvider)

        var results: [RankedPerson] = []

        for person in try people.allPeople(includingPlaceholders: true) {
            var reasons: [PersonMatchReason] = []

            reasons.append(contentsOf: nameReasons(for: person, query: query))
            reasons.append(contentsOf: try factReasons(for: person, query: query))
            if let reason = try relationReason(for: person, query: query) { reasons.append(reason) }
            if let reason = try introductionReason(for: person, query: query) { reasons.append(reason) }
            if let reason = try celebrationReason(for: person, query: query, asOf: now, calendar: calendar) {
                reasons.append(reason)
            }
            if let reason = try promiseReason(for: person, query: query) { reasons.append(reason) }

            let context = contextService.context(for: person)
            let daysSinceContact = context.daysSinceLastContact(using: dateProvider)

            if let threshold = query.notContactedForDays {
                // Somebody never spoken to is not "out of touch" — there was never touch. Including
                // them would fill the answer with everyone whose name has ever been typed.
                guard let days = daysSinceContact, days >= threshold else { continue }
                reasons.append(
                    PersonMatchReason(text: "not spoken in \(days / 30) months", strength: .structural)
                )
            }

            // A structural query is a filter: matching nothing means excluded, not merely unranked.
            if query.isStructural, reasons.allSatisfy({ $0.strength != .structural && $0.strength != .factValue }) {
                continue
            }
            guard !reasons.isEmpty else { continue }

            results.append(
                RankedPerson(
                    id: person.id,
                    name: person.displayTitle,
                    reasons: reasons,
                    daysSinceContact: daysSinceContact,
                    mentionCount: context.mentionCount
                )
            )
        }

        return Array(PersonRanker.rank(results).prefix(limit))
    }

    // MARK: - Reasons

    private func nameReasons(for person: Item, query: PersonQuery) -> [PersonMatchReason] {
        guard !query.freeText.isEmpty else { return [] }

        let needle = TextNormalizer.foldedForMatching(query.freeText)
        guard !needle.isEmpty else { return [] }

        let name = TextNormalizer.foldedForMatching(person.displayTitle)
        if name == needle { return [PersonMatchReason(text: person.displayTitle, strength: .exactName)] }
        if name.hasPrefix(needle) || name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
            return [PersonMatchReason(text: person.displayTitle, strength: .namePrefix)]
        }

        // The projection already holds names, role, organisation, location, and emails.
        if person.searchText.contains(needle) {
            return [PersonMatchReason(text: "mentioned in their details", strength: .linkedText)]
        }
        return []
    }

    private func factReasons(for person: Item, query: PersonQuery) throws(AppError) -> [PersonMatchReason] {
        let ledger = try people.ledger(for: person)
        var reasons: [PersonMatchReason] = []

        for filter in query.attributeFilters {
            let needle = TextNormalizer.foldedForMatching(filter.value)
            for observation in ledger.current(filter.attribute)
            where TextNormalizer.foldedForMatching(observation.value).contains(needle) {
                reasons.append(
                    PersonMatchReason(
                        text: "\(filter.attribute.displayName.lowercased()) \(observation.value)",
                        strength: .structural
                    )
                )
            }
        }

        // Free text also searches what is recorded about somebody — "likes natural wine" finds Maya
        // even when it is typed without the verb. Restricted facts are excluded: a private
        // reflection must not be reachable from a general search field.
        if !query.freeText.isEmpty {
            let needle = TextNormalizer.foldedForMatching(query.freeText)
            for observation in ledger.observations
            where observation.isCurrent
                && observation.sensitivity != .restricted
                && observation.attribute != .reflection
                && TextNormalizer.foldedForMatching(observation.value).contains(needle) {
                reasons.append(
                    PersonMatchReason(
                        text: "\(observation.attribute.displayName.lowercased()): \(observation.value)",
                        strength: .factValue
                    )
                )
            }
        }

        return reasons
    }

    /// `Maya's son` — somebody standing in a named relationship to a named person.
    private func relationReason(for person: Item, query: PersonQuery) throws(AppError) -> PersonMatchReason? {
        guard let filter = query.relatedTo else { return nil }

        let anchorKey = TextNormalizer.foldedForMatching(filter.personName)
        for relationship in try people.relationships(of: person) {
            guard relationship.kind == filter.kind.inverse || relationship.kind == filter.kind else { continue }
            guard let other = relationship.other else { continue }

            let otherKey = TextNormalizer.foldedForMatching(other.displayTitle)
            guard otherKey == anchorKey || otherKey.split(separator: " ").contains(where: { $0 == anchorKey[...] })
            else { continue }

            // `Maya's son` asks for Maya's children, so this person must be the *child* — which
            // reads from their own side as `parent`.
            guard relationship.kind == filter.kind.inverse else { continue }

            return PersonMatchReason(
                text: "\(other.displayTitle)'s \(filter.label ?? filter.kind.displayName)",
                strength: .structural
            )
        }
        return nil
    }

    private func introductionReason(for person: Item, query: PersonQuery) throws(AppError) -> PersonMatchReason? {
        guard let name = query.introducedBy else { return nil }
        let key = TextNormalizer.foldedForMatching(name)

        for relationship in try people.relationships(of: person) where relationship.kind == .introducedBy {
            guard let other = relationship.other else { continue }
            let otherKey = TextNormalizer.foldedForMatching(other.displayTitle)
            guard otherKey == key || otherKey.split(separator: " ").contains(where: { $0 == key[...] }) else { continue }
            return PersonMatchReason(text: "met through \(other.displayTitle)", strength: .structural)
        }
        return nil
    }

    private func celebrationReason(
        for person: Item,
        query: PersonQuery,
        asOf now: Date,
        calendar: Calendar
    ) throws(AppError) -> PersonMatchReason? {
        guard let months = query.celebrationWindowMonths else { return nil }

        var celebrations = try people.celebrations(of: person).compactMap { $0.asValue() }
        if let birthday = person.personProfile?.birthdayDate(calendar: calendar) {
            celebrations.append(
                Celebration(personID: person.id, personName: person.displayTitle, kind: .birthday, date: birthday)
            )
        }

        let upcoming = CelebrationCalendar.upcoming(
            from: celebrations, within: months * 31, asOf: now, calendar: calendar
        )
        guard let next = upcoming.first else { return nil }
        return PersonMatchReason(text: next.summary, strength: .structural)
    }

    private func promiseReason(for person: Item, query: PersonQuery) throws(AppError) -> PersonMatchReason? {
        guard query.hasOpenPromises else { return nil }

        let open = person.incomingLinks.compactMap(\.source).filter { source in
            source.deletedAt == nil && source.status == .open && PersonWorkspaceService.isPromise(source)
        }
        guard !open.isEmpty else { return nil }

        return PersonMatchReason(
            text: open.count == 1 ? "1 open reminder" : "\(open.count) open reminders",
            strength: .structural
        )
    }
}
