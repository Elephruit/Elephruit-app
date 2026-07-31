import ElephruitCore
import Foundation

/// A Contacts store made of synthetic records.
///
/// ### Why this ships in the app rather than only in the tests
/// Two reasons, and the second is the important one.
///
/// The first is ordinary: tests must never touch the developer's real address book, and a protocol
/// with only a live implementation invites exactly that. Every test in this module runs against this.
///
/// The second is that a reviewer needs to *see* the import — the onboarding, the review counts, the
/// ambiguous match, the deleted contact — without handing the app their own contacts to practise on.
/// A synthetic library reachable from development mode makes the whole flow demonstrable with nobody's
/// real data involved, which is the only honest way to show a feature like this.
///
/// Every name here is invented, and every address is in a reserved example domain.
public actor FixtureContactsProvider: ContactsProviding {
    private var contacts: [SystemContact]
    private var containers: [ContactAccount]
    private var currentAuthorization: IntegrationAuthorization

    /// Whether `requestAccess` will grant. Set by a test to exercise the denied path.
    private var grantsAccess: Bool

    /// Bumped on every mutation and used as the opaque history token.
    ///
    /// A token is only required to be opaque and comparable, so a counter is a faithful stand-in — and
    /// it makes "the token is no longer valid" a state a test can create deliberately.
    private var version = 1

    /// What changed at each version, so an incremental fetch can answer from a token.
    private var history: [Int: ContactChangeSet] = [:]

    /// Versions before this have been forgotten, which is what an expired token looks like.
    private var oldestUsableVersion = 1

    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(
        contacts: [SystemContact] = [],
        containers: [ContactAccount] = [],
        authorization: IntegrationAuthorization = .notRequested,
        grantsAccess: Bool = true
    ) {
        self.contacts = contacts
        self.containers = containers
        self.currentAuthorization = authorization
        self.grantsAccess = grantsAccess
    }

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization { currentAuthorization }

    public func requestAccess() async -> IntegrationAuthorization {
        guard currentAuthorization == .notRequested else { return currentAuthorization }
        currentAuthorization = grantsAccess ? .authorized : .denied
        return currentAuthorization
    }

    /// Simulates the user changing their mind in System Settings.
    public func setAuthorization(_ authorization: IntegrationAuthorization) {
        currentAuthorization = authorization
    }

    // MARK: - Reading

    public func accounts() async -> [ContactAccount] {
        guard currentAuthorization == .authorized else { return [] }
        return containers
    }

    public func contacts(matching query: String) async -> [ContactSummary] {
        guard currentAuthorization == .authorized else { return [] }

        let key = TextNormalizer.foldedForMatching(query)
        guard !key.isEmpty else { return [] }

        return contacts
            .filter { TextNormalizer.foldedForMatching($0.displayName).contains(key) }
            .map(Self.summary(from:))
    }

    public func contact(withIdentifier identifier: String) async -> ContactSummary? {
        guard currentAuthorization == .authorized else { return nil }
        return contacts.first { $0.id == identifier }.map(Self.summary(from:))
    }

    public func enumerateContacts(
        inContainers containerIdentifiers: [String],
        onBatch: @Sendable ([SystemContact]) async -> Void
    ) async -> Int {
        guard currentAuthorization == .authorized else { return 0 }

        let selected = containerIdentifiers.isEmpty
            ? contacts
            : contacts.filter { contact in
                contact.containerIdentifier.map(containerIdentifiers.contains) ?? false
            }

        // Batched like the real one, so a test exercises the same code path the store does.
        for start in stride(from: 0, to: selected.count, by: 200) {
            let end = min(start + 200, selected.count)
            await onBatch(Array(selected[start..<end]))
        }

        return selected.count
    }

    public func systemContact(withIdentifier identifier: String) async -> SystemContact? {
        guard currentAuthorization == .authorized else { return nil }
        return contacts.first { $0.id == identifier }
    }

    /// The same rule the live provider applies: a shared detail *and* an agreeing name.
    ///
    /// A shared number alone would re-link somebody to whoever else is on the household line.
    public func systemContact(matching signature: ContactIdentitySignature) async -> SystemContact? {
        guard currentAuthorization == .authorized else { return nil }

        return contacts.first { candidate in
            ContactIdentitySignature(contact: candidate).stronglyMatches(signature)
        }
    }

    /// Always `nil`.
    ///
    /// A fixture that returned invented image bytes would let a layout bug through by making every
    /// avatar render — the real absence is the more useful default.
    public func thumbnail(forIdentifier identifier: String) async -> Data? { nil }

    // MARK: - Change tracking

    public func currentHistoryToken() async -> Data? {
        guard currentAuthorization == .authorized else { return nil }
        return Data("\(version)".utf8)
    }

    public func changes(since token: Data) async -> ContactChangeSet? {
        guard currentAuthorization == .authorized else { return nil }

        guard let text = String(data: token, encoding: .utf8),
              let since = Int(text),
              since >= oldestUsableVersion
        else {
            // An unreadable or forgotten token. `nil` is the caller's cue to reconcile fully, which
            // is the behaviour worth testing.
            return nil
        }

        var changed = Set<String>()
        var deleted = Set<String>()

        for step in (since + 1)...max(since + 1, version) where step <= version {
            guard let event = history[step] else { continue }
            changed.formUnion(event.changedIdentifiers)
            deleted.formUnion(event.deletedIdentifiers)
        }

        // A contact deleted and then re-added is present, not absent.
        changed.subtract(deleted.filter { identifier in !contacts.contains { $0.id == identifier } })

        return ContactChangeSet(
            changedIdentifiers: changed,
            deletedIdentifiers: deleted,
            newToken: Data("\(version)".utf8)
        )
    }

    public nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<Void>.Continuation, id: UUID) {
        changeContinuations[id] = continuation
    }

    private func unregister(id: UUID) {
        changeContinuations[id] = nil
    }

    private func announceChange() {
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    // MARK: - Writing

    /// Applies a write to the synthetic store, with the same refusals the real one makes.
    ///
    /// Faithful about the refusals in particular: a fixture that always succeeds would let the
    /// caller's handling of a read-only account or a vanished record go untested, and those are the
    /// paths nobody exercises by hand.
    public func write(_ change: ContactWrite) async -> ContactWriteOutcome {
        guard currentAuthorization == .authorized else { return .notPermitted }

        guard let index = contacts.firstIndex(where: { $0.id == change.identifier }) else {
            return .recordMissing
        }

        let container = contacts[index].containerIdentifier
        if let container, containers.first(where: { $0.id == container })?.isReadOnly == true {
            return .accountIsReadOnly
        }

        var updated = contacts[index]
        updated.jobTitle = change.jobTitle
        updated.organizationName = change.organizationName
        updated.emailAddresses = change.emailAddresses
        updated.phoneNumbers = change.phoneNumbers
        updated.urlAddresses = change.urlAddresses

        // Postal addresses are untouched because a write cannot carry them — the same guarantee the
        // real provider makes, asserted here by there being nothing to assign.
        contacts[index] = updated

        version += 1
        history[version] = ContactChangeSet(changedIdentifiers: [change.identifier])
        announceChange()

        return .written
    }

    // MARK: - Mutation, for tests

    /// Adds or replaces a contact, as an edit in the Contacts app would.
    public func upsert(_ contact: SystemContact) {
        version += 1
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        history[version] = ContactChangeSet(changedIdentifiers: [contact.id])
        announceChange()
    }

    /// Removes a contact, as deleting it or removing its account would.
    public func remove(identifier: String) {
        version += 1
        contacts.removeAll { $0.id == identifier }
        history[version] = ContactChangeSet(deletedIdentifiers: [identifier])
        announceChange()
    }

    /// Forgets every token issued so far, which is what an expired history looks like.
    public func expireHistory() {
        oldestUsableVersion = version + 1
        history.removeAll()
    }

    public func replaceAll(with contacts: [SystemContact]) {
        version += 1
        self.contacts = contacts
        history[version] = ContactChangeSet(changedIdentifiers: Set(contacts.map(\.id)))
        announceChange()
    }

    static func summary(from contact: SystemContact) -> ContactSummary {
        ContactSummary(
            id: contact.id,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            emailAddresses: contact.emailAddresses,
            phoneNumbers: contact.phoneNumbers,
            postalAddresses: contact.postalAddresses,
            urlAddresses: contact.urlAddresses,
            birthdayMonth: contact.birthday?.month,
            birthdayDay: contact.birthday?.day,
            birthdayYear: contact.birthday?.year,
            accountName: contact.containerName,
            isReadOnly: false
        )
    }
}

