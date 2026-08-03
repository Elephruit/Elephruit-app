import ElephruitCore
import Foundation
import SwiftData

/// How an attachment's bytes are held.
public enum AttachmentStorageKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Elephruit owns a copy inside its container. The default, because a copy cannot
    /// be broken by the user moving the original, and it can sync.
    case managedCopy

    /// Elephruit holds a security-scoped bookmark to a file the user owns. Offered for
    /// large files. May go stale, which is a modelled state rather than an error.
    case externalBookmark

    public var displayName: String {
        switch self {
        case .managedCopy: "Copied into Elephruit"
        case .externalBookmark: "Linked to a file on this Mac"
        }
    }
}

/// Metadata for a file attached to an item.
///
/// The **bytes are not here** — they live on disk under
/// `Application Support/Elephruit/Attachments/<id>/`, or in the user's own file system
/// behind a bookmark. See `docs/adr/0003-attachments-on-disk.md`.
///
/// Milestone 1 defines this entity so that Phase 2's attachment UI is not a migration.
/// Nothing in milestone 1 creates one.
@Model
public final class Attachment {
    public var id: UUID = UUID()

    /// As shown to the user, and as written on export.
    public var filename: String = ""

    /// Uniform Type Identifier — `public.png`, `com.adobe.pdf`.
    public var typeIdentifier: String = "public.data"

    public var byteCount: Int = 0

    /// SHA-256 of the bytes, hex-encoded. Used for duplicate detection on import.
    public var contentHash: String?

    public var createdAt: Date = Date()

    /// ``AttachmentStorageKind`` raw value.
    public var storageKindRaw: String = AttachmentStorageKind.managedCopy.rawValue

    /// For ``AttachmentStorageKind/managedCopy``: path relative to the attachments root,
    /// so the container can move without invalidating every row.
    public var relativePath: String?

    /// For ``AttachmentStorageKind/externalBookmark``: the security-scoped bookmark.
    ///
    /// This is *not* a secret — it is an OS-issued capability token for a file the user
    /// already chose — so the store is its correct home. Secrets go in the Keychain.
    public var bookmarkData: Data?

    /// Where the external file was last seen, for the "Locate…" recovery flow.
    public var lastKnownPath: String?

    /// Set when a bookmark fails to resolve. A state, not an error.
    public var referenceLostAt: Date?

    /// Text pulled out of the file on device — OCR for images, extraction for PDFs.
    /// Populated in Phase 3; feeds ``Item/searchText``.
    public var extractedText: String?

    public var owner: Item?

    public init(
        id: UUID = UUID(),
        filename: String = "",
        typeIdentifier: String = "public.data",
        byteCount: Int = 0,
        storageKind: AttachmentStorageKind = .managedCopy,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.storageKindRaw = storageKind.rawValue
        self.createdAt = createdAt
    }
}

extension Attachment {
    public var storageKind: AttachmentStorageKind {
        get { AttachmentStorageKind(rawValue: storageKindRaw) ?? .managedCopy }
        set { storageKindRaw = newValue.rawValue }
    }

    /// Whether the bytes are currently reachable, as far as the store knows.
    public var isReferenceLost: Bool { referenceLostAt != nil }

    /// Path within an export bundle: `Attachments/<id>/<filename>`. Predictable by
    /// design, so an export is navigable without the app.
    public var exportRelativePath: String {
        "Attachments/\(id.uuidString)/\(filename.isEmpty ? id.uuidString : filename)"
    }

    public var displayName: String {
        filename.isEmpty ? "Untitled File" : filename
    }

    public var formattedSize: String {
        byteCount.formatted(.byteCount(style: .file))
    }
}

/// The CRM detail for an ``ItemKind/person``.
///
/// A satellite entity rather than more columns on ``Item``, because these fields are
/// substantial and apply to exactly one kind. Contacts remains authoritative for
/// anything mirrored from it; ``PersonProfile/contactsIdentifier`` is a soft pointer,
/// not a copy of ownership.
///
/// Defined in milestone 1 so Phase 3's People UI is not a migration.
@Model
public final class PersonProfile {
    public var id: UUID = UUID()

