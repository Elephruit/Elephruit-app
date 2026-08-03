import Foundation

/// The reusable kinds understood by the Records module.
///
/// A record remains an `Item`; this value describes the real-world subject represented by that
/// item. Unknown values are kept as ``other`` so adding a type never makes an older build discard
/// the record.
public enum RecordType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case person
    case pet
    case vehicle
    case organization
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: "Person"
        case .pet: "Pet"
        case .vehicle: "Vehicle"
        case .organization: "Organization"
        case .other: "Other"
        }
    }

    public var pluralDisplayName: String {
        switch self {
        case .person: "People"
        case .pet: "Pets"
        case .vehicle: "Vehicles"
        case .organization: "Organizations"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .person: "person"
        case .pet: "pawprint"
        case .vehicle: "car"
        case .organization: "building.2"
        case .other: "cube"
        }
    }
}

/// How a record entered the library. This controls filing, never ownership: a contact-backed
/// person and a manually entered person are the same kind of record.
public enum RecordOrigin: String, Codable, Sendable, Hashable {
    case manual
    case contacts
    case existingPeople
}
