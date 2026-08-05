import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Group colours: how one is chosen, that it survives a round trip, and that membership can be
/// asked about a whole list at once.
@Suite("Person group colours")
@MainActor
struct PersonGroupColorTests {
    /// The group service over one in-memory store.
    struct Fixture {
        let store: StoreFixture
        let people: SwiftDataPersonRepository
        let groups: PersonGroupService

        @MainActor
        init() throws {
            let dateProvider = FixedDateProvider.reference
            let store = try StoreFixture(dateProvider: dateProvider)
            self.store = store

            let people = SwiftDataPersonRepository(
                context: store.context, items: store.items, dateProvider: dateProvider
            )
            self.people = people
            self.groups = PersonGroupService(
                context: store.context,
                items: store.items,
                people: people,
                search: PersonSearchService(people: people, items: store.items, dateProvider: dateProvider),
                dateProvider: dateProvider
            )
        }

        @MainActor
        func person(_ name: String) throws -> Item {
            try people.createPerson(PersonDraft(fullName: name))
        }
    }

    // MARK: - Choosing a colour

    /// The rule, without a store. Twelve groups, twelve different colours.
    @Test("Every colour is used once before any is used twice")
    func firstTwelveAreDistinct() {
        var assigned: [String] = []
        for _ in 0..<PersonGroupService.groupColorNames.count {
            assigned.append(PersonGroupService.assignableColorName(existing: assigned))
        }

        #expect(Set(assigned).count == assigned.count, "no colour should repeat inside the first pass")
        #expect(Set(assigned) == Set(PersonGroupService.groupColorNames))
    }

