import ElephruitDesign
import SwiftUI
import Testing

/// A selected row stays readable.
///
/// ### The bug this pins down
/// A focused `List` selection paints the accent colour behind the row and sets the foreground style
/// to the selected-content colour, so *unstyled* text turns white and stays legible. Naming a colour
/// opts out of that: `Color.primary` is `labelColor`, which is near-black in light mode and stays
/// near-black on top of the blue fill. Every row in the app named its colours, so every selected row
/// was dark text on a blue background.
///
/// The failure is invisible until somebody selects a row *in a focused window* — a screenshot of the
/// list looks perfect — which is exactly the kind of thing that has to be asserted rather than
/// reviewed.
@Suite("Row emphasis")
struct RowEmphasisTests {
    @Test("An unselected row uses the semantic label colours")
    func standardProminence() {
        #expect(Theme.Emphasis.primary.color(prominence: .standard) == Theme.Colors.primaryText)
        #expect(Theme.Emphasis.secondary.color(prominence: .standard) == Theme.Colors.secondaryText)
        #expect(Theme.Emphasis.tertiary.color(prominence: .standard) == Theme.Colors.tertiaryText)
        #expect(Theme.Emphasis.placeholder.color(prominence: .standard) == Theme.Colors.placeholderText)
    }

    /// `nil` means "name no colour", which is what lets the relative styles follow the selection.
    @Test("A selected row names no colour of its own")
    func increasedProminence() {
        for emphasis in Theme.Emphasis.allCases {
            #expect(
                emphasis.color(prominence: .increased) == nil,
                "\(emphasis) would paint its own colour on top of the selection fill"
            )
        }
    }
}
