import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The address book, as the rest of the app sees it.
///
/// ### Off until asked for
/// Contacts access is a **preference**, stored per-device, and it starts off. Until it is turned on
/// the app holds a `NoContactsProvider` and never touches `CNContactStore` — no prompt appears, no
/// entitlement is exercised, and every view runs the same code path it would with an empty address
/// book.
///
/// The same ordering the calendar uses, for the same reason: a permission dialogue on first launch,
/// before anybody has decided the feature is wanted, is what gets an app denied permanently.
@Observable
@MainActor
public final class ContactsService {
    public private(set) var isEnabled: Bool
    public private(set) var authorization: IntegrationAuthorization = .notRequested

    /// The accounts macOS has configured — iCloud, Google, Exchange, On My Mac.
    public private(set) var accounts: [ContactAccount] = []

    public private(set) var isLoading = false

    /// The last search's results.
    public private(set) var searchResults: [ContactSummary] = []

    private var provider: any ContactsProviding
    private let makeProvider: @Sendable () -> any ContactsProviding
    private let dateProvider: any DateProvider
    private let defaults: UserDefaults

    static let enabledKey = "contacts.isEnabled"

    public init(
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard,
        makeProvider: @escaping @Sendable () -> any ContactsProviding
    ) {
        self.dateProvider = dateProvider
        self.defaults = defaults
        self.makeProvider = makeProvider

        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.provider = enabled ? makeProvider() : NoContactsProvider()
    }

    // MARK: - Enabling

    /// Turns the feature on and asks for access, in that order.
    @discardableResult
    public func enable() async -> IntegrationAuthorization {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)

        provider = makeProvider()
        authorization = await provider.requestAccess()

        if authorization.canRead {
            await refreshAccounts()
        }
        return authorization
    }

    /// Turns it off and forgets what was read.
    ///
    /// macOS keeps the *permission* — only System Settings can revoke that, and the interface says
    /// so rather than implying this button undoes it.
    public func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)

        provider = NoContactsProvider()
        accounts = []
        searchResults = []
        authorization = .notRequested
    }

    /// Re-reads the current authorisation without prompting.
    public func refreshAuthorization() async {
        authorization = await provider.authorization
    }

    public func refreshAccounts() async {
        isLoading = true
        defer { isLoading = false }
        accounts = await provider.accounts()
    }

    // MARK: - Reading

    public func search(_ query: String) async {
        guard isEnabled else {
            searchResults = []
            return
        }

        isLoading = true
        defer { isLoading = false }
        searchResults = await provider.contacts(matching: query)
    }

    public func contact(withIdentifier identifier: String) async -> ContactSummary? {
        await provider.contact(withIdentifier: identifier)
    }

    // MARK: - Bridging

    /// A system contact as a person draft.
    ///
    /// Everything Contacts holds and nothing it does not. The app's own layer — observations,
    /// reflections, relationship history, timeline — is never populated from here, because Contacts
    /// has no such fields and inventing them from an organisation name would be fabrication.
    public static func draft(from contact: ContactSummary) -> PersonDraft {
        var birthday: PartialDate?
        if let month = contact.birthdayMonth, let day = contact.birthdayDay {
            // Contacts genuinely omits the year when the birthday was entered without one, which is
            // the same distinction `PartialDate` makes. Both sides agree that a missing year is
            // information rather than a gap to fill.
            birthday = PartialDate(year: contact.birthdayYear, month: month, day: day)
        }

        return PersonDraft(
            fullName: contact.fullName,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            roleTitle: contact.jobTitle,
            organizationName: contact.organizationName,
            emails: contact.emailAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            phones: contact.phoneNumbers.map { LabelledValue(label: $0.label, value: $0.value) },
            addresses: contact.postalAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            websites: contact.urlAddresses.map { LabelledValue(label: $0.label, value: $0.value) },
            birthday: birthday,
            contactsIdentifier: contact.id,
            contactsAccountName: contact.accountName,
            // Contacts is authoritative for what it holds, and the item records where it came from.
            source: ItemSource(kind: .systemStore, identifier: contact.id)
        )
    }

    /// A system contact as the identity matcher sees it.
    public static func candidate(from contact: ContactSummary, id: UUID = UUID()) -> IdentityCandidate {
        var birthday: PartialDate?
        if let month = contact.birthdayMonth, let day = contact.birthdayDay {
            birthday = PartialDate(year: contact.birthdayYear, month: month, day: day)
        }

        return IdentityCandidate(
            id: id,
            fullName: contact.fullName,
            emails: contact.emailAddresses.map(\.value),
            phones: contact.phoneNumbers.map(\.value),
            contactsIdentifier: contact.id,
            accountName: contact.accountName,
            organization: contact.organizationName,
            birthday: birthday
        )
    }

    /// What changed in a linked contact since it was last read.
    ///
    /// Returned as a list rather than applied, because a refresh that silently overwrote a detail the
    /// user corrected here would make the app's copy untrustworthy — and the user corrected it for a
    /// reason.
    public static func differences(between profile: PersonProfile, and contact: ContactSummary) -> [ContactDifference] {
        var differences: [ContactDifference] = []

        func compare(_ field: String, _ mine: String?, _ theirs: String?) {
            let left = mine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let right = theirs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard left != right, !right.isEmpty else { return }
            differences.append(ContactDifference(field: field, mine: left.isEmpty ? nil : left, theirs: right))
        }

        compare("Given name", profile.givenName, contact.givenName)
        compare("Family name", profile.familyName, contact.familyName)
        compare("Role", profile.roleTitle, contact.jobTitle)
        compare("Organisation", profile.organizationName, contact.organizationName)

        let mineEmails = Set(profile.emails.map { ContactDetailRecognizer.normalizedEmail($0.value) })
        for email in contact.emailAddresses
        where !mineEmails.contains(ContactDetailRecognizer.normalizedEmail(email.value)) {
            differences.append(ContactDifference(field: "Email", mine: nil, theirs: email.value))
        }

        let minePhones = Set(profile.phones.map { ContactDetailRecognizer.normalizedPhone($0.value) })
        for phone in contact.phoneNumbers
        where !minePhones.contains(ContactDetailRecognizer.normalizedPhone(phone.value)) {
            differences.append(ContactDifference(field: "Phone", mine: nil, theirs: phone.value))
        }

        return differences
    }
}

/// One field where the app's copy and the system contact disagree.
public struct ContactDifference: Sendable, Hashable, Identifiable {
    public var field: String

    /// What Elephruit holds. `nil` means it holds nothing.
    public var mine: String?

    /// What Contacts holds.
    public var theirs: String

    public var id: String { "\(field)-\(theirs)" }

    public init(field: String, mine: String?, theirs: String) {
        self.field = field
        self.mine = mine
        self.theirs = theirs
    }

    /// Whether accepting this would overwrite something rather than fill a gap.
    ///
    /// The two are offered differently: a gap is filled with one click, and an overwrite says what
    /// it would replace.
    public var isOverwrite: Bool { mine != nil }

    public var summary: String {
        guard let mine else { return "\(field): \(theirs)" }
        return "\(field): \(mine) → \(theirs)"
    }
}
