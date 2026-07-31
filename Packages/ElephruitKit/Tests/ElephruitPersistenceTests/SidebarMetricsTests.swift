import AppKit
import ElephruitDesign
import Foundation
import Testing

/// **Criterion A1-4** — primary sidebar destinations never truncate at any supported width or text
/// size; the minimum width grows instead.
///
/// The rule is easy to state and easy to lose: someone adds a longer destination, or a localiser
/// translates "Upcoming" into something half again as long, and a fixed 180pt minimum quietly starts
/// clipping primary navigation. These tests are what make that a build failure rather than a
/// discovery.
@Suite("Sidebar metrics")
struct SidebarMetricsTests {
    private let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    @Test("Short titles sit at the floor")
    func shortTitlesUseTheFloor() {
        let width = SidebarMetrics.minimumWidth(fittingTitles: ["Today", "Inbox"], font: bodyFont)
        #expect(width == SidebarMetrics.floorWidth)
    }

    @Test("A longer title raises the minimum rather than being cut")
    func longTitlesRaiseTheMinimum() {
        let short = SidebarMetrics.minimumWidth(fittingTitles: ["Today"], font: bodyFont)
        let long = SidebarMetrics.minimumWidth(
            fittingTitles: ["Today", "Bevorstehende Aufgaben und Termine"],
            font: bodyFont
        )

        #expect(long > short, "A title that cannot fit must widen the sidebar, not be truncated")
        #expect(long > SidebarMetrics.floorWidth)
    }

    @Test("A larger text size raises the minimum")
    func largerTextRaisesTheMinimum() {
        let title = "A reasonably long destination"

        let standard = SidebarMetrics.minimumWidth(
            fittingTitles: [title],
            font: NSFont.systemFont(ofSize: 13)
        )
        let accessible = SidebarMetrics.minimumWidth(
            fittingTitles: [title],
            font: NSFont.systemFont(ofSize: 24)
        )

        #expect(accessible > standard, "At an accessibility text size the sidebar cannot be as narrow")
    }

    @Test("The derived width leaves room for the icon, the gap, and a count")
    func chromeIsAccountedFor() {
        // A single character still needs the glyph column, the gap, both insets, and the count
        // reserve — otherwise a badge appearing would reflow the label.
        let width = SidebarMetrics.minimumWidth(fittingTitles: ["A"], font: bodyFont)
        #expect(width >= SidebarMetrics.chromeWidth)
        #expect(SidebarMetrics.chromeWidth > SidebarMetrics.iconColumn + SidebarMetrics.countReserve)
    }

    @Test("No titles still yields a usable sidebar")
    func emptyTitlesAreSafe() {
        #expect(SidebarMetrics.minimumWidth(fittingTitles: [], font: bodyFont) == SidebarMetrics.floorWidth)
    }

    @Test("The ideal width is never below the minimum")
    func idealNeverBelowMinimum() {
        let longTitles = ["Extraordinarily Long Destination Name That Will Not Fit"]

        let minimum = SidebarMetrics.minimumWidth(fittingTitles: longTitles)
        let ideal = SidebarMetrics.idealWidth(fittingTitles: longTitles)

        #expect(ideal >= minimum)
        #expect(SidebarMetrics.idealWidth(fittingTitles: ["Today"]) == SidebarMetrics.defaultWidth)
    }

    @Test("Every shipped destination title fits at the default width")
    func shippedTitlesFitTheDefault() {
        // If this fails, either a destination has been given too long a name or the default width
        // needs raising. Both are decisions worth making deliberately.
        let width = SidebarMetrics.minimumWidth(
            fittingTitles: ["Today", "Upcoming", "Inbox", "Notes", "Projects", "Areas",
                            "People", "Bookmarks", "Archive", "Trash", "Saved Searches"],
            font: bodyFont
        )

        #expect(width <= SidebarMetrics.defaultWidth)
    }

    @Test("The published measurements are ordered sensibly")
    func measurementsAreCoherent() {
        #expect(SidebarMetrics.floorWidth < SidebarMetrics.defaultWidth)
        #expect(SidebarMetrics.defaultWidth < SidebarMetrics.maximumWidth)
        #expect(SidebarMetrics.selectionInset < SidebarMetrics.baseRowHeight)
    }
}
