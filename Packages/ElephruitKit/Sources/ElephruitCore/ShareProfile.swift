import Foundation

/// One field of the user's own card that a share profile may include.
public enum ShareableField: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fullName
    case pronouns
    case pronunciation
    case jobTitle
    case organization
    case personalEmail
    case workEmail
    case mobilePhone
    case workPhone
    case website
    case postalAddress
    case birthday
    case photo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullName: "Name"
        case .pronouns: "Pronouns"
        case .pronunciation: "Name pronunciation"
        case .jobTitle: "Job title"
        case .organization: "Organisation"
        case .personalEmail: "Personal email"
        case .workEmail: "Work email"
        case .mobilePhone: "Mobile"
        case .workPhone: "Work phone"
        case .website: "Website"
        case .postalAddress: "Address"
        case .birthday: "Birthday"
        case .photo: "Photo"
        }
    }

    /// Fields that identify a person's home or their body, and which therefore default to off.
    public var isPersonallySensitive: Bool {
        switch self {
        case .postalAddress, .birthday, .mobilePhone: true
        default: false
        }
    }
}

/// A named subset of the user's own details, for handing out.
///
/// ### Why several profiles rather than one card with checkboxes
/// The decision "what does this person get" is made once per audience, not once per encounter.
/// Somebody meeting a plumber and somebody meeting a conference contact want different answers, and
/// making that a saved, named thing means the choice is made calmly in advance rather than in the
/// two seconds before a QR code is scanned.
public struct ShareProfile: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var fields: Set<ShareableField>

    /// Whether this is the one offered first.
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, fields: Set<ShareableField>, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.fields = fields
        self.isDefault = isDefault
    }

    /// The three profiles a new library starts with.
    ///
    /// Chosen so the *minimal* one is genuinely minimal — a name and one way to reply — because the
    /// case it exists for is handing details to somebody the user has just met.
    public static func defaults() -> [ShareProfile] {
        [
            ShareProfile(
                name: "Professional",
                fields: [.fullName, .pronouns, .jobTitle, .organization, .workEmail, .workPhone, .website],
                isDefault: true
            ),
            ShareProfile(
                name: "Personal",
                fields: [.fullName, .pronouns, .pronunciation, .personalEmail, .mobilePhone, .photo]
            ),
            ShareProfile(name: "Minimal", fields: [.fullName, .personalEmail]),
        ]
    }

    /// Whether this profile would disclose a home address, a birthday, or a mobile number.
    ///
    /// Surfaced beside the share button, once, in plain language. Not a warning dialog — the user
    /// chose these fields deliberately — but a reminder of what is about to be handed over.
    public var includesSensitiveFields: Bool {
        fields.contains { $0.isPersonallySensitive }
    }

    public var sensitiveFieldNames: [String] {
        fields.filter(\.isPersonallySensitive).map(\.displayName).sorted()
    }
}

/// The values behind the fields, for one person.
public struct ShareableCard: Sendable, Hashable {
    public var values: [ShareableField: String]

    public init(values: [ShareableField: String] = [:]) {
        self.values = values
    }

    public subscript(field: ShareableField) -> String? {
        get { values[field] }
        set { values[field] = newValue }
    }
}

/// Turns a card and a profile into a vCard.
///
/// ### What is guaranteed never to be in the output
/// Observations, private reflections, relationship history, timeline entries, internal tags,
/// confidence, provenance, and every identifier this app uses internally. The emitter is given a
/// ``ShareableCard`` — a flat dictionary of contact fields — precisely so that it *cannot* reach
/// anything else. `ShareProfileTests` asserts on the absence rather than trusting the structure.
public enum VCardEmitter {
    /// vCard 3.0, which every macOS and iOS version in use imports without complaint.
    public static func emit(card: ShareableCard, profile: ShareProfile) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]

        func include(_ field: ShareableField) -> String? {
            guard profile.fields.contains(field) else { return nil }
            guard let value = card[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        if let name = include(.fullName) {
            lines.append("FN:\(escape(name))")
            let parts = name.split(separator: " ").map(String.init)
            let family = parts.count > 1 ? parts[parts.count - 1] : ""
            let given = parts.first ?? ""
            lines.append("N:\(escape(family));\(escape(given));;;")
        }

        if let title = include(.jobTitle) { lines.append("TITLE:\(escape(title))") }
        if let organization = include(.organization) { lines.append("ORG:\(escape(organization))") }
        if let email = include(.personalEmail) { lines.append("EMAIL;TYPE=INTERNET,HOME:\(escape(email))") }
        if let email = include(.workEmail) { lines.append("EMAIL;TYPE=INTERNET,WORK:\(escape(email))") }
        if let phone = include(.mobilePhone) { lines.append("TEL;TYPE=CELL:\(escape(phone))") }
        if let phone = include(.workPhone) { lines.append("TEL;TYPE=WORK,VOICE:\(escape(phone))") }
        if let site = include(.website) { lines.append("URL:\(escape(site))") }
        if let address = include(.postalAddress) { lines.append("ADR;TYPE=HOME:;;\(escape(address));;;;") }
        if let birthday = include(.birthday) { lines.append("BDAY:\(escape(birthday))") }

        // Pronouns and pronunciation have no standard vCard property, so they go in the note field
        // rather than being dropped. A custom `X-` property would be invisible to every app that
        // matters, which is the same as losing them.
        var noteParts: [String] = []
        if let pronouns = include(.pronouns) { noteParts.append("Pronouns: \(pronouns)") }
        if let pronunciation = include(.pronunciation) { noteParts.append("Pronounced: \(pronunciation)") }
        if !noteParts.isEmpty {
            lines.append("NOTE:\(escape(noteParts.joined(separator: " · ")))")
        }

        lines.append("END:VCARD")
        // vCard requires CRLF. Some parsers tolerate bare newlines; the ones that do not fail
        // silently and produce an empty contact, which is worse than an error.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The characters vCard gives meaning to.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// A filename for the exported card.
    public static func filename(for name: String, profile: ShareProfile) -> String {
        let base = name.isEmpty ? "Contact" : name
        let safe = base.replacingOccurrences(of: "/", with: "-")
        return "\(safe) (\(profile.name)).vcf"
    }
}
