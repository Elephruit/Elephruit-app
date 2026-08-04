import ElephruitCore
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// Caret completion, on its own.
///
/// The rule for "is the caret part-way through a tag" is the whole of the autocomplete feature, and
/// it is pure — so it is tested here rather than through a window.
@Suite("Capture completion")
struct CaptureCompletionTests {
    @Test("Each sigil starts its own kind of completion")
    func triggers() throws {
        let cases: [(String, CaptureCompletion.Trigger, String)] = [
            ("Call #wo", .tag, "wo"),
            ("Call @Pri", .person, "Pri"),
            ("Call >Q3", .project, "Q3"),
            ("Ship !hi", .bang, "hi"),
            ("Call due:fri", .dueDate, "fri"),
            ("Call follow:tue", .followDate, "tue"),
        ]

        for (text, trigger, query) in cases {
            let completion = try #require(
                CaptureCompletion.active(in: text, caretAt: text.count),
                "no completion for “\(text)”"
            )
            #expect(completion.trigger == trigger)
            #expect(completion.query == query)
        }
    }

    @Test("Grammar entered in Notes is captured without rewriting the note body")
    func notesGrammarIsCaptured() {
        let composition = QuickJotComposition(
            titleText: "The launch screen crashes",
            notesText: "Seen on beta #bug >Elephruit @Mike !high"
        )
        let vocabulary = CaptureVocabulary(
            projects: ["Elephruit"],
            people: ["Mike"]
        )

        let captured = composition.captured(knowing: vocabulary)

        #expect(captured.kind == .bug)
        #expect(captured.projectHint == "Elephruit")
        #expect(captured.personHints == ["Mike"])
        #expect(captured.priority == .high)
        #expect(captured.body == "Seen on beta #bug >Elephruit @Mike !high")
    }

    /// `due:` starts with a letter, so a sigil-first test would never see it and would offer tag
    /// suggestions for the word "due".
    @Test("A keyword is recognised ahead of a plain word")
    func keywordsBeatWords() throws {
        let completion = try #require(CaptureCompletion.active(in: "due:", caretAt: 4))
        #expect(completion.trigger == .dueDate)
        #expect(completion.query.isEmpty)
    }

    @Test("A sigil with nothing after it still completes")
    func emptyQueryStillCompletes() throws {
        let completion = try #require(CaptureCompletion.active(in: "Call @", caretAt: 6))
        #expect(completion.trigger == .person)
        #expect(completion.query.isEmpty)
    }

    /// A finished word must stop offering suggestions, or the list hangs over text the user has
    /// moved on from.
    @Test("A completed word stops completing")
    func whitespaceEndsIt() {
        #expect(CaptureCompletion.active(in: "Call #work ", caretAt: 11) == nil)
        #expect(CaptureCompletion.active(in: "Call #work and", caretAt: 14) == nil)
    }

    @Test("Plain text is not a completion")
    func plainTextDoesNotComplete() {
        #expect(CaptureCompletion.active(in: "Call Priya", caretAt: 10) == nil)
        #expect(CaptureCompletion.active(in: "", caretAt: 0) == nil)
        #expect(CaptureCompletion.active(in: "  ", caretAt: 2) == nil)
    }

    @Test("Completion follows the caret rather than the end of the line")
    func caretRatherThanEnd() throws {
        let text = "Call @Pri about it"
        let completion = try #require(CaptureCompletion.active(in: text, caretAt: 9))
        #expect(completion.trigger == .person)
        #expect(completion.query == "Pri")
    }

    // MARK: - Names with spaces

    /// Most projects and most people have a space in their name, so a suggestion list that gave up
    /// at the space gave up exactly where it was needed.
    @Test("A name being typed across a space still completes")
    func namesCompleteAcrossSpaces() throws {
        let cases: [(String, CaptureCompletion.Trigger, String)] = [
            ("Plan >Q3 Lau", .project, "Q3 Lau"),
            ("Ask @Mike Zeh", .person, "Mike Zeh"),
            ("Ask @Anna Maria del", .person, "Anna Maria del"),
        ]

        for (text, trigger, query) in cases {
            let completion = try #require(
                CaptureCompletion.active(in: text, caretAt: text.count),
                "no completion for “\(text)”"
            )
            #expect(completion.trigger == trigger)
            #expect(completion.query == query)
        }
    }

    /// A tag is one slug and a date keyword brings its own words with it, so neither has any use for
    /// a query that spans a space — and both would offer suggestions over ordinary prose if they did.
    @Test("Only the sigils that name things read across a space")
    func onlyNamesCompleteAcrossSpaces() {
        #expect(CaptureCompletion.active(in: "Call #work and", caretAt: 14) == nil)
        #expect(CaptureCompletion.active(in: "Meet due:friday morning", caretAt: 23) == nil)
    }

    /// Bounded, so an ordinary sentence after a name stops offering suggestions rather than trailing
    /// them to the end of the line.
    @Test("The search for a sigil gives up after a few words")
    func completionGivesUpEventually() {
        #expect(CaptureCompletion.active(in: "Ask @Mike about the beta", caretAt: 24) == nil)
    }

    /// The grammar stops at the end of the first line, so the completion has to as well.
    @Test("A sigil on the line above is not what this line is naming")
    func completionDoesNotCrossLines() {
        #expect(CaptureCompletion.active(in: ">Q3\nLaunch", caretAt: 10) == nil)
    }

    // MARK: - Accepting

    @Test("Accepting replaces the partial word and leaves the caret after a space")
    func accepting() {
        let text = "Call @Pri"
        let completion = CaptureCompletion.active(in: text, caretAt: text.count)
        let applied = completion?.applying("Priya", to: text, caretAt: text.count)

        #expect(applied?.text == "Call @Priya ")
        #expect(applied?.caret == 12)
    }

    @Test("Accepting mid-line keeps what came after it")
    func acceptingMidLine() {
        let text = "Call @Pri about it"
        let completion = CaptureCompletion.active(in: text, caretAt: 9)
        let applied = completion?.applying("Priya", to: text, caretAt: 9)

        #expect(applied?.text == "Call @Priya  about it")
    }

    @Test("A multi-word value is accepted whole")
    func multiWordValues() {
        let text = "Plan >Q3"
        let completion = CaptureCompletion.active(in: text, caretAt: text.count)
        let applied = completion?.applying("Q3 Launch", to: text, caretAt: text.count)

        #expect(applied?.text == "Plan >Q3 Launch ")
    }

    /// The parser has to still understand what completion produced. A suggestion that rounds-trips
    /// into something the grammar does not recognise would be worse than no suggestion.
    @Test("What completion produces still parses")
    func acceptedTextParses() {
        let text = "Call @Pri"
        let completion = CaptureCompletion.active(in: text, caretAt: text.count)
        let applied = completion?.applying("Priya", to: text, caretAt: text.count)

        let draft = CaptureParser.parse(applied?.text ?? "")
        #expect(draft.personHints == ["Priya"])
    }

    /// The same promise for a name with a space in it, which is where it used to be broken: the
    /// suggestion inserted `@Mike Zehrer` and the parser then read `@Mike`. It holds because both
    /// sides are given the same names — the suggestion could not have been offered otherwise.
    @Test("What completion produces still parses when the name has a space")
    func acceptedMultiWordTextParses() {
        let text = "Ask @Mike"
        let completion = CaptureCompletion.active(in: text, caretAt: text.count)
        let applied = completion?.applying("Mike Zehrer", to: text, caretAt: text.count)
        #expect(applied?.text == "Ask @Mike Zehrer ")

        let draft = CaptureParser.parse(
            applied?.text ?? "",
            knowing: CaptureVocabulary(people: ["Mike Zehrer"])
        )
        #expect(draft.personHints == ["Mike Zehrer"])
        #expect(draft.title == "Ask")
    }
}

