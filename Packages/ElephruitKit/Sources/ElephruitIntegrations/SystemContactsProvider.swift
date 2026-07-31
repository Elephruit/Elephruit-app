import Contacts
import ElephruitCore
import Foundation

/// Reads the system Contacts store.
///
/// ### Every API here was checked against the macOS SDK headers, not recalled
/// - `CNContactStore.requestAccess(for:completionHandler:)` — the current spelling on macOS; unlike
///   EventKit there is no `requestFullAccess` split, because Contacts has only one access tier
/// - `CNAuthorizationStatus.limited` — `API_AVAILABLE(ios(18.0))` and absent on macOS, so it is
///   handled in the `@unknown default` rather than named
/// - `CNContactStore.containers(matching:)` and `CNContainer` — the account grouping; a container's
///   `name` is what the user sees in the Contacts app's sidebar
/// - `enumerateContacts(with:usingBlock:)` — the streaming fetch, which is what makes a library of
///   several thousand affordable
/// - `CNChangeHistoryFetchRequest` and `CNFetchResult.currentHistoryToken` — `API_AVAILABLE(macos(13.0))`
/// - `CNContactStoreDidChange` — the change notification, posted for any mutation
///
/// ### What it deliberately cannot do
/// The `CNContactStore` is `private` and never escapes, and ``ContactsProviding`` has no write
/// method. No method here calls `execute(_:)` with a `CNSaveRequest`, and
/// `ContactsWriteSafetyTests` asserts that against the source rather than trusting review — the same
/// arrangement, and for the same reason, as the calendar provider.
///
/// ### Why an actor
/// `CNContactStore` is not `Sendable`, and the two usual escapes are banned by this project's source
/// rules. Every `CNContact` is projected into a value type *inside* the actor, so nothing
/// non-`Sendable` crosses back out — and the projection is also where all the expensive string work
/// happens, which is how it stays off the main actor.
public actor SystemContactsProvider: ContactsProviding {
    /// Owned privately and never handed out. The read-only guarantee rests on this not escaping.
    private let store = CNContactStore()

    /// Container names by identifier, resolved once so a per-contact lookup is not a per-contact
    /// fetch. Cleared whenever the store changes.
    private var containerNames: [String: String] = [:]

    /// Which container each contact belongs to.
    ///
    /// A *unified* contact spans containers by definition, so this records the first one it was seen
    /// in — enough to say "this came from your work account" and not claimed to be more.
    private var containerByContact: [String: String] = [:]

    public init() {}

    // MARK: - Authorisation

    public var authorization: IntegrationAuthorization {
        Self.authorization(for: CNContactStore.authorizationStatus(for: .contacts))
    }

    static func authorization(for status: CNAuthorizationStatus) -> IntegrationAuthorization {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default:
            // A status this build has never heard of — `.limited`, if it ever reaches macOS — is not
            // assumed to grant anything. Treating an unknown status as permission is precisely the
            // bug that would read a library the user meant to keep partly private.
            .denied
        }
    }

    public func requestAccess() async -> IntegrationAuthorization {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        guard current == .notDetermined else {
            // macOS records the answer permanently. Asking again shows nothing and would make the
            // interface look broken to somebody who declined once.
            return Self.authorization(for: current)
        }

        let granted = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    Diagnostics.integrations.error(
                        "Contacts access request failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: granted)
            }
        }

        return granted ? .authorized : .denied
    }

    // MARK: - Accounts

    public func accounts() async -> [ContactAccount] {
        guard authorization == .authorized else { return [] }

        do {
            let containers = try store.containers(matching: nil)
            var result: [ContactAccount] = []

            for container in containers {
                containerNames[container.identifier] = container.name

                // Counted with an empty key list, which fetches identifiers and nothing else. The
                // count is for a summary line; paying for names to produce it would be absurd.
                let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                let members = (try? store.unifiedContacts(matching: predicate, keysToFetch: [])) ?? []

                for member in members where containerByContact[member.identifier] == nil {
                    containerByContact[member.identifier] = container.identifier
                }

                result.append(
                    ContactAccount(
                        id: container.identifier,
                        name: Self.displayName(for: container),
                        contactCount: members.count,
                        // Exchange directories are read-only to third-party apps. Reported rather
                        // than acted on — this app never writes to any of them.
                        isReadOnly: container.type == .exchange
                    )
                )
            }
            return result
        } catch {
            Diagnostics.integrations.error(
                "Could not read contact accounts: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// The container's own name, or its protocol when it has none.
    ///
    /// **Never a guessed provider.** `CNContainerType` says how a container talks, not who runs it:
    /// `.cardDAV` covers iCloud, Google, Fastmail, and every other CardDAV server alike. Labelling an
    /// unnamed CardDAV container "iCloud" would be a plausible lie, and the user would have no way to
    /// tell. In practice macOS names the iCloud container "iCloud" and this shows exactly that.
    static func displayName(for container: CNContainer) -> String {
        let name = container.name.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty else { return name }

        return switch container.type {
        case .local: "On My Mac"
        case .exchange: "Exchange account"
        case .cardDAV: "CardDAV account"
        case .unassigned: "Other contacts"
        @unknown default: "Other contacts"
        }
    }

    // MARK: - Keys

    /// The keys fetched for a list or an import, and no more.
    ///
    /// Deliberately explicit. Contacts requires a key list, which makes over-fetching a deliberate
    /// act — so `CNContactNoteKey` is absent (it needs an entitlement this app has no case for),
    /// image data is absent (fetched per contact, on demand, for somebody actually on screen), and
    /// social profiles and instant-message handles are absent because nothing displays them.
    ///
    /// A computed property inside the actor rather than a `static let`, because `CNKeyDescriptor` is
    /// not `Sendable` and a static would be shared mutable state. The two escapes the compiler
    /// suggests — `@preconcurrency` on the import, or `nonisolated(unsafe)` here — are both banned by
    /// this project's source rules and enforced by `SourceHygieneTests`.
    private var importKeys: [any CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactFamilyNameKey,
            CNContactNamePrefixKey,
            CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactPhoneticGivenNameKey,
            CNContactPhoneticFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactDepartmentNameKey,
            CNContactJobTitleKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactBirthdayKey,
            CNContactDatesKey,
            CNContactRelationsKey,
            CNContactImageDataAvailableKey,
        ].map { $0 as NSString as any CNKeyDescriptor }
    }

    /// The smaller list the old search box uses.
    private var summaryKeys: [any CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactBirthdayKey,
        ].map { $0 as NSString as any CNKeyDescriptor }
    }

    // MARK: - Reading

    public func contacts(matching query: String) async -> [ContactSummary] {
        guard authorization == .authorized else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let predicate = CNContact.predicateForContacts(matchingName: trimmed)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: summaryKeys)
            return contacts.map { summary(from: $0) }
        } catch {
            Diagnostics.integrations.error(
                "Contacts search failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    public func contact(withIdentifier identifier: String) async -> ContactSummary? {
        guard authorization == .authorized else { return nil }

        do {
            return summary(from: try store.unifiedContact(withIdentifier: identifier, keysToFetch: summaryKeys))
        } catch {
            // A missing record is a state, not a failure: the user deleted the contact, or the
            // account it lived in was removed. The app records that the link is dangling.
            Diagnostics.integrations.debug("Contact no longer exists")
            return nil
        }
    }

    // MARK: - Import

    /// Streams every unified contact, in batches.
    ///
    /// `enumerateContacts` hands back one `CNContact` at a time and lets each go before the next, so
    /// peak memory is one batch rather than the whole library. Each is projected to a value type
    /// immediately — the `CNContact` never leaves this actor, and the batch that crosses back is
    /// `Sendable` by construction.
    ///
    /// `unifyResults` is what makes the iCloud Maya and the Google Maya arrive as one record. macOS
    /// already knows they are the same person, and inheriting that beats re-deriving it and
    /// disagreeing.
    public func enumerateContacts(
        inContainers containerIdentifiers: [String],
        onBatch: @Sendable ([SystemContact]) async -> Void
    ) async -> Int {
        guard authorization == .authorized else { return 0 }

        // Container names are needed to label each contact, and the map is built here rather than
        // assumed — a scan that runs before anybody opened the accounts list still labels correctly.
        if containerNames.isEmpty { _ = await accounts() }

        let request = CNContactFetchRequest(keysToFetch: importKeys)
        request.unifyResults = true
        request.sortOrder = .givenName

        if !containerIdentifiers.isEmpty {
            request.predicate = CNContact.predicateForContactsInContainer(
                withIdentifier: containerIdentifiers[0]
            )
        }

        var batch: [SystemContact] = []
        var total = 0
        // 200 keeps a batch small enough to stay responsive and large enough that the hand-off cost
        // disappears against the fetch.
        let batchSize = 200

        // Collected synchronously inside the enumeration block — which cannot be `async` — then
        // handed over between batches.
        var pending: [[SystemContact]] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                batch.append(self.snapshot(from: contact))
                total += 1

                if batch.count >= batchSize {
                    pending.append(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            Diagnostics.integrations.error(
                "Contact enumeration failed: \(error.localizedDescription, privacy: .public)"
            )
            return total
        }

        if !batch.isEmpty { pending.append(batch) }

        for group in pending {
            await onBatch(group)
        }

        // Multiple containers need multiple passes: `predicateForContactsInContainer` takes one
        // identifier, and Contacts rejects compound predicates. Recursing per container and letting
        // the caller de-duplicate by identifier is simpler than the alternatives and correct, because
        // a unified contact returns the same identifier from every container it appears in.
        if containerIdentifiers.count > 1 {
            for identifier in containerIdentifiers.dropFirst() {
                total += await enumerateContacts(inContainers: [identifier], onBatch: onBatch)
            }
        }

        return total
    }

    public func systemContact(withIdentifier identifier: String) async -> SystemContact? {
        guard authorization == .authorized else { return nil }

        do {
            return snapshot(from: try store.unifiedContact(withIdentifier: identifier, keysToFetch: importKeys))
        } catch {
            Diagnostics.integrations.debug("Contact no longer resolves by identifier")
            return nil
        }
    }

    /// Re-finds a contact whose identifier stopped resolving.
    ///
    /// ### Why a shared email or phone is not enough on its own
    /// The search narrows by contact detail — never by name, which would re-link somebody to a
    /// stranger who happens to share theirs. But the narrowing is only a *lookup*: households share
    /// a landline and couples share an address, so the first record holding a number is not
    /// necessarily the person the link belonged to.
    ///
    /// So every candidate is then checked with ``ContactIdentitySignature/stronglyMatches(_:)``,
    /// which requires the shared detail **and** a name that agrees or is absent. Without that check a
    /// deleted contact silently re-links to whoever else has the house phone — which a test caught
    /// doing exactly that.
    public func systemContact(matching signature: ContactIdentitySignature) async -> SystemContact? {
        guard authorization == .authorized else { return nil }

        func verified(_ contacts: [CNContact]) -> SystemContact? {
            for contact in contacts {
                let candidate = snapshot(from: contact)
                if ContactIdentitySignature(contact: candidate).stronglyMatches(signature) {
                    return candidate
                }
            }
            return nil
        }

        for email in signature.emailKeys {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            if let found = try? store.unifiedContacts(matching: predicate, keysToFetch: importKeys),
               let match = verified(found) {
                return match
            }
        }

        for phone in signature.phoneKeys {
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
            if let found = try? store.unifiedContacts(matching: predicate, keysToFetch: importKeys),
               let match = verified(found) {
                return match
            }
        }

        return nil
    }

    public func thumbnail(forIdentifier identifier: String) async -> Data? {
        guard authorization == .authorized else { return nil }

        let keys = [CNContactThumbnailImageDataKey as NSString as any CNKeyDescriptor]
        return try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys).thumbnailImageData
    }

    // MARK: - Change tracking

    /// Always `nil` on this SDK, and the reason is in the header rather than in a decision here.
    ///
    /// ### Change history is not reachable from Swift
    /// The only entry point is
    /// `-[CNContactStore enumeratorForChangeHistoryFetchRequest:error:]`, and it is annotated
    /// **`NS_SWIFT_UNAVAILABLE("")`** in `CNContactStore.h` — checked against the macOS 27 SDK, not
    /// recalled. Its result type is `CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *>`, a nested
    /// ObjC generic that does not bridge, which is presumably why. There is no Swift overlay and no
    /// alternative spelling; calling it needs an Objective-C shim in the app target.
    ///
    /// Returning `nil` is not a stub. It is the protocol's documented signal for *"no usable token —
    /// reconcile fully"*, which is the same path a token that has expired or come from another
    /// machine takes. `ContactSyncService` already has to handle that case correctly, so the live
    /// provider takes it every time and the behaviour is identical, only less efficient: a change
    /// notification triggers a reconciliation over the linked contacts rather than over a delta.
    ///
    /// The incremental path is implemented, and `FixtureContactsProvider` supplies real tokens, so
    /// the logic is exercised by tests and ready for the day an ObjC shim or a Swift-callable API
    /// makes it reachable. See `docs/23` for the follow-up.
    public func currentHistoryToken() async -> Data? {
        nil
    }

    /// Always `nil`, for the reason given on ``currentHistoryToken()``.
    public func changes(since token: Data) async -> ContactChangeSet? {
        nil
    }

    /// Fires when the Contacts database changes.
    ///
    /// The notification carries no useful payload and is posted generously — several times for one
    /// edit. Coalescing is the consumer's job, and `ContactSyncService` does it.
    public nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            // A `Task` rather than a stored observer token: `addObserver` hands back an
            // `any NSObjectProtocol`, which is not `Sendable`, so capturing it in the `@Sendable`
            // termination handler is a compile error — and the two ways round that are the escapes
            // this project's source rules ban. A task is `Sendable`, and cancelling it removes the
            // observation, so the same job is done without an exemption.
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                    continuation.yield()
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Projection

    /// Projects a `CNContact` into the full value type, inside the actor.
    private func snapshot(from contact: CNContact) -> SystemContact {
        let containerIdentifier = containerByContact[contact.identifier]

        return SystemContact(
            id: contact.identifier,
            givenName: contact.givenName,
            middleName: contact.middleName,
            familyName: contact.familyName,
            namePrefix: contact.namePrefix,
            nameSuffix: contact.nameSuffix,
            nickname: contact.nickname,
            phoneticGivenName: contact.phoneticGivenName,
            phoneticFamilyName: contact.phoneticFamilyName,
            organizationName: contact.organizationName,
            departmentName: contact.departmentName,
            jobTitle: contact.jobTitle,
            emailAddresses: contact.emailAddresses.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value as String)
            },
            phoneNumbers: contact.phoneNumbers.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value.stringValue)
            },
            postalAddresses: contact.postalAddresses.map {
                ContactLabelledValue(
                    label: Self.label($0.label),
                    value: CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                )
            },
            urlAddresses: contact.urlAddresses.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value as String)
            },
            dates: contact.dates.compactMap { entry in
                // `CNContact.dates` is `NSArray<CNLabeledValue<NSDateComponents *> *>`. The class
                // does not value-bridge inside a generic, so these are non-optional `Int`s carrying
                // `NSDateComponentUndefined` when unset — unlike `birthday`, which bridges to
                // `DateComponents?` and is genuinely optional. Mixing the two conventions up is how a
                // contact acquires an anniversary in the year 2147483647.
                Self.labelledDate(label: Self.label(entry.label), components: entry.value)
            },
            birthday: contact.birthday.flatMap { components in
                guard let month = components.month, let day = components.day else { return nil }
                // Contacts genuinely omits the year for a birthday entered without one, which is the
                // same distinction `PartialDate` makes. Both sides agree a missing year is
                // information rather than a gap to fill.
                return ContactLabelledDate(label: "birthday", year: components.year, month: month, day: day)
            },
            relations: contact.contactRelations.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value.name)
            },
            containerIdentifier: containerIdentifier,
            containerName: containerIdentifier.flatMap { containerNames[$0] },
            hasImage: contact.imageDataAvailable
        )
    }

    /// The narrower projection the search box still uses.
    private func summary(from contact: CNContact) -> ContactSummary {
        let containerIdentifier = containerByContact[contact.identifier]

        return ContactSummary(
            id: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            emailAddresses: contact.emailAddresses.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value as String)
            },
            phoneNumbers: contact.phoneNumbers.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value.stringValue)
            },
            postalAddresses: contact.postalAddresses.map {
                ContactLabelledValue(
                    label: Self.label($0.label),
                    value: CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                )
            },
            urlAddresses: contact.urlAddresses.map {
                ContactLabelledValue(label: Self.label($0.label), value: $0.value as String)
            },
            birthdayMonth: contact.birthday?.month,
            birthdayDay: contact.birthday?.day,
            birthdayYear: contact.birthday?.year,
            accountName: containerIdentifier.flatMap { containerNames[$0] },
            isReadOnly: false
        )
    }

    /// Reads an `NSDateComponents` that uses `NSDateComponentUndefined` for "not set".
    static func labelledDate(label: String, components: NSDateComponents) -> ContactLabelledDate? {
        let month = components.month
        let day = components.day
        guard month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return nil }

        let year = components.year
        return ContactLabelledDate(
            label: label,
            year: year == NSDateComponentUndefined ? nil : year,
            month: month,
            day: day
        )
    }

    /// Contacts' labels arrive wrapped — `_$!<Mobile>!$_` — and have to be localised back.
    ///
    /// A custom label the user typed themselves comes through unwrapped and is returned unchanged,
    /// which is the point: "Beach house" is what they called it.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}