// MARK: - A synthetic library

/// Invented contacts that exercise the cases a real library contains.
///
/// Every one is here because it breaks something naive: a unified record that must not become two
/// people, two different people who share a surname, a contact that matches somebody already in the
/// CRM, a row with no name at all, a birthday with no year, custom labels.
///
/// **No real person's details appear here.** Every address is in `example.com` or a reserved
/// subdomain of it, and every number is in the 555 range set aside for fiction.
public enum ContactFixtures {
    public static let icloudContainer = ContactAccount(
        id: "fixture-icloud", name: "iCloud", contactCount: 6, isReadOnly: false
    )
    public static let workContainer = ContactAccount(
        id: "fixture-work", name: "Northwind Directory", contactCount: 3, isReadOnly: true
    )
    public static let localContainer = ContactAccount(
        id: "fixture-local", name: "On My Mac", contactCount: 1, isReadOnly: false
    )

    public static var containers: [ContactAccount] {
        [icloudContainer, workContainer, localContainer]
    }

    /// A library of ten, each with a reason to exist.
    public static var library: [SystemContact] {
        [
            // Matches the sample CRM's Maya on email — proposed as a link, not a second person.
            SystemContact(
                id: "fixture-maya",
                givenName: "Maya",
                familyName: "Chen",
                nickname: "Maya",
                phoneticGivenName: "MY-uh",
                organizationName: "Northwind Studio",
                departmentName: "Design",
                jobTitle: "Head of Design",
                emailAddresses: [
                    ContactLabelledValue(label: "work", value: "maya@northwind.example"),
                    ContactLabelledValue(label: "home", value: "maya.chen@example.com"),
                ],
                phoneNumbers: [
                    ContactLabelledValue(label: "mobile", value: "512-555-0192"),
                    ContactLabelledValue(label: "work", value: "512-555-0100"),
                ],
                postalAddresses: [
                    ContactLabelledValue(label: "home", value: "12 Rosewood Lane, Austin, TX")
                ],
                urlAddresses: [ContactLabelledValue(label: "work", value: "northwind.example")],
                birthday: ContactLabelledDate(label: "birthday", year: 1987, month: 10, day: 12),
                relations: [ContactLabelledValue(label: "spouse", value: "Sam Okonkwo")],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            ),

            // Nobody in the CRM — a straightforward new person, with a custom label.
            SystemContact(
                id: "fixture-arun",
                givenName: "Arun",
                middleName: "Kabir",
                familyName: "Devi",
                namePrefix: "Dr",
                organizationName: "Rivergate Clinic",
                jobTitle: "Physiotherapist",
                emailAddresses: [ContactLabelledValue(label: "work", value: "arun@rivergate.example")],
                phoneNumbers: [ContactLabelledValue(label: "Clinic front desk", value: "512-555-0143")],
                birthday: ContactLabelledDate(label: "birthday", month: 4, day: 2),
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            ),

            // Shares a surname with the next one and nothing else. Must not merge.
            SystemContact(
                id: "fixture-jordan-reyes",
                givenName: "Jordan",
                familyName: "Reyes",
                organizationName: "Fieldstone",
                jobTitle: "Account manager",
                emailAddresses: [ContactLabelledValue(label: "work", value: "jordan.reyes@fieldstone.example")],
                phoneNumbers: [ContactLabelledValue(label: "mobile", value: "512-555-0161")],
                containerIdentifier: workContainer.id,
                containerName: workContainer.name
            ),
            SystemContact(
                id: "fixture-jordan-reyes-two",
                givenName: "Jordan",
                familyName: "Reyes",
                organizationName: "Halcyon Press",
                jobTitle: "Editor",
                emailAddresses: [ContactLabelledValue(label: "work", value: "j.reyes@halcyon.example")],
                phoneNumbers: [ContactLabelledValue(label: "mobile", value: "512-555-0178")],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            ),

            // A record with no name of any kind — a stub some mail client made. Counted, not imported.
            SystemContact(
                id: "fixture-nameless",
                emailAddresses: [ContactLabelledValue(label: "other", value: "no-reply@example.com")],
                containerIdentifier: localContainer.id,
                containerName: localContainer.name
            ),

            // An organisation rather than a person. Has a usable name, and it is not a personal one.
            SystemContact(
                id: "fixture-org",
                organizationName: "Rosewood Building Management",
                emailAddresses: [ContactLabelledValue(label: "work", value: "office@rosewood.example")],
                phoneNumbers: [ContactLabelledValue(label: "work", value: "512-555-0120")],
                containerIdentifier: workContainer.id,
                containerName: workContainer.name
            ),

            // Shares a phone number with Maya's household but has a different name — the ambiguous
            // case, which must go to review rather than being linked or created silently.
            SystemContact(
                id: "fixture-household",
                givenName: "Sam",
                familyName: "Okonkwo",
                emailAddresses: [ContactLabelledValue(label: "home", value: "sam@example.com")],
                phoneNumbers: [ContactLabelledValue(label: "home", value: "512-555-0192")],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            ),

            SystemContact(
                id: "fixture-priya",
                givenName: "Priya",
                familyName: "Raman",
                organizationName: "Meridian",
                jobTitle: "Head of Product",
                emailAddresses: [ContactLabelledValue(label: "work", value: "priya@meridian.example")],
                birthday: ContactLabelledDate(label: "birthday", month: 12, day: 30),
                containerIdentifier: workContainer.id,
                containerName: workContainer.name
            ),

            SystemContact(
                id: "fixture-lin",
                givenName: "Wei",
                familyName: "Lin",
                nickname: "Lin",
                phoneticFamilyName: "LIN",
                emailAddresses: [ContactLabelledValue(label: "home", value: "wei.lin@example.com")],
                phoneNumbers: [ContactLabelledValue(label: "Boat", value: "512-555-0155")],
                dates: [ContactLabelledDate(label: "anniversary", year: 2011, month: 6, day: 4)],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            ),

            SystemContact(
                id: "fixture-tomas",
                givenName: "Tomás",
                familyName: "Ferreira",
                organizationName: "Kestrel Labs",
                jobTitle: "Research lead",
                emailAddresses: [ContactLabelledValue(label: "work", value: "tomas@kestrel.example")],
                phoneNumbers: [ContactLabelledValue(label: "work", value: "512-555-0136")],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name,
                hasImage: true
            ),
        ]
    }

