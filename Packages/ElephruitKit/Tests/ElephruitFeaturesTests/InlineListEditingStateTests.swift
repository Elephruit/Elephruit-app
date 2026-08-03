import Testing

@testable import ElephruitFeatures

@Suite("Inline list editor selection")
struct InlineListEditingStateTests {
    @Test("Opening an editor clears native list selection")
    func openingClearsSelection() {
        var state = InlineListEditingState<String>()

        let selection = state.beginEditing("entry")

        #expect(state.editingID == "entry")
        #expect(selection.isEmpty, "The system accent must not fill the expanded editor")
    }

    @Test("Controls inside an editor cannot reselect its row")
    func editorControlsCannotReselectRow() {
        var state = InlineListEditingState(editingID: "entry")

        let selection = state.acceptSelection(["entry"])

        #expect(state.editingID == "entry")
        #expect(selection.isEmpty)
    }

    @Test("Selecting another row closes the editor and keeps navigation working")
    func anotherRowClosesEditor() {
        var state = InlineListEditingState(editingID: "entry")

        let selection = state.acceptSelection(["another"])

        #expect(state.editingID == nil)
        #expect(selection == ["another"])
    }

    @Test("Closing an editor can restore its compact row selection")
    func closingCanRestoreSelection() {
        var state = InlineListEditingState(editingID: "entry")

        let selection = state.endEditing(restoringSelection: "entry")

        #expect(state.editingID == nil)
        #expect(selection == ["entry"])
    }
}
