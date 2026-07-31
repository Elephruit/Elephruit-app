import CoreGraphics
import ElephruitDesign
import Testing

/// Where a wrapping row breaks.
///
/// Every failure mode of a layout like this is a width the reviewer did not happen to try: an item
/// dropped at a boundary, a line one item too long because the spacing was left out of the sum, a
/// hang on something wider than its container. None of them are visible until the window is exactly
/// the wrong size, so they are asserted rather than looked at.
@Suite("Flow layout")
struct FlowLayoutTests {
    private func sizes(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    @Test("Everything that fits stays on one line")
    func oneLine() {
        let lines = FlowLayout.lines(of: sizes([40, 40, 40]), within: 200, spacing: 8)

        #expect(lines.count == 1)
        #expect(lines[0].indices == [0, 1, 2])
        #expect(lines[0].width == 136, "three at forty, plus two gaps of eight")
    }

    @Test("Spacing counts towards the break")
    func spacingIsPartOfTheSum() {
        // 40 + 8 + 40 + 8 + 40 = 136 fits in 140. Forget the gaps and it looks like 120, which
        // would also fit in 130 — where it does not.
        #expect(FlowLayout.lines(of: sizes([40, 40, 40]), within: 140, spacing: 8).count == 1)
        #expect(FlowLayout.lines(of: sizes([40, 40, 40]), within: 130, spacing: 8).count == 2)
    }

    @Test("Nothing is lost across a break")
    func everySubviewIsPlacedExactlyOnce() {
        for width in stride(from: 10 as CGFloat, through: 400, by: 7) {
            let lines = FlowLayout.lines(of: sizes([30, 90, 45, 120, 60, 15]), within: width, spacing: 8)
            let placed = lines.flatMap(\.indices)

            #expect(placed.sorted() == [0, 1, 2, 3, 4, 5], "at width \(width)")
            #expect(placed == placed.sorted(), "reading order changed at width \(width)")
        }
    }

    /// The loop must make progress even when the item cannot possibly fit, or a narrow inspector
    /// hangs the app rather than truncating a label.
    @Test("An item wider than the container gets its own line rather than no line")
    func oversizedItem() {
        let lines = FlowLayout.lines(of: sizes([500]), within: 100, spacing: 8)

        #expect(lines.count == 1)
        #expect(lines[0].indices == [0])
    }

    @Test("Line height is the tallest item on it")
    func lineHeight() {
        let mixed = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 32)]
        let lines = FlowLayout.lines(of: mixed, within: 200, spacing: 8)

        #expect(lines[0].height == 32)
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(FlowLayout.lines(of: [], within: 200, spacing: 8).isEmpty)
    }

    /// The panel is 560 points wide with 16 points of padding each side. The six grammar hints have
    /// to land in one or two lines there — three would push the buttons off the bottom of a panel
    /// that sizes itself to its content.
    @Test("The capture grammar fits the panel in at most two lines")
    func grammarHintsFitTheCapturePanel() {
        // Generous estimates: a sigil, a gap, and a word at caption size.
        let hintWidths: [CGFloat] = [46, 62, 62, 84, 128, 58]
        let lines = FlowLayout.lines(of: sizes(hintWidths), within: 560 - 32, spacing: 12)

        #expect(lines.count <= 2)
    }
}
