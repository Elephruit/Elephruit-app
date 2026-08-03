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
        #expect(ReminderComposerField.tags.advanced() == .checklist)
        #expect(ReminderComposerField.checklist.advanced() == .deadline)
        #expect(ReminderComposerField.deadline.advanced() == .title)
    }

    @Test("Shift-Tab follows the same path backwards")
    func reverseTraversal() {
        #expect(ReminderComposerField.title.advanced(reverse: true) == .deadline)
        #expect(ReminderComposerField.checklist.advanced(reverse: true) == .tags)
        #expect(ReminderComposerField.notes.advanced(reverse: true) == .title)
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
            onEscape: {}
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
