import AppKit
import SwiftUI

/// Makes the native sidebar pane exactly as wide as the user last made it.
///
/// `navigationSplitViewColumnWidth(_:)` constrains the SwiftUI content, but AppKit may still resize
/// the `NSSplitViewItem` containing that content when sibling columns appear or disappear. Empty
/// list destinations exercise that path repeatedly while their detail column settles. Locking the
/// split item itself removes the sidebar from that negotiation entirely.
struct SidebarSplitViewLock: NSViewRepresentable {
    var width: CGFloat

    func makeNSView(context: Context) -> SidebarSplitViewLockMarker {
        SidebarSplitViewLockMarker(width: width)
    }

    func updateNSView(_ marker: SidebarSplitViewLockMarker, context: Context) {
        guard marker.width != width else { return }
        marker.width = width
    }
}

@MainActor
final class SidebarSplitViewLockMarker: NSView {
    private(set) var adjustmentCount = 0

    var width: CGFloat {
        didSet {
            guard width != oldValue else { return }
            lockContainingPane()
        }
    }

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        lockAfterHierarchySettles()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lockAfterHierarchySettles()
    }

    /// Locks the nearest native split-view item containing this marker.
    ///
    /// The nearest split is important when SwiftUI nests split views: only the sidebar item in the
    /// navigation split is fixed, never the navigation split's whole subtree in an outer container.
    @discardableResult
    func lockContainingPane() -> Bool {
        guard width.isFinite, width > 0 else { return false }

        var ancestor = superview
        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let index = splitView.arrangedSubviews.firstIndex(where: { isDescendant(of: $0) }),
               let controller = splitViewController(for: splitView),
                controller.splitViewItems.indices.contains(index) {
                let item = controller.splitViewItems[index]
                let constraintsChanged = item.minimumThickness != width
                    || item.maximumThickness != width
                    || item.holdingPriority != .required

                // `updateNSView` can run for any state change in the window. Calling
                // `adjustSubviews()` unconditionally turns those updates into new split-layout
                // passes, which can feed back into another SwiftUI update. Once the pane is locked
                // there is nothing to do; AppKit itself enforces the equal min/max constraints.
                guard constraintsChanged else { return true }

                item.minimumThickness = width
                item.maximumThickness = width
                item.holdingPriority = .required
                adjustmentCount += 1
                splitView.adjustSubviews()
                return true
            }
            ancestor = view.superview
        }

        return false
    }

    private func splitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
        if let controller = splitView.delegate as? NSSplitViewController {
            return controller
        }

        var responder: NSResponder? = splitView.nextResponder
        while let current = responder {
            if let controller = current as? NSSplitViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }

    private func lockAfterHierarchySettles() {
        lockContainingPane()
        Task { @MainActor [weak self] in
            self?.lockContainingPane()
        }
    }
}
