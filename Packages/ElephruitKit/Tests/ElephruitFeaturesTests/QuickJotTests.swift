import ElephruitCore
import ElephruitFeatures
import ElephruitModel
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
}

/// The panel's controller, without a window.
@MainActor
@Suite("Quick Jot controller")
struct QuickJotControllerTests {
    private func makeController() -> (QuickJotController, AppServices) {
        let services = AppServices.inMemory(populated: false)
        return (QuickJotController(services: services), services)
    }

    @Test("Saving captures what was typed and clears the field")
    func savingCaptures() throws {
        let (controller, services) = makeController()
        controller.text = "Renew the studio insurance #admin"

        #expect(controller.save())
        #expect(controller.text.isEmpty)

        let items = try services.items.items(matching: .everything())
        #expect(items.contains { $0.title == "Renew the studio insurance" })
    }

    @Test("An empty field saves nothing")
    func emptySavesNothing() throws {
        let (controller, services) = makeController()
        controller.text = "   \n  "

        #expect(controller.save() == false)
        #expect(try services.items.items(matching: .everything()).isEmpty)
    }

    /// Closing is not discarding. Someone who dismissed by accident should find their sentence
    /// still there — which is the whole reason the text lives on the controller rather than in the
    /// view that gets destroyed with the panel.
    @Test("Hiding keeps the text")
    func hidingKeepsTheText() {
        let (controller, _) = makeController()
        controller.text = "half a thought"

        controller.hide()
        #expect(controller.text == "half a thought")
    }

    @Test("A successful save is the only thing that clears the field")
    func onlySavingClears() {
        let (controller, _) = makeController()
        controller.text = "something"
        controller.hide()
        controller.hide()
        #expect(controller.text == "something")

        _ = controller.save()
        #expect(controller.text.isEmpty)
    }

    @Test("The grammar applies through the panel as it does everywhere else")
    func grammarApplies() throws {
        let (controller, services) = makeController()
        controller.text = "- Call the framer #errand due:tomorrow !high"

        #expect(controller.save())

        let item = try #require(try services.items.items(matching: .everything()).first)
        #expect(item.kind == .task)
        #expect(item.dueAt != nil)
        #expect(item.priority == .high)
        #expect(item.tags.contains { $0.slug == "errand" })
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
