import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Everything a person's page shows, assembled from what already exists.
///
/// ### Why one service rather than five
/// The timeline, the meeting brief, the relationship charts, and the context sidebar are four views
/// of one traversal: the links pointing at a person and the observations recorded about them. Split
/// across four services they would each walk the graph separately and could each reach a different
/// conclusion about, say, whether a task counts as an open promise. One service, one traversal, one
/// answer.
@MainActor
public final class PersonWorkspaceService {
    private let people: any PersonRepository
    private let items: any ItemRepository
    private let dateProvider: any DateProvider

    public init(people: any PersonRepository, items: any ItemRepository, dateProvider: any DateProvider) {
        self.people = people
        self.items = items
        self.dateProvider = dateProvider
    }

    // MARK: - Timeline

    /// Everything linked to a person, newest first.
    ///
    /// Both link directions are walked: a note *mentions* a person, and a meeting is linked *to* its
    /// attendees, so a one-directional traversal would silently lose half of somebody's history.
    public func timeline(for person: Item, limit: Int = 500) throws(AppError) -> [PersonTimelineEntry] {
        var entries: [PersonTimelineEntry] = []
        var seen = Set<UUID>()

        let observations = try people.observations(for: person)
        let factsBySource = Dictionary(grouping: observations.compactMap { record -> (UUID, PersonObservationRecord)? in
            guard let sourceID = record.sourceItem?.id else { return nil }
            return (sourceID, record)
        }) { $0.0 }

        func consider(_ related: Item) {
            guard related.deletedAt == nil, related.id != person.id, seen.insert(related.id).inserted else { return }
            guard related.kind.participatesInContentViews else { return }

            let facts = factsBySource[related.id]?.map(\.1) ?? []

            entries.append(
                PersonTimelineEntry(
                    id: related.id,
                    kind: related.kind,
                    title: related.displayTitle,
                    excerpt: related.body.isEmpty ? nil : TextNormalizer.excerpt(from: related.body, limit: 140),
                    date: PeopleService.contactDate(of: related),
                    source: related.source.kind,
                    provenance: Self.provenance(of: related),
                    channel: Self.channel(of: related),
                    interactionKind: PersonInteractionKind(tagSlugs: related.tagSlugs),
                    tagSlugs: related.tagSlugs.filter { !$0.hasPrefix("interaction/") },
                    otherPeople: Self.otherPeople(in: related, excluding: person.id),
                    confirmedFactCount: facts.count { $0.isCurrent },
                    suggestedFactCount: 0,
                    isOpen: related.status == .open,
                    isPromise: Self.isPromise(related),
                    attachmentCount: (related.attachments ?? []).count
                )
            )
        }

        for link in (person.incomingLinks ?? []) {
            guard let source = link.source else { continue }
            consider(source)
        }
        for link in (person.outgoingLinks ?? []) {
            guard let target = link.target else { continue }
            consider(target)
        }

        return Array(entries.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// How the app came to know about an interaction.
    ///
    /// Stored in the item's source identifier rather than as a column, because it applies to exactly
    /// one kind and adding a column to the shared `Item` row for it would widen every note in the
    /// library to carry a field only an interaction uses.
    static func provenance(of item: Item) -> InteractionProvenance? {
        guard item.kind == .interaction || item.kind == .meeting else { return nil }
        if let identifier = item.sourceIdentifier,
           let stored = InteractionProvenance(rawValue: identifier) {
            return stored
        }
        // A meeting from the calendar was detected; anything else with no marker was written down.
        return item.source.kind == .systemStore ? .detected : .logged
    }

    static func channel(of item: Item) -> ContactChannel? {
        guard let identifier = item.sourceURLString, let url = URL(string: identifier) else { return nil }
        return switch url.scheme {
        case "tel": .call
        case "sms": .message
        case "mailto": .email
        case "facetime": .facetimeVideo
        case "facetime-audio": .facetimeAudio
        default: nil
        }
    }

    /// Whether a task reads as something the user owes somebody rather than a job they gave
    /// themselves.
    ///
    /// Tagged, not inferred from wording. Guessing at "I said I'd…" would be a language model
    /// pretending to be a rule, and the cost of a wrong guess here is a list the user stops trusting.
    /// Which tags count is ``TagConventions/owed``, so this and the view that hides the marker from a
    /// chip row cannot disagree about it.
    static func isPromise(_ item: Item) -> Bool {
        item.kind.isWorkItem && item.tagSlugs.contains { TagConventions.marksOwed($0) }
    }

    static func otherPeople(in item: Item, excluding personID: UUID) -> [PersonReference] {
        var references: [PersonReference] = []
        var seen: Set<UUID> = [personID]

        for link in (item.outgoingLinks ?? []) {
            guard let target = link.target, target.kind == .person, target.deletedAt == nil else { continue }
            guard seen.insert(target.id).inserted else { continue }
            references.append(PersonReference(id: target.id, name: target.displayTitle))
        }
        for link in (item.incomingLinks ?? []) {
            guard let source = link.source, source.kind == .person, source.deletedAt == nil else { continue }
            guard seen.insert(source.id).inserted else { continue }
            references.append(PersonReference(id: source.id, name: source.displayTitle))
        }

        return references
    }

    // MARK: - Portrait

    /// The facts a person's cards show, with every estimate already resolved.
    public func portrait(of person: Item) throws(AppError) -> PersonPortrait {
        let ledger = try people.ledger(for: person)
        let now = dateProvider.now
        let calendar = dateProvider.calendar

        var cards: [PortraitCard] = []
        for attribute in ledger.populatedAttributes {
            let current = ledger.current(attribute)
            guard !current.isEmpty else { continue }

            cards.append(
                PortraitCard(
                    attribute: attribute,
                    values: current.map { observation in
                        PortraitValue(
                            observationID: observation.id,
                            text: observation.value,
                            confidence: observation.effectiveConfidence(asOf: now, calendar: calendar),
                            observedOn: observation.observedOn,
                            lastConfirmedOn: observation.lastConfirmedOn,
                            sensitivity: observation.sensitivity,
                            sourceItemID: observation.sourceItemID,
                            isStale: observation.isStale(asOf: now, calendar: calendar)
                        )
                    },
                    historyCount: ledger.history(attribute).count
                )
            )
        }

        return PersonPortrait(
            personID: person.id,
            name: person.displayTitle,
            cards: cards,
            age: try age(of: person),
            grade: grade(of: person, ledger: ledger),
            staleFacts: ledger.stale(asOf: now, calendar: calendar)
        )
    }

    /// What the app knows it does not know about somebody, in the order worth asking.
    ///
    /// ### Why missing names come before unconfirmed facts
    /// A name is a single field with a single right answer that the user either has or does not, and
    /// supplying it turns a phrase into a person everywhere at once. An unconfirmed fact is a
    /// judgement — *is this still true?* — and asking a judgement first is how a list of small
    /// questions becomes a chore nobody opens.
    ///
    /// Both are *offered*, never acted on. Nothing here is filled in by the app, and nothing here is
    /// hidden because it has gone unanswered for long enough.
    public func thingsToFillIn(for person: Item) throws(AppError) -> [FillInPrompt] {
        var prompts: [FillInPrompt] = []

        for relationship in try people.relationships(of: person) {
            guard let other = relationship.other,
                  other.personProfile?.hasStatedName == false
            else { continue }

            prompts.append(
                FillInPrompt(
                    id: other.id,
                    personID: other.id,
                    personName: other.displayTitle,
                    kind: .missingName(relationLabel: relationship.displayLabel),
                    prompt: "What is \(person.displayTitle)'s \(relationship.displayLabel) called?"
                )
            )
        }

        let now = dateProvider.now
        for observation in try people.ledger(for: person).stale(asOf: now, calendar: dateProvider.calendar) {
            prompts.append(
                FillInPrompt(
                    id: observation.id,
                    personID: person.id,
                    personName: person.displayTitle,
                    kind: .unconfirmedFact(
                        attribute: observation.attribute,
                        value: observation.value,
                        lastConfirmedOn: observation.lastConfirmedOn
                    ),
                    // The question is not in the sentence, because the button beside it already
                    // asks it. Two askings read as two questions.
                    prompt: "\(observation.attribute.displayName): \(observation.value)"
                )
            )
        }

        return prompts
    }

    /// How old somebody is: exactly if a birthday is recorded, estimated if an age ever was.
    ///
    /// A recorded birthday always wins. That is the whole point of scenario 12 — adding one turns
    /// every hedged sentence on the page into a plain one.
    public func age(of person: Item) throws(AppError) -> AgeEstimate {
        let calendar = dateProvider.calendar

        if let birthday = person.personProfile?.birthdayDate(calendar: calendar),
           birthday.hasYear,
           let exact = birthday.resolved(calendar: calendar) {
            return AgeEstimator.exactAge(bornOn: exact, asOf: dateProvider.now, calendar: calendar)
        }

        let ledger = try people.ledger(for: person)
        guard let observation = ledger.current(.observedAge).first,
              let years = Int(observation.value)
        else { return .unknown }

        return AgeEstimator.estimate(
            observedAge: years,
            observedOn: observation.observedOn,
            asOf: dateProvider.now,
            calendar: calendar
        )
    }

    func grade(of person: Item, ledger: FactLedger) -> GradeEstimate? {
        guard let observation = ledger.current(.schoolGrade).first,
              let grade = SchoolGrade.parse(observation.value),
              let startYear = observation.schoolYearStart
        else { return nil }

        return GradeEstimator.estimate(
            observedGrade: grade,
            schoolYear: SchoolYear(startYear: startYear),
            asOf: dateProvider.now,
            calendar: dateProvider.calendar
        )
    }

    // MARK: - Relationship charts

    /// Lays out one view of somebody's relationships.
    ///
    /// Breadth-first to a bounded depth, so a large family does not become an unreadable web and a
    /// cycle introduced by a bug cannot hang the interface.
    public func chart(_ kind: RelationshipChartKind, for person: Item, maxDepth: Int = 2) throws(AppError) -> RelationshipChart {
        var nodes: [UUID: RelationshipNode] = [
            person.id: RelationshipNode(
                id: person.id,
                name: person.displayTitle,
                depth: 0,
                rank: 0,
                isPlaceholder: person.personProfile?.isPlaceholder ?? false
            ),
        ]
        var edges: [RelationshipEdge] = []
        var seenEdges = Set<String>()

        var frontier: [(item: Item, depth: Int, rank: Int)] = [(person, 0, 0)]
        var visited: Set<UUID> = [person.id]

        while !frontier.isEmpty {
            var next: [(item: Item, depth: Int, rank: Int)] = []

            for entry in frontier where entry.depth < maxDepth {
                for relationship in try people.relationships(of: entry.item) {
                    guard kind.includedKinds.contains(relationship.kind) else { continue }
                    guard relationship.isCurrent, let other = relationship.other else { continue }

                    // One edge per unordered pair *per relationship*, and the reciprocal row is the
                    // same relationship seen from the other end. So both the pair and the kind are
                    // canonicalised — the pair by sorting the identifiers, the kind by taking
                    // whichever of it and its inverse sorts first. Without the second half, walking
                    // out to Jack and back draws Maya-is-parent and Jack-is-child as two lines
                    // between the same two nodes.
                    let pairKey = [entry.item.id, other.id].map(\.uuidString).sorted().joined()
                    let kindKey = min(relationship.kindRaw, relationship.kind.inverse.rawValue)
                    if seenEdges.insert(pairKey + kindKey).inserted {
                        edges.append(
                            RelationshipEdge(fromID: entry.item.id, toID: other.id, kind: relationship.kind)
                        )
                    }

                    guard visited.insert(other.id).inserted else { continue }

                    let rank = entry.rank + RelationshipChart.rank(for: relationship.kind)
                    nodes[other.id] = RelationshipNode(
                        id: other.id,
                        name: other.displayTitle,
                        depth: entry.depth + 1,
                        rank: rank,
                        relationToSubject: entry.depth == 0 ? relationship.kind : nil,
                        customLabel: entry.depth == 0 ? relationship.customLabel : nil,
                        isPlaceholder: other.personProfile?.isPlaceholder ?? false
                    )
                    next.append((other, entry.depth + 1, rank))
                }
            }

            frontier = next
        }

        return RelationshipChart(
            kind: kind,
            subjectID: person.id,
            nodes: Array(nodes.values),
            edges: edges
        )
    }

    // MARK: - Meeting brief

    /// Everything worth knowing before seeing somebody.
    ///
    /// Private reflections are excluded structurally rather than filtered: a brief is the thing most
    /// likely to be read aloud or over somebody's shoulder, and a flag that has to be checked is a
    /// flag that eventually is not.
    public func brief(for person: Item) throws(AppError) -> MeetingBrief {
        let now = dateProvider.now
        let calendar = dateProvider.calendar
        let ledger = try people.ledger(for: person)
        let entries = try timeline(for: person, limit: 100)
        let context = PeopleService(items: items, dateProvider: dateProvider).context(for: person)

        var lines: [BriefEntry] = []

        if let last = entries.first(where: \.isContact) {
            lines.append(
                BriefEntry(
                    section: .lastInteraction,
                    text: last.title,
                    sourceItemID: last.id,
                    detail: ContactMoment(id: last.id, kind: last.kind, title: last.title, date: last.date)
                        .relativeDescription(using: dateProvider)
                )
            )
        } else if let mention = entries.first {
            lines.append(
                BriefEntry(
                    section: .lastInteraction,
                    text: "Not spoken yet — last mentioned in “\(mention.title)”",
                    confidence: .inferred,
                    sourceItemID: mention.id
                )
            )
        }

        for attribute in [FactAttribute.lifeEvent, .location, .employer, .role, .lookingFor] {
            for observation in ledger.current(attribute) {
                lines.append(
                    BriefEntry(
                        section: attribute == .lifeEvent ? .lifeContext : .recentChanges,
                        text: "\(attribute.displayName): \(observation.value)",
                        confidence: observation.effectiveConfidence(asOf: now, calendar: calendar),
                        sourceItemID: observation.sourceItemID,
                        observedOn: observation.observedOn,
                        detail: observation.effectiveConfidence(asOf: now, calendar: calendar).needsLabel
                            ? EstimateProvenance.sentence(observedOn: observation.observedOn)
                            : nil
                    )
                )
            }
        }

        for entry in entries where entry.isOpen {
            lines.append(
                BriefEntry(
                    section: entry.isPromise ? .openPromises : .relatedWork,
                    text: entry.title,
                    sourceItemID: entry.id
                )
            )
        }

        let celebrations = try people.celebrations(of: person).compactMap { $0.asValue() }
        let profileBirthday = person.personProfile?.birthdayDate(calendar: calendar).map {
            Celebration(personID: person.id, personName: person.displayTitle, kind: .birthday, date: $0)
        }
        for upcoming in CelebrationCalendar.upcoming(
            from: celebrations + (profileBirthday.map { [$0] } ?? []),
            within: 60, asOf: now, calendar: calendar
        ) {
            lines.append(
                BriefEntry(
                    section: .upcomingDates,
                    text: upcoming.summary,
                    detail: upcoming.isShiftedFromLeapDay ? "Born on 29 February; shown on the 28th this year." : nil
                )
            )
        }

        // Family, with every estimate carrying its working.
        for relationship in try people.relationships(of: person)
        where RelationshipChartKind.family.includedKinds.contains(relationship.kind) {
            guard let other = relationship.other else { continue }

            var text = "\(other.displayTitle) · \(relationship.displayLabel)"
            var confidence = FactConfidence.stated
            var observedOn: Date?
            var detail: String?

            let age = try self.age(of: other)
            if age != .unknown {
                text += " · \(age.displayText)"
                if age.isEstimate {
                    confidence = .inferred
                    let otherLedger = try people.ledger(for: other)
                    observedOn = otherLedger.current(.observedAge).first?.observedOn
                    detail = observedOn.map { EstimateProvenance.sentence(observedOn: $0) }
                }
            }

            if let grade = grade(of: other, ledger: try people.ledger(for: other)) {
                text += " · \(grade.displayText)"
                if grade.isEstimate { confidence = .inferred }
            }

            lines.append(
                BriefEntry(
                    section: .family,
                    text: text,
                    confidence: confidence,
                    sourceItemID: other.id,
                    observedOn: observedOn,
                    detail: detail
                )
            )
        }

        // Things worth asking about: what they were looking for, and what is going on.
        for observation in ledger.current(.lookingFor) {
            lines.append(
                BriefEntry(
                    section: .conversationStarters,
                    text: "Were they able to find \(observation.value)?",
                    confidence: .inferred,
                    sourceItemID: observation.sourceItemID,
                    observedOn: observation.observedOn,
                    detail: EstimateProvenance.sentence(observedOn: observation.observedOn)
                )
            )
        }

        if let days = context.daysSinceLastContact(using: dateProvider), days > 90 {
            lines.append(
                BriefEntry(
                    section: .conversationStarters,
                    text: "It has been \(days / 30) months since you last spoke.",
                    confidence: .stated
                )
            )
        }

        return MeetingBrief(personID: person.id, personName: person.displayTitle, assembledAt: now, entries: lines)
    }

    // MARK: - Context sidebar

    /// What the trailing pane shows.
    public func sidebar(for person: Item) throws(AppError) -> PersonSidebarContext {
        let now = dateProvider.now
        let calendar = dateProvider.calendar
        let entries = try timeline(for: person)
        let ledger = try people.ledger(for: person)

        let related = try people.relationships(of: person).compactMap { relationship -> RelatedPerson? in
            guard let other = relationship.other, relationship.isCurrent else { return nil }
            return RelatedPerson(
                id: other.id,
                name: other.displayTitle,
                label: relationship.displayLabel,
                kind: relationship.kind
            )
        }

        let celebrations = try people.celebrations(of: person).compactMap { $0.asValue() }
        let profileBirthday = person.personProfile?.birthdayDate(calendar: calendar).map {
            Celebration(personID: person.id, personName: person.displayTitle, kind: .birthday, date: $0)
        }

        return PersonSidebarContext(
            personID: person.id,
            upcoming: entries.filter { $0.date > now }.sorted { $0.date < $1.date },
            openItems: entries.filter(\.isOpen),
            promises: entries.filter { $0.isOpen && $0.isPromise },
            relatedPeople: related,
            sharedProjects: try sharedProjects(with: person),
            places: ledger.current(.location).map(\.value),
            staleFacts: ledger.stale(asOf: now, calendar: calendar),
            celebrations: CelebrationCalendar.upcoming(
                from: celebrations + (profileBirthday.map { [$0] } ?? []),
                within: 90, asOf: now, calendar: calendar
            ),
            destinations: person.personProfile?.destinations() ?? []
        )
    }

    /// Projects that both the user and this person appear in.
    private func sharedProjects(with person: Item) throws(AppError) -> [PersonReference] {
        var seen = Set<UUID>()
        var result: [PersonReference] = []

        for link in (person.incomingLinks ?? []) {
            guard let source = link.source, source.deletedAt == nil else { continue }
            guard let project = source.enclosingProject() ?? source.filedUnderContainers().first else { continue }
            guard seen.insert(project.id).inserted else { continue }
            result.append(PersonReference(id: project.id, name: project.displayTitle))
        }

        return result
    }
}

// MARK: - Values

/// A person's structured facts, ready to render.
/// One thing the app knows it does not know, phrased as a question it can ask in a single field.
public struct FillInPrompt: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Somebody recorded before their name was known — "Dave's son".
        case missingName(relationLabel: String)

        /// A fact old enough that the app has stopped vouching for it.
        case unconfirmedFact(attribute: FactAttribute, value: String, lastConfirmedOn: Date)
    }

