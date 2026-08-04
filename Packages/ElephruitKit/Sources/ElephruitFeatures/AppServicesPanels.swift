import ElephruitFeaturesCore
import Foundation

/// The two application-wide panels, reached exactly as they were before the model split.
///
/// `AppServices` moved to `ElephruitFeaturesCore` so the iPhone app can share it, and that
/// module cannot name `MiniTimerController` or `QuickLogController` — both are AppKit panels.
/// The storage stayed behind (the accessory registry); the names live here, beside the only
/// platform that has the types. Every existing call site — `services.miniTimer`,
/// `services.quickLog.show()` — reads exactly as it did.
extension AppServices {
    /// The app collapsed to its clock, and whether it currently is.
    ///
    /// Built on first use, because an app nobody collapses should never construct a panel.
    public var miniTimer: MiniTimerController {
        accessory(MiniTimerController.self) {
            MiniTimerController(services: self, defaults: defaults)
        }
    }

    /// The panel that starts a timer from any application, and names it once it is going.
    ///
    /// Held app-wide because three separate surfaces need to open it: the global shortcut,
    /// the File menu, and the menu bar.
    public var quickLog: QuickLogController {
        accessory(QuickLogController.self) {
            QuickLogController(services: self)
        }
    }
}