/// The panel's controller, without a window.
@MainActor
@Suite("Quick Jot controller")
struct QuickJotControllerTests {
    private func makeController() -> (QuickJotController, AppServices) {
        let services = AppServices.inMemory(populated: false)
        return (QuickJotController(services: services), services)
    }

    @Test("Saving captures what was composed and clears everything")
    func savingCaptures() throws {
        let (controller, services) = makeController()
        controller.composition.titleText = "Renew the studio insurance #admin"
        controller.composition.notesText = "The excess went up again"

        #expect(controller.save())
        #expect(controller.composition.titleText.isEmpty)
        #expect(controller.composition.notesText.isEmpty)
        #expect(controller.composition.draft.isEmpty)

        let item = try #require(
            try services.items.items(matching: .everything())
                .first { $0.title == "Renew the studio insurance" }
        )
        #expect(item.body == "The excess went up again")
        #expect((item.tags ?? []).contains { $0.slug == "admin" })
    }

    @Test("Saving strips visible Notes grammar after applying it")
    func savingCleansNotesGrammar() throws {
        let (controller, services) = makeController()
        controller.composition.titleText = "Testing"
        controller.composition.notesText = "test #bug due:today"

        #expect(controller.save())

        let item = try #require(
            try services.items.items(matching: .everything())
                .first { $0.title == "Testing" }
        )
        #expect(item.kind == .bug)
        #expect(item.body == "test")
        #expect(!item.body.contains("#bug"))
        #expect(!item.body.contains("due:today"))
    }

    @Test("An empty composition saves nothing")
    func emptySavesNothing() throws {
        let (controller, services) = makeController()
        controller.composition.titleText = "   "
        controller.composition.notesText = "  "

        #expect(controller.save() == false)
        #expect(try services.items.items(matching: .everything()).isEmpty)
    }

    /// Chips are not a reason to write a row. An untitled deadline in the Inbox is a puzzle, not a
    /// capture.
    @Test("Chips with nothing written save nothing")
    func chipsAloneSaveNothing() throws {
        let (controller, services) = makeController()
        controller.composition.draft.setDue(DateInterpretation(day: .tomorrow))
        controller.composition.draft.addTag("admin")

        #expect(controller.save() == false)
        #expect(try services.items.items(matching: .everything()).isEmpty)
    }

    /// Closing is not discarding. Someone who dismissed by accident should find their sentence still
    /// there — which is the whole reason this lives on the controller rather than in the view that
    /// gets destroyed with the panel. There is more at stake now than a sentence: the chips took
    /// trips through menus to assemble.
    @Test("Hiding keeps the text and the chips")
    func hidingKeepsEverything() {
        let (controller, _) = makeController()
        controller.composition.titleText = "half a thought"
        controller.composition.draft.addTag("admin")

        controller.hide()
        #expect(controller.composition.titleText == "half a thought")
        #expect(controller.composition.draft.tagSlugs == ["admin"])
    }

    @Test("A successful save is the only thing that clears the panel")
    func onlySavingClears() {
        let (controller, _) = makeController()
        controller.composition.titleText = "something"
        controller.hide()
        controller.hide()
        #expect(controller.composition.titleText == "something")

        _ = controller.save()
        #expect(controller.composition.titleText.isEmpty)
    }

    /// The end-to-end promise: a line typed straight into the title still means everything it meant
    /// before any of this existed, even though not one of its tokens was terminated by a space.
    @Test("The grammar applies through the panel as it does everywhere else")
    func grammarApplies() throws {
        let (controller, services) = makeController()
        controller.composition.titleText = "- Call the framer #errand due:tomorrow !high"

        #expect(controller.save())

        let item = try #require(try services.items.items(matching: .everything()).first)
        #expect(item.title == "Call the framer")
        #expect(item.kind == .reminder)
        #expect(item.dueAt != nil)
        #expect(item.priority == .high)
        #expect((item.tags ?? []).contains { $0.slug == "errand" })
    }

    /// Saving flushes first, so a token the user finished but never terminated becomes a chip on the
    /// way past rather than being left as words in the title.
    @Test("An unterminated token is still understood at the moment of saving")
    func savingFlushesFirst() throws {
        let (controller, services) = makeController()
        controller.composition.titleText = "Prep the deck due:friday"

        #expect(controller.save())

        let item = try #require(try services.items.items(matching: .everything()).first)
        #expect(item.title == "Prep the deck")
        #expect(item.dueAt != nil)
    }

    /// Chips placed by hand and tokens typed into the sentence are not competing accounts of one
    /// thing — they have to arrive together, resolved against the real library.
    @Test("What was clicked and what was typed both reach the saved item")
    func clickedAndTypedBothLand() throws {
        let (controller, services) = makeController()
        let project = try services.items.create(ItemDraft(kind: .project, title: "Q3 Launch"))

        controller.composition.draft.addTag("urgent")
        controller.composition.draft.setProject(project.title)
        controller.composition.titleText = "Call the framer #errand @Sarah"

        #expect(controller.save())

        let item = try #require(
            try services.items.items(matching: .everything()).first { $0.title == "Call the framer" }
        )
        #expect(item.parent?.id == project.id)
        #expect((item.tags ?? []).map(\.slug).sorted() == ["errand", "urgent"])
        #expect(try services.items.items(matching: .everything()).contains { $0.title == "Sarah" })
    }
}

