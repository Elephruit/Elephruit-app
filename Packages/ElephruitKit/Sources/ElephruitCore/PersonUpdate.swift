import Foundation

/// Somebody learned about in passing, and everything said about them in the same breath.
///
/// ### Why a name is optional here and nowhere else
/// The most common thing anybody learns about another person's family is that it exists. *He has a
/// son and a daughter* is two facts, and until this type existed the app could record neither of
/// them, because creating a related person went through
/// ``ElephruitPersistence/PersonRepository/resolveOrCreatePlaceholder(named:)``, which throws on an
/// empty string. The user's three options were to invent a name, to type "son" into a name field, or
/// to record nothing — and the app shipped with the third being the honest one.
///
/// So a capture with no name is ordinary rather than incomplete. What it produces is a record whose
/// title is a *phrase* — "Dave's son" — and which is flagged as not having a stated name, so that a
/// name learned later replaces the phrase rather than joining it, and so the interface can ask.
///
/// ### Why the grade is text and not a `SchoolGrade`
/// Because ``SchoolGrade/parse(_:)`` is allowed to fail, and what the user typed has to survive that
/// failure. An unparsed grade is stored verbatim, shown verbatim, and — correctly — never advanced;
/// re-wording it into the nearest thing the app understood would be the app claiming somebody said
/// something they did not.
public struct RelativeCapture: Sendable, Hashable, Identifiable {
    public var id: UUID

    public var kind: RelationshipKind

    /// The record this row is about, when the caller already knows.
    ///
    /// ### Why the repository is not allowed to work this out
    /// Two rows saying "son" with no name are either one child recorded twice or two children, and
    /// nothing in the data distinguishes them. Guessing *reuse* silently merges two people, which is
    /// unrecoverable and invisible; guessing *new* leaves a duplicate, which is visible and one tap
    /// to fix. So the repository always creates, and identity is stated here by the one caller that
    /// actually has it — the editor that opened an existing relative in order to change them.
    public var existingPersonID: UUID?

    /// The user's own word — "son", "step-mother". Never inferred from a name or a pronoun.
    public var label: String?

    /// Their name, when it was given. `nil` is legal, and ordinary.
    public var name: String?

    /// Whole years, as stated. The estimator turns this into a window that widens on its own.
    public var age: Int?

    /// The grade exactly as the user wrote it — "8th", "senior", "going into second".
    public var gradeText: String?

    /// Which school year ``gradeText`` referred to.
    public var schoolYearIntent: SchoolYearIntent

    public var school: String?

    /// Anything else worth keeping, recorded as a quick fact on their own record.
    public var note: String?

    public init(
        id: UUID = UUID(),
        kind: RelationshipKind = .child,
        existingPersonID: UUID? = nil,
        label: String? = nil,
        name: String? = nil,
        age: Int? = nil,
        gradeText: String? = nil,
        schoolYearIntent: SchoolYearIntent = .current,
        school: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.existingPersonID = existingPersonID
        self.label = label
        self.name = name
        self.age = age
        self.gradeText = gradeText
        self.schoolYearIntent = schoolYearIntent
        self.school = school
        self.note = note
    }

    // MARK: What was actually said

    /// Their name with the whitespace taken off, or `nil` if there was not one.
    public var statedName: String? {
        Self.cleaned(name)
    }

    /// Whether a name was given. The flag the record is created with, and the query behind the
    /// "to fill in" list.
    public var hasStatedName: Bool { statedName != nil }

    public var statedGradeText: String? { Self.cleaned(gradeText) }

    public var statedSchool: String? { Self.cleaned(school) }

    public var statedNote: String? { Self.cleaned(note) }

    public var statedLabel: String? { Self.cleaned(label)?.lowercased() }

    /// The grade, if this app can read it. `nil` means the text stands as written and is never
    /// advanced — see the type's note.
    public var parsedGrade: SchoolGrade? {
        statedGradeText.flatMap(SchoolGrade.parse)
    }

    /// Whether the user said anything at all in this row.
    ///
    /// ### Why a label counts and a kind does not
    /// "He has a son" is a complete fact with no name, no age and no grade behind it, so a row
    /// cannot be required to carry one of those to be worth writing. But a multi-row editor also
    /// produces rows nobody filled in, and those have a kind too — every row does, because the
    /// picker has a default. The word the user chose is the thing that separates the two: it is
    /// typed, or it is set by pressing *Add a son*, and either way somebody meant it. An untouched
    /// row has no word and is discarded.
    public var isEmpty: Bool {
        existingPersonID == nil && statedName == nil && statedLabel == nil && age == nil
            && statedGradeText == nil && statedSchool == nil && statedNote == nil
    }

