import ElephruitCore
import ElephruitFeaturesCore
import SwiftUI

/// The iPhone and iPad app.
///
/// One shell per window, chosen by width — `AdaptiveRootView` is where that choice and the handoff
/// between the two live. The Mac's other scenes are desktop furniture; their jobs live inside the
/// shell here (the timer accessory, the capture button, a Settings screen in the sidebar), except
/// the keyboard, which the iPad genuinely has: `ElephruitMobileCommands` puts the Mac's own
/// shortcut registry behind the ⌘-hold overlay.
@main
struct ElephruitMobileApp: App {
    @State private var environment = MobileAppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileRootWindow(environment: environment)
                .task { environment.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Backgrounding is the phone's "the machine may vanish now": pending editor
                    // debounces are flushed so nothing typed is lost to a suspension, exactly as
                    // the Mac flushes before quit.
                    if phase == .background || phase == .inactive {
                        environment.services?.flushForSuspension()
                    }
                }
        }
        .commands { ElephruitMobileCommands() }

        // A second window, opened onto one record — the iPad's answer to the Mac's "Open in New
        // Window". Only the sidebar offers it, and only where the platform supports more than one
        // window, so a phone never advertises a scene it cannot show.
        WindowGroup(for: MobileRoute.self) { route in
            MobileRootWindow(environment: environment, initialRoute: route.wrappedValue)
                .task { environment.start() }
        }
    }
}

/// Switches on the boot outcome, exactly as the Mac's `RootWindow` does.
private struct MobileRootWindow: View {
    let environment: MobileAppEnvironment
    var initialRoute: MobileRoute?

    var body: some View {
        switch environment.state {
        case .opening:
            // One frame of nothing beats a spinner that promises slowness.
            Color.clear

        case .ready(let services):
            AdaptiveRootView(initialRoute: initialRoute)
                .appServices(services)

        case .failed(let error):
            MobileFailureView(error: error) {
                environment.retry()
            }
        }
    }
}