    /// Past the end of the palette there is no unused colour left. The next one reuses the *least*
    /// used, which is the flattest distribution available, and does it deterministically.
    @Test("The thirteenth group reuses the least-used colour, in palette order")
    func pastTheEndItReusesTheLeastUsed() {
        let full = PersonGroupService.groupColorNames
        let next = PersonGroupService.assignableColorName(existing: full)
        #expect(next == full[0], "with everything used once, the first in palette order wins the tie")

        let uneven = full + [full[0]]
        #expect(
            PersonGroupService.assignableColorName(existing: uneven) == full[1],
            "the colour now used twice should not be chosen again while others are used once"
        )
    }

    /// Unknown names — a colour written by a newer build, or graphite, which groups do not use —
    /// must not make a used colour look free.
    @Test("A colour outside the group palette is ignored rather than counted")
    func unknownColorsAreIgnored() {
        let chosen = PersonGroupService.assignableColorName(existing: ["graphite", "chartreuse"])
        #expect(chosen == PersonGroupService.groupColorNames[0])
    }

    /// Graphite is the colour of *no group*, so it is never handed out as one.
    @Test("Graphite is not a group colour")
    func graphiteIsNotOffered() {
        #expect(!PersonGroupService.groupColorNames.contains("graphite"))
    }

    /// The two lists this feature spans, held together.
    ///
    /// `ElephruitPersistence` stores a colour *name* and deliberately does not depend on
    /// `ElephruitDesign`, so nothing in the compiler stops the two drifting: a palette entry renamed
    /// on one side leaves a group whose stored colour resolves to the accent fallback, which looks
    /// like a group that was never coloured rather than like a bug. This is the check that would
    /// have to fail first.
    @Test("Every group colour is a real palette entry")
    func groupColorsExistInThePalette() {
        for name in PersonGroupService.groupColorNames {
            #expect(Theme.Palette(rawValue: name) != nil, "\(name) is not in Theme.Palette")
        }
    }

    /// The other direction: the palette may only gain a colour that groups deliberately decline.
    /// Today that is graphite and nothing else, so a new palette entry has to be considered here
    /// rather than silently never offered.
    @Test("The palette holds nothing groups have quietly forgotten")
    func thePaletteHoldsNothingUnaccountedFor() {
        let offered = Set(PersonGroupService.groupColorNames)
        let declined: Set<String> = ["graphite"]
        let all = Set(Theme.Palette.allCases.map(\.rawValue))

        #expect(all == offered.union(declined), "a new palette colour must be offered to groups or declined on purpose")
    }

    // MARK: - Against the store

    @Test("A created group keeps its colour, and the next group gets a different one")
    func createdGroupsGetDistinctColors() throws {
        let fixture = try Fixture()

        let family = try fixture.groups.createFixedGroup(named: "Family")
        let work = try fixture.groups.createFixedGroup(named: "Work")

        #expect(family.colorName != nil)
        #expect(work.colorName != nil)
        #expect(family.colorName != work.colorName)

        // Re-read rather than trusting the returned value: the point is that it was written down.
        let stored = try fixture.groups.allGroups()
        #expect(stored.first { $0.id == family.id }?.colorName == family.colorName)
        #expect(stored.first { $0.id == work.id }?.colorName == work.colorName)
    }

    @Test("A smart group is coloured from the same palette as a fixed one")
    func smartGroupsShareThePalette() throws {
        let fixture = try Fixture()

        let fixed = try fixture.groups.createFixedGroup(named: "Family")
        let smart = try fixture.groups.createSmartGroup(named: "In Austin", query: "people in Austin")

        #expect(smart.colorName != nil)
        #expect(smart.colorName != fixed.colorName)

        let summaries = try fixture.groups.allGroupSummaries()
        #expect(summaries.first { $0.id == smart.id }?.colorName == smart.colorName)
    }

    @Test("An explicit colour is honoured instead of the next one in the palette")
    func explicitColorWins() throws {
        let fixture = try Fixture()
        let group = try fixture.groups.createFixedGroup(named: "Cycling", colorName: "teal")
        #expect(group.colorName == "teal")
    }

    @Test("Changing a group's colour is visible to the next read")
    func colorCanBeChanged() throws {
        let fixture = try Fixture()
        let group = try fixture.groups.createFixedGroup(named: "Family")

        try fixture.groups.setColor("pink", forGroup: group.id)
        #expect(try fixture.groups.group(id: group.id)?.colorName == "pink")

        try fixture.groups.setColor(nil, forGroup: group.id)
        #expect(try fixture.groups.group(id: group.id)?.colorName == nil)
    }

    @Test("Renaming keeps the group a group")
    func renamingKeepsThePrefix() throws {
        let fixture = try Fixture()
        let group = try fixture.groups.createFixedGroup(named: "Familly")

        try fixture.groups.rename(groupID: group.id, to: "Family")

        let renamed = try fixture.groups.group(id: group.id)
        #expect(renamed?.name == "Family", "the prefix should not leak into the displayed name")
        #expect(try fixture.groups.allGroups().count == 1, "renaming must not orphan it out of the section")
    }

    // MARK: - Membership, inverted

    /// The whole point of the index: one person, many groups, answered without asking per row.
    @Test("Somebody in two groups carries both, in listing order")
    func aPersonCanBeInManyGroups() throws {
        let fixture = try Fixture()
        let maya = try fixture.person("Maya Chen")
        let jack = try fixture.person("Jack Chen")

        let family = try fixture.groups.createFixedGroup(named: "Family")
        let work = try fixture.groups.createFixedGroup(named: "Work")

        try fixture.groups.add(maya, to: family.id)
        try fixture.groups.add(maya, to: work.id)
        try fixture.groups.add(jack, to: family.id)

        let membership = try fixture.groups.membership()

        #expect(membership.groups(for: maya.id).map(\.name) == ["Family", "Work"])
        #expect(membership.groups(for: jack.id).map(\.name) == ["Family"])
        #expect(membership.groups(for: maya.id).compactMap(\.colorName).count == 2)
    }

    @Test("Somebody in no group carries none, rather than being absent in a way that reads as an error")
    func peopleWithNoGroupsAreEmptyNotMissing() throws {
        let fixture = try Fixture()
        let alone = try fixture.person("Alex Rivera")
        _ = try fixture.groups.createFixedGroup(named: "Family")

        #expect(try fixture.groups.membership().groups(for: alone.id).isEmpty)
    }

    @Test("Removing somebody from a group takes their dot with them")
    func removalUpdatesTheIndex() throws {
        let fixture = try Fixture()
        let maya = try fixture.person("Maya Chen")
        let family = try fixture.groups.createFixedGroup(named: "Family")

        try fixture.groups.add(maya, to: family.id)
        #expect(try fixture.groups.membership().groups(for: maya.id).count == 1)

        try fixture.groups.remove(maya, from: family.id)
        #expect(try fixture.groups.membership().groups(for: maya.id).isEmpty)
    }

    /// A deleted group is gone from the index too — otherwise a row keeps a dot for a group that no
    /// longer exists, and tapping through to it finds nothing.
    @Test("A deleted group leaves no dots behind")
    func deletingAGroupClearsItsMembership() throws {
        let fixture = try Fixture()
        let maya = try fixture.person("Maya Chen")
        let family = try fixture.groups.createFixedGroup(named: "Family")
        try fixture.groups.add(maya, to: family.id)

        try fixture.groups.deleteGroup(id: family.id)

        #expect(try fixture.groups.membership().groups(for: maya.id).isEmpty)
        #expect(try fixture.groups.allGroups().isEmpty)
    }

    /// The membership editor only offers fixed groups, so it asks for fixed membership only.
    @Test("Explicit membership excludes smart groups, which have none to write")
    func fixedMembershipIgnoresSmartGroups() throws {
        let fixture = try Fixture()
        let maya = try fixture.person("Maya Chen")

        let family = try fixture.groups.createFixedGroup(named: "Family")
        try fixture.groups.add(maya, to: family.id)
        _ = try fixture.groups.createSmartGroup(named: "Everyone", query: "Maya")

        #expect(try fixture.groups.fixedGroupIDs(containing: maya.id) == [family.id])
    }

    @Test("Adding somebody twice does not give them two dots for one group")
    func addingIsIdempotent() throws {
        let fixture = try Fixture()
        let maya = try fixture.person("Maya Chen")
        let family = try fixture.groups.createFixedGroup(named: "Family")

        try fixture.groups.add(maya, to: family.id)
        try fixture.groups.add(maya, to: family.id)

        #expect(try fixture.groups.membership().groups(for: maya.id).count == 1)
    }
}
