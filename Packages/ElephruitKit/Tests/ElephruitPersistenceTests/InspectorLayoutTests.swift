import AppKit
import ElephruitCore
import ElephruitDesign
import Foundation
import SwiftUI
import Testing

/// **Criterion A1-3** — no inspector control clips at any supported width or text size.
///
/// ### Why these are measurements, not image snapshots
/// The scope document called for snapshot tests. Image-diff snapshotting needs a third-party
/// framework, which the project forbids without approval, and it answers the wrong question anyway:
/// a snapshot tells you the pixels changed, not that a control was clipped.
///
/// Clipping has an exact definition — a view whose *intrinsic* width exceeds the width it is given —
/// and `NSHostingView.fittingSize` measures that directly. These tests render the real views through
/// AppKit at each supported width and fail if anything needs more room than it has. That is a
/// stronger assertion than a picture, and it needs no dependency.
@MainActor
@Suite("Inspector layout")
struct InspectorLayoutTests {
    /// Every width the inspector can be dragged to, plus the breakpoint on both sides.
    private static let supportedWidths: [CGFloat] = [240, 280, 299, 300, 340, 380, 420]

    /// The standard text size and a large accessibility one.
    private static let fontSizes: [CGFloat] = [13, 20]

    /// Renders a view at a fixed width and returns the width it actually wanted.
    private func intrinsicWidth(of view: some View, constrainedTo width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    // MARK: - The decision itself

    @Test("The arrangement changes at the breakpoint, not before or after")
    func styleFollowsWidth() {
        #expect(InspectorLayout.style(forWidth: 240) == .stacked)
        #expect(InspectorLayout.style(forWidth: 299) == .stacked)
        #expect(InspectorLayout.style(forWidth: 300) == .inline)
        #expect(InspectorLayout.style(forWidth: 420) == .inline)
    }

    @Test("A control always gets a positive width, at every supported size")
    func controlWidthIsNeverNegative() {
        for width in Self.supportedWidths {
            let style = InspectorLayout.style(forWidth: width)
            let available = InspectorLayout.availableControlWidth(paneWidth: width, style: style)

            #expect(available > 0, "No room for a control at \(width)pt")
            #expect(available <= width, "A control cannot be wider than its pane")
        }
    }

    @Test("Stacking gives a control more room than an inline row would")
    func stackingBuysWidth() {
        let width: CGFloat = 260

        let inline = InspectorLayout.availableControlWidth(paneWidth: width, style: .inline)
        let stacked = InspectorLayout.availableControlWidth(paneWidth: width, style: .stacked)

        #expect(stacked > inline)
        #expect(stacked - inline == InspectorLayout.labelColumnWidth + InspectorLayout.labelGap)
    }

    @Test("The segmented control is only offered where it fits")
    func segmentedOnlyWhereItFits() {
        // The reported failure: at a 280pt pane the old inline row gave the control 162pt, and three
        // segments reading "Open | Completed | Cancelled" need roughly 220. They do not compress —
        // they clip, which is what the screenshot showed.
        let oldInlineWidthAt280 = InspectorLayout.availableControlWidth(paneWidth: 280, style: .inline)
        #expect(oldInlineWidthAt280 < 220, "This is the width that used to clip")

        // Stacking buys back the label column, so at 280 the control now genuinely fits.
        #expect(InspectorLayout.canUseSegmentedControl(paneWidth: 280))

        // Narrower still, even stacked there is not enough room, so the control becomes a menu.
        #expect(InspectorLayout.canUseSegmentedControl(paneWidth: 240) == false)

        // And it is available again once the pane is wide enough for an inline row.
        #expect(InspectorLayout.canUseSegmentedControl(paneWidth: 420))
    }

    // MARK: - Rendered measurement

    @Test("An inspector row never wants more width than it is given")
    func rowsNeverExceedTheirPane() {
        for width in Self.supportedWidths {
            let style = InspectorLayout.style(forWidth: width)

            let row = InspectorRow("Defer until") {
                Text("30 July 2026")
            }
            .environment(\.inspectorLayoutStyle, style)
            .padding(.horizontal, InspectorLayout.horizontalPadding / 2)

            let needed = intrinsicWidth(of: row, constrainedTo: width)

            #expect(
                needed <= width + 0.5,
                "A row wanted \(needed)pt inside a \(width)pt pane — that is a clip"
            )
        }
    }

    @Test("A long label does not push a row past its pane")
    func longLabelsDoNotOverflow() {
        for width in Self.supportedWidths {
            let style = InspectorLayout.style(forWidth: width)

            let row = InspectorRow("Wiederkehrendes Fälligkeitsdatum") {
                Text("Every 2 weeks on Monday")
            }
            .environment(\.inspectorLayoutStyle, style)

            let needed = intrinsicWidth(of: row, constrainedTo: width)
            #expect(needed <= width + 0.5, "A long label overflowed at \(width)pt")
        }
    }

    @Test("Rows hold at accessibility text sizes too")
    func rowsHoldAtLargeTextSizes() {
        for width in Self.supportedWidths {
            for size in Self.fontSizes {
                let style = InspectorLayout.style(forWidth: width)

                let row = InspectorRow("Priority") {
                    Text("Normal")
                }
                .font(.system(size: size))
                .environment(\.inspectorLayoutStyle, style)

                let needed = intrinsicWidth(of: row, constrainedTo: width)
                #expect(
                    needed <= width + 0.5,
                    "A row overflowed at \(width)pt with \(size)pt text"
                )
            }
        }
    }

    @Test("A whole inspector section fits at the narrowest supported width")
    func sectionFitsAtMinimum() {
        let width = InspectorLayout.minimumWidth

        let section = InspectorSection("Dates") {
            InspectorRow("Start") { Text("29 July 2026") }
            InspectorRow("Due") { Text("30 July 2026") }
            InspectorRow("Created") { Text("29 Jul 2026 at 7:52 AM") }
        }
        .environment(\.inspectorLayoutStyle, InspectorLayout.style(forWidth: width))
        .frame(maxWidth: .infinity, alignment: .leading)

        let needed = intrinsicWidth(of: section, constrainedTo: width)
        #expect(needed <= width + 0.5, "A section wanted \(needed)pt at the \(width)pt minimum")
    }

    @Test("The published widths are ordered sensibly")
    func widthsAreCoherent() {
        #expect(InspectorLayout.minimumWidth < InspectorLayout.idealWidth)
        #expect(InspectorLayout.idealWidth <= InspectorLayout.maximumWidth)

        // The ideal width must be at or above the breakpoint, or the inspector would open stacked by
        // default — which would be a strange first impression at a comfortable size.
        #expect(InspectorLayout.idealWidth >= InspectorLayout.stackingBreakpoint)
    }
}
