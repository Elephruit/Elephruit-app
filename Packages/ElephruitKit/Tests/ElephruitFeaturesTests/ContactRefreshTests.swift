import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// Keeping linked contacts current — and what happens when that stops being possible.
///
/// The rule under test throughout is that a refresh may replace a value the app imported and nobody
/// has touched, and may not do anything else. Every other case here is a variation on what "anything
/// else" means: a value the user changed, a contact that disappeared, a permission that went away.
@Suite("Contact refresh")
@MainActor
struct ContactRefreshTests {
    typealias Fixture = ContactImportTests.Fixture

    static func maya(
        emails: [(String, String)] = [("work", "maya@northwind.example")],
        phones: [(String, String)] = [("mobile", "512-555-0192")],
        organization: String = "Northwind Studio"
    ) -> SystemContact {
        SystemContact(
            id: "maya",
            givenName: "Maya",
            familyName: "Chen",
            organizationName: organization,
            emailAddresses: emails.map { ContactLabelledValue(label: $0.0, value: $0.1) },
            phoneNumbers: phones.map { ContactLabelledValue(label: $0.0, value: $0.1) },
            containerIdentifier: ContactFixtures.icloudContainer.id,
            containerName: ContactFixtures.icloudContainer.name
        )
    }

    /// Imports one contact and returns the person and their link.
    func importOne(
        _ contact: SystemContact,
        into fixture: Fixture
    ) throws -> (person: Item, link: SystemContactLink) {
        try fixture.importAll([contact])

        let link = try #require(try fixture.imports.link(forContactIdentifier: contact.id))
        let person = try #require(link.person)
        return (person, link)
    }

    // MARK: - Refreshing values

    @Test("A changed phone number is refreshed")
    func changedPhoneIsRefreshed() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        let updated = Self.maya(phones: [("mobile", "512-555-9999")])
        let result = try fixture.sync.apply(updated, to: link)

