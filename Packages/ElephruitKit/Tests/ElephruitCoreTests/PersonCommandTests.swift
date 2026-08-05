import ElephruitCore
import Foundation
import Testing

/// The command bar's grammar.
///
/// Every example from the specification appears here verbatim, because the grammar's only real
/// specification *is* the set of lines somebody expects to be able to type. The second half of the
/// suite is about what must not happen: nothing externally visible runs without a confirmation, and
/// nothing at all runs from a line the parser did not understand.
@Suite("Person commands")
struct PersonCommandTests {
    static let mayaID = UUID()
    static let danielleID = UUID()
    static let nishaID = UUID()
    static let designTeamID = UUID()
    static let familyID = UUID()

    static let context = CommandContext(
        people: [
            KnownPerson(id: mayaID, fullName: "Maya Chen", aliases: ["Maya"]),
            KnownPerson(id: danielleID, fullName: "Danielle Okafor", aliases: ["Danielle"]),
            KnownPerson(id: nishaID, fullName: "Nisha Raman", aliases: ["Nisha"]),
        ],
        groups: [
            KnownGroup(id: designTeamID, name: "Design Team", memberCount: 5),
            KnownGroup(id: familyID, name: "Family", memberCount: 4),
        ]
    )

    let parser = DeterministicPersonCommandParser()

    func parse(_ input: String) -> ParsedCommand {
        parser.parse(input, context: Self.context)
    }

    // MARK: - The specification's examples

    @Test("Maya")
    func bareName() {
        let command = parse("Maya")
        #expect(command.intent == .open(personID: Self.mayaID))
        #expect(!command.requiresConfirmation)
    }

    @Test("Maya mobile")
    func revealADetail() {
        let command = parse("Maya mobile")
        #expect(command.intent == .reveal(personID: Self.mayaID, channel: .call))
        #expect(!command.requiresConfirmation, "showing a number is not the same as dialling it")
    }

    @Test("call Maya")
    func callSomebody() {
        let command = parse("call Maya")
        #expect(command.intent == .contact(personID: Self.mayaID, channel: .call))
        #expect(command.requiresConfirmation, "a call reaches another human being")
        #expect(command.summary == "Call Maya Chen")
    }

    @Test("message Maya")
    func messageSomebody() {
        #expect(parse("message Maya").intent == .contact(personID: Self.mayaID, channel: .message))
        #expect(parse("text Maya").intent == .contact(personID: Self.mayaID, channel: .message))
    }

    @Test("email Maya")
    func emailSomebody() {
        let command = parse("email Maya")
        #expect(command.intent == .contact(personID: Self.mayaID, channel: .email))
        #expect(command.requiresConfirmation)
    }

    @Test("facetime Maya")
    func facetimeSomebody() {
        #expect(parse("facetime Maya").intent == .contact(personID: Self.mayaID, channel: .facetimeVideo))
        #expect(parse("facetime audio Maya").intent == .contact(personID: Self.mayaID, channel: .facetimeAudio))
    }

    @Test("meet Maya next Tuesday at 2")
    func scheduleAMeeting() {
        let command = parse("meet Maya next Tuesday at 2")

        guard case .schedule(let personID, let day, let time) = command.intent else {
            Issue.record("expected a scheduling intent, got \(command.intent)")
            return
        }
        #expect(personID == Self.mayaID)
        #expect(day == .nextWeekday(3))
        #expect(time?.hour == 14, "‘at 2’ in a meeting is the afternoon")
        #expect(command.requiresConfirmation, "putting something in a calendar is externally visible")
    }

    @Test("add Maya Chen maya@example.com 512-555-0192")
    func addDetailsToSomebodyWhoExists() {
        let command = parse("add Maya Chen maya@example.com 512-555-0192")

        guard case .addDetails(let personID, let fields) = command.intent else {
            Issue.record("expected details to be added to the existing Maya, got \(command.intent)")
            return
        }
        #expect(personID == Self.mayaID)
        #expect(fields.emails == ["maya@example.com"])
        #expect(fields.phones == ["512-555-0192"])
    }

    @Test("add Theo Brandt theo@example.com creates somebody new")
    func addCreatesANewPerson() {
        let command = parse("add Theo Brandt theo@example.com")

        guard case .createPerson(let fields) = command.intent else {
            Issue.record("expected a creation, got \(command.intent)")
            return
        }
        #expect(fields.name == "Theo Brandt")
        #expect(fields.emails == ["theo@example.com"])
        #expect(!command.requiresConfirmation, "creating a local record is nobody else's business")
    }

    /// A partial first-name match must not swallow the rest of a name.
    ///
    /// The library holds Danielle Okafor. `add Danielle Fournier` is a *different* person, and
    /// matching "Danielle" and treating "Fournier" as a detail to append to Okafor is how a command
    /// bar quietly corrupts a record.
    @Test("add Danielle Fournier creates somebody new, despite Danielle Okafor existing")
    func addDoesNotMatchAPartialName() {
        let command = parse("add Danielle Fournier danielle@example.com")

        guard case .createPerson(let fields) = command.intent else {
            Issue.record("expected a creation, got \(command.intent)")
            return
        }
        #expect(fields.name == "Danielle Fournier")
        #expect(fields.emails == ["danielle@example.com"])
    }

