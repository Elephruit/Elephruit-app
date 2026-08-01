import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// Invents enough people to make the People list's performance a thing that can be observed.
///
/// ### Why this exists
/// The stated requirement for this module is that it stays fast with four hundred records, and the
/// hand-written sample library contains eight. Eight people cannot demonstrate a scrolling problem
/// and cannot demonstrate its absence either, so every claim about People's performance has so far
/// been an argument about the code rather than a measurement of the app. A reviewer either pointed
/// the build at their own address book — which is the one thing the fixtures exist to avoid — or
/// took it on faith.
///
/// These records are deliberately *shallow*: a name, a role, an organisation, a place, and one email
/// address. A list row reads exactly those fields, so the row's cost is reproduced exactly; anything
/// deeper would slow the seeding without changing what the list has to draw.
///
/// Every value is obviously invented. Names are assembled from two small pools, addresses are on
/// `example.com`, and no telephone number is real.
public enum BulkPeopleSampleData {
    /// Distinct enough to sort into most letters of the alphabet, which is what the section index
    /// and the A–Z jump bar need in order to be exercised at all.
    private static let givenNames = [
        "Amara", "Bex", "Caleb", "Dara", "Esme", "Felix", "Gita", "Hana", "Idris", "Jonas",
        "Kiran", "Lena", "Mateo", "Nadia", "Oscar", "Priya", "Quentin", "Rosa", "Selim", "Tomas",
        "Ursula", "Viggo", "Wren", "Xiomara", "Yusuf", "Zara", "Anders", "Beatrix", "Cormac", "Delphine",
    ]

    private static let familyNames = [
        "Abara", "Bergstrom", "Castellanos", "Dvorak", "Eriksen", "Fontaine", "Gallagher", "Haddad",
        "Ibarra", "Jorgensen", "Kowalski", "Lindqvist", "Mbeki", "Nakamura", "Okonjo", "Pereira",
        "Quintero", "Rasmussen", "Sandoval", "Thorne", "Ueda", "Vasquez", "Whitfield", "Xu",
        "Yilmaz", "Zeitler",
    ]

    private static let organizations = [
        "Northwind Studio", "Acme Instruments", "Harbour & Vane", "Pellucid Labs", "Ridgeline Co-op",
        "Vantage Press", "Sundial Systems", "Bellweather Group",
    ]

    private static let roles = [
        "Principal engineer", "Head of Design", "Account manager", "Researcher", "Founder",
        "Operations lead", "Copywriter", "Data analyst", "Support engineer", "Illustrator",
    ]

    private static let places = [
        "Austin", "Lisbon", "Chicago", "Berlin", "Toronto", "Nairobi", "Osaka", "Glasgow",
    ]

    /// Adds `count` invented people to the library.
    ///
    /// Deterministic: the same count always produces the same people, in the same order, with the
    /// same organisations. A seeded list that changed between runs would make "is this slower than
    /// last time" unanswerable, which is the only question the list exists to answer.
    @MainActor
    public static func populate(services: AppServices, count: Int) throws(AppError) {
        let people = services.persons
        let items = services.items

        for index in 0..<count {
            // Coprime strides through the two pools, so the pairing does not repeat until both are
            // exhausted and the alphabet fills evenly rather than in blocks.
            let given = givenNames[index % givenNames.count]
            let family = familyNames[(index * 7) % familyNames.count]

            // The index is part of the name because two pools of thirty and twenty-six collide long
            // before four hundred, and a list with sixteen identical "Amara Abara" rows tests
            // deduplication rather than scrolling.
            let fullName = "\(given) \(family) \(index + 1)"

            let person = try people.createPerson(
                PersonDraft(
                    fullName: fullName,
                    givenName: given,
                    familyName: family,
                    roleTitle: roles[index % roles.count],
                    organizationName: organizations[index % organizations.count],
                    locationText: places[index % places.count],
                    emails: [
                        LabelledValue(
                            label: "work",
                            value: "\(given.lowercased()).\(index + 1)@example.com"
                        )
                    ]
                )
            )

            // A minority are favourites, so the Favorites scope has something in it and the star in
            // the row is drawn for some rows and not others — which is the case that costs, because
            // a row that never varies can be laid out once.
            if index % 11 == 0 {
                try items.update(person) { $0.isFavorite = true }
            }
        }
    }
}
