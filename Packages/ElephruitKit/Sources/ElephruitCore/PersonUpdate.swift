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

    /// Everything said about them, keyed by what it is about.
    ///
    /// ### Why a dictionary rather than fields
    /// This was five named properties — age, grade, school, note — and each one cost an edit in six
    /// files, a field in three editors, and a branch in the save path. Which meant the answer to
    /// "can I record where my colleague's partner works" was no, permanently, for want of a
    /// `String?`. The fields were also gated on `kind == .child` in four places, so a partner
    /// finishing a PhD could not have a grade.
    ///
    /// Keyed by ``FactAttribute``, which is an open type: what a row can carry is now whatever the
    /// user names, and the editors ask ``RelationshipKind/suggestedAttributes`` what to *offer*
    /// rather than deciding what is *possible*.
    public var facts: [FactAttribute: String]

    /// Which school year a ``FactAttribute/schoolGrade`` value referred to.
    ///
    /// Beside the dictionary rather than in it, because it is not a fact about anybody — it is which
    /// of two readings of one fact was meant, and storing "starting" as the value of some parallel
    /// attribute would make it a claim about the child.
    public var schoolYearIntent: SchoolYearIntent

    public init(
        id: UUID = UUID(),
        kind: RelationshipKind = .child,
        existingPersonID: UUID? = nil,
        label: String? = nil,
        name: String? = nil,
        facts: [FactAttribute: String] = [:],
        schoolYearIntent: SchoolYearIntent = .current
    ) {
        self.id = id
        self.kind = kind
        self.existingPersonID = existingPersonID
        self.label = label
        self.name = name
        self.facts = facts
        self.schoolYearIntent = schoolYearIntent
    }

    /// The older shape, for callers that only ever wanted a child.
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
        self.init(
            id: id, kind: kind, existingPersonID: existingPersonID,
            label: label, name: name, schoolYearIntent: schoolYearIntent
        )
        self.age = age
        self.gradeText = gradeText
        self.school = school
        self.note = note
    }

    // MARK: The named facts, as accessors

    /// What is recorded for one attribute, with the whitespace taken off. Setting `nil` or blank
    /// removes it, so a field cleared by the user records nothing rather than an empty string.
    public subscript(attribute: FactAttribute) -> String? {
        get { Self.cleaned(facts[attribute]) }
        set {
            if let cleaned = Self.cleaned(newValue) {
                facts[attribute] = cleaned
            } else {
                facts.removeValue(forKey: attribute)
            }
        }
    }

    /// Whole years, as stated. The estimator turns this into a window that widens on its own.
    public var age: Int? {
        get { self[.observedAge].flatMap(Int.init) }
        set { self[.observedAge] = newValue.map(String.init) }
    }

    /// The grade exactly as the user wrote it — "8th", "senior", "going into second".
    public var gradeText: String? {
        get { self[.schoolGrade] }
        set { self[.schoolGrade] = newValue }
    }

    public var school: String? {
        get { self[.school] }
        set { self[.school] = newValue }
    }

    /// Anything else worth keeping, recorded as a quick fact on their own record.
    public var note: String? {
        get { self[.quickFact] }
        set { self[.quickFact] = newValue }
    }

    // MARK: What was actually said

    /// Their name with the whitespace taken off, or `nil` if there was not one.
    public var statedName: String? {
        Self.cleaned(name)
    }

    /// Whether a name was given. The flag the record is created with, and the query behind the
    /// "to fill in" list.
    public var hasStatedName: Bool { statedName != nil }

    public var statedGradeText: String? { gradeText }

    public var statedSchool: String? { school }

    public var statedNote: String? { note }

    public var statedLabel: String? { Self.cleaned(label)?.lowercased() }

    /// Everything actually said, in the order the interface offers it: the suggestions for this
    /// relationship first, then anything the user named that is not among them.
    public var statedFacts: [(attribute: FactAttribute, value: String)] {
        let suggested = kind.suggestedAttributes
        let present = facts.filter { Self.cleaned($0.value) != nil }

        let inOrder = suggested.compactMap { attribute in
            present[attribute].map { (attribute: attribute, value: $0) }
        }
        let rest = present.keys
            .filter { !suggested.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { key in present[key].map { (attribute: key, value: $0) } }

        return inOrder + rest
    }

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
        existingPersonID == nil && statedName == nil && statedLabel == nil && statedFacts.isEmpty
    }

    /// How many facts this row records, not counting the relationship itself.
    public var factCount: Int { statedFacts.count }

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
        statedFacts.map { entry in
            ObservationDraft(
                attribute: entry.attribute,
                value: entry.value,
                schoolYearStart: entry.attribute == .schoolGrade
                    ? schoolYearIntent.schoolYear(observedOn: observedOn, calendar: calendar).startYear
                    : nil
            )
        }
    }

    /// One line saying what will be written, for the preview under the field.
    ///
    /// Built here rather than in a view so the Mac's sheet footer, the phone's confirmation and the
    /// meeting debrief cannot describe the same save three different ways.
    public func summarySentence(subjectName: String, observedOn: Date, calendar: Calendar) -> String {
        var sentence = statedName.map { "\($0) is \(kind.possessivePhrase(subject: subjectName, label: statedLabel))" }
            ?? "A \(statedLabel ?? kind.displayName) of \(subjectName), name not known yet"

        // Three attributes have a phrasing of their own because a sentence reads badly otherwise —
        // "Age: 8" against "8 years old". Everything else, including attributes nobody has thought
        // of yet, reads as "Heading: value", which is plain and never wrong.
        let clauses: [String] = statedFacts.map { entry in
            switch entry.attribute {
            case .observedAge:
                "\(entry.value) years old"
            case .schoolGrade:
                {
                    let year = schoolYearIntent.schoolYear(observedOn: observedOn, calendar: calendar)
                    return "\(SchoolGrade.parse(entry.value)?.displayText ?? entry.value) in \(year.displayText)"
                }()
            case .school:
                "at \(entry.value)"
            default:
                "\(entry.attribute.displayName.lowercased()): \(entry.value)"
            }
        }

        if !clauses.isEmpty {
            sentence += " · " + clauses.joined(separator: ", ")
        }
        return sentence
    }

    /// What the app made of the grade that was typed, said back before anything is saved.
    ///
    /// ### Why an unreadable grade has to be announced rather than quietly kept
    /// Storing it verbatim and never advancing it is the right behaviour — the alternative is
    /// re-wording somebody's words into the nearest thing understood — but it is a terrible
    /// surprise. The moment to notice that "upper sixth" will sit unchanged forever is while it is
    /// being typed, not next August when the card has silently stayed put and the child has not.
    ///
    /// `nil` when there is no grade to read. Lives here rather than in a view so the Mac's sheet,
    /// the phone's sheet and the meeting debrief cannot say three different things about one word.
    public func gradeReading(observedOn: Date, calendar: Calendar) -> String? {
        guard let text = statedGradeText else { return nil }
        let year = schoolYearIntent.schoolYear(observedOn: observedOn, calendar: calendar)

        guard let grade = parsedGrade else {
            return "“\(text)” is kept exactly as written for \(year.displayText). "
                + "Elephruit cannot read it as a grade, so it will not move up each year."
        }
        return "Reads as \(grade.displayText) in \(year.displayText), and moves up each August."
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

// MARK: - Offering a relative

/// The words on the add buttons, and what each one means.
///
/// Gendered words sit beside the neutral one rather than replacing it. The app never infers one —
/// pressing *Son* is the user saying it, which is the only way a gendered word ever enters a record
/// here.
public enum RelativeQuickAdd {
    public static let all: [(label: String, kind: RelationshipKind)] = [
        ("Son", .child),
        ("Daughter", .child),
        ("Child", .child),
        ("Partner", .partner),
        ("Parent", .parent),
        ("Sibling", .sibling),
    ]

    /// A new row, always carrying a word.
    ///
    /// The word is what makes a row worth writing — see ``ElephruitCore/RelativeCapture/isEmpty``.
    /// Every row arrives by somebody pressing a button that says one, so seeding it from the button
    /// is not a default being invented on the user's behalf; it is what they just pressed. Without
    /// it, opening the editor from *Add Child…* produces a row the save button refuses.
    public static func row(kind: RelationshipKind, label: String?) -> RelativeCapture {
        RelativeCapture(kind: kind, label: label ?? kind.displayName)
    }
}
