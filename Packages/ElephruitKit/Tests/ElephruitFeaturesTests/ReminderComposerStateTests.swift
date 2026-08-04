import AppKit
import ElephruitCore
@testable import ElephruitFeatures
import ElephruitModel
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

    @Test("Native reminder popovers follow presentation state without a deferred handoff")
    @MainActor
    func nativePopoverPresentationIsImmediate() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window; `close()` on a window that also releases itself is the
        // over-release that was killing the test host at autorelease-pool pop.
        window.isReleasedWhenClosed = false
        let anchor = ReminderPopoverAnchorView(
            frame: NSRect(x: 80, y: 40, width: 80, height: 24)
        )
        window.contentView = anchor
        window.orderFrontRegardless()

        let coordinator = ReminderNativePopoverCoordinator()
        coordinator.attach(to: anchor)
        for visit in 0..<100 {
            coordinator.update(
                anchor: anchor,
                content: AnyView(Text("Picker \(visit)")),
                isPresented: true,
                preferredEdge: .minY
            )
            #expect(coordinator.isPopoverShown)

            coordinator.update(
                anchor: anchor,
                content: AnyView(Text("Picker \(visit)")),
                isPresented: false,
                preferredEdge: .minY
            )
            #expect(!coordinator.isPopoverShown)
        }

        coordinator.detach(from: anchor)
        window.close()
    }

    @Test("A saved reminder can repopulate the entire composer")
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

    @Test("Committing a checklist row clears the live editor before the next row")
    @MainActor
    func committedChecklistEditorStartsBlank() {
        var draft = ReminderComposerDraft()
        draft.pendingStep = "First row"
        let router = ReminderComposerFocusRouter()
        let editor = ReminderPlainTextEditor(
            text: Binding(get: { draft.pendingStep }, set: { draft.pendingStep = $0 }),
            placeholder: "Add a checklist item",
            role: .body,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .checklist,
            focusRouter: router
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()
        textView.coordinator = coordinator
        textView.string = draft.pendingStep
        router.register(textView, for: .checklist)

        draft.commitPendingStep()
        router.replaceText("", caret: 0, for: .checklist)

        #expect(draft.checklist.map(\.title) == ["First row"])
        #expect(draft.pendingStep.isEmpty)
        #expect(textView.string.isEmpty)
        #expect(coordinator.lastEditorText.isEmpty)
        #expect(textView.selectedRange().location == 0)
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

    @Test("Registering an editor never changes SwiftUI-bound selection synchronously")
    @MainActor
    func editorRegistrationDefersFocus() {
        var selectionChanges = 0
        let router = ReminderComposerFocusRouter()
        let editor = ReminderPlainTextEditor(
            text: .constant("Reminder"),
            placeholder: "Reminder",
            role: .title,
            onTab: { _ in },
            onReturn: {},
            onCommandReturn: {},
            onEscape: {},
            field: .title,
            focusRouter: router,
            onSelectionChange: { _ in selectionChanges += 1 }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ReminderEditorTextView()
        textView.delegate = coordinator
        textView.coordinator = coordinator
        textView.string = "Reminder"
        selectionChanges = 0

        router.register(textView, for: .title)

        #expect(selectionChanges == 0)
        #expect(router.pendingRegistrationFocusField == .title)
    }

    @Test("Only a click elsewhere in the composer window commits")
    @MainActor
    func outsideClickBoundary() {
        #expect(ReminderComposerEventMonitor.shouldCommitClick(
            eventWindowIsComposerWindow: true,
            composerContainsLocation: false
        ))
        #expect(!ReminderComposerEventMonitor.shouldCommitClick(
            eventWindowIsComposerWindow: true,
            composerContainsLocation: true
        ))
        #expect(!ReminderComposerEventMonitor.shouldCommitClick(
            eventWindowIsComposerWindow: false,
            composerContainsLocation: false
        ))
    }

    @Test("Arrow routing is available before the destination editor mounts")
    @MainActor
    func persistentArrowRouting() {
        let router = ReminderComposerFocusRouter()
        var verticalMoves: [Int] = []
        var horizontalMoves: [Int] = []
        router.onVerticalMove = { verticalMoves.append($0); return true }
        router.onHorizontalMove = { horizontalMoves.append($0); return true }

        #expect(ReminderComposerEventMonitor.handleArrowKey(126, using: router))
        #expect(ReminderComposerEventMonitor.handleArrowKey(125, using: router))
        #expect(ReminderComposerEventMonitor.handleArrowKey(123, using: router))
        #expect(ReminderComposerEventMonitor.handleArrowKey(124, using: router))

        #expect(verticalMoves == [-1, 1])
        #expect(horizontalMoves == [-1, 1])
    }

    @Test("Unclaimed arrows remain available for normal caret movement")
    @MainActor
    func unclaimedArrowRouting() {
        let router = ReminderComposerFocusRouter()

        #expect(!ReminderComposerEventMonitor.handleArrowKey(126, using: router))
        #expect(!ReminderComposerEventMonitor.handleArrowKey(123, using: router))
        #expect(!ReminderComposerEventMonitor.handleArrowKey(48, using: router))
    }

    @Test("Hardware arrow flags do not disable persistent routing")
    @MainActor
    func hardwareArrowModifiers() {
        #expect(ReminderComposerEventMonitor.allowsArrowRouting(with: []))
        #expect(ReminderComposerEventMonitor.allowsArrowRouting(with: [.function]))
        #expect(ReminderComposerEventMonitor.allowsArrowRouting(with: [.numericPad]))
        #expect(ReminderComposerEventMonitor.allowsArrowRouting(with: [.capsLock]))
        #expect(!ReminderComposerEventMonitor.allowsArrowRouting(with: [.shift]))
        #expect(!ReminderComposerEventMonitor.allowsArrowRouting(with: [.command]))
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
        #expect(ReminderPlainTextEditor.verticalInset(for: .body) == 5)
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
