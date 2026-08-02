import AppKit
@testable import ElephruitFeatures
import ElephruitCore
import Foundation
import Testing

/// The editing pipeline, driven end to end with no window: keystrokes go into the real
/// `NoteProseTextView`, the delegate converts what changed, and the assertions read the
/// document the model now holds. This is the whole path a keypress takes in the app, minus
/// only the pixels.
@Suite("Note editor flow")
@MainActor
struct NoteEditorFlowTests {
    /// A live editor over one prose segment, wired exactly as `NoteProseSegmentView` wires it.
    private struct Editor {
        let model: NoteEditorModel
        let view: NoteProseTextView
        let coordinator: NoteProseSegmentView.Coordinator
        let insertions: InsertionBox
    }

    @MainActor
    final class InsertionBox {
        var received: [(command: NoteInsertionCommand, location: NotePieceLocation)] = []
    }

    private func makeEditor(_ document: NoteDocument) -> Editor {
        let model = NoteEditorModel()
        model.load(document)

        let insertions = InsertionBox()
        let parent = NoteProseSegmentView(
            model: model,
            ordinal: 0,
            onInsertionCommand: { command, location in
                insertions.received.append((command, location))
                // What the page does with an object command, minus the pickers.
                if command == .divider {
                    model.insertObject(.divider, at: location)
                }
            },
            onOpenLink: { _ in }
        )
        let coordinator = parent.makeCoordinator()

        let view = NoteProseTextView()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        view.delegate = coordinator
        view.noteCoordinator = coordinator
        coordinator.textView = view
        coordinator.render(into: view)
        model.registry.register(view, ordinal: 0)

        return Editor(model: model, view: view, coordinator: coordinator, insertions: insertions)
    }

    private func prose(_ kind: NoteParagraphKind = .paragraph, _ text: String, indent: Int = 0) -> NotePiece {
        .prose(NoteParagraph(kind: kind, text: NoteRichText(text), indent: indent))
    }

    private func caretToEnd(_ view: NoteProseTextView) {
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    }

    // MARK: Typing

