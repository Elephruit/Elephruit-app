import ElephruitDesign
import SwiftUI
import UIKit

/// `withAnimation`, with Reduce Motion honoured — the one way this target animates
/// an imperative state change.
///
/// The design system's promise is that no view animates directly (`Theme.Motion`
/// explains why); `View.calmAnimation` keeps it for declarative animation, and this
/// keeps it for the imperative kind. Checked at the moment of the change rather than
/// captured at view creation, so flipping the setting takes effect immediately.
@MainActor
func withCalmAnimation<Result>(
    _ animation: Animation = Theme.Motion.standard,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(
        Theme.Motion.respectingReduceMotion(
            animation,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        ),
        body
    )
}
