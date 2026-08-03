import AppKit
import ElephruitCore
@testable import ElephruitFeatures
import Foundation
import SwiftUI
import Testing

@Suite("Reminder composer state")
struct ReminderComposerStateTests {
    @Test("Tab follows the promised path and wraps")
    func forwardTraversal() {
        #expect(ReminderComposerField.title.advanced() == .notes)
        #expect(ReminderComposerField.notes.advanced() == .project)
        #expect(ReminderComposerField.project.advanced() == .when)
        #expect(ReminderComposerField.when.advanced() == .tags)
        #expect(ReminderComposerField.tags.advanced() == .people)
        #expect(ReminderComposerField.people.advanced() == .checklist)
        #expect(ReminderComposerField.checklist.advanced() == .deadline)
        #expect(ReminderComposerField.deadline.advanced() == .title)
    }

    @Test("Shift-Tab follows the same path backwards")
    func reverseTraversal() {
        #expect(ReminderComposerField.title.advanced(reverse: true) == .deadline)
        #expect(ReminderComposerField.checklist.advanced(reverse: true) == .people)
        #expect(ReminderComposerField.notes.advanced(reverse: true) == .title)
        #expect(ReminderComposerField.project.advanced(reverse: true) == .notes)
    }

    @Test("A stale popover dismissal cannot cancel a newer visit to the same field")
    func stalePopoverRequest() {
        var gate = ReminderPopoverPresentationGate()
        let firstVisit = gate.nextRequest()
        gate.cancel()
        let secondVisit = gate.nextRequest()

        #expect(!gate.accepts(firstVisit, for: .when, activeField: .when))
        #expect(gate.accepts(secondVisit, for: .when, activeField: .when))
        #expect(!gate.accepts(secondVisit, for: .when, activeField: .tags))
    }

    @Test("A saved reminder can repopulate the entire composer")
    func editingDraft() {
        var original = ReminderComposerDraft()
        original.title = "Call Taylor"
        original.personNames = ["Taylor Reed"]
        original.projectTitle = "House move"
        original.tagSlugs = ["calls"]
        let reminder = LightweightReminder(draft: original, now: .distantPast)

        let reopened = ReminderComposerDraft(reminder: reminder)

        #expect(reopened.title == "Call Taylor")
        #expect(reopened.personNames == ["Taylor Reed"])
        #expect(reopened.projectTitle == "House move")
        #expect(reopened.tagSlugs == ["calls"])
    }

    @Test("Reminder shortcuts use Quick Jot names and leave the prose clean")
    func reminderShortcuts() {
        let extracted = ReminderShortcutParser.extract(
            from: "Call Sam #calls >House move @Sam Rivera\nBring forms #paperwork",
            knowing: CaptureVocabulary(
                projects: ["House move"],
                people: ["Sam Rivera"]
            )
        )

        #expect(extracted.text == "Call Sam\nBring forms")
        #expect(extracted.tagSlugs == ["calls", "paperwork"])
        #expect(extracted.personNames == ["Sam Rivera"])
        #expect(extracted.projectTitle == "House move")
    }

    @Test("A Quick Jot kind word remains a reminder tag")
    func reminderKindShortcutStaysTag() {
        let extracted = ReminderShortcutParser.extract(
            from: "Investigate #bug",
            knowing: .empty
        )

        #expect(extracted.text == "Investigate")
        #expect(extracted.tagSlugs == ["bug"])
    }

    @Test("A pending checklist line is trimmed, appended, and cleared")
    func commitStep() {
        var draft = ReminderComposerDraft()
        draft.pendingStep = "  Pack charger  "

        draft.commitPendingStep()

        #expect(draft.checklist.map(\.title) == ["Pack charger"])
        #expect(draft.pendingStep.isEmpty)
    }

