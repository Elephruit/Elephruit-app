import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// One conversation, written to a real store.
///
/// The worked example from `docs/37-relationship-capture-plan.md`: on 5 August 2026 somebody
/// mentions a son going into his senior year and a daughter going into eighth, both at South High,
/// and names neither of them. What a value-type test cannot assert is here — that a person with no
/// name survives a round trip, that the reciprocal is written, that the source is attached to every
/// fact, and that renaming the father rewrites the children who are described in terms of him.
@Suite("Person capture")
@MainActor
struct PersonCaptureTests {
    struct Fixture {
        let store: StoreFixture
        let people: SwiftDataPersonRepository
        let workspace: PersonWorkspaceService

        @MainActor
        init(now: Date) throws {
            let clock = FixedDateProvider(now: now)
            let store = try StoreFixture(dateProvider: clock)
            self.store = store
            let people = SwiftDataPersonRepository(
                context: store.context, items: store.items, dateProvider: clock
            )
            self.people = people
            self.workspace = PersonWorkspaceService(
                people: people, items: store.items, dateProvider: clock
            )
        }
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    static let conversation = date(2026, 8, 5)
    static let nextAugust = date(2027, 8, 5)

    static var son: RelativeCapture {
        RelativeCapture(
            kind: .child, label: "son",
            gradeText: "senior", schoolYearIntent: .starting, school: "South High School"
        )
    }

    static var daughter: RelativeCapture {
        RelativeCapture(
            kind: .child, label: "daughter",
            gradeText: "8th", schoolYearIntent: .starting, school: "South High School"
        )
    }

    /// The father, plus the whole conversation applied against him.
    ///
    /// - Parameter readingOn: What the store's clock says *now*. The conversation itself is always
    ///   dated 5 August 2026, which is what makes reading it a year later a real test rather than a
    ///   rearrangement of the same instant.
    @MainActor
    static func afterTheConversation(readingOn: Date = conversation) throws -> (Fixture, Item, Item) {
        let fixture = try Fixture(now: readingOn)
        let dave = try fixture.people.createPerson(PersonDraft(fullName: "Dave Marsh"))
        let note = try fixture.store.items.create(
            ItemDraft(kind: .note, title: "Coffee with Dave")
        )

        try fixture.people.apply(
            PersonUpdate(
                subjectID: dave.id,
                observations: [
                    ObservationDraft(
                        attribute: .significance,
                        value: "Bought their house for the South High district"
                    ),
                ],
                relatives: [son, daughter]
            ),
            source: note,
            observedOn: conversation
        )

        return (fixture, dave, note)
    }

    // MARK: - Somebody with no name

    @Test("Two children are recorded in one save, neither of them named")
    func theWorkedExample() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let relationships = try fixture.people.relationships(of: dave)
        #expect(relationships.count == 2)
        #expect(relationships.allSatisfy { $0.kind == .child })
        #expect(Set(relationships.compactMap(\.customLabel)) == ["son", "daughter"])

        let titles = Set(relationships.compactMap { $0.other?.displayTitle })
        #expect(titles == ["Dave Marsh's son", "Dave Marsh's daughter"])
    }

    @Test("An unnamed child is flagged as unnamed rather than as somebody called that")
    func unnamedChildrenAreFlagged() throws {
        let (fixture, _, _) = try Self.afterTheConversation()

        let unnamed = try fixture.people.unnamedRelatives()
        #expect(unnamed.count == 2)
        #expect(unnamed.allSatisfy { $0.personProfile?.hasStatedName == false })
        #expect(unnamed.allSatisfy { $0.personProfile?.isPlaceholder == true })
        // The phrase must never be split into name parts — "Dave" is not this child's given name.
        for relative in unnamed {
            #expect(try #require(relative.personProfile).givenName.isEmpty)
        }
    }

    @Test("Unnamed children stay out of the people list, like every other placeholder")
    func unnamedChildrenAreNotInTheLibraryList() throws {
        let (fixture, _, _) = try Self.afterTheConversation()

        let listed = try fixture.people.allPeople(includingPlaceholders: false)
        #expect(listed.map(\.displayTitle) == ["Dave Marsh"])
    }

