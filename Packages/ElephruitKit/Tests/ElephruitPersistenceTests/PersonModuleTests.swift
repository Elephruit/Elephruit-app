import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// The People module against a real store.
///
/// The assertions that matter here are the ones a value-type test cannot make: that a reciprocal
/// relationship survives a round trip through the store, that correcting a fact leaves both rows on
/// disk, and that a merge moves everything it said it would and destroys nothing.
@Suite("People module")
@MainActor
struct PersonModuleTests {
    /// A fixture with the People services wired over one in-memory store.
    struct Fixture {
        let store: StoreFixture
        let people: SwiftDataPersonRepository
        let workspace: PersonWorkspaceService
        let identity: PersonIdentityService
        let search: PersonSearchService
        let groups: PersonGroupService

        @MainActor
        init(dateProvider: FixedDateProvider = .reference, audit: FetchAudit? = nil) throws {
            let store = try StoreFixture(dateProvider: dateProvider, audit: audit)
            self.store = store

            let people = SwiftDataPersonRepository(
                context: store.context, items: store.items, dateProvider: dateProvider, audit: audit
            )
            self.people = people
            self.workspace = PersonWorkspaceService(
                people: people, items: store.items, dateProvider: dateProvider
            )
            self.identity = PersonIdentityService(
                context: store.context, people: people, items: store.items, dateProvider: dateProvider
            )
            let search = PersonSearchService(people: people, items: store.items, dateProvider: dateProvider)
            self.search = search
            self.groups = PersonGroupService(
                context: store.context, items: store.items, people: people,
                search: search, dateProvider: dateProvider
            )
        }
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - People

    @Test("Creating a person makes them findable by their details")
    func creatingAPersonIndexesTheirProfile() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                roleTitle: "Head of Design",
                organizationName: "Northwind",
                locationText: "Austin",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )

