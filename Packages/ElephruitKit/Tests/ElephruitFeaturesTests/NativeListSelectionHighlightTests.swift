import AppKit
import Testing

@testable import ElephruitFeatures

@MainActor
@Suite("Native list selection presentation")
struct NativeListSelectionHighlightTests {
    @Test("The row suppressor disables its owning table's accent selection")
    func suppressesOwningTableSelectionHighlight() {
        let table = NSTableView()
        table.selectionHighlightStyle = .regular

        let rowContainer = NSView()
        table.addSubview(rowContainer)

        let suppressor = NativeListSelectionHighlightSuppressorView()
        rowContainer.addSubview(suppressor)

        #expect(table.selectionHighlightStyle == .none)
    }
}
