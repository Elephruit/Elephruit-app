import Foundation

/// A labelled value as Contacts holds it — `("mobile", "512-555-0192")`.
///
/// Distinct from ``LabelledValue`` in the model layer, which is what the CRM stores: this one is what
/// the system said, and keeping them separate is what lets a refresh tell them apart.
public struct ContactLabelledValue: Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One of the accounts the operating system has configured — iCloud, Google, Exchange, On My Mac.
///
/// ### The name is the system's, never the app's guess
/// `CNContainer.name` is what the user sees in the Contacts app's own sidebar, and it is the only
/// name shown here. The framework does not reliably say "this container is iCloud", so the app does
/// not say it either: a container whose name is empty is labelled by its *type* — "On My Mac",
/// "CardDAV", "Exchange" — which is a statement about the protocol and not a claim about the
/// provider.
public struct ContactAccount: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var contactCount: Int

    /// Whether the account is read-only to this app — an Exchange directory usually is.
    public var isReadOnly: Bool

    public init(id: String, name: String, contactCount: Int, isReadOnly: Bool = false) {
        self.id = id
        self.name = name
        self.contactCount = contactCount
        self.isReadOnly = isReadOnly
    }
}

/// A system contact, projected into a value type.
///
/// ### Why this is bigger than `ContactSummary` and replaces it for import
/// `ContactSummary` was built for a search box: enough to show a row and offer a link. An import has
/// to carry everything the CRM will store, keep the labels people actually gave their numbers, and
/// remember which container the record came from — so that a refresh two months later can tell a
/// changed value from a value it simply never had.
///
/// `Sendable`, because it is produced inside the Contacts actor and consumed on the main actor. No
/// `CNContact` ever crosses that boundary.
public struct SystemContact: Sendable, Hashable, Identifiable {
    /// `CNContact.identifier` for the **unified** contact.
    ///
    /// Stable in ordinary use and *not* treated as identity — see ``ContactIdentitySignature`` for
    /// why, and for what happens when it stops resolving.
    public var id: String

    // MARK: Name

    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var namePrefix: String
    public var nameSuffix: String
    public var nickname: String

    /// Phonetic fields, when the record has them. Kept because a name whose pronunciation somebody
    /// bothered to record is exactly the name worth getting right.
    public var phoneticGivenName: String
    public var phoneticFamilyName: String

    // MARK: Work

    public var organizationName: String
    public var departmentName: String
    public var jobTitle: String

    // MARK: Labelled values

    public var emailAddresses: [ContactLabelledValue]
    public var phoneNumbers: [ContactLabelledValue]
    public var postalAddresses: [ContactLabelledValue]
    public var urlAddresses: [ContactLabelledValue]

    /// Anniversaries and other standard dates, by their label.
    public var dates: [ContactLabelledDate]

    /// The birthday, which frequently has no year.
    public var birthday: ContactLabelledDate?

    // MARK: Relations

    /// `CNContactRelation` entries — "spouse: Sam", "child: Jack".
    ///
    /// Imported as **suggestions only**. A relation is a name written by hand in another app; it is
    /// not a link, and resolving it to a CRM person without asking would be the app inventing a
    /// family from a string.
    public var relations: [ContactLabelledValue]

    // MARK: Provenance

    /// `CNContainer.identifier` this record lives in, when the framework exposed it.
    public var containerIdentifier: String?

    /// The container's **system-provided** name. Never guessed — see ``ContactAccount``.
    public var containerName: String?

    /// Whether the record carries an image, without carrying the image.
    ///
    /// The flag comes from `imageDataAvailable`, which needs no image key and therefore no megabytes.
    /// Thumbnails are fetched one at a time, for a person actually on screen.
    public var hasImage: Bool

