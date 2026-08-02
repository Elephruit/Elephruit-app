import AppKit
@testable import ElephruitFeatures
import Testing

@Suite("Sidebar split-view lock")
@MainActor
struct SidebarSplitViewLockTests {
    @Test("The native sidebar item has one permitted thickness")
    func locksNativeItem() {
        let fixture = fixture()

        #expect(fixture.marker.lockContainingPane())
        #expect(fixture.sidebarItem.minimumThickness == 240)
        #expect(fixture.sidebarItem.maximumThickness == 240)
        #expect(fixture.sidebarItem.holdingPriority == .required)
    }

    @Test("Only a new user width changes the native thickness")
    func updatesNativeItem() {
        let fixture = fixture()
        fixture.marker.lockContainingPane()

        fixture.marker.width = 272

        #expect(fixture.sidebarItem.minimumThickness == 272)
        #expect(fixture.sidebarItem.maximumThickness == 272)
    }

    private func fixture() -> (
        controller: NSSplitViewController,
        sidebarItem: NSSplitViewItem,
        marker: SidebarSplitViewLockMarker
    ) {
        let controller = NSSplitViewController()
        let sidebarController = NSViewController()
        sidebarController.view = NSView()
        let contentController = NSViewController()
        contentController.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(NSSplitViewItem(viewController: contentController))
        _ = controller.view

        let marker = SidebarSplitViewLockMarker(width: 240)
        sidebarController.view.addSubview(marker)
        return (controller, sidebarItem, marker)
    }
}