    /// A library of `count` synthetic contacts, for checking the import stays responsive.
    ///
    /// Generated rather than written out, and deterministic, so a performance check is repeatable and
    /// no real data is anywhere near it.
    public static func largeLibrary(count: Int) -> [SystemContact] {
        let givenNames = ["Ada", "Bo", "Cleo", "Dev", "Esi", "Finn", "Gia", "Hal", "Ivo", "Jun"]
        let familyNames = ["Nakamura", "Oyelaran", "Petrov", "Quintero", "Rahman", "Silva", "Tan"]

        return (0..<count).map { index in
            let given = givenNames[index % givenNames.count]
            let family = familyNames[(index / givenNames.count) % familyNames.count]

            return SystemContact(
                id: "fixture-bulk-\(index)",
                givenName: given,
                familyName: "\(family)\(index)",
                organizationName: index % 3 == 0 ? "Example Corp" : "",
                emailAddresses: [
                    ContactLabelledValue(label: "work", value: "\(given.lowercased()).\(index)@example.com")
                ],
                phoneNumbers: [
                    ContactLabelledValue(label: "mobile", value: "512-555-\(String(format: "%04d", index % 10000))")
                ],
                containerIdentifier: icloudContainer.id,
                containerName: icloudContainer.name
            )
        }
    }
}