    public init(
        id: String,
        givenName: String = "",
        middleName: String = "",
        familyName: String = "",
        namePrefix: String = "",
        nameSuffix: String = "",
        nickname: String = "",
        phoneticGivenName: String = "",
        phoneticFamilyName: String = "",
        organizationName: String = "",
        departmentName: String = "",
        jobTitle: String = "",
        emailAddresses: [ContactLabelledValue] = [],
        phoneNumbers: [ContactLabelledValue] = [],
        postalAddresses: [ContactLabelledValue] = [],
        urlAddresses: [ContactLabelledValue] = [],
        dates: [ContactLabelledDate] = [],
        birthday: ContactLabelledDate? = nil,
        relations: [ContactLabelledValue] = [],
        containerIdentifier: String? = nil,
        containerName: String? = nil,
        hasImage: Bool = false
    ) {
        self.id = id
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.namePrefix = namePrefix
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.phoneticGivenName = phoneticGivenName
        self.phoneticFamilyName = phoneticFamilyName
        self.organizationName = organizationName
        self.departmentName = departmentName
        self.jobTitle = jobTitle
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.dates = dates
        self.birthday = birthday
        self.relations = relations
        self.containerIdentifier = containerIdentifier
        self.containerName = containerName
        self.hasImage = hasImage
    }

    /// Given, middle, and family, joined.
    ///
    /// Prefix and suffix are deliberately excluded: "Dr" and "Jr" are part of how somebody is
    /// addressed rather than of what they are called, and putting them in the display name makes
    /// every list row longer for no gain. Both are still imported and still shown on the card.
    public var fullName: String {
        [givenName, middleName, familyName]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }

    /// The name to show when there is no personal name at all — a company record, usually.
    public var displayName: String {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        if !nickname.isEmpty { return nickname }
        if !organizationName.isEmpty { return organizationName }
        return ""
    }

