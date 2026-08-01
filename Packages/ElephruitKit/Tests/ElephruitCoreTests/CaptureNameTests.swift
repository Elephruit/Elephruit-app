import ElephruitCore
import Foundation
import Testing

/// Names with spaces in them.
///
/// `>Elephruit App` used to file under a project called "Elephruit" and leave the word "App" in the
/// title — and `@Mike Zehrer` used to create a second person called "Mike" next to the one the user
/// meant. Both are the same bug: the tokenizer splits on spaces, and most real projects and most
/// real people have a space in their name.
///
/// The fix is not more punctuation. It is telling the parser which names exist, so it can tell the
/// second word of a name from the first word of the sentence — the only thing that can.
@Suite("Capture names with spaces")
struct CaptureNameTests {
    private let vocabulary = CaptureVocabulary(
        projects: ["Elephruit App", "Q3 Launch", "Operations"],
        people: ["Mike Zehrer", "Priya Raman", "Sarah"]
    )

    // MARK: - The reported case

    @Test("A two-word project is claimed whole")
    func twoWordProject() {
        let draft = CaptureParser.parse("Ship the beta >Elephruit App", knowing: vocabulary)

        #expect(draft.projectHint == "Elephruit App")
        #expect(draft.title == "Ship the beta", "the second word of the name is not left in the title")
    }

    @Test("A two-word person is claimed whole")
    func twoWordPerson() {
        let draft = CaptureParser.parse("Ask @Mike Zehrer about it", knowing: vocabulary)

        #expect(draft.personHints == ["Mike Zehrer"])
        #expect(draft.title == "Ask about it")
    }

    // MARK: - Where the name ends

    /// The whole risk of reading across a space: a name must not swallow the sentence after it.
    @Test("Extension stops at the first word that is not part of the name")
    func extensionStopsAtTheSentence() {
        let draft = CaptureParser.parse(">Q3 Launch slipped a week", knowing: vocabulary)

        #expect(draft.projectHint == "Q3 Launch")
        #expect(draft.title == "slipped a week")
    }

    @Test("A name nobody has claims only its first word, as it always did")
    func unknownNamesAreNotExtended() {
        let draft = CaptureParser.parse(">Everest base camp", knowing: vocabulary)

        #expect(draft.projectHint == "Everest")
        #expect(draft.title == "base camp")
    }

    @Test("Extension stops at the next token rather than reading through it")
    func extensionStopsAtTheNextToken() {
        let draft = CaptureParser.parse("Write it up >Q3 Launch #urgent due:friday", knowing: vocabulary)

        #expect(draft.projectHint == "Q3 Launch")
        #expect(draft.tagSlugs == ["urgent"])
        #expect(draft.dueDate == .nextWeekday(6))
        #expect(draft.title == "Write it up")
    }

    /// Half-typed is the state the field is in for most of the time anyone is looking at it, so the
    /// interpretation row has to be right about it too.
    @Test("A half-typed name still reads as a name")
    func halfTypedNamesStillExtend() {
        let draft = CaptureParser.parse(">Q3 Lau", knowing: vocabulary)
        #expect(draft.projectHint == "Q3 Lau")
    }

    @Test("The longest name that matches wins")
    func longestNameWins() {
        let both = CaptureVocabulary(people: ["Sarah", "Sarah Okonjo"])
        let draft = CaptureParser.parse("Call @Sarah Okonjo tomorrow", knowing: both)

        #expect(draft.personHints == ["Sarah Okonjo"])
        #expect(draft.title == "Call tomorrow")
    }

    // MARK: - Quoting

    /// Quoting is how you name something that does not exist yet, and it has to keep working — so a
    /// quoted value is never extended over what follows it.
    @Test("A quoted name is taken exactly as written")
    func quotingWins() {
        let draft = CaptureParser.parse(">\"Elephruit\" App", knowing: vocabulary)

        #expect(draft.projectHint == "Elephruit")
        #expect(draft.title == "App")
    }

    @Test("A quoted name still spans its spaces")
    func quotedNamesStillSpanSpaces() {
        let draft = CaptureParser.parse(">\"Q3 Launch\" is late", knowing: vocabulary)

        #expect(draft.projectHint == "Q3 Launch")
        #expect(draft.title == "is late")
    }

    // MARK: - Without a vocabulary

    /// The grammar on its own is unchanged, which is what keeps every other test in this target
    /// honest: nothing here quietly rewrote what the sigils mean.
    @Test("With no names known, nothing is read across a space")
    func withoutVocabularyNothingChanges() {
        let draft = CaptureParser.parse("Ship the beta >Elephruit App")

        #expect(draft.projectHint == "Elephruit")
        #expect(draft.title == "Ship the beta App")
    }

    // MARK: - What the field draws

    /// A token drawn as one object has to *be* one object. Underlining `>Elephruit` while filing
    /// under "Elephruit App" would be the interface describing a different capture from the one
    /// being made.
    @Test("The highlight covers the whole name")
    func highlightCoversTheWholeName() throws {
        let text = "Ship the beta >Elephruit App"
        let span = try #require(
            CaptureHighlight.spans(in: text, knowing: vocabulary).first { $0.kind == .project }
        )

        #expect(span.text == "Elephruit App")
        #expect(span.utf16Range == 14..<text.utf16.count)
    }

    // MARK: - A second project

    /// Only the first `>` names the project. The second stays text, and must not eat the words after
    /// it on its way to being ignored.
    @Test("A second project hint consumes nothing")
    func secondHintConsumesNothing() {
        let draft = CaptureParser.parse(">Q3 Launch >Elephruit App", knowing: vocabulary)

        #expect(draft.projectHint == "Q3 Launch")
        #expect(draft.title == ">Elephruit App")
    }
}
