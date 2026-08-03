import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Testing

@Suite("Records service")
@MainActor
struct RecordsServiceTests {
    private func fixture() throws -> (
        StoreFixture,
        SwiftDataPersonRepository,
        RecordsService
    ) {
        let store = try StoreFixture()
        let people = SwiftDataPersonRepository(
            context: store.context,
            items: store.items,
            dateProvider: store.dateProvider
        )
        let records = RecordsService(
            context: store.context,
            items: store.items,
            people: people,
            dateProvider: store.dateProvider
        )
        return (store, people, records)
    }

    @Test("Different subject types share one persisted records collection")
    func createsPeoplePetsAndVehicles() throws {
        let (store, _, records) = try fixture()

        let person = try records.create(RecordDraft(name: "Maya Chen", type: .person))
        let pet = try records.create(RecordDraft(
            name: "Juniper",
            type: .pet,
            details: [
                "species": "Dog",
                "vet": "Lakeview Animal Hospital",
                "vet_address": "10 Lakeview Drive",
                "vet_phone": "+15125550120",
                "vet_maps_url": "https://maps.apple.com/?q=Lakeview%20Animal%20Hospital",
                "vet_map_item_id": "map-item-123",
            ]
        ))
        let vehicle = try records.create(RecordDraft(
            name: "Family wagon",
            type: .vehicle,
            details: ["year": "2024", "make": "Volvo"]
        ))

        #expect(try records.allRecords().map(\.title) == ["Family wagon", "Juniper", "Maya Chen"])
        #expect(records.type(of: person) == .person)
        #expect(records.type(of: pet) == .pet)
        #expect(records.type(of: vehicle) == .vehicle)

        let persistedPet = try store.requireItem(id: pet.id)
        #expect(persistedPet.recordProfile?.details["vet"] == "Lakeview Animal Hospital")
        #expect(persistedPet.recordProfile?.details["vet_address"] == "10 Lakeview Drive")
        #expect(persistedPet.recordProfile?.details["vet_phone"] == "+15125550120")
        #expect(persistedPet.recordProfile?.details["vet_map_item_id"] == "map-item-123")
    }

    @Test("People retain structured Apple Contacts fields")
    func createsStructuredPerson() throws {
        let (_, _, records) = try fixture()

        let person = try records.create(RecordDraft(
            name: "Dr Maya Lin Chen PhD",
            type: .person,
            details: [
                "given_name": "Maya",
                "middle_name": "Lin",
                "family_name": "Chen",
                "name_prefix": "Dr",
                "name_suffix": "PhD",
                "nickname": "May",
                "department": "Design",
                "role": "Head of Design",
                "organization": "Northwind",
                "email": "maya@northwind.example",
                "phone": "+15125550192",
            ]
        ))

        let profile = person.personProfile
        #expect(profile?.givenName == "Maya")
        #expect(profile?.middleName == "Lin")
        #expect(profile?.familyName == "Chen")
        #expect(profile?.namePrefix == "Dr")
        #expect(profile?.nameSuffix == "PhD")
        #expect(profile?.nickname == "May")
        #expect(profile?.departmentName == "Design")
        #expect(profile?.roleTitle == "Head of Design")
        #expect(profile?.organizationName == "Northwind")
        #expect(profile?.emails.first?.value == "maya@northwind.example")
        #expect(profile?.phones.first?.value == "+15125550192")
    }

    @Test("Contact imports wait in Unsorted until explicitly filed")
    func importFilingState() throws {
        let (store, people, records) = try fixture()
        let person = try people.createPerson(PersonDraft(fullName: "Ari Reed"))

        try records.markImported(person)
        #expect(records.isUnsorted(person))
        #expect(try store.requireItem(id: person.id).recordProfile?.origin == .contacts)

        try records.file(person)
        #expect(!records.isUnsorted(person))
        #expect(try store.requireItem(id: person.id).recordProfile?.isUnsorted == false)
    }

    @Test("Legacy People appear in Records without changing their profile")
    func projectsExistingPeople() throws {
        let (_, people, records) = try fixture()
        let person = try people.createPerson(PersonDraft(fullName: "Legacy Person"))

        #expect(person.recordProfile == nil)
        #expect(try records.allRecords().contains { $0.id == person.id })
        #expect(person.recordProfile == nil)
    }
}
