import EverythingCore
import Foundation
import SwiftData

/// How an attachment's bytes are held.
public enum AttachmentStorageKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Everything owns a copy inside its container. The default, because a copy cannot
    /// be broken by the user moving the original, and it can sync.
    case managedCopy

    /// Everything holds a security-scoped bookmark to a file the user owns. Offered for
    /// large files. May go stale, which is a modelled state rather than an error.
    case externalBookmark

    public var displayName: String {
        switch self {
        case .managedCopy: "Copied into Everything"
        case .externalBookmark: "Linked to a file on this Mac"
        }
    }
}

/// Metadata for a file attached to an item.
///
/// The **bytes are not here** — they live on disk under
/// `Application Support/Everything/Attachments/<id>/`, or in the user's own file system
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

    /// Names and roles, folded into ``Item/searchText`` so searching for a person finds
    /// them by any of their parts.
    public var searchableText: String {
        var parts = [givenName, familyName]
        if let roleTitle { parts.append(roleTitle) }
        parts.append(contentsOf: emails.map(\.value))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Given + family, or whichever exists.
    public var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
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
/// never merged into it, so Everything can never corrupt the user's calendar. Defined in
/// milestone 1; populated in Phase 3.
@Model
public final class EventReference {
    public var id: UUID = UUID()

    /// EventKit's `calendarItemIdentifier`.
    public var calendarItemIdentifier: String = ""

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
        calendarItemIdentifier: String = "",
        cachedTitle: String = "",
        startAt: Date? = nil,
        endAt: Date? = nil
    ) {
        self.id = id
        self.calendarItemIdentifier = calendarItemIdentifier
        self.cachedTitle = cachedTitle
        self.startAt = startAt
        self.endAt = endAt
    }
}

extension EventReference {
    public var isReferenceLost: Bool { referenceLostAt != nil }

    public var displayTitle: String {
        cachedTitle.isEmpty ? "Untitled Event" : cachedTitle
    }
}
