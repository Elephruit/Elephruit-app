import AppKit
import SwiftUI

/// Keeps the native split view from using the sidebar to absorb changes in the panes beside it.
///
/// SwiftUI exposes the sidebar's allowed width range, but not AppKit's holding priority. Those are
/// different decisions: the range says where the divider may be dragged; the holding priority says
/// which pane keeps its current width when another pane appears, disappears, or changes constraints.
/// `NavigationSplitView` otherwise moves the sidebar a few points during every Today/Inbox switch.
///
/// The zero-cost marker reaches only the nearest containing `NSSplitView` and marks the pane that
/// actually contains it. The divider remains user-resizable because holding priority governs
/// automatic layout, not explicit divider drags.
struct SidebarSplitViewStability: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarSplitViewMarker {
        SidebarSplitViewMarker()
    }

    func updateNSView(_ nsView: SidebarSplitViewMarker, context: Context) {
        nsView.protectContainingPane()
    }
}

final class SidebarSplitViewMarker: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        protectAfterHierarchySettles()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        protectAfterHierarchySettles()
    }

    /// Returns whether a containing split-view pane was found and protected.
    ///
    /// Internal rather than private so the AppKit hierarchy can be asserted without launching a
    /// window. The nearest split view is deliberate: a nested split's whole subtree must not be
    /// assigned the sidebar's priority in its parent.
    @discardableResult
    func protectContainingPane() -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let index = splitView.subviews.firstIndex(where: { isDescendant(of: $0) }) {
                splitView.setHoldingPriority(.required, forSubviewAt: index)
                return true
            }
            ancestor = view.superview
        }
        return false
    }

    private func protectAfterHierarchySettles() {
        Task { @MainActor [weak self] in
            self?.protectContainingPane()
        }
    }
}
