import AppKit
@testable import ElephruitFeatures
import Foundation
import SwiftUI
import Testing

@Suite("Reminder composer state")
struct ReminderComposerStateTests {
    @Test("Tab follows the promised path and wraps")
    func forwardTraversal() {
        #expect(ReminderComposerField.title.advanced() == .notes)
        #expect(ReminderComposerField.notes.advanced() == .when)
        #expect(ReminderComposerField.when.advanced() == .tags)
        #expect(ReminderComposerField.tags.advanced() == .people)
        #expect(ReminderComposerField.people.advanced() == .checklist)
        #expect(ReminderComposerField.checklist.advanced() == .deadline)
        #expect(ReminderComposerField.deadline.advanced() == .project)
        #expect(ReminderComposerField.project.advanced() == .title)
    }

    @Test("Shift-Tab follows the same path backwards")
    func reverseTraversal() {
        #expect(ReminderComposerField.title.advanced(reverse: true) == .project)
        #expect(ReminderComposerField.checklist.advanced(reverse: true) == .people)
        #expect(ReminderComposerField.notes.advanced(reverse: true) == .title)
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
}
