import ElephruitDesign
import Testing

@Suite("Report series colours")
struct ReportSeriesPaletteTests {
    @Test("The same visible identity keeps its fallback colour")
    func identityIsStableAcrossCharts() {
        let first = ReportSeriesPalette.palette(
            colorName: nil,
            identity: "Elephruit App",
            isUnassigned: false
        )

        #expect(first != nil)
        #expect(first == ReportSeriesPalette.palette(
            colorName: nil,
            identity: "  elephruit app  ",
            isUnassigned: false
        ))
    }

    @Test("Fallback colours are distributed by identity, not report position")
    func identitiesUseThePalette() {
        let colours = Set((0..<20).compactMap {
            ReportSeriesPalette.palette(
                colorName: nil,
                identity: "Series \($0)",
                isUnassigned: false
            )
        })

        #expect(colours.count > 1)
    }

    @Test("Stored colours and unassigned rows keep their semantic meaning")
    func semanticColoursTakePriority() {
        #expect(ReportSeriesPalette.palette(
            colorName: "purple",
            identity: "Any project",
            isUnassigned: false
        ) == Theme.Palette.purple)
        #expect(ReportSeriesPalette.palette(
            colorName: nil,
            identity: "No project",
            isUnassigned: true
        ) == Theme.Palette.graphite)
    }
}
