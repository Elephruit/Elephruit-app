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
/// - `CNContactFormatter.string(from:style:)` — used only as a fallback, because the app keeps given
///   and family names separately
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
/// non-`Sendable` crosses back out.
public actor SystemContactsProvider: ContactsProviding {
    /// Owned privately and never handed out. The read-only guarantee rests on this not escaping.
    private let store = CNContactStore()

    /// Resolved once and cached: the container each contact belongs to, so a summary can name its
    /// account without a fetch per row.
    private var containerNames: [String: String] = [:]

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
            // A status this build has never heard of — `.limited` on a future macOS, say — is not
            // assumed to grant anything.
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
                let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                let count = (try? store.unifiedContacts(matching: predicate, keysToFetch: [])) ?? []
                containerNames[container.identifier] = container.name

                result.append(
                    ContactAccount(
                        id: container.identifier,
                        name: container.name.isEmpty ? Self.defaultName(for: container.type) : container.name,
                        contactCount: count.count,
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

    static func defaultName(for type: CNContainerType) -> String {
        switch type {
        case .local: "On My Mac"
        case .exchange: "Exchange"
        case .cardDAV: "CardDAV"
        case .unassigned: "Other"
        @unknown default: "Other"
        }
    }

    // MARK: - Reading

    /// The keys fetched, and no more.
    ///
    /// Deliberately explicit and deliberately short. Contacts requires a key list, and the honest
    /// list is the one matching what the app actually shows — note-fetching keys, image data, and
    /// social profiles are all absent because nothing here needs them and requesting data the app
    /// does not use is exactly the habit the privacy posture exists to prevent.
    ///
    /// A computed property inside the actor rather than a `static let`, because `CNKeyDescriptor` is
    /// not `Sendable` and a static would be shared mutable state. The two escapes the compiler
    /// suggests — `@preconcurrency` on the import, or `nonisolated(unsafe)` here — are both banned by
    /// this project's source rules and enforced by `SourceHygieneTests`. Rebuilding a small array of
    /// constants per fetch costs nothing measurable and needs no exemption.
    private var keys: [any CNKeyDescriptor] {
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

    public func contacts(matching query: String) async -> [ContactSummary] {
        guard authorization == .authorized else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let predicate = CNContact.predicateForContacts(matchingName: trimmed)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
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
            return summary(from: try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys))
        } catch {
            // A missing record is a state, not a failure: the user deleted the contact, or the
            // account it lived in was removed. The app records that the link is dangling.
            Diagnostics.integrations.debug("Contact no longer exists")
            return nil
        }
    }

    /// Projects a `CNContact` into a value type, inside the actor.
    ///
    /// Nothing non-`Sendable` crosses the isolation boundary because the projection happens here.
    private func summary(from contact: CNContact) -> ContactSummary {
        var birthdayMonth: Int?
        var birthdayDay: Int?
        var birthdayYear: Int?

        if let birthday = contact.birthday {
            birthdayMonth = birthday.month
            birthdayDay = birthday.day
            // Contacts genuinely omits the year for a birthday given without one, which is the same
            // distinction `PartialDate` makes. Both sides of the bridge agree that a missing year is
            // information rather than an absence to be filled in.
            birthdayYear = birthday.year
        }

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
            birthdayMonth: birthdayMonth,
            birthdayDay: birthdayDay,
            birthdayYear: birthdayYear,
            accountName: nil,
            isReadOnly: false
        )
    }

    /// Contacts' labels arrive wrapped — `_$!<Mobile>!$_` — and have to be localised back.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}
