import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// The onboarding and import flow, driven the way the views drive it.
///
/// ### Why this exists beside the service tests
/// The services are correct in isolation; this asserts they are *wired together* correctly — that
/// pressing Continue asks for permission and not before, that a refusal lands in the state with the
/// System Settings button, that Select All respects a search, and that the primary button cannot
/// resolve an ambiguity. Each of those is a bug that unit tests on `ContactImportService` would
/// happily pass through.
///
/// It drives `ContactImportModel`, which is what every screen in the flow reads. No `CNContactStore`
/// is constructed, and no real contact is touched.
@Suite("Contact onboarding flow")
@MainActor
struct ContactOnboardingFlowTests {
    typealias Fixture = ContactImportTests.Fixture

    func model(_ fixture: Fixture) -> ContactImportModel {
        ContactImportModel(services: fixture.services)
    }

    /// Phases compare by shape rather than by payload, which is what the assertions care about.
    func isExplaining(_ phase: ContactImportModel.Phase) -> Bool {
        if case .explaining = phase { return true }
        return false
    }

    func isReviewing(_ phase: ContactImportModel.Phase) -> Bool {
        if case .reviewing = phase { return true }
        return false
    }

    func isFinished(_ phase: ContactImportModel.Phase) -> Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: - Permission

    /// Acceptance 1: an explanation before the prompt, never the other way round.
    @Test("Opening the flow explains itself and asks for nothing")
    func explanationComesFirst() async throws {
        let fixture = try Fixture(authorization: .notRequested)
        let model = self.model(fixture)

        await model.prepare()

        #expect(isExplaining(model.phase))
        #expect(
            await fixture.provider.authorization == .notRequested,
            "preparing the screen must not trigger the system prompt"
        )
    }

    /// Acceptance 2.
    @Test("Continuing asks for access and lands in review")
    func continuingRequestsAccess() async throws {
        let fixture = try Fixture(authorization: .notRequested)
        let model = self.model(fixture)

        await model.prepare()
        await model.requestAccess()

        #expect(await fixture.provider.authorization == .authorized)
        #expect(isReviewing(model.phase))
    }

    /// Acceptance 16 and 17.
    @Test("A refusal is a recoverable state, and the rest of People still works")
    func refusalIsRecoverable() async throws {
        let fixture = try Fixture(authorization: .notRequested)
        await fixture.provider.setAuthorization(.notRequested)

        // A provider that will refuse.
        let refusing = FixtureContactsProvider(
            contacts: [], authorization: .notRequested, grantsAccess: false
        )
        let services = AppServices.inMemory(
            populated: false,
            contactsProvider: { refusing },
            defaults: UserDefaults(suiteName: "refusal-\(UUID().uuidString)") ?? .standard
        )
        let model = ContactImportModel(services: services)

        await model.prepare()
        await model.requestAccess()

        guard case .accessDenied = model.phase else {
            Issue.record("expected the denied state, got \(model.phase)")
            return
        }

        // And the CRM is entirely usable by hand.
        let person = try services.persons.createPerson(PersonDraft(fullName: "Typed By Hand"))
        #expect(try services.persons.allPeople(includingPlaceholders: true).count == 1)
        #expect(person.displayTitle == "Typed By Hand")
    }

    @Test("A restricted Mac reads differently from a refusal")
    func restrictedIsItsOwnState() async throws {
        let fixture = try await Fixture.ready(authorization: .restricted)
        let model = self.model(fixture)

        await model.prepare()

        guard case .accessRestricted = model.phase else {
            Issue.record("expected the restricted state, got \(model.phase)")
            return
        }
    }

    @Test("An empty address book is a state, not an error")
    func emptyLibrary() async throws {
        let fixture = try await Fixture.ready(contacts: [])
        let model = self.model(fixture)

        await model.prepare()

        guard case .empty = model.phase else {
            Issue.record("expected the empty state, got \(model.phase)")
            return
        }
    }

    // MARK: - Review

    /// Acceptance 3 and 4.
    @Test("The scan discovers contacts and previews before anything is created")
    func scanPreviewsWithoutWriting() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()

        let plan = try #require(model.plan)
        #expect(plan.totalAvailable == ContactFixtures.library.count)
        #expect(plan.count(of: .createPerson) > 0)
        #expect(plan.unusableCount == 1, "the nameless stub is counted rather than imported")
        #expect(plan.containers.count == 3)

        #expect(
            try fixture.people.allPeople(includingPlaceholders: true).isEmpty,
            "a preview must write nothing"
        )
    }

    @Test("The summary reports every outcome it found")
    func summaryCoversOutcomes() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)
        await model.prepare()

        let plan = try #require(model.plan)
        #expect(plan.headline.contains("contacts available"))
        #expect(!plan.summaryLines.isEmpty)
        #expect(plan.summaryLines.allSatisfy { $0.count > 0 })
    }

    /// Acceptance 5.
    @Test("Importing all creates people and links")
    func importAll() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        await model.runImport()

        guard case .finished(let report) = model.phase else {
            Issue.record("expected to finish, got \(model.phase)")
            return
        }
        #expect(report.created > 0)
        #expect(report.isCompleteSuccess)
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == report.changedCount)
    }

    /// Acceptance 6.
    @Test("Importing a chosen subset imports only that subset")
    func importSubset() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        model.deselectAllVisible()

        let wanted = try #require(
            model.visibleProposals.first { $0.outcome == .createPerson }
        )
        model.setSelection(true, for: wanted.id)

        await model.runImport()

        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 1)
        #expect(
            try fixture.people.allPeople(includingPlaceholders: true).first?.displayTitle
                == wanted.contact.displayName
        )
    }

    @Test("Select All respects the current search rather than the whole library")
    func selectAllIsScopedToWhatIsShown() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        model.deselectAllVisible()

        model.searchText = "Arun"
        #expect(model.visibleProposals.count == 1)

        model.selectAllVisible()
        model.searchText = ""

        let plan = try #require(model.plan)
        #expect(
            plan.selectedActionableCount == 1,
            "Select All meaning “including the ones you filtered out” is a trap"
        )
    }

    @Test("Filtering by account narrows the list")
    func containerFilter() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        let all = model.visibleProposals.count

        model.selectedContainerIDs = [ContactFixtures.workContainer.id]
        #expect(model.visibleProposals.count < all)
        #expect(
            model.visibleProposals.allSatisfy {
                $0.contact.containerIdentifier == ContactFixtures.workContainer.id
            }
        )
    }

    @Test("Sorting by outcome puts what will happen first")
    func sortByOutcome() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        model.sortOrder = .outcome

        let ranks = model.visibleProposals.map(\.outcome.sortRank)
        #expect(ranks == ranks.sorted())
    }

    // MARK: - Ambiguity

    /// Acceptance 9 and 10.
    @Test("An ambiguous match is never swept up by the primary button")
    func ambiguousRowsAreNotSelected() async throws {
        let fixture = try await Fixture.ready()

        // Somebody already here who shares Maya's household number under a different name.
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                phones: [LabelledValue(label: "home", value: "512-555-0192")]
            )
        )

        let model = self.model(fixture)
        await model.prepare()

        let ambiguous = model.visibleProposals.filter { $0.outcome == .needsReview }
        #expect(!ambiguous.isEmpty, "the fixture contains a deliberate near-miss")
        #expect(ambiguous.allSatisfy { !$0.isSelected })

        await model.runImport()

        // Nobody ambiguous was created or linked.
        let names = try fixture.people.allPeople(includingPlaceholders: true).map(\.displayTitle)
        #expect(names.count { $0 == "Maya Chen" } == 1, "no silent merge, and no silent duplicate")
    }

    @Test("Resolving an ambiguity by hand then imports it")
    func resolvingAnAmbiguity() async throws {
        let fixture = try await Fixture.ready()
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                phones: [LabelledValue(label: "home", value: "512-555-0192")]
            )
        )

        let model = self.model(fixture)
        await model.prepare()

        let ambiguous = try #require(model.visibleProposals.first { $0.outcome == .needsReview })

        // "They are a different person."
        model.resolve(ambiguous.id, as: .createPerson, personID: nil)
        await model.runImport()

        let names = try fixture.people.allPeople(includingPlaceholders: true).map(\.displayTitle)
        #expect(names.contains(ambiguous.contact.displayName))
    }

    /// Acceptance 8.
    @Test("An existing person is proposed as a match rather than duplicated")
    func existingPersonIsMatched() async throws {
        let fixture = try await Fixture.ready()
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )

        let model = self.model(fixture)
        await model.prepare()

        let maya = try #require(model.visibleProposals.first { $0.contact.id == "fixture-maya" })
        #expect(maya.outcome == .linkToExisting)
        #expect(maya.matchedPersonName == "Maya Chen")

        await model.runImport()
        #expect(
            try fixture.people.allPeople(includingPlaceholders: true).count { $0.displayTitle == "Maya Chen" } == 1
        )
    }

    // MARK: - Idempotency

    /// Acceptance 11.
    @Test("Running the whole flow twice does not create a second library")
    func repeatingTheImportIsSafe() async throws {
        let fixture = try await Fixture.ready()

        let first = self.model(fixture)
        await first.prepare()
        await first.runImport()
        let afterFirst = try fixture.people.allPeople(includingPlaceholders: true).count

        let second = self.model(fixture)
        await second.prepare()

        // The second scan reports them as already linked, and there is nothing left to do.
        let plan = try #require(second.plan)
        #expect(plan.alreadyLinkedCount == afterFirst)
        #expect(!plan.isRunnable)

        await second.runImport()
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == afterFirst)
    }

    @Test("A session records the run for the settings screen")
    func sessionIsRecorded() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        await model.runImport()

        let session = try #require(try fixture.imports.lastSession())
        #expect(session.isFinished)
        #expect(session.createdCount > 0)
        #expect(session.totalConsidered == ContactFixtures.library.count)
    }

    // MARK: - Whole-journey checks

    /// Acceptance 12, 13, and 14, through the flow rather than the service.
    @Test("After an import, a changed number refreshes and the CRM layer is untouched")
    func importThenRefresh() async throws {
        let fixture = try await Fixture.ready()

        let model = self.model(fixture)
        await model.prepare()
        await model.runImport()

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle == "Maya Chen" }
        )

        // Something only the CRM knows.
        try fixture.people.record(
            ObservationDraft(attribute: .significance, value: "Taught me to run a design review"),
            about: person, observedOn: fixture.services.dateProvider.now,
            confidence: .stated, sensitivity: .normal, source: nil
        )

        // The number changes in the address book.
        var updated = ContactFixtures.library[0]
        updated.phoneNumbers = [ContactLabelledValue(label: "mobile", value: "512-555-4242")]
        await fixture.provider.upsert(updated)

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        let report = await coordinator.refresh()

        #expect(report.updated == 1)
        #expect(person.personProfile?.phones.contains { $0.value == "512-555-4242" } == true)

        // The previous value is history, and the CRM layer is exactly as it was.
        let link = try #require(try fixture.imports.link(for: person))
        #expect((link.values ?? []).contains { $0.value == "512-555-0192" && !$0.isCurrent })
        #expect(try fixture.people.ledger(for: person).value(of: .significance)
                    == "Taught me to run a design review")
    }

    /// Acceptance 15, through the flow.
    @Test("Deleting a contact afterwards keeps the person and explains the state")
    func importThenDelete() async throws {
        let fixture = try await Fixture.ready()

        let model = self.model(fixture)
        await model.prepare()
        await model.runImport()

        let before = try fixture.people.allPeople(includingPlaceholders: true).count
        await fixture.provider.remove(identifier: "fixture-maya")

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        await coordinator.refresh()

        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == before)

        let link = try #require(try fixture.imports.link(forContactIdentifier: "fixture-maya"))
        #expect(link.state == .unavailable)
        #expect(link.state.explanation.contains("kept"), "the explanation must not be alarming")
    }

    /// Acceptance 18.
    @Test("A linked person can be unlinked and linked again")
    func unlinkAndRelink() async throws {
        let fixture = try await Fixture.ready()
        let model = self.model(fixture)

        await model.prepare()
        await model.runImport()

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle == "Maya Chen" }
        )

        try fixture.imports.unlink(person)
        #expect(try fixture.imports.link(for: person) == nil)
        #expect(person.personProfile?.emails.isEmpty == false)

        try fixture.imports.relink(person, to: ContactFixtures.library[0])
        #expect(try fixture.imports.link(for: person)?.contactIdentifier == "fixture-maya")
    }

    /// Acceptance 19.
    @Test("A large library scans and reviews without the plan going wrong")
    func largeLibraryFlow() async throws {
        let fixture = try await Fixture.ready(contacts: ContactFixtures.largeLibrary(count: 1500))
        let model = self.model(fixture)

        let started = Date()
        await model.prepare()
        let elapsed = Date().timeIntervalSince(started)

        let plan = try #require(model.plan)
        #expect(plan.totalAvailable == 1500)
        #expect(plan.count(of: .createPerson) == 1500)
        #expect(elapsed < 30, "scanning 1,500 contacts took \(elapsed)s")

        // Search stays responsive over the whole set.
        model.searchText = "Ada"
        #expect(!model.visibleProposals.isEmpty)
        #expect(model.visibleProposals.count < 1500)
    }

    @Test("Four hundred contacts import as one fast transaction")
    func fourHundredContactImport() async throws {
        let fixture = try await Fixture.ready(contacts: ContactFixtures.largeLibrary(count: 400))
        let model = self.model(fixture)
        await model.prepare()

        let started = ContinuousClock.now
        await model.runImport()
        let elapsed = started.duration(to: .now)

        guard case .finished(let report) = model.phase else {
            Issue.record("expected a finished import, got \(model.phase)")
            return
        }
        #expect(report.created == 400)
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 400)
        #expect(elapsed < .seconds(5), "importing 400 contacts took \(elapsed)")
    }

    @Test("Every phase the interface switches over is reachable")
    func phasesAreReachable() async throws {
        // A `switch` with no default is only safe if each case is actually produced somewhere; this
        // is the check that the enum has not grown a state nothing can enter.
        let denied = try await Fixture.ready(authorization: .denied)
        let deniedModel = model(denied)
        await deniedModel.prepare()
        guard case .accessDenied = deniedModel.phase else {
            Issue.record("denied unreachable")
            return
        }

        let restricted = try await Fixture.ready(authorization: .restricted)
        let restrictedModel = model(restricted)
        await restrictedModel.prepare()
        guard case .accessRestricted = restrictedModel.phase else {
            Issue.record("restricted unreachable")
            return
        }

        let empty = try await Fixture.ready(contacts: [])
        let emptyModel = model(empty)
        await emptyModel.prepare()
        guard case .empty = emptyModel.phase else {
            Issue.record("empty unreachable")
            return
        }

        let ready = try await Fixture.ready()
        let readyModel = model(ready)
        await readyModel.prepare()
        #expect(isReviewing(readyModel.phase))

        await readyModel.runImport()
        #expect(isFinished(readyModel.phase))
    }
}
