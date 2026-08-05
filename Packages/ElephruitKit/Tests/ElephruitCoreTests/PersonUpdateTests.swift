import ElephruitCore
import Foundation
import Testing

/// One conversation, captured.
///
/// The spine of this suite is the conversation this whole capture path was built for, from
/// `docs/37-relationship-capture-plan.md`: on 5 August 2026 somebody mentions a son going into his
/// senior year and a daughter going into eighth, both at South High, and names neither of them. Nine
/// facts, three people, no names — and a year later the record has to be right without anybody
/// having gone back to edit it.
@Suite("Person updates")
struct PersonUpdateTests {
    /// A Gregorian calendar in GMT, so these give the same answer wherever they run.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    static let conversation = date(2026, 8, 5)

    static var son: RelativeCapture {
        RelativeCapture(
            kind: .child,
            label: "son",
            gradeText: "senior",
            schoolYearIntent: .starting,
            school: "South High School"
        )
    }

    static var daughter: RelativeCapture {
        RelativeCapture(
            kind: .child,
            label: "daughter",
            gradeText: "8th",
            schoolYearIntent: .starting,
            school: "South High School"
        )
    }

    // MARK: - Somebody with no name

    @Test("A relative with no name is recordable, and reads as a person rather than a category")
    func namelessRelativeHasAPhraseForATitle() {
        let capture = Self.son

        #expect(!capture.hasStatedName)
        #expect(!capture.isEmpty, "The word 'son' is what somebody said. It is not an empty row.")
        #expect(capture.derivedTitle(subjectName: "Dave Marsh") == "Dave Marsh's son")
        #expect(capture.title(subjectName: "Dave Marsh") == "Dave Marsh's son")
    }

    @Test("A name, once given, is the title")
    func namedRelativeUsesTheName() {
        var capture = Self.son
        capture.name = "  Josh  "

        #expect(capture.hasStatedName)
        #expect(capture.statedName == "Josh")
        #expect(capture.title(subjectName: "Dave Marsh") == "Josh")
        // The phrase survives beside the name, because it is still how the family reads.
        #expect(capture.derivedTitle(subjectName: "Dave Marsh") == "Dave Marsh's son")
    }

    @Test("Without the user's own word the phrase falls back to the relationship")
    func phraseFallsBackToTheKind() {
        let capture = RelativeCapture(kind: .child)
        #expect(capture.derivedTitle(subjectName: "Dave") == "Dave's child")
    }

    @Test("A row nobody filled in is not written")
    func untouchedRowsAreDiscarded() {
        let update = PersonUpdate(
            subjectID: UUID(),
            relatives: [RelativeCapture(), Self.son]
        )

        #expect(update.relatives.count == 2)
        #expect(update.recordableRelatives.count == 1)
        #expect(update.recordableRelatives.first?.statedLabel == "son")
    }

    // MARK: - What it becomes

    @Test("The son's row becomes a grade in the right school year, and a school")
    func sonBecomesObservations() {
        let drafts = Self.son.observations(observedOn: Self.conversation, calendar: Self.calendar)

        #expect(drafts.count == 2)

        let grade = drafts.first { $0.attribute == .schoolGrade }
        #expect(grade?.value == "senior", "Stored as it was said, never re-worded")
        #expect(grade?.schoolYearStart == 2026)

        #expect(drafts.first { $0.attribute == .school }?.value == "South High School")
    }

    @Test("An age becomes an observed age rather than a birthday")
    func ageBecomesAnObservation() {
        var capture = Self.daughter
        capture.age = 13

        let drafts = capture.observations(observedOn: Self.conversation, calendar: Self.calendar)
        #expect(drafts.first { $0.attribute == .observedAge }?.value == "13")
    }

    /// The whole reason the intent is asked for. Said six weeks earlier, the same sentence would
    /// otherwise have been filed against 2025–26 and read a full year behind ever after.
    @Test("Going into a grade in July is still the 2026–27 year")
    func summerCaptureLandsInTheComingYear() {
        var capture = Self.daughter
        capture.schoolYearIntent = .starting

        let drafts = capture.observations(observedOn: Self.date(2026, 7, 20), calendar: Self.calendar)
        #expect(drafts.first { $0.attribute == .schoolGrade }?.schoolYearStart == 2026)
    }

