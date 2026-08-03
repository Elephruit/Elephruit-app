import ElephruitCore
import Foundation

public enum RecordsScope: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case all
    case unsorted
    case people
    case pets
    case vehicles
    case organizations
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All Records"
        case .unsorted: "Unsorted"
        case .people: "People"
        case .pets: "Pets"
        case .vehicles: "Vehicles"
        case .organizations: "Organizations"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: "circle.grid.2x2"
        case .unsorted: "tray"
        case .people: RecordType.person.symbolName
        case .pets: RecordType.pet.symbolName
        case .vehicles: RecordType.vehicle.symbolName
        case .organizations: RecordType.organization.symbolName
        case .other: RecordType.other.symbolName
        }
    }

    public var recordType: RecordType? {
        switch self {
        case .all, .unsorted: nil
        case .people: .person
        case .pets: .pet
        case .vehicles: .vehicle
        case .organizations: .organization
        case .other: .other
        }
    }
}
