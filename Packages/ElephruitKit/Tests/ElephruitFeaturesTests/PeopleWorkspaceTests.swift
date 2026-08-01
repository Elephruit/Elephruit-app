import ElephruitCore
@testable import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// The People module wired together, against the sample library.
///
/// ### Why the fixture is worth testing
/// Sample data is the demo path, and a demo path that quietly stops producing the state it is meant
/// to demonstrate is worse than none — somebody opens the app, sees a tidy page, and concludes the
/// feature does not do what it says. These assert that each awkward case the fixture exists to create
/// is actually there: an estimated age, a stale fact, an unkept promise, a duplicate to reconcile.
@Suite("People workspace")
@MainActor
struct PeopleWorkspaceTests {
    func makeServices() -> AppServices {
        // A fixed clock 540 days after the coffee conversation, which is where the estimates bite.
        AppServices.inMemory(dateProvider: FixedDateProvider.reference, populated: true)
    }

    func person(named name: String, in services: AppServices) throws -> Item {
        let people = try services.persons.allPeople(includingPlaceholders: true)
        guard let match = people.first(where: { $0.displayTitle == name }) else {
            throw AppError.itemNotFound(id: UUID())
        }
        return match
    }

    // MARK: - The fixture exists

    @Test("The sample library has the people it promises")
    func sampleDataCreatesPeople() throws {
        let services = makeServices()
        let names = try services.persons.allPeople(includingPlaceholders: true).map(\.displayTitle)

        for expected in ["Maya Chen", "Sam Okonkwo", "Jack Chen", "Pepper", "Nisha Raman", "Rosa Iyer"] {
            #expect(names.contains(expected), "the fixture is missing \(expected)")
        }
    }

    @Test("Maya's page assembles")
    func portraitAssembles() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let portrait = try services.personWorkspace.portrait(of: maya)

