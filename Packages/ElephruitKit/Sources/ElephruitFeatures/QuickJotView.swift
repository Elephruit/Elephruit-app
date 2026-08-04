import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The contents of the floating capture panel.
///
/// Deliberately the same grammar, the same parser and the same save path as the in-window sheet —
/// this is a different way in, not a different feature. Everything between the title and the buttons
/// is ``CaptureComposer``, which is that promise made structural rather than repeated.
///
/// What is left here is only what a panel does differently from a sheet: it cannot dismiss itself,
/// so cancelling asks the controller to hide the window; and it stays open after a failure, so it
/// has an error to show.
struct QuickJotView: View {
    @Bindable var controller: QuickJotController

    var body: some View {
        CaptureComposer(
            composition: $controller.composition,
            presentationStyle: .panel,
            error: controller.lastError,
            confirmation: controller.confirmation,
            onSave: { controller.save() },
            onCancel: { controller.hide() }
        )
        .frame(width: 560)
        .background(Theme.FloatingCapturePanel.background)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }
}