    /// The person or observation this is about, so a list of these is stable across reloads.
    public var id: UUID

    /// Whose record answering it would change.
    public var personID: UUID
    public var personName: String

    public var kind: Kind

    /// The question, as it is put to the user.
    public var prompt: String

    public init(id: UUID, personID: UUID, personName: String, kind: Kind, prompt: String) {
        self.id = id
        self.personID = personID
        self.personName = personName
        self.kind = kind
        self.prompt = prompt
    }

    public var symbolName: String {
        switch kind {
        case .missingName: "person.fill.questionmark"
        case .unconfirmedFact: "questionmark.circle"
        }
    }
}

public struct PersonPortrait: Sendable {
    public var personID: UUID
    public var name: String
    public var cards: [PortraitCard]
    public var age: AgeEstimate
    public var grade: GradeEstimate?
    public var staleFacts: [PersonObservation]

    public init(
        personID: UUID,
        name: String,
        cards: [PortraitCard],
        age: AgeEstimate,
        grade: GradeEstimate?,
        staleFacts: [PersonObservation]
    ) {
        self.personID = personID
        self.name = name
        self.cards = cards
        self.age = age
        self.grade = grade
        self.staleFacts = staleFacts
    }

    /// "approximately 7–8 years old · likely in 3rd grade" — the line under a child's name.
    public var ageAndGradeLine: String? {
        var parts: [String] = []
        if age != .unknown { parts.append(age.displayText) }
        if let grade { parts.append(grade.displayText) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether that line is an estimate and must be labelled.
    public var ageAndGradeIsEstimate: Bool {
        age.isEstimate || grade?.isEstimate == true
    }
}

public struct PortraitCard: Sendable, Identifiable {
    public var attribute: FactAttribute
    public var values: [PortraitValue]

    /// How many superseded values sit behind this card.
    public var historyCount: Int

    public var id: String { attribute.rawValue }

    public init(attribute: FactAttribute, values: [PortraitValue], historyCount: Int) {
        self.attribute = attribute
        self.values = values
        self.historyCount = historyCount
    }
}

public struct PortraitValue: Sendable, Identifiable {
    public var observationID: UUID
    public var text: String
    public var confidence: FactConfidence
    public var observedOn: Date
    public var lastConfirmedOn: Date
    public var sensitivity: FactSensitivity
    public var sourceItemID: UUID?
    public var isStale: Bool

    public var id: UUID { observationID }

    public init(
        observationID: UUID,
        text: String,
        confidence: FactConfidence,
        observedOn: Date,
        lastConfirmedOn: Date,
        sensitivity: FactSensitivity,
        sourceItemID: UUID?,
        isStale: Bool
    ) {
        self.observationID = observationID
        self.text = text
        self.confidence = confidence
        self.observedOn = observedOn
        self.lastConfirmedOn = lastConfirmedOn
        self.sensitivity = sensitivity
        self.sourceItemID = sourceItemID
        self.isStale = isStale
    }

    /// The sentence beneath the value, when the app owes the user its working.
    public var provenanceSentence: String? {
        guard confidence.needsLabel else { return nil }
        return isStale
            ? "Last confirmed \(lastConfirmedOn.formatted(date: .abbreviated, time: .omitted)). Still true?"
            : EstimateProvenance.sentence(observedOn: observedOn)
    }
}

public struct RelatedPerson: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var label: String
    public var kind: RelationshipKind

    public init(id: UUID, name: String, label: String, kind: RelationshipKind) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
    }
}

