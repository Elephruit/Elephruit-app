import ElephruitCore
import Foundation
import SwiftData

/// The association between a CRM person and a system contact.
///
/// ### Why this is an entity and `contactsIdentifier` was not enough
/// A column answers "which record" and nothing else. A link has to answer *when it was last read*,
/// *which account it came from*, *what to do when the identifier stops resolving*, and *whether it is
/// currently readable at all* — and each of those is a fact about the link rather than about either
/// side of it.
///
/// ``PersonProfile/contactsIdentifier`` stays, mirrored from here, so every view written before this
/// slice keeps working. This is what the sync layer actually operates on.
///
/// **CloudKit compliance**, on the same terms as every other entity: every attribute defaulted, no
/// unique constraints, every to-one relationship optional with a declared inverse, no `.deny` rule.
@Model
public final class SystemContactLink {
    /// Looking a link up by the contact it points at is the hot path for both import and refresh.
    #Index<SystemContactLink>([\.contactIdentifier])

    public var id: UUID = UUID()

    /// `CNContact.identifier` for the unified contact.
    ///
    /// A strong signal and *not* the identity — see ``identitySignature``.
    public var contactIdentifier: String = ""

    /// `CNContainer.identifier`, when the framework exposed one.
    public var containerIdentifier: String?

    /// The container's system-provided name. Stored for display, never used to decide anything.
    public var containerName: String?

    /// ``ElephruitCore/ContactIdentitySignature/storageKey`` — folded name, emails, and phones.
    ///
    /// The fallback when the identifier stops resolving, which happens whenever an account is removed
    /// and re-added or a library moves to a new Mac. Refreshed on every successful read, so it tracks
    /// the contact rather than freezing at import time.
    public var identitySignature: String = ""

    /// ``ElephruitCore/ContactSyncState`` raw value.
    public var stateRaw: String = ContactSyncState.linked.rawValue

    public var linkedAt: Date = Date()

    /// The last time the system record was successfully read.
    public var lastRefreshedAt: Date?

    /// When the record was first found to be missing. Cleared if it comes back.
    public var unavailableSince: Date?

    /// The import session that created this link, when one did.
    ///
    /// By identifier rather than a relationship: sessions are pruned and a link must outlive the one
    /// that made it. A dangling identifier reads as "no session", which is correct.
    public var importSessionID: UUID?

    // MARK: Relationships

    public var person: Item?

    /// Every value this link has supplied, current and superseded.
    @Relationship(deleteRule: .cascade, inverse: \ImportedContactValue.link)
    public var values: [ImportedContactValue] = []

    public init(
        id: UUID = UUID(),
        contactIdentifier: String = "",
        containerIdentifier: String? = nil,
        containerName: String? = nil,
        identitySignature: String = "",
        state: ContactSyncState = .linked,
        person: Item? = nil,
        linkedAt: Date = Date(),
        importSessionID: UUID? = nil
    ) {
        self.id = id
        self.contactIdentifier = contactIdentifier
        self.containerIdentifier = containerIdentifier
        self.containerName = containerName
        self.identitySignature = identitySignature
        self.stateRaw = state.rawValue
        self.person = person
        self.linkedAt = linkedAt
        self.lastRefreshedAt = linkedAt
        self.importSessionID = importSessionID
    }
}

extension SystemContactLink {
    public var state: ContactSyncState {
        get { ContactSyncState(rawValue: stateRaw) ?? .linked }
        set { stateRaw = newValue.rawValue }
    }

    public var signature: ContactIdentitySignature? {
        ContactIdentitySignature.decode(identitySignature)
    }

    /// Whether this link can currently supply fresh values.
    public var isLive: Bool { state == .linked }

    /// Values this link currently supplies, newest first.
    public var currentValues: [ImportedContactValue] {
        values.filter { $0.supersededAt == nil }.sorted { $0.lastObservedAt > $1.lastObservedAt }
    }