        #expect(result.didChange)
        #expect(person.personProfile?.phones.contains { $0.value == "512-555-9999" } == true)
    }

    @Test("A changed email is refreshed")
    func changedEmailIsRefreshed() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        let updated = Self.maya(emails: [("work", "maya.chen@northwind.example")])
        try fixture.sync.apply(updated, to: link)

        #expect(person.personProfile?.emails.contains { $0.value == "maya.chen@northwind.example" } == true)
    }

    /// The reason values are superseded rather than overwritten.
    @Test("The previous value is kept as history, not destroyed")
    func previousValueSurvives() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (_, link) = try importOne(Self.maya(), into: fixture)

        try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        let allPhones = link.values.filter { $0.fieldKey == ContactField.phone }
        #expect(allPhones.count == 2, "the old number is a row that was superseded, not one that was deleted")

        let superseded = try #require(allPhones.first { !$0.isCurrent })
        #expect(superseded.value == "512-555-0192")
        #expect(superseded.supersededAt != nil)
        #expect(superseded.firstObservedAt <= superseded.supersededAt ?? .distantPast)
    }

    @Test("An unchanged contact records that it was seen, and nothing else")
    func unchangedContactIsNotRewritten() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (_, link) = try importOne(Self.maya(), into: fixture)

        let before = link.currentValues.count
        let result = try fixture.sync.apply(Self.maya(), to: link)

        #expect(!result.didChange)
        #expect(link.currentValues.count == before)
        #expect(link.lastRefreshedAt != nil)
    }

    @Test("A field the contact gains is added")
    func newFieldIsAdded() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        let updated = Self.maya(
            emails: [("work", "maya@northwind.example"), ("home", "maya@example.com")]
        )
        try fixture.sync.apply(updated, to: link)

        #expect(person.personProfile?.emails.count == 2)
        #expect(link.currentValues.contains { $0.fieldKey == ContactField.email && $0.label == "home" })
    }

    // MARK: - Local overrides

    /// The rule that makes editing here safe.
    @Test("A value the user changed here is never overwritten by a refresh")
    func overriddenValueIsNotOverwritten() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        try fixture.sync.markOverridden(
            person: person, field: ContactField.phone, label: "mobile", newValue: "512-555-0000"
        )

        let result = try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        #expect(person.personProfile?.phones.contains { $0.value == "512-555-0000" } == true,
                "the user's value stands")
        #expect(person.personProfile?.phones.contains { $0.value == "512-555-9999" } == false)
        #expect(result.newConflicts == 1, "and the disagreement is recorded rather than discarded")
    }

    @Test("The disagreement is reported as a conflict with both values")
    func conflictIsReported() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        try fixture.sync.markOverridden(
            person: person, field: ContactField.phone, label: "mobile", newValue: "512-555-0000"
        )
        try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        let conflicts = try fixture.sync.conflicts()
        let conflict = try #require(conflicts.first)

        #expect(conflict.localValue == "512-555-0000")
        #expect(conflict.systemValue == "512-555-9999")
        #expect(conflict.personName == "Maya Chen")
        #expect(conflict.summary.contains("you have"))
    }

    @Test("Taking the system value supersedes the local one and updates the page")
    func resolvingTakesTheSystemValue() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        try fixture.sync.markOverridden(
            person: person, field: ContactField.phone, label: "mobile", newValue: "512-555-0000"
        )
        try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        let conflict = try #require(try fixture.sync.conflicts().first)
        try fixture.sync.resolveConflictTakingSystemValue(conflict.id)

        #expect(try fixture.sync.conflicts().isEmpty)
        #expect(person.personProfile?.phones.contains { $0.value == "512-555-9999" } == true)
        #expect(link.values.contains { $0.value == "512-555-0000" && !$0.isCurrent },
                "and the value they had chosen is still on record")
    }

    @Test("Keeping the local value clears the conflict without changing anything")
    func resolvingKeepsTheLocalValue() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        try fixture.sync.markOverridden(
            person: person, field: ContactField.phone, label: "mobile", newValue: "512-555-0000"
        )
        try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        let conflict = try #require(try fixture.sync.conflicts().first)
        try fixture.sync.resolveConflictKeepingLocalValue(conflict.id)

        #expect(try fixture.sync.conflicts().isEmpty)
        #expect(person.personProfile?.phones.contains { $0.value == "512-555-0000" } == true)
    }

    // MARK: - CRM data is never touched

    /// The promise the whole module rests on.
    @Test("A refresh leaves notes, facts, relationships, and history untouched")
    func crmDataSurvivesARefresh() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, link) = try importOne(Self.maya(), into: fixture)

        // A CRM layer that Contacts knows nothing about.
        try fixture.people.record(
            ObservationDraft(attribute: .significance, value: "Taught me how to run a design review"),
            about: person, observedOn: fixture.services.dateProvider.now,
            confidence: .stated, sensitivity: .normal, source: nil
        )
        try fixture.people.record(
            ObservationDraft(attribute: .reflection, value: "quietly unhappy at Northwind"),
            about: person, observedOn: fixture.services.dateProvider.now,
            confidence: .stated, sensitivity: .restricted, source: nil
        )

        let jack = try fixture.people.resolveOrCreatePlaceholder(named: "Jack Chen")
        try fixture.people.relate(person, to: jack, as: .child, label: "son")

        let note = try fixture.services.items.create(ItemDraft(kind: .note, title: "Coffee"))
        try fixture.services.items.link(note, to: person, kind: .mentions)

        try fixture.services.items.update(person) { $0.isFavorite = true }

        // Something changes in the address book.
        try fixture.sync.apply(Self.maya(phones: [("mobile", "512-555-9999")]), to: link)

        let ledger = try fixture.people.ledger(for: person)
        #expect(ledger.value(of: .significance) == "Taught me how to run a design review")
        #expect(ledger.current(.reflection).first?.value == "quietly unhappy at Northwind")
        #expect(try fixture.people.relationships(of: person).count == 1)
        #expect(try fixture.services.personWorkspace.timeline(for: person).contains { $0.id == note.id })
        #expect(person.isFavorite)
    }

    // MARK: - Disappearance

    /// The most important thing this layer does not do.
    @Test("A deleted system contact does not delete the CRM person")
    func deletedContactKeepsThePerson() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        let (person, link) = try importOne(Self.maya(), into: fixture)
        let personID = person.id

        await fixture.provider.remove(identifier: "maya")

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        let outcome = await coordinator.refresh(link)

        #expect(outcome == .wentUnavailable)
        #expect(link.state == .unavailable)
        #expect(link.unavailableSince != nil)

        // The person is still there, with everything they had.
        let survivor = try #require(try fixture.people.person(id: personID))
        #expect(survivor.deletedAt == nil)
        #expect(survivor.personProfile?.phones.isEmpty == false, "the last known values are kept")
    }

    @Test("A contact that comes back is found again")
    func recoveredContact() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        let (_, link) = try importOne(Self.maya(), into: fixture)
        let coordinator = ContactRefreshCoordinator(services: fixture.services)

        await fixture.provider.remove(identifier: "maya")
        #expect(await coordinator.refresh(link) == .wentUnavailable)

        await fixture.provider.upsert(Self.maya())
        #expect(await coordinator.refresh(link) == .recovered)
        #expect(link.state == .linked)
    }

    /// The case the identity signature exists for.
    @Test("A contact whose identifier changed is re-found by its email")
    func identifierChangeIsSurvived() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        let (_, link) = try importOne(Self.maya(), into: fixture)
        let coordinator = ContactRefreshCoordinator(services: fixture.services)

        // The account was removed and re-added: same person, new identifier.
        await fixture.provider.remove(identifier: "maya")
        var reAdded = Self.maya()
        reAdded.id = "maya-after-reimport"
        await fixture.provider.upsert(reAdded)

        let outcome = await coordinator.refresh(link)

        #expect(outcome != .wentUnavailable, "the person did not go anywhere, only the identifier did")
        #expect(link.contactIdentifier == "maya-after-reimport")
        #expect(link.state == .linked)
    }

    // MARK: - Permission

    @Test("Revoked access marks links unreadable and keeps every person")
    func revokedAccessKeepsEverything() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        let (person, link) = try importOne(Self.maya(), into: fixture)
        let coordinator = ContactRefreshCoordinator(services: fixture.services)

        await fixture.provider.setAuthorization(.denied)
        await coordinator.refresh()

        #expect(link.state == .unreadable)
        #expect(link.state != .unavailable, "a permission is not a missing contact, and reads differently")
        #expect(try fixture.people.person(id: person.id) != nil)
        #expect(person.personProfile?.phones.isEmpty == false)
    }

    @Test("Restored access makes links live again")
    func restoredAccess() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        let (_, link) = try importOne(Self.maya(), into: fixture)
        let coordinator = ContactRefreshCoordinator(services: fixture.services)

        await fixture.provider.setAuthorization(.denied)
        await coordinator.refresh()
        #expect(link.state == .unreadable)

        await fixture.provider.setAuthorization(.authorized)
        await coordinator.refresh()
        #expect(link.state == .linked)
    }

    @Test("Denied access does not stop manual CRM use")
    func deniedAccessLeavesTheCRMUsable() async throws {
        let fixture = try Fixture(contacts: [], authorization: .denied)

        let person = try fixture.people.createPerson(
            PersonDraft(fullName: "Someone Typed By Hand",
                        emails: [LabelledValue(label: "work", value: "typed@example.com")])
        )
        try fixture.people.record(
            ObservationDraft(attribute: .like, value: "long walks"),
            about: person, observedOn: fixture.services.dateProvider.now,
            confidence: .stated, sensitivity: .normal, source: nil
        )

        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 1)
        #expect(try fixture.people.ledger(for: person).value(of: .like) == "long walks")
        #expect(try fixture.imports.linkedCount() == 0)
    }

    // MARK: - Incremental refresh

    @Test("A stored token skips contacts that did not change")
    func incrementalRefreshSkipsUnchanged() async throws {
        let alice = SystemContact(
            id: "alice", givenName: "Alice", familyName: "Nakamura",
            emailAddresses: [ContactLabelledValue(label: "work", value: "alice@example.com")]
        )
        let bob = SystemContact(
            id: "bob", givenName: "Bob", familyName: "Oyelaran",
            emailAddresses: [ContactLabelledValue(label: "work", value: "bob@example.com")]
        )

        let fixture = try Fixture(contacts: [alice, bob])
        await fixture.enableContacts()
        try fixture.importAll([alice, bob])

        let token = try #require(await fixture.provider.currentHistoryToken())
        fixture.services.contacts.storeHistoryToken(token)

        // Only Alice changes.
        var changedAlice = alice
        changedAlice.phoneNumbers = [ContactLabelledValue(label: "mobile", value: "512-555-0001")]
        await fixture.provider.upsert(changedAlice)

        let delta = try #require(await fixture.services.contacts.changesSinceStoredToken())
        #expect(delta.changedIdentifiers == ["alice"])
        #expect(delta.deletedIdentifiers.isEmpty)
    }

    /// A missing or expired token is a normal state, not a failure.
    @Test("An unusable token asks for a full reconciliation instead of failing")
    func invalidTokenFallsBackToFullReconciliation() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()
        try fixture.importAll([Self.maya()])

        let token = try #require(await fixture.provider.currentHistoryToken())
        fixture.services.contacts.storeHistoryToken(token)

        // The store forgets its history, as it does after a long gap or a rebuild.
        await fixture.provider.expireHistory()

        #expect(
            await fixture.services.contacts.changesSinceStoredToken() == nil,
            "nil is the caller's cue to reconcile fully"
        )

        // And a full refresh still works and still updates.
        await fixture.provider.upsert(Self.maya(phones: [("mobile", "512-555-7777")]))

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        let report = await coordinator.refresh()

        #expect(report.checked == 1)
        #expect(report.updated == 1)
    }

    @Test("Garbage in place of a token is handled rather than trusted")
    func corruptTokenIsRejected() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()

        fixture.services.contacts.storeHistoryToken(Data("not a token".utf8))
        #expect(await fixture.services.contacts.changesSinceStoredToken() == nil)
    }

    // MARK: - Unlink and relink

    @Test("Unlinking keeps both records and stops refreshing")
    func unlinkKeepsBoth() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, _) = try importOne(Self.maya(), into: fixture)

        try fixture.imports.unlink(person)

        #expect(try fixture.imports.link(for: person) == nil)
        #expect(person.personProfile?.contactsIdentifier == nil)
        #expect(person.personProfile?.phones.isEmpty == false, "unlinking is not a way to lose a number")
        #expect(await fixture.provider.systemContact(withIdentifier: "maya") != nil)
    }

    @Test("Relinking points a person at a different contact")
    func relinkWorks() async throws {
        let other = SystemContact(
            id: "other", givenName: "Maya", familyName: "Chen",
            emailAddresses: [ContactLabelledValue(label: "work", value: "m.chen@elsewhere.example")]
        )

        let fixture = try Fixture(contacts: [Self.maya(), other])
        let (person, _) = try importOne(Self.maya(), into: fixture)

        try fixture.imports.relink(person, to: other)

        let link = try #require(try fixture.imports.link(for: person))
        #expect(link.contactIdentifier == "other")
        #expect(person.personProfile?.emails.contains { $0.value == "m.chen@elsewhere.example" } == true)
    }

    @Test("Re-importing after an unlink does not create a second person")
    func unlinkThenReimport() throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        let (person, _) = try importOne(Self.maya(), into: fixture)

        try fixture.imports.unlink(person)
        try fixture.importAll([Self.maya()])

        // The email still matches, so the second pass proposes a link rather than a new person.
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 1)
    }

    // MARK: - Reporting

    @Test("A refresh reports what it did in plain language")
    func refreshReportReadsWell() async throws {
        let fixture = try Fixture(contacts: [Self.maya()])
        await fixture.enableContacts()
        try fixture.importAll([Self.maya()])

        await fixture.provider.upsert(Self.maya(phones: [("mobile", "512-555-3333")]))

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        let report = await coordinator.refresh()

        #expect(report.summary.contains("updated"))
        #expect(coordinator.linkedCount == 1)
        #expect(fixture.services.contacts.lastRefreshedAt != nil)
    }

    @Test("With nothing linked, the status line says so rather than looking broken")
    func emptyStatus() async throws {
        let fixture = try Fixture(contacts: [])
        await fixture.enableContacts()

        let coordinator = ContactRefreshCoordinator(services: fixture.services)
        let report = await coordinator.refresh()

        #expect(report.checked == 0)
        #expect(report.summary == "Nothing linked yet.")
    }
}