/// The hot-key result type, which is what Settings reports.
@Suite("Hot key registration")
struct HotKeyRegistrationTests {
    @Test("Only a real registration counts as active")
    func activeStates() {
        #expect(HotKeyRegistration.registered(KeyBinding("j", [.command, .shift])).isActive)
        #expect(HotKeyRegistration.unbound.isActive == false)
        #expect(HotKeyRegistration.alreadyClaimed(KeyBinding("j")).isActive == false)
        #expect(HotKeyRegistration.unsupportedKey(KeyBinding("j")).isActive == false)
    }

    /// The point of the whole design: a refusal is stated, not swallowed.
    @Test("A refusal explains itself and names the keys")
    func refusalsExplainThemselves() throws {
        let binding = KeyBinding("j", [.command, .shift])

        let claimed = try #require(HotKeyRegistration.alreadyClaimed(binding).explanation)
        #expect(claimed.contains("⇧⌘J"))
        #expect(claimed.contains("another app"))

        let unsupported = try #require(HotKeyRegistration.unsupportedKey(binding).explanation)
        #expect(unsupported.contains("⇧⌘J"))
    }

    /// Nothing to report is not the same as nothing to say — a working shortcut needs no sentence.
    @Test("Success and deliberate unbinding say nothing")
    func successIsQuiet() {
        #expect(HotKeyRegistration.registered(KeyBinding("j")).explanation == nil)
        #expect(HotKeyRegistration.unbound.explanation == nil)
    }
}
