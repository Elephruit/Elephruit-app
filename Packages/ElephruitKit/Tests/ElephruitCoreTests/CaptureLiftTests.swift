import Foundation
import Testing

@testable import ElephruitCore

/// Taking settled instructions out of the sentence they were written in.
@Suite("Capture lift")
struct CaptureLiftTests {
    private let launch = CaptureVocabulary(projects: ["Q3 Launch"], people: ["Sarah Okonjo"])

    /// Lifts with the caret at the end, which is where it is for all but the mid-string cases.
    private func lift(
        _ text: String,
        knowing vocabulary: CaptureVocabulary = .empty,
        flushing: Bool = false
    ) -> CaptureLift.Result {
        CaptureLift.lift(
            text,
            caretAt: text.count,
            knowing: vocabulary,
            flushing: flushing
        )
    }

    // MARK: - Tokens that cannot grow

    @Test("A tag leaves the sentence as soon as the space after it is typed")
    func tagLiftsOnTheSpace() {
        let result = lift("Call the framer #errand ")

        #expect(result.didLift)
        #expect(result.text == "Call the framer ")
        #expect(result.lifted.tagSlugs == ["errand"])
    }

    @Test("A tag still being typed is left alone")
    func tagInFlightStays() {
        let result = lift("Call the framer #err")

        #expect(result.didLift == false)
        #expect(result.text == "Call the framer #err")
    }

    /// The last keystroke before the space. Lifting here would take the tag away mid-word.
    @Test("A finished-looking tag with no space after it is still in flight")
    func tagAtTheEndStays() {
        #expect(lift("Call the framer #errand").didLift == false)
    }

    @Test("A priority cannot grow either, so it goes on the space")
    func priorityLifts() {
        let result = lift("Read the brief !high ")

        #expect(result.text == "Read the brief ")
        #expect(result.lifted.priority == .high)
    }

    // MARK: - Tokens that can grow

    /// The rule the whole design turns on. `>Q3` is followed by a space and looks finished; somebody
    /// half-way through typing `Q3 Launch` would watch their project become the wrong one.
    @Test("A project name waits, because the next word might be part of it")
    func projectWaitsForAWordThatIsNotItsOwn() {
        #expect(lift(">Q3 ", knowing: launch).didLift == false)
        #expect(lift(">Q3 Launch ", knowing: launch).didLift == false)
    }

    @Test("A project name goes once a word arrives that plainly is not part of it")
    func projectLiftsAfterACompletedWord() {
        let result = lift(">Q3 Launch slipped ", knowing: launch)

        #expect(result.text == "slipped ")
        #expect(result.lifted.projectHint == "Q3 Launch")
    }

    /// Growability is a property of the kind, not of the library. Waiting one word costs nothing and
    /// means the rule does not need to know which names exist.
    @Test("A project waits even when no name could possibly extend it")
    func projectWaitsWithNoVocabulary() {
        #expect(lift(">Q3 ").didLift == false)

        let result = lift(">Q3 hello ")
        #expect(result.text == "hello ")
        #expect(result.lifted.projectHint == "Q3")
    }

    @Test("A name that extends past what the library knows keeps the extra words")
    func unknownExtensionStaysInTheTitle() {
        let result = lift(">Everest base camp ")

        #expect(result.lifted.projectHint == "Everest")
        #expect(result.text == "base camp ")
    }

    @Test("A person's name waits the same way a project's does")
    func personWaits() {
        #expect(lift("Ask @Sarah ", knowing: launch).didLift == false)

        let result = lift("Ask @Sarah Okonjo about it ", knowing: launch)
        #expect(result.lifted.personHints == ["Sarah Okonjo"])
        #expect(result.text == "Ask about it ")
    }

    // MARK: - Dates, which grow greedily

    @Test("A deadline waits, because a number after it might become a time")
    func deadlineWaitsForATime() {
        #expect(lift("Prep due:friday ").didLift == false)
        #expect(lift("Prep due:friday 3").didLift == false)
    }

    @Test("A deadline takes its time with it once both have settled")
    func deadlineTakesItsTime() {
        let result = lift("Prep due:friday 3pm sharp ")

        #expect(result.text == "Prep sharp ")
        #expect(result.lifted.dueDate == .nextWeekday(6))
        #expect(result.lifted.dueTime?.hour == 15)
    }