        let stored = try fixture.store.requireItem(id: maya.id)
        #expect(stored.kind == .person)
        #expect(stored.personProfile?.givenName == "Maya")
        #expect(stored.personProfile?.familyName == "Chen")
        // The profile has to be folded into the projection *after* it exists, or the person is
        // indexed empty and cannot be found by role or organisation.
        #expect(stored.searchText.contains("northwind"))
        #expect(stored.searchText.contains("austin"))
    }

    @Test("A phone number is not folded into the general search text")
    func phoneNumbersStayOutOfTheProjection() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", phones: [LabelledValue(label: "mobile", value: "512-555-0192")])
        )

        let stored = try fixture.store.requireItem(id: maya.id)
        #expect(!stored.searchText.contains("5550192"), "“555” must not match three people for invisible reasons")
    }

    @Test("Adding details never removes the ones already there")
    func addingDetailsIsAdditive() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", emails: [LabelledValue(label: "work", value: "maya@northwind.example")])
        )

        try fixture.people.addDetails(
            to: maya,
            from: PersonDraft(fullName: "ignored", phones: [LabelledValue(label: "mobile", value: "512-555-0192")])
        )

        let stored = try fixture.store.requireItem(id: maya.id)
        #expect(stored.personProfile?.emails.count == 1)
        #expect(stored.personProfile?.phones.count == 1)
        #expect(stored.displayTitle == "Maya Chen", "adding a phone number must not rename anybody")
    }

    @Test("The same number written two ways is stored once")
    func detailsAreDeduplicatedOnANormalisedForm() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", phones: [LabelledValue(label: "mobile", value: "512-555-0192")])
        )
        try fixture.people.addDetails(
            to: maya,
            from: PersonDraft(fullName: "x", phones: [LabelledValue(label: "cell", value: "+1 (512) 555-0192")])
        )

        #expect(try fixture.store.requireItem(id: maya.id).personProfile?.phones.count == 1)
    }

    // MARK: - Reciprocal relationships

    @Test("Making Maya Jack's parent makes Jack Maya's child")
    func relationshipsAreReciprocalOnDisk() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen", isPlaceholder: true))

        try fixture.people.relate(maya, to: jack, as: .parent, label: nil)

        let mayaSide = try fixture.people.relationships(of: maya)
        #expect(mayaSide.count == 1)
        #expect(mayaSide.first?.kind == .parent)

        let jackSide = try fixture.people.relationships(of: jack)
        #expect(jackSide.count == 1)
        #expect(jackSide.first?.kind == .child, "the other half is written in the same save")
        #expect(jackSide.first?.reciprocalID == mayaSide.first?.id)
    }

    @Test("The user's own word describes only the side they said it about")
    func customLabelsAreNotMirrored() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.resolveOrCreatePlaceholder(named: "Jack")

        // "Maya's son Jack" — said from Maya's side.
        try fixture.people.relate(maya, to: jack, as: .child, label: "son")

        #expect(try fixture.people.relationships(of: maya).first?.customLabel == "son")
        #expect(
            try fixture.people.relationships(of: jack).first?.customLabel == nil,
            "the app was never told what Jack calls Maya, and must not invent it"
        )
        #expect(try fixture.people.relationships(of: jack).first?.kind == .parent)
    }

    @Test("Removing a relationship removes both halves")
    func unrelatingIsSymmetric() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))

        let relationship = try fixture.people.relate(maya, to: jack, as: .parent, label: nil)
        try fixture.people.unrelate(relationship)

        #expect(try fixture.people.relationships(of: maya).isEmpty)
        #expect(try fixture.people.relationships(of: jack).isEmpty, "a one-sided relationship is a bug, not a state")
    }

    @Test("Relating the same pair twice changes nothing")
    func relatingIsIdempotent() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))

        try fixture.people.relate(maya, to: jack, as: .parent, label: nil)
        try fixture.people.relate(maya, to: jack, as: .parent, label: nil)

        #expect(try fixture.people.relationships(of: maya).count == 1)
        #expect(try fixture.people.relationships(of: jack).count == 1)
    }

    @Test("Nobody is their own sibling")
    func selfRelationshipIsRejected() throws {
        let fixture = try Fixture()
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        #expect(throws: AppError.self) {
            try fixture.people.relate(maya, to: maya, as: .sibling, label: nil)
        }
    }

    @Test("A person mentioned but not yet described becomes a placeholder")
    func placeholdersAreRealRecords() throws {
        let fixture = try Fixture()

        let jack = try fixture.people.resolveOrCreatePlaceholder(named: "Jack")
        #expect(jack.personProfile?.isPlaceholder == true)
        #expect(jack.kind == .person)

        // Asking again finds the same person rather than making a second one.
        let again = try fixture.people.resolveOrCreatePlaceholder(named: "jack")
        #expect(again.id == jack.id)
    }

    // MARK: - Observations

    @Test("Recording Jack's age and grade keeps the date they were said on")
    func observationsKeepTheirDate() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2026, 7, 18)))

        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        let conversation = try fixture.store.makeNote(title: "Coffee with Maya")

        try fixture.people.record(
            ObservationDraft(attribute: .observedAge, value: "6"),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: conversation
        )
        try fixture.people.record(
            ObservationDraft(attribute: .schoolGrade, value: "2nd grade", effective: .today),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: conversation
        )

        let ledger = try fixture.people.ledger(for: jack)
        #expect(ledger.value(of: .observedAge) == "6")
        #expect(ledger.current(.observedAge).first?.sourceItemID == conversation.id)

        // "Entering" means the year that has not begun. July 2026 falls in 2025-26, so the grade
        // refers to 2026-27 and the stored school year has to say so.
        #expect(ledger.current(.schoolGrade).first?.schoolYearStart == 2026)
    }

    @Test("Eighteen months later the page says 7–8 and likely 3rd grade")
    func estimatesAdvanceFromTheObservation() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2026, 7, 18)))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))

        try fixture.people.record(
            ObservationDraft(attribute: .observedAge, value: "6"),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try fixture.people.record(
            ObservationDraft(attribute: .schoolGrade, value: "2nd grade", effective: .today),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: nil
        )

        // The same store, read eighteen months later.
        let later = PersonWorkspaceService(
            people: fixture.people,
            items: fixture.store.items,
            dateProvider: FixedDateProvider(now: Self.date(2028, 1, 18))
        )
        let portrait = try later.portrait(of: jack)

        #expect(portrait.age.displayText == "approximately 7–8 years old")
        #expect(portrait.grade?.displayText == "likely in 3rd grade")
        #expect(portrait.ageAndGradeIsEstimate)
        #expect(portrait.ageAndGradeLine == "approximately 7–8 years old · likely in 3rd grade")
    }

    @Test("Adding an exact birthday makes the age exact")
    func birthdayOverridesTheEstimate() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2028, 1, 18)))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))

        try fixture.people.record(
            ObservationDraft(attribute: .observedAge, value: "6"),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        #expect(try fixture.workspace.age(of: jack).isEstimate)

        guard let birthday = PartialDate(year: 2020, month: 3, day: 4) else {
            Issue.record("could not build the birthday")
            return
        }
        try fixture.people.addCelebration(to: jack, kind: .birthday, title: nil, date: birthday)

        let age = try fixture.workspace.age(of: jack)
        #expect(age == .exact(years: 7))
        #expect(!age.isEstimate, "a recorded birthday ends the hedging")
    }

    @Test("Correcting a fact keeps the original on disk")
    func correctionIsNonDestructive() throws {
        let fixture = try Fixture()
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        let original = try fixture.people.record(
            ObservationDraft(attribute: .employer, value: "Acme"),
            about: maya, observedOn: Self.date(2025, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )

        try fixture.people.correct(original, to: "Northwind", note: "I misheard this")

        let ledger = try fixture.people.ledger(for: maya)
        #expect(ledger.value(of: .employer) == "Northwind")
        #expect(ledger.history(.employer).map(\.value) == ["Acme"])

        // On disk, not merely in the ledger's reading of it.
        let stored = try fixture.people.observations(for: maya)
        #expect(stored.count == 2)
        #expect(stored.contains { $0.value == "Acme" && !$0.isCurrent })
        #expect(stored.first { $0.value == "Northwind" }?.correctionNote == "I misheard this")
    }

    @Test("A newer single-valued fact supersedes the older one")
    func singleValuedFactsSupersede() throws {
        let fixture = try Fixture()
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        try fixture.people.record(
            ObservationDraft(attribute: .location, value: "Portland"),
            about: maya, observedOn: Self.date(2024, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try fixture.people.record(
            ObservationDraft(attribute: .location, value: "Austin"),
            about: maya, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: nil
        )

        let ledger = try fixture.people.ledger(for: maya)
        #expect(ledger.current(.location).map(\.value) == ["Austin"])
        #expect(ledger.history(.location).map(\.value) == ["Portland"])
    }

    @Test("Likes accumulate rather than replacing each other")
    func multiValuedFactsAccumulate() throws {
        let fixture = try Fixture()
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        for value in ["natural wine", "small restaurants"] {
            try fixture.people.record(
                ObservationDraft(attribute: .like, value: value),
                about: maya, observedOn: Self.date(2026, 7, 18),
                confidence: .stated, sensitivity: .normal, source: nil
            )
        }

        #expect(try fixture.people.ledger(for: maya).current(.like).count == 2)
    }

    @Test("Confirming a stale fact makes it current again without changing it")
    func confirmingResetsTheClock() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2026, 7, 18)))
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        let observation = try fixture.people.record(
            ObservationDraft(attribute: .employer, value: "Acme"),
            about: maya, observedOn: Self.date(2023, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        #expect(observation.asValue()?.isStale(asOf: Self.date(2026, 7, 18), calendar: calendar) == true)

        try fixture.people.confirm(observation)

        #expect(observation.asValue()?.isStale(asOf: Self.date(2026, 7, 18), calendar: calendar) == false)
        #expect(observation.value == "Acme", "confirming changes when, never what")
        #expect(observation.observedOn == Self.date(2023, 1, 1), "the original date is the anchor and never moves")
    }

    // MARK: - Timeline

    @Test("A note linked to somebody appears in their timeline")
    func linkedNotesAppearInTheTimeline() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let note = try fixture.store.makeNote(title: "Dinner plans", body: "She prefers small restaurants.")
        try fixture.store.items.link(note, to: maya, kind: .mentions)

        let timeline = try fixture.workspace.timeline(for: maya)
        #expect(timeline.contains { $0.id == note.id })
        #expect(timeline.first { $0.id == note.id }?.excerpt?.isEmpty == false)
    }

    @Test("A meeting linked to its attendees appears too")
    func outgoingLinksAreWalkedAsWell() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let meeting = try fixture.store.items.create(ItemDraft(kind: .meeting, title: "Quarterly review"))
        // A meeting links *to* its attendees, so a one-directional walk would lose it.
        try fixture.store.items.link(meeting, to: maya, kind: .participant)

        #expect(try fixture.workspace.timeline(for: maya).contains { $0.id == meeting.id })
    }

    @Test("A timeline entry says where it came from")
    func timelineEntriesCarryProvenance() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let interaction = try fixture.store.items.create(
            ItemDraft(kind: .interaction, title: "Called about the move", source: ItemSource(kind: .manual))
        )
        try fixture.store.items.link(interaction, to: maya, kind: .mentions)

        let entry = try #require(try fixture.workspace.timeline(for: maya).first { $0.id == interaction.id })
        #expect(entry.provenance == .logged)
        #expect(entry.isContact)
    }

    @Test("Trashed items leave the timeline")
    func trashedItemsAreNotShown() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let note = try fixture.store.makeNote(title: "Old note")
        try fixture.store.items.link(note, to: maya, kind: .mentions)
        try fixture.store.items.moveToTrash(note)

        #expect(try fixture.workspace.timeline(for: maya).isEmpty)
    }

    // MARK: - Charts

    @Test("A family chart puts parents above and children below")
    func familyChartIsRanked() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        let partner = try fixture.people.createPerson(PersonDraft(fullName: "Sam Okonkwo"))
        let colleague = try fixture.people.createPerson(PersonDraft(fullName: "Theo Brandt"))

        try fixture.people.relate(maya, to: jack, as: .child, label: "son")
        try fixture.people.relate(maya, to: partner, as: .partner, label: nil)
        try fixture.people.relate(maya, to: colleague, as: .colleague, label: nil)

        let chart = try fixture.workspace.chart(.family, for: maya)

        #expect(chart.nodes.count == 3, "the colleague belongs to a different chart")
        #expect(chart.nodes.first { $0.name == "Jack Chen" }?.rank == 1)
        #expect(chart.nodes.first { $0.name == "Sam Okonkwo" }?.rank == 0)
        #expect(chart.nodes.first { $0.name == "Jack Chen" }?.roleLabel == "son")
    }

    @Test("An organisation chart puts a manager above and reports below")
    func organisationChartIsRanked() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let boss = try fixture.people.createPerson(PersonDraft(fullName: "Rosa Iyer"))
        let report = try fixture.people.createPerson(PersonDraft(fullName: "Theo Brandt"))

        try fixture.people.relate(maya, to: boss, as: .manager, label: nil)
        try fixture.people.relate(maya, to: report, as: .directReport, label: nil)

        let chart = try fixture.workspace.chart(.professional, for: maya)

        #expect(chart.nodes.first { $0.name == "Rosa Iyer" }?.rank == -1)
        #expect(chart.nodes.first { $0.name == "Theo Brandt" }?.rank == 1)
        #expect(chart.rows.map(\.rank) == [-1, 0, 1])
    }

    @Test("One line is drawn per pair, not two")
    func reciprocalRowsDoNotDoubleTheEdges() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        try fixture.people.relate(maya, to: jack, as: .child, label: nil)

        #expect(try fixture.workspace.chart(.family, for: maya).edges.count == 1)
    }

    // MARK: - Identity

    @Test("A merge moves everything and destroys nothing")
    func mergeIsNonDestructive() throws {
        let fixture = try Fixture()

        let primary = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", emails: [LabelledValue(label: "work", value: "maya@northwind.example")])
        )
        let duplicate = try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                phones: [LabelledValue(label: "mobile", value: "512-555-0192")]
            )
        )

        let note = try fixture.store.makeNote(title: "Coffee")
        try fixture.store.items.link(note, to: duplicate, kind: .mentions)
        try fixture.people.record(
            ObservationDraft(attribute: .like, value: "natural wine"),
            about: duplicate, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        try fixture.people.relate(duplicate, to: jack, as: .child, label: "son")

        let plan = try fixture.identity.plan(merging: duplicate, into: primary)
        #expect(plan.movedObservations == 1)
        #expect(plan.movedRelationships == 1)
        #expect(plan.addedPhones == ["512-555-0192"])

        try fixture.identity.merge(plan)

        let survivor = try #require(try fixture.people.person(id: primary.id))
        #expect(survivor.personProfile?.emails.count == 1)
        #expect(survivor.personProfile?.phones.count == 1)
        #expect(try fixture.people.ledger(for: survivor).value(of: .like) == "natural wine")
        #expect(try fixture.people.relationships(of: survivor).contains { $0.other?.id == jack.id })
        #expect(try fixture.workspace.timeline(for: survivor).contains { $0.id == note.id })

        // The absorbed record is in the Trash, recoverable, rather than gone.
        let absorbed = try #require(try fixture.store.items.item(id: duplicate.id))
        #expect(absorbed.deletedAt != nil)
    }

    @Test("A merge keeps both sides of a conflict")
    func mergeKeepsConflictingValues() throws {
        let fixture = try Fixture()

        let primary = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", roleTitle: "Head of Design")
        )
        let duplicate = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", roleTitle: "Design Lead")
        )

        let plan = try fixture.identity.plan(merging: duplicate, into: primary)
        #expect(plan.conflicts.count == 1)

        try fixture.identity.merge(plan)

        let survivor = try #require(try fixture.people.person(id: primary.id))
        #expect(survivor.personProfile?.roleTitle == "Head of Design", "the survivor keeps its own value")

        let ledger = try fixture.people.ledger(for: survivor)
        #expect(
            ledger.observations.contains { $0.value == "Design Lead" },
            "and the other is kept as a dated, unconfirmed observation rather than discarded"
        )
    }

    @Test("Two records from the same Contacts row are certain, and two strangers are not")
    func duplicateDetection() throws {
        let fixture = try Fixture()

        try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", contactsIdentifier: "ABC-123", contactsAccountName: "iCloud")
        )
        try fixture.people.createPerson(
            PersonDraft(fullName: "M. Chen", contactsIdentifier: "ABC-123", contactsAccountName: "Google")
        )
        try fixture.people.createPerson(PersonDraft(fullName: "Theo Brandt"))

        let duplicates = try fixture.identity.duplicates()
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.isCertain == true)
        #expect(duplicates.first?.explanation.contains("Same Contacts record") == true)
    }

    // MARK: - Search

    @Test("People are found by what is recorded about them")
    func searchMatchesFacts() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.people.record(
            ObservationDraft(attribute: .like, value: "natural wine"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try fixture.people.createPerson(PersonDraft(fullName: "Theo Brandt"))

        let results = try fixture.search.search("likes natural wine")
        #expect(results.map(\.name) == ["Maya Chen"])
        #expect(results.first?.bestReason?.text.contains("natural wine") == true)
    }

    @Test("People are found by where they live")
    func searchMatchesLocation() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.people.record(
            ObservationDraft(attribute: .location, value: "Austin"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try fixture.people.createPerson(PersonDraft(fullName: "Theo Brandt"))

        #expect(try fixture.search.search("people in Austin").map(\.name) == ["Maya Chen"])
    }

    @Test("Maya's son finds Jack and not Maya")
    func searchMatchesRelationships() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        try fixture.people.relate(maya, to: jack, as: .child, label: "son")

        let results = try fixture.search.search("Maya's son")
        #expect(results.map(\.id) == [jack.id])
    }

    @Test("A private reflection is not reachable from the search field")
    func restrictedFactsAreNotSearched() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.people.record(
            ObservationDraft(attribute: .reflection, value: "worried about the redundancy rumours"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .restricted, source: nil
        )

        #expect(try fixture.search.search("redundancy").isEmpty)
    }

    // MARK: - Groups and batch actions

    @Test("A fixed group holds who was put in it")
    func fixedGroups() throws {
        let fixture = try Fixture()

        let group = try fixture.groups.createFixedGroup(named: "Family")
        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.groups.add(maya, to: group.id)

        let reloaded = try #require(try fixture.groups.group(id: group.id))
        #expect(reloaded.name == "Family")
        #expect(reloaded.memberIDs == [maya.id])
        #expect(!reloaded.isSmart)
    }

    @Test("A smart group recomputes as people change")
    func smartGroups() throws {
        let fixture = try Fixture()

        let group = try fixture.groups.createSmartGroup(named: "Austin", query: "people in Austin")
        #expect(group.memberIDs.isEmpty)

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.people.record(
            ObservationDraft(attribute: .location, value: "Austin"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .normal, source: nil
        )

        let reloaded = try #require(try fixture.groups.group(id: group.id))
        #expect(reloaded.memberIDs == [maya.id], "nothing was added to the group; the world changed")
        #expect(reloaded.isSmart)
    }

    /// The privacy failure a group email makes easy: everyone learns everyone else's address.
    @Test("A group email hides addresses and says so")
    func groupEmailPreviewUsesBlindCopy() throws {
        let fixture = try Fixture()

        let group = try fixture.groups.createFixedGroup(named: "Design Team")
        for (name, email) in [("Maya Chen", "maya@example.com"), ("Theo Brandt", "theo@example.com")] {
            let person = try fixture.people.createPerson(
                PersonDraft(fullName: name, emails: [LabelledValue(label: "work", value: email)])
            )
            try fixture.groups.add(person, to: group.id)
        }

        let reloaded = try #require(try fixture.groups.group(id: group.id))
        let preview = try fixture.groups.preview(.email, for: reloaded)

        #expect(preview.recipients.count == 2)
        #expect(preview.usesBlindCopy)
        #expect(preview.url?.absoluteString.contains("bcc=") == true)
        #expect(preview.privacyNote?.contains("hidden from each other") == true)
    }

    @Test("Somebody with no email is named as skipped rather than silently dropped")
    func groupPreviewNamesExclusions() throws {
        let fixture = try Fixture()

        let group = try fixture.groups.createFixedGroup(named: "Design Team")
        let reachable = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", emails: [LabelledValue(label: "work", value: "maya@example.com")])
        )
        let unreachable = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        try fixture.groups.add(reachable, to: group.id)
        try fixture.groups.add(unreachable, to: group.id)

        let preview = try fixture.groups.preview(.email, for: try #require(try fixture.groups.group(id: group.id)))

        #expect(preview.recipients.count == 1)
        #expect(preview.excluded.map(\.name) == ["Jack Chen"])
        #expect(preview.excluded.first?.reason == "no email address")
        #expect(preview.summary.contains("1 skipped"))
    }

    @Test("A group export carries no app-only data")
    func groupExportIsSafe() throws {
        let fixture = try Fixture()

        let group = try fixture.groups.createFixedGroup(named: "Design Team")
        let maya = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Chen", emails: [LabelledValue(label: "work", value: "maya@example.com")])
        )
        try fixture.groups.add(maya, to: group.id)
        try fixture.people.record(
            ObservationDraft(attribute: .reflection, value: "worried about the redundancy rumours"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .restricted, source: nil
        )

        let vcards = try fixture.groups.exportVCards(
            for: try #require(try fixture.groups.group(id: group.id)),
            profile: ShareProfile(name: "Professional", fields: [.fullName, .workEmail])
        )

        #expect(vcards.contains("Maya Chen"))
        #expect(!vcards.contains("redundancy"), "a private reflection must not leave the app in an export")
    }

    // MARK: - Meeting brief

    @Test("A brief labels its estimates and names its sources")
    func meetingBriefDistinguishesFactFromEstimate() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2028, 1, 18)))

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        let jack = try fixture.people.createPerson(PersonDraft(fullName: "Jack Chen"))
        try fixture.people.relate(maya, to: jack, as: .child, label: "son")

        let conversation = try fixture.store.makeNote(title: "Coffee with Maya")
        try fixture.store.items.link(conversation, to: maya, kind: .mentions)
        try fixture.people.record(
            ObservationDraft(attribute: .observedAge, value: "6"),
            about: jack, observedOn: Self.date(2026, 7, 18),
            confidence: .stated, sensitivity: .normal, source: conversation
        )

        let brief = try fixture.workspace.brief(for: maya)

        let family = try #require(brief.entries.first { $0.section == .family })
        #expect(family.text.contains("Jack Chen"))
        #expect(family.text.contains("approximately 7–8 years old"))
        #expect(family.needsEstimateLabel)
        #expect(family.detail?.contains("Estimated from information shared") == true)
        #expect(brief.estimateCount >= 1)
    }

    @Test("A brief never contains a private reflection")
    func briefExcludesReflections() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        try fixture.people.record(
            ObservationDraft(attribute: .reflection, value: "worried about the redundancy rumours"),
            about: maya, observedOn: Self.date(2026, 1, 1),
            confidence: .stated, sensitivity: .restricted, source: nil
        )

        let brief = try fixture.workspace.brief(for: maya)
        #expect(!brief.entries.contains { $0.text.contains("redundancy") })
    }

    // MARK: - Celebrations

    @Test("A birthday lives in one place and appears in one list")
    func birthdaysAreNotDuplicated() throws {
        let fixture = try Fixture(dateProvider: FixedDateProvider(now: Self.date(2026, 9, 30)))

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        guard let birthday = PartialDate(year: 1987, month: 10, day: 12) else {
            Issue.record("could not build the birthday")
            return
        }
        try fixture.people.addCelebration(to: maya, kind: .birthday, title: nil, date: birthday)

        let all = try fixture.people.allCelebrations()
        let mayasBirthdays = all.filter { $0.personID == maya.id && $0.kind == .birthday }
        #expect(mayasBirthdays.count == 1, "the profile and the celebration row must not both report it")
        #expect(maya.personProfile?.birthdayHasYear == true)
    }

    @Test("Loading all celebrations uses a bounded number of fetches")
    func allCelebrationsDoesNotFetchPerPerson() throws {
        let audit = FetchAudit()
        let fixture = try Fixture(audit: audit)

        for index in 0..<20 {
            _ = try fixture.people.createPerson(PersonDraft(fullName: "Person \(index)"))
        }

        let (_, tally) = try audit.measure {
            try fixture.people.allCelebrations()
        }

        #expect(tally.itemFetches == 1, "people should be loaded in one fetch: \(tally.description)")
        #expect(tally.otherFetches == 1, "celebrations should be loaded in one fetch: \(tally.description)")
        #expect(tally.total == 2, "the fetch count must not grow with the number of people: \(tally.description)")
    }

    @Test("My Card is exactly one person")
    func myCardIsSingular() throws {
        let fixture = try Fixture()

        let first = try fixture.people.createPerson(PersonDraft(fullName: "Alex Rivera"))
        let second = try fixture.people.createPerson(PersonDraft(fullName: "Someone Else"))

        try fixture.people.setMyCard(first)
        #expect(try fixture.people.myCard()?.id == first.id)

        try fixture.people.setMyCard(second)
        #expect(try fixture.people.myCard()?.id == second.id)
        #expect(first.personProfile?.isMyCard == false, "choosing a new card clears the old one")
    }

    // MARK: - Names staying in step

    @Test("Renaming a person re-splits their name rather than leaving the old one behind")
    func renameKeepsNamePartsInStep() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        #expect(maya.personProfile?.givenName == "Maya")
        #expect(maya.personProfile?.familyName == "Chen")

        try fixture.store.items.update(maya) { $0.title = "Maya Okonkwo" }

        #expect(
            maya.personProfile?.familyName == "Okonkwo",
            """
            The parts were split once at creation and never again, so a rename left the profile \
            spelling the old name — which searched wrongly and would have offered the address book \
            a name the user had already changed.
            """
        )
        #expect(maya.personProfile?.givenName == "Maya")
    }

    @Test("A name set deliberately in parts survives an unrelated edit")
    func deliberatePartsAreNotReSplit() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))

        // What the editor writes: parts that say more than a two-word split could work out, and a
        // title assembled from them.
        try fixture.people.updateProfile(of: maya) { profile in
            profile.namePrefix = "Dr"
            profile.givenName = "Maya"
            profile.middleName = "Lin"
            profile.familyName = "Chen"
            profile.nameSuffix = "PhD"
        }
        try fixture.store.items.update(maya) { $0.title = "Dr Maya Lin Chen PhD" }

        // Any later edit at all. This is the one that used to undo the correction.
        try fixture.store.items.update(maya) { $0.isFavorite = true }

        #expect(maya.personProfile?.givenName == "Maya", "a prefix must not become somebody's first name")
        #expect(maya.personProfile?.familyName == "Chen")
        #expect(maya.personProfile?.namePrefix == "Dr")
        #expect(maya.personProfile?.nameSuffix == "PhD")
    }

    @Test("A person renamed to nothing keeps the parts they had")
    func emptyRenameLeavesPartsAlone() throws {
        let fixture = try Fixture()

        let maya = try fixture.people.createPerson(PersonDraft(fullName: "Maya Chen"))
        // Validation refuses an empty title, so the parts must survive the rejection intact.
        try? fixture.store.items.update(maya) { $0.title = "   " }

        #expect(maya.personProfile?.givenName == "Maya")
        #expect(maya.personProfile?.familyName == "Chen")
    }
}