        #expect(!portrait.cards.isEmpty)
        #expect(portrait.cards.contains { $0.attribute == .significance })
        #expect(portrait.cards.contains { $0.attribute == .like })
        #expect(portrait.cards.contains { $0.attribute == .communicationPreference })
    }

    /// Scenarios 10 and 11: an age and a grade recorded on a date, read back later as labelled
    /// estimates.
    @Test("Jack's age and grade come back as estimates with their working")
    func jacksAgeIsAnEstimate() throws {
        let services = makeServices()
        let jack = try person(named: "Jack Chen", in: services)
        let portrait = try services.personWorkspace.portrait(of: jack)

        #expect(portrait.age.isEstimate, "an age derived from a dated remark is never stated flatly")
        #expect(portrait.ageAndGradeIsEstimate)
        #expect(portrait.ageAndGradeLine?.contains("approximately") == true)
        #expect(portrait.grade != nil)

        // And every value on the page can say where it came from.
        let ageValue = portrait.cards.first { $0.attribute == .observedAge }?.values.first
        #expect(ageValue?.sourceItemID != nil, "the conversation it was learned in is still attached")
    }

    /// Scenario 12: a recorded birthday ends the hedging.
    @Test("Adding an exact birthday turns the estimate into arithmetic")
    func birthdayEndsTheEstimate() throws {
        let services = makeServices()
        let jack = try person(named: "Jack Chen", in: services)

        #expect(try services.personWorkspace.age(of: jack).isEstimate)

        guard let birthday = PartialDate(year: 2020, month: 3, day: 4) else {
            Issue.record("could not build the birthday")
            return
        }
        try services.persons.addCelebration(to: jack, kind: .birthday, title: nil, date: birthday)

        let age = try services.personWorkspace.age(of: jack)
        #expect(!age.isEstimate)
        if case .exact = age {} else {
            Issue.record("expected an exact age, got \(age)")
        }
    }

    /// Scenario 13: correction without destroying history.
    @Test("Correcting a fact leaves the previous value readable")
    func correctionKeepsHistory() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)

        guard let employer = try services.persons.observations(for: maya)
            .first(where: { $0.attribute == .employer })
        else {
            Issue.record("the fixture has no employer to correct")
            return
        }

        try services.persons.correct(employer, to: "Fieldstone", note: "She changed jobs in the spring")

        let portrait = try services.personWorkspace.portrait(of: maya)
        let card = portrait.cards.first { $0.attribute == .employer }
        #expect(card?.values.first?.text == "Fieldstone")
        #expect(card?.historyCount == 1, "the previous employer is history, not gone")
    }

    /// Scenario 7: a note linked elsewhere appears here.
    @Test("A note linked to Maya is in Maya's timeline")
    func linkedNotesAppear() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let timeline = try services.personWorkspace.timeline(for: maya)

        #expect(timeline.contains { $0.title == "Studio pricing conversation" })
        #expect(timeline.contains { $0.kind == .interaction })
        #expect(timeline.contains { $0.kind == .meeting })
    }

    @Test("The timeline distinguishes a conversation from a button press")
    func provenanceIsVisible() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let timeline = try services.personWorkspace.timeline(for: maya)

        let logged = timeline.first { $0.provenance == .logged }
        let initiated = timeline.first { $0.provenance == .initiated }

        #expect(logged?.isContact == true)
        #expect(initiated?.isContact == false, "starting a message is not the same as having spoken")
    }

    /// Scenario 14, in the fixture: a promise the user has not kept.
    @Test("An unkept promise is open and labelled")
    func openPromiseExists() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let context = try services.personWorkspace.sidebar(for: maya)

        #expect(!context.promises.isEmpty)
        #expect(context.promises.first?.isOpen == true)
    }

    @Test("A fact nobody has confirmed in years is flagged rather than hidden")
    func staleFactIsFlagged() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let portrait = try services.personWorkspace.portrait(of: maya)

        #expect(!portrait.staleFacts.isEmpty)
        #expect(portrait.staleFacts.contains { $0.attribute == .employer })
    }

    /// Scenarios 16 and 17.
    @Test("Maya has a family chart and an organisation chart, and they differ")
    func chartsAreSeparate() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)

        let family = try services.personWorkspace.chart(.family, for: maya)
        let professional = try services.personWorkspace.chart(.professional, for: maya)

        #expect(family.nodes.contains { $0.name == "Jack Chen" })
        #expect(!family.nodes.contains { $0.name == "Rosa Iyer" }, "a manager is not family")

        #expect(professional.nodes.contains { $0.name == "Rosa Iyer" })
        #expect(!professional.nodes.contains { $0.name == "Jack Chen" }, "a child is not an employee")

        // Ranked: the manager above, the reports below.
        #expect(professional.nodes.first { $0.name == "Rosa Iyer" }?.rank == -1)
        #expect(professional.nodes.contains { $0.rank == 1 })
    }

    /// Scenario 18.
    @Test("Birthdays and anniversaries come back in date order")
    func upcomingCelebrations() throws {
        let services = makeServices()
        let all = try services.persons.allCelebrations()

        #expect(all.contains { $0.kind == .birthday })
        #expect(all.contains { $0.kind == .anniversary })

        let upcoming = CelebrationCalendar.upcoming(
            from: all, within: 365, asOf: services.dateProvider.now, calendar: services.dateProvider.calendar
        )
        #expect(!upcoming.isEmpty)
        #expect(upcoming == upcoming.sorted { $0.daysAway < $1.daysAway })

        // The leap-day birthday is represented rather than dropped.
        #expect(upcoming.contains { $0.celebration.personName == "Nisha Raman" })
    }

    /// Scenario 15.
    @Test("The meeting brief separates what is known from what is guessed")
    func meetingBrief() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let brief = try services.personWorkspace.brief(for: maya)

        #expect(!brief.isEmpty)
        #expect(brief.sections.contains { $0.section == .family })
        #expect(brief.estimateCount > 0, "Jack's age is an estimate and the brief must say so")

        // And the private reflection is not in it.
        #expect(!brief.entries.contains { $0.text.lowercased().contains("unhappy") })
    }

    /// Scenario 3.
    @Test("People are findable by preference, place, and relationship")
    func search() throws {
        let services = makeServices()

        #expect(try services.personSearch.search("likes natural wine").contains { $0.name == "Maya Chen" })
        #expect(try services.personSearch.search("people in Austin").contains { $0.name == "Maya Chen" })
        #expect(try services.personSearch.search("Maya's son").contains { $0.name == "Jack Chen" })
        #expect(try services.personSearch.search("people I met through Nisha").contains { $0.name == "Danielle Okafor" })
        #expect(try services.personSearch.search("open promises").contains { $0.name == "Maya Chen" })
    }

    @Test("A private reflection is not reachable from search")
    func reflectionsAreNotSearchable() throws {
        let services = makeServices()
        #expect(try services.personSearch.search("unhappy").isEmpty)
    }

    /// Scenario 6.
    @Test("A group action names its recipients and hides their addresses")
    func groupPreview() throws {
        let services = makeServices()
        guard let team = try services.personGroups.allGroups().first(where: { $0.name == "Design Team" }) else {
            Issue.record("the fixture has no Design Team")
            return
        }

        let preview = try services.personGroups.preview(.email, for: team)
        #expect(preview.recipients.count >= 2)
        #expect(preview.usesBlindCopy)
        #expect(preview.url?.absoluteString.contains("bcc=") == true)
    }

    @Test("A smart group recomputes and a fixed one does not")
    func groupKinds() throws {
        let services = makeServices()
        let groups = try services.personGroups.allGroups()

        let family = groups.first { $0.name == "Family" }
        let austin = groups.first { $0.name == "In Austin" }

        #expect(family?.isSmart == false)
        #expect(family?.memberCount == 4)
        #expect(austin?.isSmart == true)
        #expect(austin?.memberIDs.contains(try person(named: "Maya Chen", in: services).id) == true)
    }

    /// Scenario 1, in the shape the fixture can exercise without the address book.
    @Test("Two records for one person are offered as a duplicate")
    func duplicatesAreOffered() throws {
        let services = makeServices()
        let duplicates = try services.personIdentity.duplicates()

        #expect(!duplicates.isEmpty)
        #expect(duplicates.contains { $0.isCertain }, "a shared Contacts record is certain")
    }

    @Test("Merging the duplicate keeps everything and trashes nothing important")
    func mergeWorks() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let duplicate = try person(named: "M. Chen", in: services)

        let before = try services.personWorkspace.timeline(for: maya).count
        let plan = try services.personIdentity.plan(merging: duplicate, into: maya)
        try services.personIdentity.merge(plan)

        #expect(try services.personWorkspace.timeline(for: maya).count >= before)
        #expect(try services.persons.person(id: duplicate.id)?.deletedAt != nil)
    }

    /// Scenario 19.
    @Test("My Card exports a safe subset and nothing else")
    func myCardExport() throws {
        let services = makeServices()
        let card = try #require(try services.persons.myCard())
        #expect(card.displayTitle == "Alex Rivera")

        guard let minimal = services.shareProfiles.first(where: { $0.name == "Minimal" }) else {
            Issue.record("no minimal profile")
            return
        }

        var shareable = ShareableCard()
        shareable[.fullName] = card.displayTitle
        shareable[.personalEmail] = card.personProfile?.emails.last?.value
        shareable[.mobilePhone] = card.personProfile?.phones.first?.value
        shareable[.postalAddress] = card.personProfile?.addresses.first?.value

        let vcard = VCardEmitter.emit(card: shareable, profile: minimal)
        #expect(vcard.contains("Alex Rivera"))
        #expect(!vcard.contains("Chestnut"), "the home address was not in the minimal profile")
        #expect(!vcard.contains("512-555-0134"))
    }

    /// Scenario 2, through the parser the command bar actually uses.
    @Test("A person can be created from one line of natural language")
    func commandBarCreatesAPerson() throws {
        let services = makeServices()
        let context = CommandContext(
            people: try services.persons.allPeople(includingPlaceholders: true).map {
                KnownPerson(id: $0.id, fullName: $0.displayTitle)
            }
        )

        let command = services.commandParser.parse(
            "add Theo Ramirez theo.ramirez@example.com 512-555-0155", context: context
        )

        guard case .createPerson(let fields) = command.intent else {
            Issue.record("expected a creation, got \(command.intent)")
            return
        }
        #expect(fields.name == "Theo Ramirez")
        #expect(fields.emails == ["theo.ramirez@example.com"])
        #expect(fields.phones == ["512-555-0155"])
    }

    /// Why the plus button opens a form rather than the command bar.
    ///
    /// The bar creates people only from `add`/`new`; a bare name is a search, and a search is not
    /// runnable. So the most natural thing to type after pressing a plus was the one thing the bar
    /// could not act on. If this ever starts passing as a creation, the form is no longer the only
    /// honest answer to that button — but it is still the expected one.
    @Test("A bare name is a search the command bar cannot run")
    func bareNameIsNotRunnable() throws {
        let services = makeServices()
        let command = services.commandParser.parse("Theo Ramirez", context: CommandContext())

        guard case .search = command.intent else {
            Issue.record("expected a search, got \(command.intent)")
            return
        }
        #expect(!command.isRunnable)
    }

    @Test("The new-person form leaves untouched fields unset rather than empty")
    func newPersonFormOmitsBlankFields() throws {
        let draft = NewPersonSheet.draft(
            name: "  Theo Ramirez  ", organization: "", role: "  ",
            email: "theo.ramirez@example.com", phone: ""
        )

        #expect(draft.fullName == "Theo Ramirez")
        #expect(draft.organizationName == nil)
        #expect(draft.roleTitle == nil, "a blank role must not become a role of empty string")
        #expect(draft.emails.map { $0.value } == ["theo.ramirez@example.com"])
        #expect(draft.phones.isEmpty)
    }

    /// Scenario 5, at the point where the app hands off to the system.
    @Test("Maya has two numbers, so calling her has to ask")
    func callingAsksWhichNumber() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let destinations = maya.personProfile?.destinations() ?? []

        let candidates = ContactDestinationPolicy.candidates(for: .call, from: destinations)
        #expect(candidates.count == 2)
        #expect(
            ContactDestinationPolicy.automatic(for: .call, from: destinations)?.label == "mobile",
            "the first number is preferred, which is a convention the user controls by reordering"
        )
    }

    @Test("Every quick action either works or explains why it cannot")
    func quickActionsAreHonest() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let jack = try person(named: "Jack Chen", in: services)

        // Maya can be reached every way her details allow.
        let mayaDestinations = maya.personProfile?.destinations() ?? []
        for channel in [ContactChannel.call, .message, .email, .maps, .web] {
            #expect(
                !ContactDestinationPolicy.candidates(for: channel, from: mayaDestinations).isEmpty,
                "\(channel.displayName) should be available for Maya"
            )
        }

        // Jack is a placeholder with no details, so every channel is empty — which the interface
        // renders as a disabled button whose help text says why, never as a control that does
        // nothing when pressed.
        let jackDestinations = jack.personProfile?.destinations() ?? []
        #expect(jackDestinations.isEmpty)
    }

    /// Scenario 8, and the rule that makes the last-contact line trustworthy.
    @Test("A recorded conversation counts as contact; a started one does not")
    func interactionProvenanceDecidesContact() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)

        let before = services.people.context(for: maya).lastContact
        #expect(before != nil, "the fixture has recorded conversations")

        let started = try services.items.create(
            ItemDraft(kind: .interaction, title: "Call started", startAt: services.dateProvider.now)
        )
        try services.items.update(started) { $0.sourceIdentifier = InteractionProvenance.initiated.rawValue }
        try services.items.link(started, to: maya, kind: .mentions)

        let entry = try #require(
            try services.personWorkspace.timeline(for: maya).first { $0.id == started.id }
        )
        #expect(!entry.isContact, "pressing Call is not having spoken")
    }

    // MARK: - Staying current

    /// The bug: a task added about somebody went to the Inbox and did not appear on their page
    /// until the view was rebuilt by navigating away and back.
    ///
    /// This asserts the *cause* rather than the symptom, because the symptom is a view lifecycle
    /// and cannot be driven from here. The page watched the person's `updatedAt`; the write that
    /// changes what the page shows does not touch the person at all.
    @Test("Adding a task about somebody leaves their own row untouched")
    func aLinkedWriteDoesNotMoveThePersonsTimestamp() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let before = maya.updatedAt

        let task = try services.items.create(
            ItemDraft(kind: .task, title: "Follow up with \(maya.displayTitle)")
        )
        try services.items.link(task, to: maya, kind: .mentions)

        #expect(
            maya.updatedAt == before,
            """
            If this ever becomes false the workspace could watch `updatedAt` alone — but while it \
            holds, that is exactly why it could not see the new task.
            """
        )

        #expect(
            try services.personWorkspace.timeline(for: maya).contains { $0.id == task.id },
            "the traversal finds it immediately; only the view was late"
        )
    }

    @Test("Announcing a write bumps the token every linked page watches")
    func changeTokenAdvancesOnEveryWrite() throws {
        let services = makeServices()
        let maya = try person(named: "Maya Chen", in: services)
        let start = services.changeToken

        let task = try services.items.create(ItemDraft(kind: .task, title: "Send Maya the deck"))
        try services.items.link(task, to: maya, kind: .mentions)
        services.noteChange(to: task)

        #expect(services.changeToken == start + 1)

        services.noteRemoval(of: task.id)
        #expect(services.changeToken == start + 2, "a removal is a change too")

        // Recomputing badges after a change already announced must not announce a second one, or
        // one write becomes two rounds of reloads on every open page.
        services.refreshDerivedState()
        #expect(services.changeToken == start + 2)
    }
}
