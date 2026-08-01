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
    ///
    /// ### Why there is no `if` in here
    /// There was, and it was the whole fault. This used to return `Group { if pinned { … } else { … } }`,
    /// and a split view reads a column's width from the column's own content — a width buried inside
    /// a `Group`'s conditional never reached it. So *none* of ``ModuleLayoutPolicy``'s numbers were
    /// ever applied to the middle or the detail column, and both columns sat wherever AppKit's
    /// remembered divider happened to leave them: a list at 1,170 points against a declared maximum
    /// of 480, and an editor squeezed to 118 against a declared minimum of 420.
    ///
    /// The tell was which columns were *right*. The sidebar and the inspector apply their modifiers
    /// directly and were correctly sized in every module; the two routed through here were the two
    /// that were broken. A pinned column is now expressed as a range whose three numbers are equal,
    /// which is the same statement without a branch to lose it in.
    func moduleColumnWidth(
        _ column: ModuleShellLayout.Column,
        layout: ModuleShellLayout,
        resolved: CGFloat,
        pinned: CGFloat?
    ) -> some View {
        let policy: DetailPanePolicy? = switch column {
        case .detail: layout.detail
        case .inspector: layout.inspector
        case .primary, .sidebar: nil
        }

        let bounds: PaneWidth = switch column {
        case .primary, .sidebar: layout.primary
        case .detail: layout.detail.width
        case .inspector: layout.inspector.width
        }

        let fixedAt: CGFloat? = pinned ?? (policy?.isResizable == false ? resolved : nil)

        // The ceiling is what the shell worked out this column may have, never the whole window: a
        // column that may grow to the window's width is a column that can take the space the pane
        // beside it needed, which is what left an editor at 118 points.
        let ceiling = max(resolved, bounds.minimum)
        let floor = fixedAt ?? bounds.minimum

        // ### Why the minimum is also stated as a frame
        // `navigationSplitViewColumnWidth` is a request, and on the middle column of a three-column
        // split view AppKit does not always grant it: a freshly-created window laid the list out at
        // 198 points against a declared minimum of 260, and a restored one at 808 against a maximum
        // of 520. A minimum expressed as the *content's* own frame is not a request — the split view
        // cannot draw a pane narrower than the thing inside it — so the two together hold where
        // either alone did not.
        //
        // Only the minimum is enforced this way. A maximum expressed as a frame would cap the
        // content and leave the pane's remainder empty, which is a worse failure than a wide column:
        // it looks like a rendering bug rather than a layout preference.
        return frame(minWidth: floor)
            .navigationSplitViewColumnWidth(
                min: floor,
                ideal: fixedAt ?? resolved,
                max: fixedAt ?? ceiling
            )
    }
}
