import ElephruitCore
import Foundation
import Testing

/// The grammar the expansion asks for: `due:` and `follow:` as different things, priority, and
/// dates a person would actually type.
///
/// The distinction that matters most here is `due:` versus `follow:`. A deadline can become overdue
/// and should nag; a date to come back to something should bring it into view that morning and then
/// stop. Conflating them is how a to-do list becomes a wall of red.
@Suite("Capture grammar")
struct CaptureGrammarTests {
    // MARK: - The plan's fixtures, verbatim

    @Test("Call @Priya about the proposal #client follow:Tuesday")
    func followFixture() {
        let draft = CaptureParser.parse("Call @Priya about the proposal #client follow:Tuesday")

        #expect(draft.personHints == ["Priya"])
        #expect(draft.tagSlugs == ["client"])
        #expect(draft.followDate == .nextWeekday(3))
        #expect(draft.dueDate == nil, "a date to come back to is not a deadline")
        #expect(draft.title == "Call about the proposal")
    }

    @Test("Submit expense report >Operations due:Friday !high")
    func dueAndPriorityFixture() {
        let draft = CaptureParser.parse("Submit expense report >Operations due:Friday !high")

        #expect(draft.projectHint == "Operations")
        #expect(draft.dueDate == .nextWeekday(6))
        #expect(draft.priority == .high)
        #expect(draft.kind == .reminder)
        #expect(draft.title == "Submit expense report")
    }

    @Test("Idea for onboarding improvements #product")
    func plainNoteFixture() {
        let draft = CaptureParser.parse("Idea for onboarding improvements #product")

        #expect(draft.kind == .note, "nothing here implies an action")
        #expect(draft.tagSlugs == ["product"])
        #expect(draft.dueDate == nil)
        #expect(draft.title == "Idea for onboarding improvements")
    }

    @Test("Review launch plan >Q3-Launch due:tomorrow 3pm")
    func dueWithTimeFixture() {
        let draft = CaptureParser.parse("Review launch plan >Q3-Launch due:tomorrow 3pm")

        #expect(draft.projectHint == "Q3-Launch")
        #expect(draft.dueDate == .tomorrow)
        #expect(draft.dueTime == TimeOfDay(hour: 15, minute: 0))
        #expect(draft.title == "Review launch plan", "the time was consumed, not left in the title")
    }

    // MARK: - due: versus follow:

    @Test("Both dates can be given, and they are different fields")
    func dueAndFollowTogether() {
        let draft = CaptureParser.parse("Chase the invoice due:friday follow:tomorrow")

        #expect(draft.dueDate == .nextWeekday(6))
        #expect(draft.followDate == .tomorrow)
    }

    @Test("The legacy ! date still means a deadline")
    func legacyBangIsStillADueDate() {
        let draft = CaptureParser.parse("Ship it !tomorrow")

        #expect(draft.dueDate == .tomorrow)
        #expect(draft.followDate == nil)
        #expect(draft.priority == nil)
    }

    @Test("Either date makes a note into a task")
    func datesImplyAction() {
        #expect(CaptureParser.parse("Something due:friday").kind == .reminder)
        #expect(CaptureParser.parse("Something follow:friday").kind == .reminder)
    }

    // MARK: - Priority

    @Test("Priorities are recognised, and absence is not normal")
    func priorities() {
        #expect(CaptureParser.parse("A !high").priority == .high)
        #expect(CaptureParser.parse("A !low").priority == .low)
        #expect(CaptureParser.parse("A !medium").priority == .normal)
        #expect(CaptureParser.parse("A").priority == nil, "saying nothing is not saying normal")
    }

    @Test("A priority does not make a note into a task")
    func priorityDoesNotImplyAction() {
        #expect(CaptureParser.parse("An idea !high").kind == .note)
    }

    // MARK: - Nothing is eaten

    @Test("An unusable date keeps its text exactly as typed")
    func unparseableDatesArePreserved() {
        let draft = CaptureParser.parse("Meeting due:someday about #things")

        #expect(draft.dueDate == nil)
        #expect(draft.title.contains("due:someday"))
        #expect(draft.unresolvedTokens.contains { $0.text == "someday" })
    }

    @Test("A word after a date that is not part of it stays in the title")
    func extensionIsNotGreedyPastWhatParses() {
        let draft = CaptureParser.parse("Prep due:friday meeting notes")

        #expect(draft.dueDate == .nextWeekday(6))
        #expect(draft.title == "Prep meeting notes")
    }

    @Test("An unrecognised follow date is preserved too")
    func unparseableFollowIsPreserved() {
        let draft = CaptureParser.parse("Ping her follow:whenever")

        #expect(draft.followDate == nil)
        #expect(draft.title.contains("follow:whenever"))
    }

    // MARK: - Source ranges

    @Test("The original text is kept verbatim, whatever the title becomes")
    func originalTextIsExact() {
        let input = "Call  @Priya   about  it #client"
        let draft = CaptureParser.parse(input)

        #expect(draft.originalText == input)
        #expect(draft.title != input, "the title collapses whitespace; the original must not")
    }

    @Test("Every recognised token points at what it came from")
    func tokenRangesAreAccurate() {
        let input = "Call @Priya #client due:friday"
        let draft = CaptureParser.parse(input)
        let characters = Array(input)

        for token in draft.tokens {
            let slice = String(characters[token.range])
            switch token.kind {
            case .person: #expect(slice == "@Priya")
            case .tag: #expect(slice == "#client")
            case .dueDate: #expect(slice == "due:friday")
            default: break
            }
        }
        #expect(draft.tokens.count == 3)
    }

    @Test("A range covers a phrase the parser extended over")
    func rangesCoverExtendedPhrases() throws {
        let input = "Review due:tomorrow 3pm"
        let draft = CaptureParser.parse(input)
        let characters = Array(input)

        let due = try #require(draft.tokens.first { $0.kind == .dueDate })
        #expect(String(characters[due.range]) == "due:tomorrow 3pm")
    }

    @Test("Ranges hold after a task prefix has been stripped")
    func rangesSurviveATaskPrefix() throws {
        let input = "- Call @Priya"
        let draft = CaptureParser.parse(input)
        let characters = Array(input)

        let person = try #require(draft.tokens.first { $0.kind == .person })
        #expect(String(characters[person.range]) == "@Priya")
    }

    @Test("A quoted value works after a keyword as well as a sigil")
    func quotedKeywordValues() {
        let draft = CaptureParser.parse("Plan due:\"next Tuesday\"")
        #expect(draft.dueDate == .nextWeekday(3))
    }
}