    @Test("A grade this app cannot read is still recorded, and still says which year")
    func unreadableGradesAreStillRecorded() {
        var capture = Self.son
        capture.gradeText = "upper sixth"

        #expect(capture.parsedGrade == nil)

        let drafts = capture.observations(observedOn: Self.conversation, calendar: Self.calendar)
        let grade = drafts.first { $0.attribute == .schoolGrade }
        #expect(grade?.value == "upper sixth")
        #expect(grade?.schoolYearStart == 2026, "Kept, so that a parser taught this later can use it")
    }

    @Test("A note becomes a quick fact on their own record")
    func notesBecomeQuickFacts() {
        var capture = Self.son
        capture.note = "Plays trumpet"

        let drafts = capture.observations(observedOn: Self.conversation, calendar: Self.calendar)
        #expect(drafts.first { $0.attribute == .quickFact }?.value == "Plays trumpet")
    }

    // MARK: - The sentence shown before anything is saved

    @Test("The preview says what will be written, including that a name is missing")
    func summaryReadsAsASentence() {
        let sentence = Self.son.summarySentence(
            subjectName: "Dave Marsh",
            observedOn: Self.conversation,
            calendar: Self.calendar
        )

        #expect(sentence == "A son of Dave Marsh, name not known yet · 12th grade in 2026–27, at South High School")
    }

    @Test("With a name it reads as the family does")
    func summaryWithAName() {
        var capture = Self.daughter
        capture.name = "Nina"

        let sentence = capture.summarySentence(
            subjectName: "Dave Marsh",
            observedOn: Self.conversation,
            calendar: Self.calendar
        )

        #expect(sentence == "Nina is Dave Marsh's daughter · 8th grade in 2026–27, at South High School")
    }

    /// An unreadable grade is shown back verbatim rather than as the nearest thing understood,
    /// because the preview is the last chance to notice the app misread somebody.
    @Test("An unreadable grade previews as it was typed")
    func summaryKeepsUnreadableText() {
        var capture = Self.son
        capture.gradeText = "upper sixth"

        let sentence = capture.summarySentence(
            subjectName: "Dave",
            observedOn: Self.conversation,
            calendar: Self.calendar
        )

        #expect(sentence.contains("upper sixth in 2026–27"))
    }

    // MARK: - The whole update

    @Test("The worked example is one update carrying nine writes")
    func theWorkedExample() {
        let update = PersonUpdate(
            subjectID: UUID(),
            observations: [
                ObservationDraft(
                    attribute: .significance,
                    value: "Bought their house for the South High district"
                ),
            ],
            relatives: [Self.son, Self.daughter]
        )

        #expect(!update.isEmpty)
        #expect(update.recordableRelatives.count == 2)
        // One fact about Dave, then a relationship and two facts for each child.
        #expect(update.writeCount == 7)
    }

    @Test("An update with nothing in it knows so")
    func emptyUpdate() {
        #expect(PersonUpdate(subjectID: UUID()).isEmpty)
        #expect(PersonUpdate(subjectID: UUID(), relatives: [RelativeCapture()]).isEmpty)
    }

    // MARK: - A year later, untouched

    /// The acceptance test from the plan, run over the pure types: nobody edits anything, and in
    /// August 2027 the son has left school and the daughter has moved up one.
    @Test("A year later the children have moved on by themselves")
    func theRecordAgesWithoutBeingEdited() {
        let nextAugust = Self.date(2027, 8, 5)

        #expect(Self.son.parsedGrade == .grade(12))
        let sonEstimate = GradeEstimator.estimate(
            observedGrade: Self.son.parsedGrade ?? .grade(12),
            schoolYear: SchoolYear(startYear: 2026),
            asOf: nextAugust,
            calendar: Self.calendar
        )
        #expect(sonEstimate.grade == .graduated)
        #expect(sonEstimate.displayText == "likely finished school")

        let daughterEstimate = GradeEstimator.estimate(
            observedGrade: Self.daughter.parsedGrade ?? .grade(8),
            schoolYear: SchoolYear(startYear: 2026),
            asOf: nextAugust,
            calendar: Self.calendar
        )
        #expect(daughterEstimate.grade == .grade(9))
        #expect(daughterEstimate.displayText == "likely in 9th grade")
        #expect(daughterEstimate.schoolYear.displayText == "2027–28")
    }
}
