@testable import ElephruitFeatures
import Foundation
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

        #expect(draft.checklist.items.map(\.title) == ["Pack charger"])
        #expect(draft.pendingStep.isEmpty)
    }
}