    public var givenName: String = ""
    public var familyName: String = ""

    /// JSON-encoded `[LabelledValue]`. Encoded rather than modelled because these are
    /// read and written as a whole and never queried field-by-field.
    public var emailsData: Data?
    public var phonesData: Data?

    /// Day and month matter; the year often is not known. Stored whole and rendered
    /// according to whether the year is meaningful.
    public var birthday: Date?
    public var birthdayHasYear: Bool = false

    public var roleTitle: String?

    /// Identifier in the system Contacts store, when the user has linked them.
    /// A pointer only — Contacts owns the data it holds.
    public var contactsIdentifier: String?

    // MARK: Added with person records
    //
    // Every one of these is optional or defaulted, so the store gains nullable columns and nothing
    // is rewritten. See `SchemaV4`.

    /// What the person goes by, when it is not their given name.
    public var nickname: String?

    /// How to say their name. Free text — "MY-uh", "rhymes with papaya" — because a phonetic
    /// alphabet nobody can read is worse than the note somebody would actually write.
    public var pronunciation: String?

    /// Recorded only when the person has stated them, and never guessed from a name.
    public var pronouns: String?

    public var organizationName: String?

    /// Where they are, as free text. Not geocoded and not resolved to a place record: the app makes
    /// no network requests, and "Austin" is enough to answer the question it is asked.
    public var locationText: String?

    /// IANA identifier, for the local-time line in the header.
    ///
    /// Chosen by the user rather than derived from ``locationText``, because deriving it needs a
    /// geocoder and a wrong time zone on somebody's card is worse than none.
    public var timeZoneIdentifier: String?

    /// JSON-encoded `[LabelledValue]`, on the same terms as emails and phones.
    public var addressesData: Data?
    public var websitesData: Data?

    // MARK: Added so a linked contact can be corrected in full
    //
    // Contacts holds these and this model did not, which meant editing somebody here could only ever
    // offer the address book a subset of what it already had. Nullable, so `SchemaV6` adds columns
    // and rewrites nothing. See `ContactWrite`.

    /// Which part of an organisation they work in — "Design", "Legal".
    public var departmentName: String?

    /// The parts of a name that are neither given nor family.
    ///
    /// Separate rather than folded into ``givenName``, because Contacts keeps them separate and a
    /// round trip through one combined field is how "Dr" becomes somebody's first name.
    public var middleName: String?
    public var namePrefix: String?
    public var nameSuffix: String?

    /// Which account the linked Contacts record lives in — "iCloud", "Google", "On My Mac".
    ///
    /// Stored for display and for the duplicate explanation, never used to decide anything.
    public var contactsAccountName: String?

    /// When the linked Contacts record was last read.
    public var contactsRefreshedAt: Date?

    /// A record created only so somebody could be mentioned — Maya's son Jack, before he has any
    /// details of his own.
    ///
    /// A placeholder is a real person record in every respect; the flag exists so lists can offer to
    /// fill one in rather than showing an empty page as though something had gone wrong.
    public var isPlaceholder: Bool = false

    /// The user's own card. At most one profile in a library has this set.
    public var isMyCard: Bool = false

    public var item: Item?

    public init(
        id: UUID = UUID(),
        givenName: String = "",
        familyName: String = "",
        roleTitle: String? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.roleTitle = roleTitle
    }
}

/// A labelled contact value — `("work", "sarah@example.com")`.
public struct LabelledValue: Codable, Sendable, Hashable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

extension PersonProfile {
    public var emails: [LabelledValue] {
        get { Self.decode(emailsData) }
        set { emailsData = Self.encode(newValue) }
    }

    public var phones: [LabelledValue] {
        get { Self.decode(phonesData) }
        set { phonesData = Self.encode(newValue) }
    }

    public var addresses: [LabelledValue] {
        get { Self.decode(addressesData) }
        set { addressesData = Self.encode(newValue) }
    }

    public var websites: [LabelledValue] {
        get { Self.decode(websitesData) }
        set { websitesData = Self.encode(newValue) }
    }