    @Test("But adding details to a name that matches exactly still finds them")
    func addMatchesACompleteName() {
        let command = parse("add Danielle danielle@example.com")

        guard case .addDetails(let personID, _) = command.intent else {
            Issue.record("expected details to be added, got \(command.intent)")
            return
        }
        #expect(personID == Self.danielleID)
    }

    @Test("Maya birthday October 12")
    func setABirthday() {
        let command = parse("Maya birthday October 12")

        guard case .setCelebration(let personID, let kind, let date) = command.intent else {
            Issue.record("expected a celebration, got \(command.intent)")
            return
        }
        #expect(personID == Self.mayaID)
        #expect(kind == .birthday)
        #expect(date.month == 10)
        #expect(date.day == 12)
        #expect(!date.hasYear, "a birthday with no year is the normal case, not a failure")
    }

    @Test("Maya moved to Austin")
    func recordAFact() {
        let command = parse("Maya moved to Austin")

        guard case .recordFact(let personID, let draft) = command.intent else {
            Issue.record("expected a fact, got \(command.intent)")
            return
        }
        #expect(personID == Self.mayaID)
        #expect(draft.attribute == .location)
        #expect(draft.value == "Austin")
    }

    @Test("Maya son Jack age 6 entering second grade")
    func recordARelationAndWhatWasSaidAboutThem() {
        let command = parse("Maya son Jack age 6 entering second grade")

        guard case .recordRelation(let personID, let kind, let label, let name, let observations) = command.intent
        else {
            Issue.record("expected a relationship, got \(command.intent)")
            return
        }
        #expect(personID == Self.mayaID)
        #expect(kind == .child)
        #expect(label == "son", "the word the user typed is kept")
        #expect(name == "Jack")

        #expect(observations.count == 2)
        #expect(observations.contains { $0.attribute == .observedAge && $0.value == "6" })
        // Kept as it was typed rather than re-worded to "2nd grade": `PersonObservation.value`
        // promises what was said, and the estimator reads it back through the same parser that
        // recognised it here.
        #expect(observations.contains { $0.attribute == .schoolGrade && $0.value == "second" })
    }

    /// The line the whole capture path was built for, from `docs/37-relationship-capture-plan.md`.
    /// Nobody says "entering twelfth grade" — they say "senior" — and the school comes in the same
    /// breath.
    @Test("Maya son senior at South High School")
    func recordAChildBySchoolAndGrade() {
        let command = parse("Maya son senior at South High School")

        guard case .recordRelation(_, let kind, let label, let name, let observations) = command.intent
        else {
            Issue.record("expected a relationship, got \(command.intent)")
            return
        }

        #expect(kind == .child)
        #expect(label == "son")
        #expect(name == "senior at South High School" || observations.count == 2)
        #expect(observations.contains { $0.attribute == .schoolGrade && $0.value == "senior" })
        #expect(observations.contains { $0.attribute == .school && $0.value == "South High School" })
    }

    @Test("note Maya prefers small restaurants")
    func addANote() {
        let command = parse("note Maya prefers small restaurants")

        #expect(command.intent == .addNote(personID: Self.mayaID, text: "prefers small restaurants"))
        #expect(!command.requiresConfirmation)
    }

    @Test("task introduce Maya to Danielle Friday")
    func createATaskMentioningPeople() {
        let command = parse("task introduce Maya to Danielle Friday")

        guard case .createTask(let text, let personIDs, let day) = command.intent else {
            Issue.record("expected a task, got \(command.intent)")
            return
        }
        #expect(text == "introduce Maya to Danielle", "the date comes off the end and the words stay")
        #expect(Set(personIDs) == [Self.mayaID, Self.danielleID])
        #expect(day == .nextWeekday(6))
    }

    @Test("show Maya's family")
    func showAChart() {
        let command = parse("show Maya's family")
        #expect(command.intent == .chart(personID: Self.mayaID, chart: .family))
    }

    @Test("Maya's org chart")
    func showAnOrganisationChart() {
        #expect(parse("Maya's org chart").intent == .chart(personID: Self.mayaID, chart: .professional))
    }

    @Test("email Design Team")
    func emailAGroup() {
        let command = parse("email Design Team")

        #expect(command.intent == .groupAction(groupID: Self.designTeamID, action: .email))
        #expect(command.requiresConfirmation, "a group email is the most externally visible thing here")
        #expect(command.summary.contains("5 people"), "the preview says how many")
    }

