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
        case .all: "person.text.rectangle"
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

    public var hint: String {
        switch self {
        case .all: "Every person and thing you track."
        case .unsorted: "Imported records waiting for you to file them."
        case .people: "Human records, with contact history and relationship context."
        case .pets: "Pets, with care notes, appointments, and medication details."
        case .vehicles: "Vehicles, with maintenance history and identifying details."
        case .organizations: "Companies, teams, and other organizations."
        case .other: "Records that do not fit one of the named types."
        case .recentlyViewed: "People whose records you opened most recently."
        case .favorites: "People you marked for quick access."
        case .celebrations: "Birthdays, anniversaries, and other dates coming up."
        case .needsFollowUp: "People you have not contacted within your follow-up window."
        case .fromContacts: "Person records linked to the system Contacts app."
        case .duplicates: "Person records that may describe the same person."
        case .group: "Person records collected in this saved group."
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