/// What the trailing pane shows for one person.
public struct PersonSidebarContext: Sendable {
    public var personID: UUID
    public var upcoming: [PersonTimelineEntry]
    public var openItems: [PersonTimelineEntry]
    public var promises: [PersonTimelineEntry]
    public var relatedPeople: [RelatedPerson]
    public var sharedProjects: [PersonReference]
    public var places: [String]
    public var staleFacts: [PersonObservation]
    public var celebrations: [UpcomingCelebration]
    public var destinations: [ContactDestination]

    public init(
        personID: UUID,
        upcoming: [PersonTimelineEntry],
        openItems: [PersonTimelineEntry],
        promises: [PersonTimelineEntry],
        relatedPeople: [RelatedPerson],
        sharedProjects: [PersonReference],
        places: [String],
        staleFacts: [PersonObservation],
        celebrations: [UpcomingCelebration],
        destinations: [ContactDestination]
    ) {
        self.personID = personID
        self.upcoming = upcoming
        self.openItems = openItems
        self.promises = promises
        self.relatedPeople = relatedPeople
        self.sharedProjects = sharedProjects
        self.places = places
        self.staleFacts = staleFacts
        self.celebrations = celebrations
        self.destinations = destinations
    }

    public var isEmpty: Bool {
        upcoming.isEmpty && openItems.isEmpty && relatedPeople.isEmpty
            && sharedProjects.isEmpty && places.isEmpty && staleFacts.isEmpty && celebrations.isEmpty
    }
}