    /// Names and roles, folded into ``Item/searchText`` so searching for a person finds
    /// them by any of their parts.
    ///
    /// Phone numbers are deliberately absent. Folding them in would put every digit of somebody's
    /// mobile into a column that a text search over the whole library reads — and "555" would match
    /// three people for reasons the user cannot see. Numbers are searched by the person repository,
    /// normalised, where a match means what it says.
    public var searchableText: String {
        var parts = [givenName, familyName]
        if let nickname { parts.append(nickname) }
        if let roleTitle { parts.append(roleTitle) }
        if let organizationName { parts.append(organizationName) }
        if let locationText { parts.append(locationText) }
        parts.append(contentsOf: emails.map(\.value))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Given + family, or whichever exists.
    public var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every part of the name, in reading order.
    ///
    /// Distinct from ``fullName`` and used for a different question. `fullName` is what to call the
    /// record; this is what the parts *spell*, and comparing it against the item's title is how the
    /// app tells "the name was renamed and the parts have fallen behind" from "the parts were set
    /// deliberately and say more than the two `fullName` covers". Without the distinction, saving a
    /// person as "Dr Maya Chen" would be re-split on the next edit into a first name of "Dr".
    public var assembledName: String {
        [namePrefix, givenName, middleName, familyName, nameSuffix]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// What to call them in a sentence — the nickname if they have one.
    public var preferredName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if !givenName.isEmpty { return givenName }
        return fullName
    }

    /// The birthday as a partial date, honouring the fact that the year is usually unknown.
    ///
    /// Reads the stored `Date` for its month and day only unless ``birthdayHasYear`` says otherwise,
    /// so a placeholder year written by an import can never be shown as though it were real.
    public func birthdayDate(calendar: Calendar) -> PartialDate? {
        guard let birthday else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: birthday)
        guard let month = components.month, let day = components.day else { return nil }
        return PartialDate(year: birthdayHasYear ? components.year : nil, month: month, day: day)
    }

    /// Every stored contact detail, in the order a card should read.
    ///
    /// The same four lists as ``destinations()``, projected for *display* rather than for dialling:
    /// a detail keeps its label so the card can say which of two numbers is the work one, and drops
    /// the preferred-destination bookkeeping, which is a question about actions and not about
    /// reading.
    public func contactDetails() -> [ContactDetail] {
        ContactCard.details(
            emails: emails.map { (label: $0.label, value: $0.value) },
            phones: phones.map { (label: $0.label, value: $0.value) },
            addresses: addresses.map { (label: $0.label, value: $0.value) },
            websites: websites.map { (label: $0.label, value: $0.value) }
        )
    }

    /// Everything that could be dialled, written to, or opened for this person.
    public func destinations() -> [ContactDestination] {
        var result: [ContactDestination] = []

        for (index, phone) in phones.enumerated() {
            result.append(
                ContactDestination(
                    label: phone.label, value: phone.value, source: .phone,
                    // The first of each kind is the preferred one. That is a convention the user
                    // controls by reordering, not a judgement the app makes.
                    isPreferred: index == 0 && phones.count > 1
                )
            )
        }
        for (index, email) in emails.enumerated() {
            result.append(
                ContactDestination(
                    label: email.label, value: email.value, source: .email,
                    isPreferred: index == 0 && emails.count > 1
                )
            )
        }
        for address in addresses {
            result.append(ContactDestination(label: address.label, value: address.value, source: .address))
        }
        for site in websites {
            result.append(ContactDestination(label: site.label, value: site.value, source: .website))
        }

        return result
    }

    /// The time where they are, when a time zone has been recorded and it differs from the user's.
    ///
    /// `nil` when the two match — "it is 3:42 pm there" is noise when it is 3:42 pm here, and the
    /// header is better off short.
    public func localTime(at instant: Date, in userZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        guard zone.secondsFromGMT(for: instant) != userZone.secondsFromGMT(for: instant) else { return nil }

        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return instant.formatted(style)
    }

