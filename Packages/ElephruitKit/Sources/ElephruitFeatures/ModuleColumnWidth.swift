import CoreGraphics
import ElephruitDesign
import SwiftUI

extension View {
    /// Sizes one column of the shell according to the module the window is in.
    ///
    /// ### Why `pinned` exists
    /// `navigationSplitViewColumnWidth(min:ideal:max:)` sets *constraints*, and AppKit's split view
    /// moves a divider only when its current position breaks one. That is right almost always and
    /// wrong at exactly one moment: arriving in a module. A People detail pane left at 520 points
    /// satisfies Notes' 420–960 range perfectly well, so nothing moves, and Notes silently inherits
    /// a width People chose. Passing a `pinned` value collapses the range to a single number for one
    /// turn of the run loop, which forces the move; the caller then clears it and the divider is the
    /// user's again.
    ///
    /// A module that says its pane is not resizable is pinned permanently, which is the same
    /// mechanism and needs no second one.
    func moduleColumnWidth(
        _ column: ModuleShellLayout.Column,
        layout: ModuleShellLayout,
        store: ModuleLayoutStore,
        module: AppModule?,
        windowWidth: CGFloat,
        pinned: CGFloat?
    ) -> some View {
        let policy: DetailPanePolicy? = switch column {
        case .detail: layout.detail
        case .inspector: layout.inspector
        case .primary, .sidebar: nil
        }

        let bounds: PaneWidth = switch column {
        case .primary: layout.primary
        case .detail: layout.detail.width
        case .inspector: layout.inspector.width
        case .sidebar: layout.primary
        }

        let resolved = store.width(of: column, in: module, available: windowWidth)
        let fixedAt: CGFloat? = pinned ?? (policy?.isResizable == false ? resolved : nil)

        return Group {
            if let fixedAt {
                self.navigationSplitViewColumnWidth(fixedAt)
            } else {
                self.navigationSplitViewColumnWidth(
                    min: bounds.minimum,
                    ideal: resolved,
                    // An unbounded column is one the module wants to fill whatever is left — the
                    // calendar's canvas. Handing it the window's own width says that without
                    // needing `.infinity`, which a split view cannot divide by.
                    max: bounds.maximum ?? max(windowWidth, bounds.minimum)
                )
            }
        }
    }
}