    @Test("The AppKit editor consumes Tab and reports its direction")
    @MainActor
    func editorTabTraversal() throws {
        var text = "unchanged"
        var traversals: [Bool] = []
        let editor = ReminderPlainTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "Reminder",
            role: .title,
            onTab: { traversals.append($0) },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .title,
            focusRouter: ReminderComposerFocusRouter()
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()
        textView.string = text
        textView.coordinator = coordinator

        textView.keyDown(with: try #require(keyEvent(keyCode: 48)))
        textView.keyDown(with: try #require(keyEvent(keyCode: 48, modifiers: .shift)))

        #expect(traversals == [false, true])
        #expect(textView.string == "unchanged")
    }

    @Test("The focus router flushes the active editor before advancing")
    @MainActor
    func routerFlushesBeforeTraversal() {
        var text = ""
        let router = ReminderComposerFocusRouter()
        let editor = ReminderPlainTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "Reminder",
            role: .title,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .title,
            focusRouter: router
        )
        let textView = ReminderEditorTextView()
        let coordinator = editor.makeCoordinator()
        textView.coordinator = coordinator
        textView.string = "Typed title"
        router.register(textView, for: .title)
        router.onTab = { reverse in
            router.activate(router.activeField.advanced(reverse: reverse))
        }

        router.handleTab(reverse: false)

        #expect(text == "Typed title")
        #expect(router.activeField == .notes)
    }

    @Test("Arrow keys move suggestion selection and Return accepts it")
    @MainActor
    func editorSuggestionKeyboard() {
        var moves: [Int] = []
        var acceptances = 0
        let editor = ReminderPlainTextEditor(
            text: .constant("d"),
            placeholder: "Which project?",
            role: .body,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .project,
            focusRouter: ReminderComposerFocusRouter(),
            onMove: { moves.append($0); return true },
            onAcceptSuggestion: { acceptances += 1; return true }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()
        textView.coordinator = coordinator

        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(moves == [1, -1])
        #expect(acceptances == 1)
    }

    @Test("Partial weekday searches return the next matching days")
    func weekdayDateSearch() throws {
        let clock = try augustThirdClock()

        let suggestions = ReminderDateSearch.suggestions(for: "we", using: clock)

        #expect(suggestions.count == 3)
        #expect(suggestions.allSatisfy { clock.calendar.component(.weekday, from: $0.date) == 4 })
        #expect(suggestions.map { clock.calendar.component(.day, from: $0.date) } == [5, 12, 19])
    }

    @Test("A bare number offers both day-of-month and offset meanings")
    func numericDateSearch() throws {
        let clock = try augustThirdClock()

        let suggestions = ReminderDateSearch.suggestions(for: "8", using: clock)

        #expect(suggestions.map(\.kind) == [.dayOfMonth, .offset])
        #expect(suggestions.map { clock.calendar.component(.day, from: $0.date) } == [8, 11])
        #expect(suggestions[1].title == "in 8 days")
    }

    @Test("Date arrows traverse quick choices, then the calendar by day or week")
    func dateArrowNavigation() throws {
        let clock = try augustThirdClock()
        var navigation = ReminderDateNavigationState()

        navigation.moveVertical(1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.target == .quick(0))
        navigation.moveVertical(1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.target == .quick(1))
        navigation.moveVertical(1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.day.map { clock.calendar.component(.day, from: $0) } == 3)

        navigation.moveHorizontal(1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.day.map { clock.calendar.component(.day, from: $0) } == 4)
        navigation.moveVertical(1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.day.map { clock.calendar.component(.day, from: $0) } == 11)
        navigation.moveVertical(-1, selected: nil, today: clock.now, calendar: clock.calendar)
        #expect(navigation.day.map { clock.calendar.component(.day, from: $0) } == 4)
    }

    @Test("Left and right commands can be claimed by a date editor")
    @MainActor
    func editorHorizontalSuggestionKeyboard() {
        var moves: [Int] = []
        let editor = ReminderPlainTextEditor(
            text: .constant(""),
            placeholder: "When",
            role: .body,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .when,
            focusRouter: ReminderComposerFocusRouter(),
            onHorizontalMove: { moves.append($0); return true }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()

        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(coordinator.textView(textView, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(moves == [-1, 1])
    }

    @Test("Compact metadata text is vertically inset")
    @MainActor
    func metadataTextAlignment() {
        #expect(ReminderPlainTextEditor.verticalInset(for: .body) == 3)
        #expect(
            ReminderPlainTextEditor.verticalInset(for: .body)
                > ReminderPlainTextEditor.verticalInset(for: .notes)
        )
    }

    @Test("Checklist stays latent until typing is consumed")
    @MainActor
    func latentChecklistTyping() {
        let router = ReminderComposerFocusRouter()
        var draft = ReminderComposerDraft()
        router.activate(.checklist)
        router.onTextInput = { characters in
            guard !draft.hasChecklistContent else { return false }
            draft.pendingStep.append(contentsOf: characters)
            return true
        }

        #expect(!draft.hasChecklistContent)
        #expect(router.handleTextInput("P"))
        #expect(draft.pendingStep == "P")
        #expect(draft.hasChecklistContent)

        draft.pendingStep = ""
        #expect(!draft.hasChecklistContent)
    }

    @Test("Deleting backwards from an empty checklist removes its final item")
    @MainActor
    func emptyChecklistDelete() {
        var removed = false
        let router = ReminderComposerFocusRouter()
        let editor = ReminderPlainTextEditor(
            text: .constant(""),
            placeholder: "Add a checklist item",
            role: .body,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .checklist,
            focusRouter: router,
            onDeleteBackwardWhenEmpty: { removed = true; return true }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()
        textView.coordinator = coordinator

        textView.deleteBackward(nil)

        #expect(removed)
    }

    @MainActor
    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func augustThirdClock() throws -> FixedDateProvider {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))
        )
        return FixedDateProvider(now: date, calendar: calendar)
    }
}
