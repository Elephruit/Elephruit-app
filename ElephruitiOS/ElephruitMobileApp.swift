import ElephruitFeaturesCore
import SwiftUI

/// The iPhone app.
///
/// One scene, one tab shell. The Mac's other scenes — menu bar extras, floating panels, a
/// Settings window — are desktop furniture; their jobs live inside the shell here (the
/// timer accessory above the tab bar, the capture button, a Settings screen in Library).
@main
struct ElephruitMobileApp: App {
    @State private var environment = MobileAppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootWindow(environment: environment)
                .task { environment.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Backgrounding is the iPhone's "the machine may vanish now": pending
                    // editor debounces are flushed so nothing typed is lost to a suspension,
                    // exactly as the Mac flushes before quit.
                    if phase == .background || phase == .inactive {
                        environment.services?.flushForSuspension()
                    }
                }
        }
    }
}

/// Switches on the boot outcome, exactly as the Mac's `RootWindow` does.
private struct MobileRootWindow: View {
    let environment: MobileAppEnvironment

    var body: some View {
        switch environment.state {
        case .opening:
            // One frame of nothing beats a spinner that promises slowness.
            Color.clear

        case .ready(let services):
            MobileRootView()
                .appServices(services)

        case .failed(let error):
            MobileFailureView(error: error) {
                environment.retry()
            }
        }
    }
}