    /// Values the user changed here, which a refresh must not overwrite.
    public var overriddenValues: [ImportedContactValue] {
        currentValues.filter { $0.origin == .overridden }
    }

    /// The line under a person's name in the linked-contact section.
    public func summary(relativeTo now: Date) -> String {
        switch state {
        case .linked:
            guard let lastRefreshedAt else { return containerName ?? "Linked" }
            let days = Calendar.autoupdatingCurrent
                .dateComponents([.day], from: lastRefreshedAt, to: now).day ?? 0

            let when: String = switch days {
            case ..<1: "today"
            case 1: "yesterday"
            case 2...30: "\(days) days ago"
            default: lastRefreshedAt.formatted(date: .abbreviated, time: .omitted)
            }

            return [containerName, "refreshed \(when)"].compactMap { $0 }.joined(separator: " · ")

        case .unavailable, .unreadable:
            return state.displayName
        }
    }
}

// MARK: - Imported values

/// One value a system contact supplied, and everything needed to know what to do with it later.
///
/// ### Why this exists beside `PersonProfile` rather than replacing part of it
/// `PersonProfile` holds the **current** emails, phones, and addresses that every existing view
/// already reads — the person's page, the quick actions, the vCard export. Nothing about those views
/// changes.
///
/// This is the **provenance ledger** underneath: for each field and label, which contact supplied the
/// value, when it was first and last seen, and whether it was imported, typed here, or deliberately
/// overridden. That division is the same one the fact model already makes — a current answer, and a
/// history that explains it — and it is what makes a refresh safe. Storing the value in two places
/// would be a bug; storing a value and its provenance is not.
///
/// Superseded rather than deleted, so "what was this before the refresh" is a query.
@Model
public final class ImportedContactValue {
    #Index<ImportedContactValue>([\.fieldKey])

    public var id: UUID = UUID()

    /// Which field — `email`, `phone`, `address`, `url`, `givenName`, `organization`, and so on.
    ///
    /// A string rather than an enum for the same reason `ItemKind` is one: a value written by a newer
    /// build reads back without loss.
    public var fieldKey: String = ""

    /// The label the value carried — "home", "work", "Beach house".
    ///
    /// Part of the identity of a value: changing a *work* number is not the same event as adding a
    /// *home* one, and a ledger that ignored the label could not tell them apart.
    public var label: String = ""

    public var value: String = ""

    /// ``ElephruitCore/ContactValueOrigin`` raw value.
    public var originRaw: String = ContactValueOrigin.imported.rawValue

    public var firstObservedAt: Date = Date()

    /// The last time the system said this. For a manual value, when it was typed.
    public var lastObservedAt: Date = Date()

    /// Set when a newer value replaced this one. The row stays.
    public var supersededAt: Date?

    /// For an overridden value: what the system most recently said, which the user chose not to take.
    ///
    /// This is what makes a conflict computable from the rows rather than needing an entity of its
    /// own — the disagreement is a property of this value, and it disappears when the value does.
    public var conflictingSystemValue: String?

    /// When that conflicting system value was seen.
    public var conflictObservedAt: Date?

    public var link: SystemContactLink?

    public init(
        id: UUID = UUID(),
        fieldKey: String = "",
        label: String = "",
        value: String = "",
        origin: ContactValueOrigin = .imported,
        observedAt: Date = Date(),
        link: SystemContactLink? = nil
    ) {
        self.id = id
        self.fieldKey = fieldKey
        self.label = label
        self.value = value
        self.originRaw = origin.rawValue
        self.firstObservedAt = observedAt
        self.lastObservedAt = observedAt
        self.link = link
    }
}

extension ImportedContactValue {
    public var origin: ContactValueOrigin {
        get { ContactValueOrigin(rawValue: originRaw) ?? .imported }
        set { originRaw = newValue.rawValue }
    }

    public var isCurrent: Bool { supersededAt == nil }

    /// Whether the system now says something different from what the user kept.
    public var hasConflict: Bool {
        conflictingSystemValue != nil && origin == .overridden
    }

