import ElephruitCore
import Foundation

public enum RecordsScope: Hashable, Sendable, Codable, Identifiable {
    case all
    case unsorted
    case people
    case pets
    case vehicles
    case organizations
    case other
    case recentlyViewed
    case favorites
    case celebrations
    case needsFollowUp
    case fromContacts
    case duplicates
    case group(id: UUID)

    public var id: String {
        switch self {
        case .all: "all"
        case .unsorted: "unsorted"
        case .people: "people"
        case .pets: "pets"
        case .vehicles: "vehicles"
        case .organizations: "organizations"
        case .other: "other"
        case .recentlyViewed: "recently-viewed"
        case .favorites: "favorites"
        case .celebrations: "celebrations"
        case .needsFollowUp: "needs-follow-up"
        case .fromContacts: "from-contacts"
        case .duplicates: "duplicates"
        case .group(let id): "group-\(id.uuidString)"
        }
    }

    public static let typeFilters: [RecordsScope] = [
        .all, .unsorted, .people, .pets, .vehicles, .organizations, .other,
    ]

    public static let personViews: [RecordsScope] = [
        .recentlyViewed, .favorites, .celebrations, .needsFollowUp, .fromContacts, .duplicates,
    ]

    public var title: String {
        switch self {
        case .all: "All Records"
        case .unsorted: "Unsorted"
        case .people: "People"
        case .pets: "Pets"
        case .vehicles: "Vehicles"
        case .organizations: "Organizations"
        case .other: "Other"
        case .recentlyViewed: "Recently Viewed"
        case .favorites: "Favorites"
        case .celebrations: "Celebrations"
        case .needsFollowUp: "Needs Follow-up"
        case .fromContacts: "From Contacts"
        case .duplicates: "Possible Duplicates"
        case .group: "Group"
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
        case .recentlyViewed: "clock.arrow.circlepath"
        case .favorites: "star"
        case .celebrations: "birthday.cake"
        case .needsFollowUp: "hand.wave"
        case .fromContacts: "person.crop.rectangle.stack"
        case .duplicates: "person.crop.circle.badge.questionmark"
        case .group: "person.2.circle"
        }
    }

    public var recordType: RecordType? {
        switch self {
        case .all, .unsorted, .recentlyViewed, .favorites, .celebrations, .needsFollowUp,
             .fromContacts, .duplicates, .group:
            nil
        case .people: .person
        case .pets: .pet
        case .vehicles: .vehicle
        case .organizations: .organization
        case .other: .other
        }
    }
}