    /// Whether this record has anything that could serve as a name.
    ///
    /// Contacts genuinely contains rows that are only an email address — a stub the Mail app made
    /// once and nobody filled in. They are counted and reported rather than imported as "Untitled",
    /// because a CRM full of blank people is worse than a CRM missing a few.
    public var hasUsableName: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The phonetic name as one string, for ``PersonProfile.pronunciation``.
    public var phoneticName: String? {
        let parts = [phoneticGivenName, phoneticFamilyName].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Title and department, as the CRM's single role field.
    public var roleTitle: String? {
        let parts = [jobTitle, departmentName].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A labelled date from a contact — a birthday, an anniversary.
public struct ContactLabelledDate: Sendable, Hashable {
    public var label: String

    public var year: Int?
    public var month: Int
    public var day: Int

    public init(label: String, year: Int? = nil, month: Int, day: Int) {
        self.label = label
        self.year = year
        self.month = month
        self.day = day
    }

    public var partialDate: PartialDate? {
        PartialDate(year: year, month: month, day: day)
    }
}

// MARK: - Identity

/// The normalized signals a contact can be recognised by when its identifier cannot be trusted.
///
/// ### Why the identifier is not enough on its own
/// `CNContact.identifier` is stable while nothing structural happens, and this app's whole reason for
/// storing a link is that things happen: an account is removed and re-added, a contact is unified
/// with another, a library is migrated to a new Mac. In each case the identifier changes or vanishes
/// while the *person* plainly did not.
///
/// So every link stores a signature too, and reconciliation tries the identifier first and the
/// signature second. A contact that matches neither is not assumed gone — the link is marked
/// unavailable and keeps its last known values, because "I cannot find this record" and "this person
/// no longer exists" are different claims and the app can only make the first.
public struct ContactIdentitySignature: Sendable, Hashable, Codable {
    /// Folded full name. Weak on its own — never sufficient for a match by itself.
    public var nameKey: String

    /// Lower-cased email addresses.
    public var emailKeys: Set<String>

    /// The last ten digits of each phone number, so two spellings of one number agree.
    public var phoneKeys: Set<String>

    public init(nameKey: String, emailKeys: Set<String>, phoneKeys: Set<String>) {
        self.nameKey = nameKey
        self.emailKeys = emailKeys
        self.phoneKeys = phoneKeys
    }

    public init(contact: SystemContact) {
        self.init(
            nameKey: TextNormalizer.foldedForMatching(contact.displayName),
            emailKeys: Set(
                contact.emailAddresses
                    .map { ContactDetailRecognizer.normalizedEmail($0.value) }
                    .filter { !$0.isEmpty }
            ),
            phoneKeys: Set(
                contact.phoneNumbers
                    .map { ContactDetailRecognizer.normalizedPhone($0.value) }
                    .filter { $0.count >= 7 }
            )
        )
    }

    /// Whether this signature and another describe the same person beyond reasonable doubt.
    ///
    /// A shared email or a shared phone number, *and* a name that does not actively contradict it.
    /// Two people genuinely can share a household email address, so the name has to agree or be
    /// absent on one side; a shared number with two different full names is exactly the case that
    /// goes to review instead.
    public func stronglyMatches(_ other: ContactIdentitySignature) -> Bool {
        let sharesContactDetail =
            !emailKeys.isDisjoint(with: other.emailKeys) || !phoneKeys.isDisjoint(with: other.phoneKeys)
        guard sharesContactDetail else { return false }

        if nameKey.isEmpty || other.nameKey.isEmpty { return true }
        return nameKey == other.nameKey
    }

    /// Stored as a single opaque string, so a link's signature is one column and one equality test.
    public var storageKey: String {
        let emails = emailKeys.sorted().joined(separator: ",")
        let phones = phoneKeys.sorted().joined(separator: ",")
        return "\(nameKey)|\(emails)|\(phones)"
    }

    public static func decode(_ storageKey: String) -> ContactIdentitySignature? {
        let parts = storageKey.components(separatedBy: "|")
        guard parts.count == 3 else { return nil }

        return ContactIdentitySignature(
            nameKey: parts[0],
            emailKeys: Set(parts[1].split(separator: ",").map(String.init)),
            phoneKeys: Set(parts[2].split(separator: ",").map(String.init))
        )
    }
}

// MARK: - Sync state

/// Where a link to a system contact currently stands.
public enum ContactSyncState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Resolving normally.
    case linked

    /// The record could not be found last time it was looked for — deleted, or its account removed.
    ///
    /// **Not an error and not a deletion.** The CRM person stays, the last imported values stay, and
    /// the interface says the information can no longer be refreshed.
    case unavailable

    /// Contacts access is off or was revoked, so nothing can be read for *any* link.
    case unreadable

    public var displayName: String {
        switch self {
        case .linked: "Linked"
        case .unavailable: "No longer in Contacts"
        case .unreadable: "Contacts access is off"
        }
    }

    /// Said without alarm, because none of these is the user's fault or a data loss.
    public var explanation: String {
        switch self {
        case .linked:
            "Standard contact details refresh from your address book."
        case .unavailable:
            """
            This contact is no longer in your address book — it may have been deleted, or its \
            account removed. Everything recorded here is kept, and can no longer be refreshed.
            """
        case .unreadable:
            """
            Contacts access is off, so linked details cannot refresh. Everything recorded here is \
            kept.
            """
        }
    }

    public var symbolName: String {
        switch self {
        case .linked: "link"
        case .unavailable: "link.badge.plus"
        case .unreadable: "lock.slash"
        }
    }
}

/// Where one stored value came from.
///
/// The question every imported field has to be able to answer, and the reason a refresh can be safe:
/// a value the app imported may be replaced by a newer one from the same source, and a value the user
/// typed here may not.
public enum ContactValueOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    /// Came from the system contact and has not been touched since.
    case imported

    /// Typed in Elephruit. No system contact claims it.
    case manual

    /// Came from the system contact and was then deliberately changed here.
    ///
    /// The one that makes refresh interesting: the system value may change again, and this value must
    /// not be quietly replaced by it. The newer system value becomes a *conflict* the user is shown.
    case overridden

    /// Derived by the app rather than stated by anyone.
    case inferred

    public var displayName: String {
        switch self {
        case .imported: "From Contacts"
        case .manual: "Entered here"
        case .overridden: "Changed here"
        case .inferred: "Worked out"
        }
    }

    /// Whether a refresh may replace this value without asking.
    public var isRefreshable: Bool {
        self == .imported
    }
}

/// A local value and a newer system value that disagree.
///
/// Computed from the two rows rather than stored, so it cannot go stale or outlive either of them.
public struct ContactSyncConflict: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var personID: UUID
    public var personName: String

    /// Which field — "Email (work)", "Phone (mobile)".
    public var field: String

    /// What Elephruit shows now, which the user chose.
    public var localValue: String

    /// What the system contact says now.
    public var systemValue: String

    public var observedAt: Date

    public init(
        id: UUID = UUID(),
        personID: UUID,
        personName: String,
        field: String,
        localValue: String,
        systemValue: String,
        observedAt: Date
    ) {
        self.id = id
        self.personID = personID
        self.personName = personName
        self.field = field
        self.localValue = localValue
        self.systemValue = systemValue
        self.observedAt = observedAt
    }

    public var summary: String {
        "\(field): you have “\(localValue)”, Contacts now has “\(systemValue)”"
    }
}