    @Test("Typing lands in the document without any re-render")
    func typingSyncs() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "Hello")]))
        let revisionBefore = editor.model.renderRevision

        caretToEnd(editor.view)
        editor.view.insertText(", world", replacementRange: editor.view.selectedRange())

        #expect(editor.model.document.pieces[0].paragraph?.plainText == "Hello, world")
        #expect(editor.model.renderRevision == revisionBefore, "typing must never rebuild the segments")
    }

    @Test("Return at the end of a list item continues the list")
    func returnContinuesAList() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.bulleted, "first", indent: 1)]))

        caretToEnd(editor.view)
        editor.view.insertNewline(nil)
        editor.view.insertText("second", replacementRange: editor.view.selectedRange())

        let paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 2)
        #expect(paragraphs[1].kind == .bulleted, "a list continues — that is the whole convenience of a list")
        #expect(paragraphs[1].indent == 1, "at the same depth")
        #expect(paragraphs[1].plainText == "second")
    }

    @Test("Return at the end of a heading produces ordinary prose")
    func returnAfterAHeadingIsProse() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.heading1, "Title")]))

        caretToEnd(editor.view)
        editor.view.insertNewline(nil)
        editor.view.insertText("body", replacementRange: editor.view.selectedRange())

        #expect(editor.model.document.paragraphs.map(\.kind) == [.heading1, .paragraph])
    }

    @Test("Return on an empty list item steps out instead of continuing")
    func returnOnAnEmptyListItemExits() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.bulleted, "only"), prose(.bulleted, "")]))

        caretToEnd(editor.view)
        editor.view.insertNewline(nil)

        let paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 2, "no new paragraph — the empty item changed kind")
        #expect(paragraphs[1].kind == .paragraph)
    }

    @Test("Return inside code is a new line of code; an empty last line leaves the block")
    func returnInsideCode() {
        let editor = makeEditor(NoteDocument(pieces: [
            .prose(NoteParagraph(kind: .code, text: NoteRichText("let x = 1"), language: "swift"))
        ]))

        caretToEnd(editor.view)
        editor.view.insertNewline(nil)
        editor.view.insertText("let y = 2", replacementRange: editor.view.selectedRange())

        var paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 1, "one block, two lines")
        #expect(paragraphs[0].plainText == "let x = 1\nlet y = 2")
        #expect(paragraphs[0].language == "swift")

        // Return twice at the end: an empty code line, then the exit.
        caretToEnd(editor.view)
        editor.view.insertNewline(nil)
        editor.view.insertNewline(nil)
        editor.view.insertText("after", replacementRange: editor.view.selectedRange())

        paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].kind == .code)
        #expect(paragraphs[0].plainText == "let x = 1\nlet y = 2", "the empty exit line is not kept")
        #expect(paragraphs[1].kind == .paragraph)
        #expect(paragraphs[1].plainText == "after")
    }

    // MARK: Markdown shortcuts

    @Test("Typing '# ' at a paragraph start makes a heading, consuming the syntax")
    func markdownHeadingShortcut() {
        let editor = makeEditor(.empty)

        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.insertText("#", replacementRange: editor.view.selectedRange())
        editor.view.insertText(" ", replacementRange: editor.view.selectedRange())
        editor.view.insertText("Section", replacementRange: editor.view.selectedRange())

        let paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].kind == .heading1)
        #expect(paragraphs[0].plainText == "Section", "the syntax is consumed, not kept")
    }

    @Test("Typing '- [ ] ' makes a checklist item, via the bullet the dash already made")
    func markdownChecklistShortcut() {
        let editor = makeEditor(.empty)

        // "- " converts to a bulleted item on its own trailing space — two keys before the
        // bracket arrives — so the checklist spelling is reached *through* the bullet.
        for character in "- " {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }
        #expect(editor.model.document.paragraphs[0].kind == .bulleted)

        for character in "[ ] " {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }
        editor.view.insertText("milk", replacementRange: editor.view.selectedRange())

        let paragraphs = editor.model.document.paragraphs
        #expect(paragraphs[0].kind == .checklist)
        #expect(paragraphs[0].isTicked == false)
        #expect(paragraphs[0].plainText == "milk")
    }

    @Test("Typing '---' becomes a divider object, splitting nothing")
    func markdownDividerShortcut() {
        let editor = makeEditor(.empty)

        for character in "---" {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }

        let pieces = editor.model.document.pieces
        #expect(pieces.contains(.object(.divider)))
        #expect(pieces.last?.paragraph != nil, "the caret still has a paragraph to live in")
    }

    @Test("'1. ' mid-sentence stays prose")
    func markdownOnlyAtParagraphStart() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "version ")]))

        caretToEnd(editor.view)
        for character in "1. " {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }

        #expect(editor.model.document.paragraphs[0].kind == .paragraph)
        #expect(editor.model.document.paragraphs[0].plainText == "version 1. ")
    }

    // MARK: Tab and Backspace

    @Test("Tab nests a list item and does nothing to prose")
    func tabIndentsOnlyLists() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.bulleted, "item")]))

        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.insertTab(nil)
        #expect(editor.model.document.paragraphs[0].indent == 1)

        editor.view.insertBacktab(nil)
        #expect(editor.model.document.paragraphs[0].indent == 0)

        let proseEditor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "text")]))
        proseEditor.view.setSelectedRange(NSRange(location: 0, length: 0))
        proseEditor.view.insertTab(nil)
        #expect(proseEditor.model.document.paragraphs[0].plainText == "text", "no tab character appears")
    }

    @Test("Backspace at a styled paragraph's head takes the style before the characters")
    func backspaceDemotesBeforeJoining() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "before"), prose(.quote, "quoted")]))

        // Caret at the start of the quote.
        editor.view.setSelectedRange(NSRange(location: 7, length: 0))
        editor.view.deleteBackward(nil)

        var paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 2, "nothing joined yet")
        #expect(paragraphs[1].kind == .paragraph, "the quote became prose")

        editor.view.deleteBackward(nil)
        paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 1, "the second press joins")
        #expect(paragraphs[0].plainText == "beforequoted")
    }

    // MARK: Inline marks

    @Test("Toggling bold marks the selection, and the second press undoes the first")
    func boldTogglesWholeSelection() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "some words here")]))

        editor.view.setSelectedRange(NSRange(location: 5, length: 5))
        editor.view.toggleMark(.bold)

        var text = editor.model.document.paragraphs[0].text
        #expect(text.marks(at: 7) == [.bold])
        #expect(text.marks(at: 2) == [])

        editor.view.toggleMark(.bold)
        text = editor.model.document.paragraphs[0].text
        #expect(text.marks(at: 7) == [])
    }

    @Test("A link set on a selection round-trips into the document")
    func linkApplies() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "read the docs")]))

        editor.view.setSelectedRange(NSRange(location: 9, length: 4))
        editor.view.applyLink(.url("https://example.org"))

        let text = editor.model.document.paragraphs[0].text
        #expect(text.link(at: 10) == .url("https://example.org"))
        #expect(text.link(at: 2) == nil)
    }

    // MARK: The / menu

    @Test("Typing / at a paragraph start opens the menu; the query follows; Escape closes it")
    func slashMenuLifecycle() {
        let editor = makeEditor(.empty)

        editor.view.insertText("/", replacementRange: editor.view.selectedRange())
        #expect(editor.model.slashMenu != nil)
        #expect(editor.model.slashMenu?.query == "")

        editor.view.insertText("ti", replacementRange: editor.view.selectedRange())
        #expect(editor.model.slashMenu?.query == "ti")
        #expect(editor.model.slashMatches.contains(.paragraph(.checklist)), "tick finds the checklist")

        editor.view.cancelOperation(nil)
        #expect(editor.model.slashMenu == nil)
    }

    @Test("Committing a kind from the menu converts the paragraph and eats the typed query")
    func slashMenuCommitsAKind() {
        let editor = makeEditor(.empty)

        editor.view.insertText("/", replacementRange: editor.view.selectedRange())
        for character in "quote" {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }
        #expect(editor.model.slashMatches.first == .paragraph(.quote))

        _ = editor.coordinator.prose(editor.view, slashCommand: .commit)
        editor.view.insertText("wise words", replacementRange: editor.view.selectedRange())

        let paragraphs = editor.model.document.paragraphs
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].kind == .quote)
        #expect(paragraphs[0].plainText == "wise words", "the /query is gone")
        #expect(editor.model.slashMenu == nil)
    }

    @Test("Committing an object from the menu goes through the page's insertion path")
    func slashMenuCommitsAnObject() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "above")]))

        caretToEnd(editor.view)
        editor.view.insertText("/", replacementRange: editor.view.selectedRange())
        // "above/" is mid-word, so no menu — the slash needs a paragraph start or a space.
        #expect(editor.model.slashMenu == nil)

        editor.view.insertText(" ", replacementRange: editor.view.selectedRange())
        editor.view.insertText("/", replacementRange: editor.view.selectedRange())
        #expect(editor.model.slashMenu != nil)

        for character in "div" {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
        }
        #expect(editor.model.slashMatches == [.divider])

        _ = editor.coordinator.prose(editor.view, slashCommand: .commit)

        #expect(editor.insertions.received.map(\.command) == [.divider])
        #expect(editor.model.document.pieces.contains(.object(.divider)))
    }

    // MARK: Selection state

    @Test("The inspector hears what the selection is")
    func selectionStateReports() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.heading2, "Head"), prose(.paragraph, "Body")]))

        editor.view.setSelectedRange(NSRange(location: 0, length: 7))
        editor.view.reportSelectionState()

        #expect(editor.model.selection.kinds == [.heading2, .paragraph])
        #expect(editor.model.selection.hasSelection)
        #expect(!editor.model.selection.canIndent)
    }

    // MARK: The outline

    @Test("The outline lists the headings with where they live")
    func outlineEntries() {
        let editor = makeEditor(NoteDocument(pieces: [
            prose(.heading1, "Alpha"),
            prose(.paragraph, "text"),
            prose(.heading2, "Beta"),
            prose(.paragraph, "more"),
            prose(.heading3, "Gamma"),
        ]))

        let outline = editor.model.outline
        #expect(outline.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(outline.map(\.level) == [1, 2, 3])
        #expect(outline.allSatisfy { $0.proseOrdinal == 0 }, "one segment holds them all")
        #expect(outline.map(\.paragraphOffset) == [0, 2, 4])
    }

    @Test("An untitled heading does not appear in the outline")
    func outlineSkipsEmptyHeadings() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.heading1, "  "), prose(.heading2, "Real")]))
        #expect(editor.model.outline.map(\.title) == ["Real"])
    }

    // MARK: Structural changes re-render

    @Test("Inserting an object bumps the revision and leaves the caret a home after it")
    func objectInsertionRerenders() {
        let editor = makeEditor(NoteDocument(pieces: [prose(.paragraph, "text")]))
        let before = editor.model.renderRevision

        editor.model.insertObject(.divider, at: NotePieceLocation(pieceIndex: 0, offset: 4))

        #expect(editor.model.renderRevision > before)
        #expect(editor.model.document.pieces.count == 3)
        #expect(editor.model.document.pieces[2].paragraph != nil, "an empty paragraph follows the last object")
        #expect(editor.model.focusRequest != nil, "the caret is sent to the prose after the object")
    }
}