    @Test("invite Family to dinner Saturday at 6")
    func inviteAGroup() {
        let command = parse("invite Family to dinner Saturday at 6")

        guard case .groupAction(let groupID, let action) = command.intent,
              case .invite(let day, let time, let title) = action
        else {
            Issue.record("expected an invitation, got \(command.intent)")
            return
        }
        #expect(groupID == Self.familyID)
        #expect(day == .nextWeekday(7))
        #expect(time?.hour == 18)
        #expect(title == "dinner")
        #expect(command.requiresConfirmation)
    }

    // MARK: - What must not happen

    @Test("A name nobody has is an offer, not an action")
    func unknownPersonBlocks() {
        let command = parse("call Theodore Brandt")

        #expect(command.ambiguities.contains { ambiguity in
            if case .unknownPerson = ambiguity { return true }
            return false
        })
        #expect(command.requiresConfirmation)

        if case .contact = command.intent {
            Issue.record("a command bar must never dial a person it could not find")
        }
    }

    @Test("Meeting somebody without saying when does not schedule anything")
    func missingDateBlocksScheduling() {
        let command = parse("meet Maya")

        #expect(command.ambiguities.contains { ambiguity in
            if case .noDateFound = ambiguity { return true }
            return false
        })
        #expect(!command.isRunnable, "a date that could not be read is not resolvable in the preview")
    }

    @Test("A group nobody has is not silently created")
    func unknownGroupBlocks() {
        let command = parse("invite Cyclists to dinner Saturday")

        #expect(command.ambiguities.contains { ambiguity in
            if case .unknownGroup = ambiguity { return true }
            return false
        })
        #expect(!command.isRunnable)
    }

    @Test("Anything unrecognised falls through to search rather than failing")
    func unrecognisedTextSearches() {
        let command = parse("what did I do last summer")

        guard case .search(let query) = command.intent else {
            Issue.record("expected a search, got \(command.intent)")
            return
        }
        #expect(query == "what did I do last summer")
        #expect(!command.isRunnable, "a search is offered, never executed as a command")
    }

    @Test("An empty line means nothing")
    func emptyInput() {
        let command = parse("   ")
        #expect(command.intent == .search(query: ""))
        #expect(!command.isRunnable)
    }

    @Test("Every externally visible intent demands confirmation")
    func externallyVisibleAlwaysConfirms() {
        let lines = [
            "call Maya",
            "message Maya",
            "email Maya",
            "facetime Maya",
            "meet Maya tomorrow at 3",
            "email Design Team",
            "invite Family to dinner Saturday at 6",
        ]

        for line in lines {
            let command = parse(line)
            #expect(command.requiresConfirmation, "“\(line)” must be previewed before it runs")
        }
    }

    @Test("Nothing local demands confirmation it does not need")
    func localIntentsRunFreely() {
        let lines = ["Maya", "Maya mobile", "note Maya likes cold rooms", "show Maya's family"]

        for line in lines {
            #expect(!parse(line).requiresConfirmation, "“\(line)” touches nothing outside the app")
        }
    }

    // MARK: - The live preview

    @Test("Recognised spans are reported with their positions")
    func entitiesCarryRanges() {
        let command = parse("call Maya")

        let person = command.entities.first { $0.kind == .person }
        #expect(person?.resolvedID == Self.mayaID)
        #expect(person?.range == 5..<9, "so the field can underline exactly what it understood")
    }

    @Test("The full name wins over the first name")
    func longestNameMatchWins() {
        let command = parse("Maya Chen mobile")
        #expect(command.intent == .reveal(personID: Self.mayaID, channel: .call))

        let person = command.entities.first { $0.kind == .person }
        #expect(person?.range == 0..<9)
    }

    // MARK: - Contact detail recognition

    @Test("Emails are recognised and near-misses are not")
    func emailRecognition() {
        #expect(ContactDetailRecognizer.isEmail("maya@example.com"))
        #expect(ContactDetailRecognizer.isEmail("m.chen+crm@sub.example.co.uk"))
        #expect(!ContactDetailRecognizer.isEmail("maya@example"))
        #expect(!ContactDetailRecognizer.isEmail("@example.com"))
        #expect(!ContactDetailRecognizer.isEmail("maya at example.com"))
    }

    @Test("Phone numbers are recognised and quantities are not")
    func phoneRecognition() {
        #expect(ContactDetailRecognizer.phone("512-555-0192") == "512-555-0192")
        #expect(ContactDetailRecognizer.phone("+1 (512) 555-0192") != nil)
        #expect(ContactDetailRecognizer.phone("2026") == nil, "a year is not a phone number")
        #expect(ContactDetailRecognizer.phone("12") == nil)
        #expect(ContactDetailRecognizer.phone("second") == nil)
    }

    @Test("Two ways of writing one number compare equal")
    func phoneNormalization() {
        #expect(
            ContactDetailRecognizer.normalizedPhone("+1 (512) 555-0192")
                == ContactDetailRecognizer.normalizedPhone("512-555-0192")
        )
    }
}
