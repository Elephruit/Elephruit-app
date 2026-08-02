import Foundation
import Testing

@testable import ElephruitCore

/// The decisions a Quick Jot collects, and how they meet the words still in the field.
@Suite("Quick Jot draft")
struct QuickJotDraftTests {
    // MARK: - Promotion

    @Test("A new draft is a note that nobody chose")
    func startsAsAnUnchosenNote() {
        let draft = QuickJotDraft()
        #expect(draft.kind == .note)
        #expect(draft.kindIsExplicit == false)
        #expect(draft.isEmpty)
    }

    @Test("Setting a deadline makes a note into a task")
    func deadlinePromotes() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .tomorrow))
        #expect(draft.kind == .task)
    }

    @Test("Setting a start date makes a note into a task")
    func followPromotes() {
        var draft = QuickJotDraft()
        draft.setFollow(.today)
        #expect(draft.kind == .task)
    }

    /// The parser deliberately does *not* do this — see `CaptureGrammarTests`. Clicking the flag is
    /// not the same act as writing `!high` in a sentence, and only one of them is unambiguous.
    @Test("Setting a priority makes a note into a task, unlike the grammar")
    func priorityPromotes() {
        var draft = QuickJotDraft()
        draft.setPriority(.high)
        #expect(draft.kind == .task)

        #expect(CaptureParser.parse("Read the brief !high").kind == .note)
    }

    @Test("Naming a project makes a note into a task")
    func projectPromotes() {
        var draft = QuickJotDraft()
        draft.setProject("Q3 Launch")
        #expect(draft.kind == .task)
    }

    @Test("Tags and people do not promote — a note can hold both")
    func tagsAndPeopleDoNotPromote() {
        var draft = QuickJotDraft()
        draft.addTag("admin")
        draft.addPerson("Sarah")
        #expect(draft.kind == .note)
    }

    @Test("Clearing a date does not demote the task back to a note")
    func clearingDoesNotDemote() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .tomorrow))
        draft.setDue(nil)

        // Demoting would throw away the notes field the user has been typing into for the last
        // minute, on the strength of them changing their mind about a date.
        #expect(draft.kind == .task)
        #expect(draft.dueDate == nil)
    }

    @Test("Being promoted is not the same as being chosen")
    func promotionIsNotExplicit() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .tomorrow))
        #expect(draft.kindIsExplicit == false)

        draft.choose(.note)
        #expect(draft.kind == .note)
        #expect(draft.kindIsExplicit)
    }

    // MARK: - Collections

    @Test("A tag is not added twice")
    func tagsDeduplicate() {
        var draft = QuickJotDraft()
        draft.addTag("admin")
        draft.addTag("admin")
        #expect(draft.tagSlugs == ["admin"])
    }

    @Test("An unusable slug is refused rather than stored")
    func invalidSlugRefused() {
        var draft = QuickJotDraft()
        draft.addTag("")
        draft.addTag("admin")
        #expect(draft.tagSlugs == ["admin"])
    }

    @Test("Choosing the bug tag records a bug kind instead of a decorative tag")
    func bugTagIsSemantic() {
        var draft = QuickJotDraft()
        draft.addTag("#Bug")

        #expect(draft.kind == .bug)
        #expect(draft.kindIsExplicit)
        #expect(!draft.tagSlugs.contains("bug"))
    }

    /// Otherwise picking "Sarah" from the menu and then typing `@sarah` links her twice, because
    /// `CaptureService` resolves both spellings to the same person.
    @Test("The same person under a different spelling is not mentioned twice")
    func peopleDeduplicateByFolding() {
        var draft = QuickJotDraft()
        draft.addPerson("Sarah Okonjo")
        draft.addPerson("sarah okonjo")
        #expect(draft.personHints == ["Sarah Okonjo"])
    }

    @Test("Order of addition is kept")
    func orderIsKept() {
        var draft = QuickJotDraft()
        draft.addTag("zebra")
        draft.addTag("apple")
        #expect(draft.tagSlugs == ["zebra", "apple"])
    }

    @Test("Removing a chip removes exactly it")
    func removal() {
        var draft = QuickJotDraft()
        draft.addTag("admin")
        draft.addTag("urgent")
        draft.addPerson("Sarah")
        draft.removeTag("admin")
        draft.removePerson("Sarah")

        #expect(draft.tagSlugs == ["urgent"])
        #expect(draft.personHints.isEmpty)
    }

    // MARK: - Applying what was lifted

    @Test("A lifted token becomes a decision, and promotes by the same rule")
    func applyingALift() {
        var draft = QuickJotDraft()
        draft.apply(CaptureParser.parse("Call the framer #errand due:tomorrow"))

        #expect(draft.tagSlugs == ["errand"])
        #expect(draft.dueDate == .tomorrow)
        #expect(draft.kind == .task)
    }

    /// A lift means the user has just typed the token and moved off it. Changing your mind about a
    /// date should work; a chip that refused to budge would be the interface arguing back.
    @Test("Typing a new date replaces the chip that was there")
    func lastWriterWins() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .today))
        draft.apply(CaptureParser.parse("Call the framer due:tomorrow"))

        #expect(draft.dueDate == .tomorrow)
    }

    @Test("A lifted task prefix sets the kind even with no token behind it")
    func taskPrefixApplies() {
        var draft = QuickJotDraft()
        draft.apply(CaptureParser.parse("- Call the framer"))
        #expect(draft.kind == .task)
    }

    @Test("An explicit choice is not overturned by what was lifted")
    func explicitChoiceSurvivesALift() {
        var draft = QuickJotDraft()
        draft.choose(.note)
        draft.apply(CaptureParser.parse("- Call the framer"))
        #expect(draft.kind == .note)
    }

    // MARK: - Merging with what is still in the field

    @Test("A tag in the field and a tag from the menu both survive")
    func tagsUnion() {
        var draft = QuickJotDraft()
        draft.addTag("urgent")

        let merged = draft.merged(with: CaptureParser.parse("Call the framer #errand"))
        #expect(merged.tagSlugs == ["urgent", "errand"])
    }

    @Test("The same tag from both sides appears once")
    func tagsUnionDeduplicates() {
        var draft = QuickJotDraft()
        draft.addTag("errand")

        let merged = draft.merged(with: CaptureParser.parse("Call the framer #errand"))
        #expect(merged.tagSlugs == ["errand"])
    }

    @Test("People union and fold, the same as they do when added")
    func peopleUnion() {
        var draft = QuickJotDraft()
        draft.addPerson("Sarah")

        let merged = draft.merged(with: CaptureParser.parse("Ask @sarah and @Mike"))
        #expect(merged.personHints == ["Sarah", "Mike"])
    }

    @Test("A chip beats a word for a slot only one of them can have")
    func decisionsBeatText() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .today))
        draft.setProject("Q3 Launch")
        draft.setPriority(.high)

        let merged = draft.merged(with: CaptureParser.parse("Ship it >Other due:friday !low"))
        #expect(merged.dueDate == .today)
        #expect(merged.projectHint == "Q3 Launch")
        #expect(merged.priority == .high)
    }

    @Test("Text fills a slot no chip has claimed")
    func textFillsEmptySlots() {
        let draft = QuickJotDraft()
        let merged = draft.merged(with: CaptureParser.parse("Ship it due:friday !low"))

        #expect(merged.dueDate == .nextWeekday(6))
        #expect(merged.priority == .low)
    }

    @Test("A deadline's day and time are never taken from different sources")
    func dayAndTimeMoveTogether() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .today))

        let merged = draft.merged(with: CaptureParser.parse("Ship it due:friday 3pm"))
        #expect(merged.dueDate == .today)
        #expect(merged.dueTime == nil)
    }

    /// The sequence this whole flag exists for.
    @Test("An explicitly chosen task is not turned into a bookmark by a pasted URL")
    func explicitKindBeatsAPastedURL() {
        var draft = QuickJotDraft()
        draft.choose(.task)

        let merged = draft.merged(with: CaptureParser.parse("read later https://example.com/x"))
        #expect(merged.kind == .task)
        #expect(merged.url != nil)
    }

    @Test("A draft with no opinion lets the words decide")
    func textDecidesWhenTheDraftIsSilent() {
        let draft = QuickJotDraft()
        let merged = draft.merged(with: CaptureParser.parse("https://example.com/x"))
        #expect(merged.kind == .bookmark)
    }

    @Test("A deadline already recorded beats a URL that cannot hold one")
    func promotedKindBeatsAPastedURL() {
        var draft = QuickJotDraft()
        draft.setDue(DateInterpretation(day: .tomorrow))

        let merged = draft.merged(with: CaptureParser.parse("read later https://example.com/x"))
        #expect(merged.kind == .task)
    }

    /// A `due:"friday` with no closing quote never settles, so it reaches the merge as text. It still
    /// has to end up on something that can hold a deadline.
    @Test("A date that never became a chip still promotes at the merge")
    func residualDatePromotes() {
        let draft = QuickJotDraft()
        let merged = draft.merged(with: CaptureParser.parse("Ship it >Q3"))

        #expect(merged.projectHint == "Q3")
        #expect(merged.kind == .task)
    }

    @Test("Merging keeps the title and body the residual parse worked out")
    func titleAndBodySurvive() {
        var draft = QuickJotDraft()
        draft.addTag("admin")

        let merged = draft.merged(with: CaptureParser.parse("Renew the insurance\nCheck the excess"))
        #expect(merged.title == "Renew the insurance")
        #expect(merged.body == "Check the excess")
    }

    @Test("Chips alone are not something worth saving")
    func chipsWithoutWordsAreEmpty() {
        var draft = QuickJotDraft()
        draft.addTag("admin")
        draft.setDue(DateInterpretation(day: .tomorrow))

        #expect(draft.merged(with: CaptureParser.parse("")).isEmpty)
    }
}