    @Test("A word that is not a date is left where it is")
    func nonDateWordStays() {
        let result = lift("Prep due:friday meeting ")

        #expect(result.text == "Prep meeting ")
        #expect(result.lifted.dueDate == .nextWeekday(6))
    }

    @Test("A start date is lifted as one, not as a deadline")
    func followLifts() {
        let result = lift("Chase it follow:tomorrow again ")

        #expect(result.lifted.followDate == .tomorrow)
        #expect(result.lifted.dueDate == nil)
    }

    // MARK: - Quoting

    @Test("Quoting settles a name, so it goes on the space")
    func quotedNameLiftsImmediately() {
        let result = lift(">\"Q3 Launch\" slipped")

        #expect(result.lifted.projectHint == "Q3 Launch")
        #expect(result.text == "slipped")
    }

    @Test("An unclosed quote never settles, and is left for the merge to claim")
    func unclosedQuoteNeverLifts() {
        #expect(lift(">\"Q3 Launch").didLift == false)
    }

    // MARK: - What is never taken

    @Test("A sigil the parser did not understand keeps its text")
    func unrecognisedNeverLifts() {
        let result = lift("Prep due:someday now ")

        #expect(result.didLift == false)
        #expect(result.text.contains("due:someday"))
    }

    /// There is no URL token — the parser leaves the word in the title and only notes what it means.
    /// Removing it would delete the one part of a bookmark anybody wants to read.
    @Test("A URL is never taken out of the text")
    func urlNeverLifts() {
        #expect(lift("read later https://example.com/x ").didLift == false)
    }

    @Test("A second project is left alone, and becomes the first once the first has gone")
    func secondProjectWaitsItsTurn() {
        let first = lift(">Alpha >Beta now ")
        #expect(first.lifted.projectHint == "Alpha")
        #expect(first.text == ">Beta now ")

        let second = lift(first.text)
        #expect(second.lifted.projectHint == "Beta")
    }

    // MARK: - The task prefix

    @Test("A task prefix disappears the moment it is complete")
    func taskPrefixLifts() {
        let result = lift("- Call the framer")

        #expect(result.text == "Call the framer")
        #expect(result.lifted.kind == .reminder)
    }

    @Test("Every spelling of the prefix works, and the longest wins")
    func everyTaskPrefix() {
        #expect(lift("- [ ] Call").text == "Call")
        #expect(lift("- [x] Call").text == "Call")
        #expect(lift("[ ] Call").text == "Call")
        #expect(lift("[] Call").text == "Call")
        #expect(lift("* Call").text == "Call")
    }

    @Test("A prefix and a tag come out together in one edit")
    func prefixAndTokenTogether() {
        let result = lift("- Call the framer #errand ")

        #expect(result.text == "Call the framer ")
        #expect(result.lifted.kind == .reminder)
        #expect(result.lifted.tagSlugs == ["errand"])
    }

    // MARK: - The caret

    @Test("The caret moves left by whatever was removed before it")
    func caretShiftsLeft() {
        // "Call #errand the framer" — the tag settles, and the caret is at the very end.
        let result = CaptureLift.lift("Call #errand the framer", caretAt: 23)

        #expect(result.text == "Call the framer")
        #expect(result.caret == 15)
    }

    @Test("A caret before what was removed does not move")
    func caretBeforeIsUntouched() {
        let result = CaptureLift.lift("Call #errand the framer", caretAt: 2)

        #expect(result.text == "Call the framer")
        #expect(result.caret == 2)
    }

    /// It has nowhere of its own to go, so it lands where the token started — which is where the eye
    /// already is.
    @Test("A caret inside what was removed lands where it began")
    func caretInsideCollapses() {
        let result = CaptureLift.lift("Call #errand the framer", caretAt: 8)

        #expect(result.text == "Call the framer")
        #expect(result.caret == 5)
    }

    @Test("An emoji before a token does not shift the removal")
    func emojiOffsets() {
        let result = lift("🎉 party #fun soon ")

        #expect(result.text == "🎉 party soon ")
        #expect(result.lifted.tagSlugs == ["fun"])
    }

    // MARK: - Guards

    @Test("Nothing is lifted while an input method is composing")
    func markedTextIsUntouched() {
        let text = "Call the framer #errand "
        let result = CaptureLift.lift(text, caretAt: text.count, hasMarkedText: true)

        #expect(result.didLift == false)
        #expect(result.text == text)
    }