    /// How many facts this row records, not counting the relationship itself.
    public var factCount: Int {
        (age == nil ? 0 : 1) + (statedGradeText == nil ? 0 : 1)
            + (statedSchool == nil ? 0 : 1) + (statedNote == nil ? 0 : 1)
    }

    /// The phrase that stands in for a name until there is one — "Dave's son".
    public func derivedTitle(subjectName: String) -> String {
        kind.possessivePhrase(subject: subjectName, label: statedLabel)
    }

    /// The title this person's record should carry: their name if they have one, the phrase if not.
    public func title(subjectName: String) -> String {
        statedName ?? derivedTitle(subjectName: subjectName)
    }

    // MARK: What it becomes

    /// The facts to record against this person.
    ///
    /// The school year is resolved *here*, against a clock, because
    /// ``ElephruitPersistence/PersonRepository/schoolYear(for:observedOn:calendar:)`` can only guess
    /// from the observation date and guesses wrong for the six weeks of summer in which people say
    /// "going into". An intent stated by the user beats a date read by the app.
    public func observations(observedOn: Date, calendar: Calendar) -> [ObservationDraft] {
        var drafts: [ObservationDraft] = []

        if let age {
            drafts.append(ObservationDraft(attribute: .observedAge, value: "\(age)"))
        }

        if let statedGradeText {
            drafts.append(
                ObservationDraft(
                    attribute: .schoolGrade,
                    value: statedGradeText,
                    schoolYearStart: schoolYearIntent
                        .schoolYear(observedOn: observedOn, calendar: calendar)
                        .startYear
                )
            )
        }

        if let statedSchool {
            drafts.append(ObservationDraft(attribute: .school, value: statedSchool))
        }

        if let statedNote {
            drafts.append(ObservationDraft(attribute: .quickFact, value: statedNote))
        }

        return drafts
    }

    /// One line saying what will be written, for the preview under the field.
    ///
    /// Built here rather than in a view so the Mac's sheet footer, the phone's confirmation and the
    /// meeting debrief cannot describe the same save three different ways.
    public func summarySentence(subjectName: String, observedOn: Date, calendar: Calendar) -> String {
        var sentence = statedName.map { "\($0) is \(kind.possessivePhrase(subject: subjectName, label: statedLabel))" }
            ?? "A \(statedLabel ?? kind.displayName) of \(subjectName), name not known yet"

        var clauses: [String] = []
        if let age {
            clauses.append("\(age) years old")
        }
        if let statedGradeText {
            let year = schoolYearIntent.schoolYear(observedOn: observedOn, calendar: calendar)
            let grade = parsedGrade?.displayText ?? statedGradeText
            clauses.append("\(grade) in \(year.displayText)")
        }
        if let statedSchool {
            clauses.append("at \(statedSchool)")
        }

        if !clauses.isEmpty {
            sentence += " · " + clauses.joined(separator: ", ")
        }
        return sentence
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - The whole capture

/// Everything one conversation added to what is known about one person.
///
/// ### Why both apps build this and neither writes
/// The Mac and the phone drifted into two different people modules — the Mac accumulated four sheets
/// and a command bar, the phone stayed read-only — because each grew its own write path. There is
/// one write path now: every interface builds a ``PersonUpdate`` and hands it to
/// ``ElephruitPersistence/PersonRepository/apply(_:source:observedOn:)``, which is the only code that
/// knows about superseding, reciprocal relationships, placeholder resolution or school years.
///
/// A platform-specific write path is therefore a review failure rather than a style preference: the
/// second one to exist is the one that will be wrong about something, and nobody will find out until
/// the two screens disagree in front of a user.
public struct PersonUpdate: Sendable, Hashable {
    /// Who the conversation was about.
    public var subjectID: UUID

    /// Facts about them.
    public var observations: [ObservationDraft]

    /// People around them, and what was said about those people.
    public var relatives: [RelativeCapture]

    public init(
        subjectID: UUID,
        observations: [ObservationDraft] = [],
        relatives: [RelativeCapture] = []
    ) {
        self.subjectID = subjectID
        self.observations = observations
        self.relatives = relatives
    }

    /// Relatives with anything in them. An editor that offers a blank row must not write it.
    public var recordableRelatives: [RelativeCapture] {
        relatives.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool {
        observations.isEmpty && recordableRelatives.isEmpty
    }

    /// How many separate things this will write, for a footer that says so before it happens.
    ///
    /// One per fact about the subject, plus one relationship and its own facts for each relative.
    /// Counted without a clock, because how many things are written does not depend on when.
    public var writeCount: Int {
        observations.count + recordableRelatives.reduce(0) { $0 + 1 + $1.factCount }
    }
}
