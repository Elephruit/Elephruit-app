import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// Importing the address book, against a fixture store.
///
/// ### No test here touches a real address book
/// Every one runs against ``FixtureContactsProvider``, which is an in-memory list of invented people
/// with `example.com` addresses and 555 numbers. `CNContactStore` is never constructed. That is not
/// only a privacy rule — a test that read the developer's contacts would pass or fail depending on
/// whose machine it ran on, which is no test at all.
@Suite("Contact import")
@MainActor
struct ContactImportTests {
    /// A CRM and a synthetic address book, wired together through the real composition root.
    ///
    /// The provider is injected, so the whole flow — service, import, sync, coordinator — is the code
    /// the app runs, with `CNContactStore` never constructed. The defaults suite is scratch, so
    /// enabling Contacts here leaves nothing behind for the user or the next test.
    @MainActor
    struct Fixture {
        let services: AppServices
        let provider: FixtureContactsProvider
        let defaults: UserDefaults

        var people: any PersonRepository { services.persons }
        var imports: ContactImportService { services.contactImports }
        var sync: ContactSyncService { services.contactSync }
        var identity: PersonIdentityService { services.personIdentity }
        var calendar: Calendar { services.dateProvider.calendar }

        @MainActor
        init(
            contacts: [SystemContact] = ContactFixtures.library,
            authorization: IntegrationAuthorization = .authorized,
            dateProvider: FixedDateProvider = .reference
        ) throws {
            let provider = FixtureContactsProvider(
                contacts: contacts,
                containers: ContactFixtures.containers,
                authorization: authorization
            )
            self.provider = provider

            let suiteName = "contacts-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            self.defaults = defaults

            self.services = AppServices.inMemory(
                dateProvider: dateProvider,
                populated: false,
                contactsProvider: { provider },
                defaults: defaults
            )
        }

        /// Turns the integration on without going through the interface.
        @MainActor
        func enableContacts() async {
            await services.contacts.enable()
        }

        /// Plans every contact, the way the model does but without the interface.
        @MainActor
        func plan(_ contacts: [SystemContact]) throws -> [ContactImportProposal] {
            let context = try imports.matchingContext()
            return contacts.map { ContactMatcher.propose($0, in: context) }
        }

        @MainActor
        @discardableResult
        func importAll(_ contacts: [SystemContact]) throws -> ContactImportReport {
            var report = ContactImportReport()
            for proposal in try plan(contacts) where proposal.outcome.changesTheDatabase {
                switch try imports.apply(proposal, sessionID: nil) {
                case .createPerson: report.created += 1
                case .linkToExisting: report.linked += 1
                default: report.skipped += 1
                }
            }
            return report
        }
    }

    static func contact(
        id: String,
        given: String = "",
        family: String = "",
        emails: [(String, String)] = [],
        phones: [(String, String)] = [],
        organization: String = ""
    ) -> SystemContact {
        SystemContact(
            id: id,
            givenName: given,
            familyName: family,
            organizationName: organization,
            emailAddresses: emails.map { ContactLabelledValue(label: $0.0, value: $0.1) },
            phoneNumbers: phones.map { ContactLabelledValue(label: $0.0, value: $0.1) }
        )
    }

    // MARK: - Normalisation

    @Test("A name, an email, and a phone normalise to a stable signature")
    func normalisation() {
        let contact = Self.contact(
            id: "a", given: "Maya", family: "Chen",
            emails: [("work", "MAYA@Example.COM")],
            phones: [("mobile", "+1 (512) 555-0192")]
        )

        let signature = ContactIdentitySignature(contact: contact)
        #expect(signature.nameKey == TextNormalizer.foldedForMatching("Maya Chen"))
        #expect(signature.emailKeys == ["maya@example.com"])
        #expect(signature.phoneKeys == ["5125550192"])
    }

    @Test("The signature survives a round trip through storage")
    func signatureRoundTrip() {
        let original = ContactIdentitySignature(
            contact: Self.contact(
                id: "a", given: "Maya", family: "Chen",
                emails: [("work", "maya@example.com")],
                phones: [("mobile", "512-555-0192")]
            )
        )

        let decoded = ContactIdentitySignature.decode(original.storageKey)
        #expect(decoded == original)
    }

    @Test("A short number is not treated as a phone signal")
    func shortNumbersAreIgnored() {
        let signature = ContactIdentitySignature(
            contact: Self.contact(id: "a", given: "Maya", phones: [("ext", "1234")])
        )
        #expect(signature.phoneKeys.isEmpty, "an extension is not an identifier")
    }