    /// "Email (work)" — how the field reads in a conflict or a provenance row.
    public var displayField: String {
        let name = Self.fieldDisplayName(fieldKey)
        return label.isEmpty ? name : "\(name) (\(label))"
    }

    public static func fieldDisplayName(_ key: String) -> String {
        switch key {
        case ContactField.givenName: "Given name"
        case ContactField.middleName: "Middle name"
        case ContactField.familyName: "Family name"
        case ContactField.namePrefix: "Prefix"
        case ContactField.nameSuffix: "Suffix"
        case ContactField.nickname: "Nickname"
        case ContactField.pronunciation: "Pronunciation"
        case ContactField.organization: "Organisation"
        case ContactField.role: "Role"
        case ContactField.email: "Email"
        case ContactField.phone: "Phone"
        case ContactField.address: "Address"
        case ContactField.url: "Website"
        case ContactField.birthday: "Birthday"
        case ContactField.date: "Date"
        default: key.capitalized
        }
    }

    /// The sentence shown under a value on the linked-contact card.
    public func provenanceSentence(relativeTo now: Date) -> String {
        let when = lastObservedAt.formatted(date: .abbreviated, time: .omitted)

        return switch origin {
        case .imported: "From Contacts, last seen \(when)."
        case .manual: "Entered here on \(when)."
        case .overridden: "Changed here on \(when). Contacts is not updated."
        case .inferred: "Worked out by Elephruit on \(when)."
        }
    }
}

/// The field keys an imported value can carry.
///
/// Constants rather than an enum so an unknown key from a newer build round-trips, and named in one
/// place so the import and the refresh cannot disagree about what a phone number is called.
public enum ContactField {
    public static let givenName = "givenName"
    public static let middleName = "middleName"
    public static let familyName = "familyName"
    public static let namePrefix = "namePrefix"
    public static let nameSuffix = "nameSuffix"
    public static let nickname = "nickname"
    public static let pronunciation = "pronunciation"
    public static let organization = "organization"
    public static let role = "role"
    public static let email = "email"
    public static let phone = "phone"
    public static let address = "address"
    public static let url = "url"
    public static let birthday = "birthday"
    public static let date = "date"
}

// MARK: - Import sessions

/// One run of the importer.
///
/// ### What it is for, and what it is not for
/// It is a **record**, not a lock. Idempotency comes from ``SystemContactLink`` — a contact that
/// already has a link is reported as already-linked and skipped — so a retry is safe whether or not a
/// session says anything, and a cancelled run leaves a consistent database because every contact is
/// written in its own transaction.
///
/// What the session adds is the ability to say what happened: how many were created, how many linked,
/// what failed and why, and whether the user stopped it. That is what the *last import* line reads,
/// and what makes a partial failure visible rather than silent.
@Model
public final class ContactImportSession {
    public var id: UUID = UUID()

    public var startedAt: Date = Date()
    public var finishedAt: Date?

    public var totalConsidered: Int = 0
    public var createdCount: Int = 0
    public var linkedCount: Int = 0
    public var skippedCount: Int = 0

    /// JSON-encoded `[ContactImportFailure]`.
    ///
    /// Encoded rather than modelled because failures are written once, read as a whole, and never
    /// queried — the same reasoning as the labelled values on `PersonProfile`.
    public var failuresData: Data?

    public var wasCancelled: Bool = false

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

extension ContactImportSession {
    public var failures: [ContactImportFailure] {
        get {
            guard let failuresData else { return [] }
            return (try? JSONDecoder().decode([ContactImportFailure].self, from: failuresData)) ?? []
        }
        set {
            failuresData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    public var report: ContactImportReport {
        ContactImportReport(
            created: createdCount,
            linked: linkedCount,
            skipped: skippedCount,
            failures: failures,
            wasCancelled: wasCancelled
        )
    }

    public var isFinished: Bool { finishedAt != nil }
}