@Suite("Quick Jot composition preview")
struct QuickJotCompositionPreviewTests {
    private let vocabulary = CaptureVocabulary(
        projects: ["Elephruit App"],
        people: ["Mike Zehrer"]
    )

    @Test("Visible Notes grammar is reflected in the live preview without changing the text")
    func previewReadsNotes() {
        let composition = QuickJotComposition(
            titleText: "Testing",
            notesText: "test >Elephruit App @Mike Zehrer\n#bug due:today"
        )

        let preview = composition.previewDraft(knowing: vocabulary)

        #expect(preview.projectHint == "Elephruit App")
        #expect(preview.personHints == ["Mike Zehrer"])
        #expect(preview.kind == .bug)
        #expect(preview.dueDate == .today)
        #expect(composition.notesText.contains(">Elephruit App"))
    }

    @Test("Settling strips Notes grammar while preserving its prose")
    func flushCleansNotes() {
        var composition = QuickJotComposition(
            titleText: "Testing",
            notesText: "test >Elephruit App @Mike Zehrer\n#bug due:today"
        )

        let didFlush = composition.flush(knowing: vocabulary)
        #expect(didFlush)
        #expect(composition.notesText.trimmingCharacters(in: .whitespacesAndNewlines) == "test")
        #expect(!composition.notesText.contains(">"))
        #expect(!composition.notesText.contains("#bug"))
        #expect(composition.draft.projectHint == "Elephruit App")
        #expect(composition.draft.personHints == ["Mike Zehrer"])
        #expect(composition.draft.kind == .bug)
        #expect(composition.draft.dueDate == .today)
    }
}