    // MARK: - Matching

    @Test("An exact email match proposes a link, not a second person")
    func exactEmailMatchLinks() throws {
        let fixture = try Fixture()
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                emails: [LabelledValue(label: "work", value: "maya@northwind.example")]
            )
        )

        let proposal = try #require(
            try fixture.plan([ContactFixtures.library[0]]).first
        )
        #expect(proposal.outcome == .linkToExisting)
        #expect(proposal.matchedPersonName == "Maya Chen")
        #expect(proposal.evidence.contains(.sharedEmail))
    }

    @Test("An exact phone match with an agreeing name proposes a link")
    func exactPhoneMatchLinks() throws {
        let fixture = try Fixture()
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Wei Lin",
                phones: [LabelledValue(label: "mobile", value: "+1 512 555 0155")]
            )
        )

        let contact = Self.contact(
            id: "lin", given: "Wei", family: "Lin", phones: [("Boat", "512-555-0155")]
        )
        let proposal = try #require(try fixture.plan([contact]).first)

        #expect(proposal.outcome == .linkToExisting)
        #expect(proposal.evidence.contains(.sharedPhone))
    }

    /// The failure this whole layer exists to prevent.
    @Test("Two people with the same name are never linked to each other")
    func sameNameIsNotAMatch() throws {
        let fixture = try Fixture()
        try fixture.people.createPerson(PersonDraft(fullName: "Jordan Reyes"))

        let other = Self.contact(
            id: "other-jordan", given: "Jordan", family: "Reyes",
            emails: [("work", "different@example.com")]
        )
        let proposal = try #require(try fixture.plan([other]).first)

        #expect(proposal.outcome == .createPerson, "a shared name is the weakest evidence there is")
    }

    @Test("A shared phone with a different name goes to review, never straight to a link")
    func ambiguousMatchNeedsReview() throws {
        let fixture = try Fixture()
        try fixture.people.createPerson(
            PersonDraft(
                fullName: "Maya Chen",
                phones: [LabelledValue(label: "home", value: "512-555-0192")]
            )
        )

        // Sam shares the household number and is a different person.
        let sam = Self.contact(
            id: "sam", given: "Sam", family: "Okonkwo", phones: [("home", "512-555-0192")]
        )
        let proposal = try #require(try fixture.plan([sam]).first)

        #expect(proposal.outcome == .needsReview)
        #expect(!proposal.isSelected, "an ambiguous row must not be swept up by the primary button")
    }

    @Test("A contact with no name of any kind is counted, not imported")
    func namelessContactIsUnusable() throws {
        let fixture = try Fixture()
        let nameless = Self.contact(id: "nameless", emails: [("other", "no-reply@example.com")])

        let proposal = try #require(try fixture.plan([nameless]).first)
        #expect(proposal.outcome == .unusable)
        #expect(!proposal.outcome.changesTheDatabase)
    }

    @Test("An organisation-only record still has a usable name")
    func organisationRecordsAreImportable() throws {
        let fixture = try Fixture()
        let org = Self.contact(id: "org", organization: "Rosewood Building Management")

        let proposal = try #require(try fixture.plan([org]).first)
        #expect(proposal.outcome == .createPerson)
        #expect(proposal.contact.displayName == "Rosewood Building Management")
    }

    // MARK: - Unified contacts

    /// macOS already knows the iCloud Maya and the Google Maya are one person, and the app inherits
    /// that rather than re-deriving it.
    @Test("A unified contact becomes exactly one CRM person")
    func unifiedContactBecomesOnePerson() throws {
        let fixture = try Fixture()

        // The provider returns unified records, so one identifier arrives once even though the
        // person exists in two accounts.
        let unified = Self.contact(
            id: "unified-maya", given: "Maya", family: "Chen",
            emails: [("work", "maya@northwind.example"), ("home", "maya@example.com")],
            phones: [("mobile", "512-555-0192")]
        )

        try fixture.importAll([unified])
        try fixture.importAll([unified])

        let people = try fixture.people.allPeople(includingPlaceholders: true)
        #expect(people.count == 1)
    }

    // MARK: - Already linked

    @Test("A contact that is already linked is reported, not re-imported")
    func alreadyLinkedIsReported() throws {
        let fixture = try Fixture()
        let contact = ContactFixtures.library[1]

        try fixture.importAll([contact])

        let proposal = try #require(try fixture.plan([contact]).first)
        #expect(proposal.outcome == .alreadyLinked)
        #expect(!proposal.outcome.changesTheDatabase)
    }

    @Test("Re-running the whole import creates nothing the second time")
    func importIsIdempotent() throws {
        let fixture = try Fixture()

        let first = try fixture.importAll(ContactFixtures.library)
        let countAfterFirst = try fixture.people.allPeople(includingPlaceholders: true).count
        #expect(first.created > 0)

        let second = try fixture.importAll(ContactFixtures.library)
        let countAfterSecond = try fixture.people.allPeople(includingPlaceholders: true).count

        #expect(second.created == 0)
        #expect(second.linked == 0)
        #expect(countAfterSecond == countAfterFirst, "a retry must be a no-op, not a second library")
    }

    @Test("Applying the same proposal twice writes once")
    func applyIsIdempotent() throws {
        let fixture = try Fixture()
        let proposal = try #require(try fixture.plan([ContactFixtures.library[1]]).first)

        #expect(try fixture.imports.apply(proposal, sessionID: nil) == .createPerson)
        #expect(
            try fixture.imports.apply(proposal, sessionID: nil) == .alreadyLinked,
            "the link is re-checked at write time, which is what makes a retry safe"
        )
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 1)
    }

    // MARK: - Imported fields

    @Test("Labels are preserved, including custom ones")
    func labelsSurviveImport() throws {
        let fixture = try Fixture()
        try fixture.importAll([ContactFixtures.library[1]])

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle.contains("Arun") }
        )
        let phones = person.personProfile?.phones ?? []
        #expect(phones.contains { $0.label == "Clinic front desk" }, "a custom label is what they called it")
    }

    @Test("A birthday with no year keeps having no year")
    func birthdayWithoutAYear() throws {
        let fixture = try Fixture()
        try fixture.importAll([ContactFixtures.library[1]])

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle.contains("Arun") }
        )
        let birthday = person.personProfile?.birthdayDate(calendar: fixture.calendar)

        #expect(birthday?.month == 4)
        #expect(birthday?.day == 2)
        #expect(birthday?.hasYear == false, "a placeholder year must never be invented")
    }

    @Test("A birthday with a year keeps it")
    func birthdayWithAYear() throws {
        let fixture = try Fixture()
        try fixture.importAll([ContactFixtures.library[0]])

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle == "Maya Chen" }
        )
        let birthday = person.personProfile?.birthdayDate(calendar: fixture.calendar)

        #expect(birthday?.year == 1987)
        #expect(birthday?.hasYear == true)
    }

    @Test("Names, phonetics, and organisation all arrive")
    func richFieldsArrive() throws {
        let fixture = try Fixture()
        try fixture.importAll([ContactFixtures.library[0]])

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle == "Maya Chen" }
        )
        let profile = try #require(person.personProfile)

        #expect(profile.givenName == "Maya")
        #expect(profile.familyName == "Chen")
        #expect(profile.nickname == "Maya")
        #expect(profile.pronunciation == "MY-uh")
        #expect(profile.organizationName == "Northwind Studio")
        #expect(profile.roleTitle?.contains("Head of Design") == true)
        #expect(profile.addresses.isEmpty == false)
        #expect(profile.websites.isEmpty == false)
    }

    /// Contacts' relation fields are names somebody typed in another app, not links.
    @Test("Contact relations do not become CRM relationships")
    func relationsAreNotResolvedAutomatically() throws {
        let fixture = try Fixture()
        // Maya's record names a spouse.
        #expect(!ContactFixtures.library[0].relations.isEmpty)

        try fixture.importAll([ContactFixtures.library[0]])

        let person = try #require(
            try fixture.people.allPeople(includingPlaceholders: true).first { $0.displayTitle == "Maya Chen" }
        )
        #expect(
            try fixture.people.relationships(of: person).isEmpty,
            "a relation is a string, and inventing a family from it is exactly what this must not do"
        )
    }

    // MARK: - Provenance

    @Test("Every imported value records where it came from and when")
    func provenanceIsRecorded() throws {
        let fixture = try Fixture()
        try fixture.importAll([ContactFixtures.library[0]])

        let link = try #require(try fixture.imports.link(forContactIdentifier: "fixture-maya"))
        #expect(link.state == .linked)
        #expect(link.containerName == "iCloud")
        #expect(!link.identitySignature.isEmpty)

        let values = link.currentValues
        #expect(values.contains { $0.fieldKey == ContactField.email && $0.label == "work" })
        #expect(values.contains { $0.fieldKey == ContactField.phone && $0.label == "mobile" })
        #expect(values.allSatisfy { $0.origin == .imported })
    }

    @Test("A link says which account it came from, using only the system's own name")
    func containerNameIsTheSystems() throws {
        let fixture = try Fixture()
        try fixture.importAll(ContactFixtures.library)

        let link = try #require(try fixture.imports.link(forContactIdentifier: "fixture-jordan-reyes"))
        #expect(link.containerName == "Northwind Directory")
        #expect(link.containerIdentifier == ContactFixtures.workContainer.id)
    }

    // MARK: - Cancellation and failure

    @Test("Stopping part-way leaves what was written complete and re-runnable")
    func partialImportIsConsistent() throws {
        let fixture = try Fixture()
        let proposals = try fixture.plan(ContactFixtures.library)
            .filter(\.outcome.changesTheDatabase)

        // Half of them, as a cancellation would.
        for proposal in proposals.prefix(2) {
            try fixture.imports.apply(proposal, sessionID: nil)
        }
        let partial = try fixture.people.allPeople(includingPlaceholders: true).count
        #expect(partial == 2)

        // Resuming does the rest and repeats none.
        var created = 0
        for proposal in proposals {
            if try fixture.imports.apply(proposal, sessionID: nil) == .createPerson { created += 1 }
        }

        #expect(created == proposals.count - 2)
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == proposals.count)
    }

    @Test("A session records what happened, including what failed")
    func sessionRecordsOutcome() throws {
        let fixture = try Fixture()
        let session = try fixture.imports.beginSession()

        let report = ContactImportReport(
            created: 4, linked: 1, skipped: 2,
            failures: [ContactImportFailure(contactID: "x", name: "Someone", reason: "unreadable")]
        )
        try fixture.imports.finish(session, report: report, totalConsidered: 8)

        let stored = try #require(try fixture.imports.lastSession())
        #expect(stored.createdCount == 4)
        #expect(stored.failures.count == 1)
        #expect(!stored.report.isCompleteSuccess)
        #expect(stored.report.summary.contains("could not be read"))
    }

    // MARK: - Permission states

    @Test("Nothing is read when access has not been granted")
    func noAccessReadsNothing() async throws {
        let provider = FixtureContactsProvider(
            contacts: ContactFixtures.library,
            containers: ContactFixtures.containers,
            authorization: .notRequested
        )

        #expect(await provider.accounts().isEmpty)
        #expect(await provider.systemContact(withIdentifier: "fixture-maya") == nil)

        let counter = BatchCounter()
        _ = await provider.enumerateContacts(inContainers: []) { batch in await counter.add(batch.count) }
        #expect(await counter.total == 0)
    }

    @Test("A refusal is remembered rather than re-asked")
    func refusalIsFinal() async throws {
        let provider = FixtureContactsProvider(
            contacts: [], authorization: .notRequested, grantsAccess: false
        )

        #expect(await provider.requestAccess() == .denied)
        #expect(await provider.requestAccess() == .denied, "asking twice must not change the answer")
    }

    @Test("Access can be granted, and then revoked from outside the app")
    func revocation() async throws {
        let provider = FixtureContactsProvider(
            contacts: ContactFixtures.library,
            containers: ContactFixtures.containers,
            authorization: .notRequested
        )

        #expect(await provider.requestAccess() == .authorized)
        #expect(await provider.systemContact(withIdentifier: "fixture-maya") != nil)

        await provider.setAuthorization(.denied)
        #expect(await provider.systemContact(withIdentifier: "fixture-maya") == nil)
    }

    // MARK: - Performance

    /// Not a benchmark — a guard that the matching pass is linear in the library and does not
    /// quietly become quadratic in the *CRM*.
    @Test("A large library plans in reasonable time")
    func largeLibraryPlans() throws {
        let fixture = try Fixture(contacts: [])

        for index in 0..<200 {
            try fixture.people.createPerson(
                PersonDraft(
                    fullName: "Existing Person \(index)",
                    emails: [LabelledValue(label: "work", value: "existing\(index)@example.com")]
                )
            )
        }

        let library = ContactFixtures.largeLibrary(count: 2000)
        let context = try fixture.imports.matchingContext()

        let started = Date()
        let proposals = library.map { ContactMatcher.propose($0, in: context) }
        let elapsed = Date().timeIntervalSince(started)

        #expect(proposals.count == 2000)
        #expect(proposals.allSatisfy { $0.outcome == .createPerson })
        #expect(elapsed < 20, "2,000 contacts against 200 people took \(elapsed)s")
    }
}


/// Counts streamed batches from a `@Sendable` callback.
private actor BatchCounter {
    private(set) var total = 0

    func add(_ count: Int) {
        total += count
    }
}
