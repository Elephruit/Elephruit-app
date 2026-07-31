import CoreGraphics
import ElephruitDesign
import Testing

/// The two decisions the notes editor makes without being told: what to say about saving, and how
/// tall to be.
///
/// Both were previously invisible — nothing was said about saving at all, and the height was a
/// `minHeight` constant repeated at five call sites — so both are asserted rather than looked at.
@Suite("Editing surface")
struct EditingSurfaceTests {
    // MARK: - Saving

    /// An interface that celebrates the expected outcome is an interface that has to be ignored.
    @Test("Nothing is said when nothing has changed")
    func idleIsSilent() {
        #expect(SaveState.idle.message == nil)
        #expect(SaveState.idle.symbolName == nil)
    }

    @Test("Saving and saved both say something, and only failure is loud")
    func statesSayTheRightThing() {
        #expect(SaveState.saving.message == "Saving…")
        #expect(SaveState.saved.message == "Saved")
        #expect(SaveState.failed("The library is read-only").message == "The library is read-only")

        #expect(!SaveState.saving.isFailure)
        #expect(!SaveState.saved.isFailure)
        #expect(SaveState.failed("x").isFailure)
    }

    /// Announcing every autosave would talk over somebody typing into the field the announcement is
    /// about.
    @Test("Only a failure is announced")
    func announcements() {
        #expect(!SaveState.idle.deservesAnnouncement)
        #expect(!SaveState.saving.deservesAnnouncement)
        #expect(!SaveState.saved.deservesAnnouncement)
        #expect(SaveState.failed("x").deservesAnnouncement)
    }

    // MARK: - Height

    /// A blank canvas that fills the pane says "this is the main event" about a field most tasks
    /// never use, and pushes the scheduling controls below the fold.
    @Test("An empty editor is compact")
    func emptyIsCompact() {
        #expect(EditorHeight.height(forLines: 0) == EditorHeight.compact)
    }

    /// Clicking into an empty editor must not make the pane jump on the first character typed.
    @Test("Focusing an empty editor gives it the room it is about to need")
    func focusedEmptyGrowsFirst() {
        let unfocused = EditorHeight.height(forLines: 0, isFocused: false)
        let focused = EditorHeight.height(forLines: 0, isFocused: true)

        #expect(focused >= unfocused)
    }

    @Test("It grows with the content")
    func growsWithContent() {
        var previous = EditorHeight.height(forLines: 0)

        for lines in 1...30 {
            let height = EditorHeight.height(forLines: lines)
            #expect(height >= previous, "shrank at \(lines) lines")
            previous = height
        }
    }

    /// Otherwise a page of notes pushes everything else out of the pane entirely, and the editor
    /// stops being a section and becomes the screen.
    @Test("It stops growing, and scrolls instead")
    func heightIsBounded() {
        #expect(EditorHeight.height(forLines: 10_000) == EditorHeight.maximum)
    }

    @Test("Empty text is no lines")
    func lineCountOfNothing() {
        #expect(EditorHeight.lineCount(of: "") == 0)
    }

    @Test("Every newline is a line")
    func lineCountOfParagraphs() {
        #expect(EditorHeight.lineCount(of: "one\ntwo\nthree") == 3)
        #expect(EditorHeight.lineCount(of: "one\n\nthree") == 3, "a blank line still occupies one")
    }

    @Test("A long line wraps into several")
    func lineCountWraps() {
        let long = String(repeating: "word ", count: 200)
        #expect(EditorHeight.lineCount(of: long, width: 560) > 1)
    }

    /// A narrow pane wraps more, so the same note is taller in it — which is what stops a resized
    /// detail column from truncating the editor.
    @Test("A narrower pane means more lines for the same text")
    func lineCountFollowsWidth() {
        let text = String(repeating: "word ", count: 100)

        #expect(EditorHeight.lineCount(of: text, width: 300) >= EditorHeight.lineCount(of: text, width: 900))
    }

    @Test("A pane narrower than anything sensible still reports a positive line length")
    func degenerateWidth() {
        #expect(EditorHeight.lineCount(of: "hello", width: 1) >= 1)
        #expect(EditorHeight.lineCount(of: "hello", width: 0) >= 1)
    }
}
