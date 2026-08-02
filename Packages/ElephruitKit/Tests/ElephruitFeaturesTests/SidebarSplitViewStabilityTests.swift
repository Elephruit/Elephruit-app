import AppKit
@testable import ElephruitFeatures
import Testing

@Suite("Sidebar split-view stability")
@MainActor
struct SidebarSplitViewStabilityTests {
    @Test("The sidebar pane receives required holding priority")
    func sidebarPaneHoldsItsWidth() {
        let splitView = NSSplitView()
        let sidebar = NSView()
        let detail = NSView()
        let marker = SidebarSplitViewMarker()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        sidebar.addSubview(marker)

        #expect(marker.protectContainingPane())
        #expect(splitView.holdingPriorityForSubview(at: 0) == .required)
        #expect(splitView.holdingPriorityForSubview(at: 1) != .required)
    }

    @Test("Only the nearest containing split view is changed")
    func nestedSplitDoesNotProtectTheWholeSubtree() {
        let outer = NSSplitView()
        let inner = NSSplitView()
        let outerDetail = NSView()
        let sidebar = NSView()
        let primary = NSView()
        let marker = SidebarSplitViewMarker()

        outer.addArrangedSubview(inner)
        outer.addArrangedSubview(outerDetail)
        inner.addArrangedSubview(sidebar)
        inner.addArrangedSubview(primary)
        sidebar.addSubview(marker)
        let originalOuterPriority = outer.holdingPriorityForSubview(at: 0)

        #expect(marker.protectContainingPane())
        #expect(inner.holdingPriorityForSubview(at: 0) == .required)
        #expect(outer.holdingPriorityForSubview(at: 0) == originalOuterPriority)
    }
}