    /// Two rows saying "son" are two children, not one recorded twice. Merging them would be
    /// unrecoverable; a duplicate is one tap to fix.
    @Test("Two unnamed children of the same kind are two people")
    func unnamedRelativesAreNeverMergedByTheirPhrase() throws {
        let fixture = try Fixture(now: Self.conversation)
        let dave = try fixture.people.createPerson(PersonDraft(fullName: "Dave Marsh"))

        try fixture.people.apply(
            PersonUpdate(
                subjectID: dave.id,
                relatives: [
                    RelativeCapture(kind: .child, label: "son"),
                    RelativeCapture(kind: .child, label: "son"),
                ]
            ),
            source: nil,
            observedOn: Self.conversation
        )

        #expect(try fixture.people.unnamedRelatives().count == 2)
    }

    // MARK: - The reciprocal

    @Test("Each child knows who their parent is")
    func theReciprocalIsWritten() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let child = try #require(try fixture.people.relationships(of: dave).first?.other)
        let fromTheChild = try fixture.people.relationships(of: child)

        #expect(fromTheChild.count == 1)
        #expect(fromTheChild.first?.kind == .parent)
        #expect(fromTheChild.first?.other?.id == dave.id)
        // "Dave's son" says nothing about what the son calls Dave, and inventing "father" from it
        // would be the app guessing at a gender it was never told.
        #expect(fromTheChild.first?.customLabel == nil)
    }

    // MARK: - The facts

    @Test("The son's grade lands in the coming school year, verbatim")
    func gradesAreRecordedAgainstTheRightYear() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let son = try #require(
            try fixture.people.relationships(of: dave)
                .compactMap(\.other)
                .first { $0.displayTitle == "Dave Marsh's son" }
        )

        let ledger = try fixture.people.ledger(for: son)
        let grade = try #require(ledger.current(.schoolGrade).first)

        #expect(grade.value == "senior")
        #expect(grade.schoolYearStart == 2026)
        #expect(ledger.value(of: .school) == "South High School")
    }

    @Test("The father keeps the fact that is about him rather than about his children")
    func theSubjectsOwnFactsAreRecorded() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let ledger = try fixture.people.ledger(for: dave)
        #expect(ledger.value(of: .significance) == "Bought their house for the South High district")
    }

    // MARK: - Provenance

    @Test("Every fact this conversation produced points back at the conversation")
    func everyFactCarriesItsSource() throws {
        let (fixture, dave, note) = try Self.afterTheConversation()

        var checked = 0
        let everybody = try [dave] + fixture.people.relationships(of: dave).compactMap(\.other)
        for person in everybody {
            for observation in try fixture.people.observations(for: person) {
                #expect(observation.sourceItem?.id == note.id, "\(observation.attribute.rawValue)")
                checked += 1
            }
        }

        #expect(checked == 5, "One about Dave, two about each child")
    }

    @Test("The conversation is on each child's timeline, not only their father's")
    func theSourceMentionsTheChildren() throws {
        let (fixture, dave, note) = try Self.afterTheConversation()

        let child = try #require(try fixture.people.relationships(of: dave).first?.other)
        let mentioned = (note.outgoingLinks ?? [])
            .filter { $0.kind == .mentions }
            .compactMap { $0.target?.id }

        #expect(mentioned.contains(child.id))
    }

    // MARK: - A year later, untouched

    /// The acceptance test from the plan. Nobody edits anything; the clock moves.
    ///
    /// The conversation is written with its own date — 5 August 2026 — against a store whose clock
    /// reads a year later, which is exactly the shape of reading an old record today.
    @Test("A year later the son has finished school and the daughter has moved up")
    func theRecordAgesByItself() throws {
        let (fixture, dave, _) = try Self.afterTheConversation(readingOn: Self.nextAugust)

        let children = try fixture.people.relationships(of: dave).compactMap(\.other)
        let portraits = try children.map { try fixture.workspace.portrait(of: $0) }
        let lines = Set(portraits.compactMap(\.ageAndGradeLine))

        #expect(lines == ["likely finished school", "likely in 9th grade"])
        #expect(portraits.allSatisfy { $0.ageAndGradeIsEstimate })
    }

    // MARK: - Filling in the blank

    @Test("The page asks for the names it does not have")
    func namesAreAskedFor() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let prompts = try fixture.workspace.thingsToFillIn(for: dave)
        #expect(prompts.count == 2)
        #expect(prompts.map(\.prompt).contains("What is Dave Marsh's son called?"))

        guard case .missingName(let label) = prompts.first?.kind else {
            Issue.record("Expected a missing name")
            return
        }
        #expect(["son", "daughter"].contains(label))
    }

    @Test("Supplying a name keeps every fact and stops the asking")
    func namingAChildKeepsWhatIsKnown() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let son = try #require(
            try fixture.people.relationships(of: dave)
                .compactMap(\.other)
                .first { $0.displayTitle == "Dave Marsh's son" }
        )

        try fixture.people.renamePerson(son, to: "Josh Marsh")

        #expect(son.displayTitle == "Josh Marsh")
        #expect(son.personProfile?.hasStatedName == true)
        #expect(son.personProfile?.givenName == "Josh")
        #expect(try fixture.people.ledger(for: son).value(of: .school) == "South High School")
        #expect(try fixture.people.unnamedRelatives().count == 1)
        #expect(try fixture.workspace.thingsToFillIn(for: dave).count == 1)
    }

    /// The cost of storing the phrase in a title rather than deriving it. Paid in the same save as
    /// the rename, which is why renaming goes through the repository at all.
    @Test("Renaming the father rewrites the children described in terms of him")
    func renamingTheSubjectRefreshesThePhrases() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        try fixture.people.renamePerson(dave, to: "David Marsh")

        let titles = Set(try fixture.people.unnamedRelatives().map(\.displayTitle))
        #expect(titles == ["David Marsh's son", "David Marsh's daughter"])
    }

    /// Somebody who has a name keeps having one. Renaming them is a correction, not the supplying
    /// of a first name, and it must not put them back in the list of people to ask about.
    @Test("Renaming somebody who already had a name does not make them nameless")
    func renamingANamedPersonKeepsThemNamed() throws {
        let fixture = try Fixture(now: Self.conversation)
        let person = try fixture.people.createPerson(
            PersonDraft(fullName: "Maya Okonjo", givenName: "Maya", familyName: "Okonjo")
        )

        try fixture.people.renamePerson(person, to: "Maya Okonjo-Reid")

        #expect(person.displayTitle == "Maya Okonjo-Reid")
        #expect(person.personProfile?.hasStatedName == true)
        #expect(try fixture.people.unnamedRelatives().isEmpty)
    }

    /// The phrase is not a name, so nothing may split it into one. An address book offered "Dave" as
    /// a child's given name and "son" as their family name is the visible end of this.
    @Test("An unnamed person's phrase is never split into name parts")
    func thePhraseIsNeverTreatedAsAName() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        try fixture.people.renamePerson(dave, to: "David Marsh")

        for relative in try fixture.people.unnamedRelatives() {
            let profile = try #require(relative.personProfile)
            #expect(profile.givenName.isEmpty)
            #expect(profile.familyName.isEmpty)
        }
    }

    @Test("A blank name is refused rather than emptying somebody's record")
    func renamingToNothingIsRefused() throws {
        let fixture = try Fixture(now: Self.conversation)
        let person = try fixture.people.createPerson(PersonDraft(fullName: "Maya Okonjo"))

        #expect(throws: AppError.self) {
            try fixture.people.renamePerson(person, to: "   ")
        }
        #expect(person.displayTitle == "Maya Okonjo")
    }

    // MARK: - Applying twice

    @Test("Re-applying a grade supersedes rather than showing two answers")
    func reapplyingSupersedes() throws {
        let (fixture, dave, _) = try Self.afterTheConversation()

        let son = try #require(
            try fixture.people.relationships(of: dave)
                .compactMap(\.other)
                .first { $0.displayTitle == "Dave Marsh's son" }
        )

        var correction = Self.son
        correction.existingPersonID = son.id
        correction.gradeText = "junior"

        try fixture.people.apply(
            PersonUpdate(subjectID: dave.id, relatives: [correction]),
            source: nil,
            observedOn: Self.conversation
        )

        let ledger = try fixture.people.ledger(for: son)
        #expect(ledger.current(.schoolGrade).count == 1)
        #expect(ledger.value(of: .schoolGrade) == "junior")
        #expect(ledger.history(.schoolGrade).map(\.value) == ["senior"], "The first answer is history, not gone")
        #expect(try fixture.people.relationships(of: dave).count == 2, "No second son")
    }

    @Test("An update with nothing in it writes nothing")
    func anEmptyUpdateIsANoOp() throws {
        let fixture = try Fixture(now: Self.conversation)
        let dave = try fixture.people.createPerson(PersonDraft(fullName: "Dave Marsh"))

        try fixture.people.apply(
            PersonUpdate(subjectID: dave.id, relatives: [RelativeCapture()]),
            source: nil,
            observedOn: Self.conversation
        )

        #expect(try fixture.people.relationships(of: dave).isEmpty)
        #expect(try fixture.people.allPeople(includingPlaceholders: true).count == 1)
    }
}
