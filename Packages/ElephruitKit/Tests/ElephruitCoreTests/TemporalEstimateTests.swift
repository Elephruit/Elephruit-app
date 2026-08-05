import ElephruitCore
import Foundation
import Testing

/// Ages and grades derived from a dated observation.
///
/// The worked example from the specification is the spine of this suite: on 18 July 2026 Maya says
/// "Jack is six and starts second grade next month", and eighteen months later the app must say
/// *approximately 7–8 years old, likely in 3rd grade* — and must say that it is estimating, and from
/// when. Everything else here is a boundary around that.
@Suite("Temporal estimates")
struct TemporalEstimateTests {
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

    // MARK: - The worked example

    @Test("Jack is six on 18 July 2026")
    func ageOnTheDayItWasSaid() {
        let estimate = AgeEstimator.estimate(
            observedAge: 6,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2026, 7, 18),
            calendar: Self.calendar
        )

        #expect(estimate == .approximate(lower: 6, upper: 6))
        #expect(estimate.displayText == "approximately 6 years old")
    }

    @Test("Eighteen months later Jack is approximately 7–8")
    func ageEighteenMonthsLater() {
        let estimate = AgeEstimator.estimate(
            observedAge: 6,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2028, 1, 18),
            calendar: Self.calendar
        )

        #expect(estimate == .approximate(lower: 7, upper: 8))
        #expect(estimate.displayText == "approximately 7–8 years old")
        #expect(estimate.isEstimate)
    }

    @Test("Exactly a year later the range collapses")
    func ageOnAnAnniversaryIsCertain() {
        let estimate = AgeEstimator.estimate(
            observedAge: 6,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2027, 7, 18),
            calendar: Self.calendar
        )

        // Whoever they are, a full year after "Jack is six" they are seven. The window of possible
        // birthdays shifted with them, and this is the one moment it lines up exactly.
        #expect(estimate == .approximate(lower: 7, upper: 7))
    }

    @Test("A day after the anniversary it opens up again")
    func ageWidensImmediatelyAfterAnAnniversary() {
        let estimate = AgeEstimator.estimate(
            observedAge: 6,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2027, 7, 19),
            calendar: Self.calendar
        )

        #expect(estimate == .approximate(lower: 7, upper: 8))
    }

    @Test("An exact birthday replaces the estimate entirely")
    func exactBirthdayGivesAnExactAge() {
        let estimate = AgeEstimator.exactAge(
            bornOn: Self.date(2020, 3, 4),
            asOf: Self.date(2028, 1, 18),
            calendar: Self.calendar
        )

        #expect(estimate == .exact(years: 7))
        #expect(estimate.displayText == "7 years old")
        #expect(!estimate.isEstimate, "a known birthday is arithmetic, and must not be hedged")
    }

    @Test("A birthday that has not come round yet this year")
    func exactAgeBeforeTheBirthday() {
        let estimate = AgeEstimator.exactAge(
            bornOn: Self.date(2020, 3, 4),
            asOf: Self.date(2028, 3, 3),
            calendar: Self.calendar
        )

        #expect(estimate == .exact(years: 7))
    }

    @Test("And on the day itself")
    func exactAgeOnTheBirthday() {
        let estimate = AgeEstimator.exactAge(
            bornOn: Self.date(2020, 3, 4),
            asOf: Self.date(2028, 3, 4),
            calendar: Self.calendar
        )

        #expect(estimate == .exact(years: 8))
    }

    @Test("Asking about a date before the observation never invents precision")
    func ageBeforeTheObservation() {
        let estimate = AgeEstimator.estimate(
            observedAge: 6,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2025, 1, 1),
            calendar: Self.calendar
        )

        #expect(estimate == .approximate(lower: 5, upper: 6))
    }

    @Test("A newborn stays representable")
    func zeroIsAValidAge() {
        let estimate = AgeEstimator.estimate(
            observedAge: 0,
            observedOn: Self.date(2026, 7, 18),
            asOf: Self.date(2026, 9, 1),
            calendar: Self.calendar
        )

        #expect(estimate == .approximate(lower: 0, upper: 1))
    }

    // MARK: - School years

    @Test("July belongs to the school year that began the previous August")
    func schoolYearBoundary() {
        #expect(SchoolYear.containing(Self.date(2026, 7, 18), calendar: Self.calendar).startYear == 2025)
        #expect(SchoolYear.containing(Self.date(2026, 8, 1), calendar: Self.calendar).startYear == 2026)
        #expect(SchoolYear.containing(Self.date(2027, 1, 5), calendar: Self.calendar).startYear == 2026)
    }

    @Test("2026–27 reads as 2026–27")
    func schoolYearDisplay() {
        #expect(SchoolYear(startYear: 2026).displayText == "2026–27")
        // The two-digit end must not lose its leading zero at a century boundary.
        #expect(SchoolYear(startYear: 2099).displayText == "2099–00")
    }

    @Test("Entering second grade in 2026–27 means third grade eighteen months later")
    func gradeAdvancesWithTheSchoolYear() {
        let estimate = GradeEstimator.estimate(
            observedGrade: .grade(2),
            schoolYear: SchoolYear(startYear: 2026),
            asOf: Self.date(2028, 1, 18),
            calendar: Self.calendar
        )

        #expect(estimate.grade == .grade(3))
        #expect(estimate.isEstimate)
        #expect(estimate.displayText == "likely in 3rd grade")
    }

    @Test("Inside the same school year the stated grade is not an estimate")
    func gradeInTheSameYearIsStated() {
        let estimate = GradeEstimator.estimate(
            observedGrade: .grade(2),
            schoolYear: SchoolYear(startYear: 2026),
            asOf: Self.date(2026, 11, 3),
            calendar: Self.calendar
        )

        #expect(estimate.grade == .grade(2))
        #expect(!estimate.isEstimate, "hedging a fact from six weeks ago reads as evasive")
        #expect(estimate.displayText == "in 2nd grade")
    }

    /// The bug this exists to prevent: deriving the school year from the observation date rather
    /// than storing what was said.
    ///
    /// "Starts second grade next month", said on 18 July 2026, is about 2026–27. July falls in
    /// 2025–26, so a naive derivation would anchor to 2025 and put Jack a whole grade behind for the
    /// rest of his life in this app.
    @Test("The summer gap does not shift the grade by a year")
    func summerObservationAnchorsToTheComingYear() {
        let derivedFromObservationDate = SchoolYear.containing(Self.date(2026, 7, 18), calendar: Self.calendar)
        #expect(derivedFromObservationDate.startYear == 2025, "which is exactly why it is not used")

        let stated = GradeEstimator.estimate(
            observedGrade: .grade(2),
            schoolYear: SchoolYear(startYear: 2026),
            asOf: Self.date(2026, 9, 15),
            calendar: Self.calendar
        )
        #expect(stated.grade == .grade(2))

        let naive = GradeEstimator.estimate(
            observedGrade: .grade(2),
            schoolYear: derivedFromObservationDate,
            asOf: Self.date(2026, 9, 15),
            calendar: Self.calendar
        )
        #expect(naive.grade == .grade(3), "the wrong answer, recorded so the difference is visible")
    }

    @Test("Grades run out at the top rather than climbing forever")
    func gradesGraduate() {
        #expect(SchoolGrade.grade(12).advanced(by: 1) == .graduated)
        #expect(SchoolGrade.grade(11).advanced(by: 5) == .graduated)
        #expect(SchoolGrade.graduated.advanced(by: -3) == .graduated, "leaving school is not reversible")
    }

    @Test("And at the bottom")
    func gradesBottomOutAtPreSchool() {
        #expect(SchoolGrade.grade(1).advanced(by: -1) == .kindergarten)
        #expect(SchoolGrade.kindergarten.advanced(by: -1) == .preSchool)
        #expect(SchoolGrade.kindergarten.advanced(by: -6) == .preSchool)
    }

    @Test("Written grades are read the way people write them")
    func gradeParsing() {
        #expect(SchoolGrade.parse("second grade") == .grade(2))
        #expect(SchoolGrade.parse("2nd") == .grade(2))
        #expect(SchoolGrade.parse("2") == .grade(2))
        #expect(SchoolGrade.parse("kindergarten") == .kindergarten)
        #expect(SchoolGrade.parse("pre-k") == .preSchool)
        #expect(SchoolGrade.parse("twelfth grade") == .grade(12))
    }

    /// Nobody says "my son is in twelfth grade". Until these four words were read, "senior" was
    /// stored as text no estimator could parse, so the grade never advanced and the record quietly
    /// held a high-school senior in place while he finished school and left.
    @Test("The words people actually use for high school are grades")
    func highSchoolWordsAreGrades() {
        #expect(SchoolGrade.parse("freshman") == .grade(9))
        #expect(SchoolGrade.parse("sophomore") == .grade(10))
        #expect(SchoolGrade.parse("junior") == .grade(11))
        #expect(SchoolGrade.parse("senior") == .grade(12))
        #expect(SchoolGrade.parse("senior year") == .grade(12))
        #expect(SchoolGrade.parse("a senior in high school") == .grade(12))
        #expect(SchoolGrade.parse("8th grade") == .grade(8))
    }

    /// A senior advances into having finished school rather than into a thirteenth grade — the
    /// property that makes the worked example read correctly a year later.
    @Test("A senior finishes school")
    func aSeniorGraduates() {
        #expect(SchoolGrade.parse("senior")?.advanced(by: 1) == .graduated)
        #expect(SchoolGrade.parse("junior")?.advanced(by: 1) == .grade(12))
    }

    @Test("A grade the parser cannot read stays unread")
    func unreadableGradesAreNotGuessed() {
        #expect(SchoolGrade.parse("sixth form") == nil)
        #expect(SchoolGrade.parse("") == nil)
        #expect(SchoolGrade.parse("99") == nil)
        // Two words neither of which is filler. Guessing that this means sixth grade is how a wrong
        // number earns a decade of being advanced every August.
        #expect(SchoolGrade.parse("sixth college") == nil)
        #expect(SchoolGrade.parse("second and third") == nil)
    }

    // MARK: - Which school year was meant

    /// The six weeks in which people say "going into", and in which reading the date alone is wrong.
    @Test("Going into a grade in July means the year about to begin")
    func startingIntentInSummer() {
        let july = Self.date(2026, 7, 20)

        #expect(SchoolYearIntent.current.schoolYear(observedOn: july, calendar: Self.calendar).startYear == 2025)
        #expect(SchoolYearIntent.starting.schoolYear(observedOn: july, calendar: Self.calendar).startYear == 2026)
    }

    /// Once the school year has turned over, "going into" and "in" agree — which is why the control
    /// has to be a stated intention rather than a rule derived from the month.
    @Test("After the turn of the school year both readings agree")
    func intentsAgreeOnceTermHasBegun() {
        let august = Self.date(2026, 8, 5)

        #expect(SchoolYearIntent.current.schoolYear(observedOn: august, calendar: Self.calendar).startYear == 2026)
        #expect(SchoolYearIntent.starting.schoolYear(observedOn: august, calendar: Self.calendar).startYear == 2026)
    }

    @Test("In the spring, going into a grade means next autumn")
    func startingIntentInSpring() {
        let february = Self.date(2027, 2, 10)

        #expect(SchoolYearIntent.current.schoolYear(observedOn: february, calendar: Self.calendar).startYear == 2026)
        #expect(SchoolYearIntent.starting.schoolYear(observedOn: february, calendar: Self.calendar).startYear == 2027)
    }

    @Test("Ordinals are English ordinals")
    func ordinalSuffixes() {
        #expect(SchoolGrade.grade(1).displayText == "1st grade")
        #expect(SchoolGrade.grade(2).displayText == "2nd grade")
        #expect(SchoolGrade.grade(3).displayText == "3rd grade")
        #expect(SchoolGrade.grade(4).displayText == "4th grade")
        #expect(SchoolGrade.grade(11).displayText == "11th grade")
        #expect(SchoolGrade.grade(12).displayText == "12th grade")
    }

    // MARK: - Provenance

    @Test("Every estimate can say where it came from")
    func provenanceSentence() {
        let sentence = EstimateProvenance.sentence(
            observedOn: Self.date(2026, 7, 18),
            locale: Locale(identifier: "en_GB")
        )

        #expect(sentence.contains("2026"))
        #expect(sentence.hasPrefix("Estimated from information shared"))
    }

    // MARK: - The ledger

    @Test("A single-valued fact is superseded by the newer one")
    func newerObservationWinsForSingleValuedFacts() {
        let subject = UUID()
        let ledger = FactLedger(observations: [
            PersonObservation(
                subjectID: subject, attribute: .location, value: "Portland",
                observedOn: Self.date(2024, 1, 1)
            ),
            PersonObservation(
                subjectID: subject, attribute: .location, value: "Austin",
                observedOn: Self.date(2026, 7, 18)
            ),
        ])

        #expect(ledger.current(.location).map(\.value) == ["Austin"])
        #expect(ledger.history(.location).map(\.value) == ["Portland"])
    }

    @Test("A multi-valued fact keeps everything")
    func multiValuedFactsAccumulate() {
        let subject = UUID()
        let ledger = FactLedger(observations: [
            PersonObservation(subjectID: subject, attribute: .like, value: "natural wine", observedOn: Self.date(2025, 3, 1)),
            PersonObservation(subjectID: subject, attribute: .like, value: "small restaurants", observedOn: Self.date(2026, 7, 18)),
        ])

        #expect(ledger.current(.like).count == 2)
        #expect(ledger.history(.like).isEmpty)
    }

    @Test("Correcting a fact keeps the original")
    func correctionPreservesHistory() {
        let subject = UUID()
        let original = PersonObservation(
            subjectID: subject, attribute: .employer, value: "Acme",
            observedOn: Self.date(2025, 1, 1), supersededOn: Self.date(2026, 7, 18)
        )
        let replacement = PersonObservation(
            subjectID: subject, attribute: .employer, value: "Northwind",
            observedOn: Self.date(2026, 7, 18), supersedesID: original.id
        )

        let ledger = FactLedger(observations: [original, replacement])

        #expect(ledger.value(of: .employer) == "Northwind")
        #expect(ledger.history(.employer).contains { $0.value == "Acme" })
        #expect(ledger.observations.count == 2, "correction appends; it never deletes")
    }

    @Test("A fact nobody has checked in two years stops being vouched for")
    func factsGoStale() {
        let observation = PersonObservation(
            subjectID: UUID(), attribute: .employer, value: "Acme",
            observedOn: Self.date(2024, 1, 1)
        )

        #expect(!observation.isStale(asOf: Self.date(2024, 6, 1), calendar: Self.calendar))
        #expect(observation.isStale(asOf: Self.date(2026, 7, 18), calendar: Self.calendar))
        #expect(observation.confidence == .stated, "the record is unchanged")
        #expect(
            observation.effectiveConfidence(asOf: Self.date(2026, 7, 18), calendar: Self.calendar) == .uncertain,
            "only the app's willingness to state it plainly decays"
        )
    }

    @Test("Preferences do not go stale")
    func someFactsNeverExpire() {
        let observation = PersonObservation(
            subjectID: UUID(), attribute: .like, value: "natural wine",
            observedOn: Self.date(2015, 1, 1)
        )

        #expect(!observation.isStale(asOf: Self.date(2026, 7, 18), calendar: Self.calendar))
    }
}