    /// This person as the identity matcher sees them.
    public func identityCandidate(calendar: Calendar) -> IdentityCandidate? {
        guard let item else { return nil }
        return IdentityCandidate(
            id: item.id,
            fullName: fullName.isEmpty ? item.displayTitle : fullName,
            emails: emails.map(\.value),
            phones: phones.map(\.value),
            contactsIdentifier: contactsIdentifier,
            accountName: contactsAccountName,
            organization: organizationName,
            birthday: birthdayDate(calendar: calendar)
        )
    }

    private static func decode(_ data: Data?) -> [LabelledValue] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([LabelledValue].self, from: data)) ?? []
    }

    private static func encode(_ values: [LabelledValue]) -> Data? {
        values.isEmpty ? nil : try? JSONEncoder().encode(values)
    }
}

/// A pointer to a calendar event, plus enough cached detail to render it offline.
///
/// **EventKit is authoritative.** This record is refreshed from the system store and
/// never merged into it, so Elephruit can never corrupt the user's calendar. Defined in
/// milestone 1; populated in Phase 3.
@Model
public final class EventReference {
    public var id: UUID = UUID()

    /// EventKit's `calendarItemIdentifier`.
    ///
    /// Kept for stores written before occurrence-stable identity existed. New references use
    /// ``EventReference/identityKey``; this is never written now, only read.
    public var calendarItemIdentifier: String = ""

    /// ``EventIdentity/storageKey`` — the external identifier plus, for a recurring event, which
    /// occurrence.
    ///
    /// A single column rather than two, so matching a stored link is one equality test rather than a
    /// compound predicate, and so a `#Predicate` comparing it stays within the clause ceiling
    /// documented on `ItemPredicateBuilder`.
    public var identityKey: String = ""

    public var cachedTitle: String = ""
    public var startAt: Date?
    public var endAt: Date?
    public var isAllDay: Bool = false
    public var calendarName: String?
    public var locationName: String?

    /// When the cached fields were last read from EventKit.
    public var lastRefreshedAt: Date?

    /// Set when the event no longer exists in EventKit — cancelled, or the calendar was
    /// removed. A state, not an error.
    public var referenceLostAt: Date?

    public var item: Item?

    public init(
        id: UUID = UUID(),
        identityKey: String = "",
        calendarItemIdentifier: String = "",
        cachedTitle: String = "",
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.id = id
        self.identityKey = identityKey
        self.calendarItemIdentifier = calendarItemIdentifier
        self.cachedTitle = cachedTitle
        self.startAt = startAt
        self.endAt = endAt
    }
}

extension EventReference {
    /// The occurrence this reference points at.
    ///
    /// Falls back to the legacy identifier column for references written before occurrence identity
    /// existed, so an old link resolves to its series rather than to nothing.
    public var identity: EventIdentity? {
        if let parsed = EventIdentity.fromStorageKey(identityKey) { return parsed }
        guard !calendarItemIdentifier.isEmpty else { return nil }
        return EventIdentity(externalIdentifier: calendarItemIdentifier)
    }

    /// Whether the event this points at could not be found the last time it was checked.
    public var isLost: Bool { referenceLostAt != nil }

    /// Copies the current state of an event into the cached columns.
    ///
    /// The cache is what lets a linked meeting still render its title and time when the calendar is
    /// switched off or permission is revoked — a link that goes blank the moment access is withdrawn
    /// would make the note it is attached to unreadable.
    public func absorb(_ event: CalendarEventSummary, at now: Date) {
        identityKey = event.identity.storageKey
        cachedTitle = event.title
        startAt = event.startAt
        endAt = event.endAt
        isAllDay = event.isAllDay
        calendarName = event.calendarName
        locationName = event.locationName
        lastRefreshedAt = now
        referenceLostAt = nil
    }

    /// Records that the event could not be found.
    ///
    /// A state rather than a deletion: the cached title and time stay, so the user sees *what* they
    /// linked to and that it is gone, rather than an empty row.
    public func markLost(at now: Date) {
        referenceLostAt = now
        lastRefreshedAt = now
    }
}

extension EventReference {
    public var isReferenceLost: Bool { referenceLostAt != nil }

    public var displayTitle: String {
        cachedTitle.isEmpty ? "Untitled Event" : cachedTitle
    }
}
