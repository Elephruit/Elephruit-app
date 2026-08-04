import ElephruitCore
@testable import ElephruitFeatures
import ElephruitModel
import Foundation
import Testing

/// What survives of the inline composer: the draft that round-trips a reminder, and the shortcut
/// parser the store still reads.
///
/// The composer card itself — eight tab stops, five application-defined popovers, a focus router
/// and an event monitor, ~1,650 lines of plumbing to make Tab work — is gone, replaced by a
/// one-line capture-grammar field and a persistent detail pane. The AppKit machinery's tests went
/// with the machinery.
@Suite("Reminder composer state")
struct ReminderComposerStateTests {
    @Test("A saved reminder can repopulate the entire draft")
    func editingDraft() {
        var original = ReminderComposerDraft()
        original.title = "Call Taylor"
        original.personNames = ["Taylor Reed"]
        original.projectTitle = "House move"
        original.tagSlugs = ["calls"]
        let reminder = Item(kind: .reminder, title: original.title)
        reminder.tags = []
        reminder.body = original.notes

        let reopened = ReminderComposerDraft(reminder: reminder)

        #expect(reopened.title == "Call Taylor")
        #expect(reopened.personNames.isEmpty)
        #expect(reopened.projectTitle == nil)
        #expect(reopened.tagSlugs.isEmpty)
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
}