    @Test("Nothing is lifted while there is a selection")
    func selectionIsUntouched() {
        let text = "Call the framer #errand "
        let result = CaptureLift.lift(text, caretAt: 4, selectionLength: 6)

        #expect(result.didLift == false)
    }

    @Test("A sentence with nothing to lift is returned untouched")
    func plainTextIsUntouched() {
        let result = lift("Call the framer about the quote")

        #expect(result.didLift == false)
        #expect(result.lifted.tagSlugs.isEmpty)
    }

    // MARK: - Whitespace

    @Test("Removing a token from the middle does not leave a double space")
    func noDoubleSpace() {
        #expect(lift("Call #errand Sarah ").text == "Call Sarah ")
    }

    @Test("A token at the end takes the space before it instead")
    func trailingTokenTakesThePrecedingSpace() {
        #expect(lift("Call Sarah #errand", flushing: true).text == "Call Sarah")
    }

    @Test("Several tokens in one pass are removed together")
    func manyTokensAtOnce() {
        let result = lift("Call @Sarah #urgent due:friday about it ")

        #expect(result.text == "Call about it ")
        #expect(result.lifted.personHints == ["Sarah"])
        #expect(result.lifted.tagSlugs == ["urgent"])
        #expect(result.lifted.dueDate == .nextWeekday(6))
    }

    // MARK: - Flushing

    /// What Save and losing focus do. There is no next keystroke, so there is nothing left to wait for.
    @Test("A flush takes everything understood, settled or not")
    func flushTakesEverything() {
        let result = lift("Prep due:friday", flushing: true)

        #expect(result.text == "Prep")
        #expect(result.lifted.dueDate == .nextWeekday(6))
    }

    @Test("A flush still refuses what the parser did not understand")
    func flushRefusesTheUnrecognised() {
        #expect(lift("Prep due:someday", flushing: true).didLift == false)
    }

    @Test("A flush of a project takes the whole name the vocabulary knows")
    func flushTakesTheWholeName() {
        let result = lift(">Q3 Launch", knowing: launch, flushing: true)

        #expect(result.text.isEmpty)
        #expect(result.lifted.projectHint == "Q3 Launch")
    }

    // MARK: - The invariant that makes lateness safe

    /// Lifting is a rearrangement, not an interpretation. Whatever a string meant before any of it
    /// was taken out, the chips plus what is left must still mean — otherwise every gap in the
    /// settling rule is a dropped instruction rather than a missing chip.
    ///
    /// `kind` is checked separately, because ``QuickJotDraft`` deliberately promotes a note to a task
    /// on a priority where the parser does not. That divergence is argued for where it is written;
    /// this only has to hold it steady.
    @Test(
        "Lifting cannot change what a line means",
        arguments: [
            "Call the framer #errand about the quote",
            "Call @Sarah #urgent due:friday about it",
            "- Renew the insurance >Q3 Launch due:tomorrow 3pm !high",
            "Ask @Sarah Okonjo whether >Q3 Launch slipped #status",
            "Chase it follow:next Tuesday #waiting",
            "read later https://example.com/x #reading",
            "Prep due:someday which is not a date",
            ">\"Q3 Launch\" needs a plan #planning",
            "Nothing here but words",
            "Notes\nwith a second line #admin",
        ]
    )
    func liftingPreservesMeaning(_ original: String) {
        let vocabulary = launch
        let expected = CaptureParser.parse(original, knowing: vocabulary)

        let result = CaptureLift.lift(
            original,
            caretAt: original.count,
            knowing: vocabulary,
            flushing: true
        )

        var draft = QuickJotDraft()
        draft.apply(result.lifted)
        let actual = draft.merged(with: CaptureParser.parse(result.text, knowing: vocabulary))

        #expect(actual.title == expected.title)
        #expect(actual.body == expected.body)
        #expect(actual.tagSlugs == expected.tagSlugs)
        #expect(actual.personHints == expected.personHints)
        #expect(actual.projectHint == expected.projectHint)
        #expect(actual.dueDate == expected.dueDate)
        #expect(actual.dueTime == expected.dueTime)
        #expect(actual.followDate == expected.followDate)
        #expect(actual.priority == expected.priority)
        #expect(actual.url == expected.url)

        let promoted = expected.kind == .note && actual.kind == .reminder
        #expect(actual.kind == expected.kind || promoted)
    }
}
