import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@testable import ElephruitFeatures

/// The seeder run backwards.
///
/// These exist because the forward direction was once run against a real library — development
/// mode does not redirect the store — and the only acceptable cleanup is one that provably touches
/// nothing else. The removal is the generator's own formulas as a matcher, so the property to
/// assert is exact inversion: everything planted is found, and nothing else is.
@Suite("Seeded people removal")
@MainActor
struct SeededPeopleRemovalTests {

    @Test("Removal takes out every seeded person and nobody else")
    func removalIsTheExactInverseOfSeeding() throws {
        let services = AppServices.inMemory(populated: false)

        // Real-shaped records, including the adversarial shapes: a name with a trailing number,
        // and a name straight out of the seed pools without its number.
        let realPeople = [
            PersonDraft(fullName: "Aaron Baker"),
            PersonDraft(fullName: "Amara Abara"),
            PersonDraft(fullName: "Blur 2", organizationName: "Northwind Studio"),
            PersonDraft(fullName: "Amanda Zehrer", organizationName: "Cigna"),
        ]
        for draft in realPeople {
            _ = try services.persons.createPerson(draft)
        }

        try BulkPeopleSampleData.populate(services: services, count: 400)

        var query = ItemQuery()
        query.kinds = [.person]
        #expect(try services.items.count(matching: query) == 404)

        services.removeSeededPeople()

        let remaining = try services.items.items(matching: query)
        #expect(remaining.count == realPeople.count)
        #expect(
            Set(remaining.map(\.title)) == Set(realPeople.map(\.fullName)),
            "removal touched a record the seeder did not create"
        )
    }

    @Test("A person the seeder did not create is never matched")
    func realPeopleAreNotSeeded() throws {
        let services = AppServices.inMemory(populated: false)

        // The hardest case: the right name at the right index, but none of the derived fields.
        let nearMiss = try services.persons.createPerson(PersonDraft(fullName: "Amara Abara 1"))
        #expect(!BulkPeopleSampleData.isSeeded(nearMiss))

        try BulkPeopleSampleData.populate(services: services, count: 1)

        var query = ItemQuery()
        query.kinds = [.person]
        let all = try services.items.items(matching: query)
        let seeded = all.filter { BulkPeopleSampleData.isSeeded($0) }

        #expect(seeded.count == 1)
        #expect(seeded.first?.id != nearMiss.id)
    }

    @Test("Removal refuses to run outside development mode")
    func removalIsDevelopmentOnly() throws {
        let services = AppServices.inMemory(populated: false)
        guard !services.isDevelopmentMode else { return }

        try BulkPeopleSampleData.populate(services: services, count: 5)
        services.removeSeededPeople()

        var query = ItemQuery()
        query.kinds = [.person]
        #expect(try services.items.count(matching: query) == 5, "removal ran without development mode")
    }
}
