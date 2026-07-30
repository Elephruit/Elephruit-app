import AppIntents
import ElephruitCore
import ElephruitFeatures
import ElephruitPersistence
import Foundation

/// Capture from anywhere, without a global hotkey of our own.
///
/// ### Why an App Intent rather than a hotkey
/// A genuine global hotkey needs either the Accessibility permission — a large ask for a note-taking
/// app, and one that makes people uneasy for good reason — or Carbon's `RegisterEventHotKey`, which
/// works in a sandbox but is undiscoverable and collides silently with whatever else claimed the
/// combination.
///
/// An App Intent gets a **user-assigned global shortcut for free** through Shortcuts.app: the user
/// picks the key, macOS owns the conflict resolution, and Elephruit needs no extra entitlement and no
/// permission prompt at all. It also arrives in Spotlight, the Shortcuts editor, and the Services
/// menu without any further work.
///
/// The trade is that the user has to assign the shortcut once. That is a real cost, and it buys not
/// asking for Accessibility — which is the right side of that trade for this app.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Elephruit"

    static let description = IntentDescription(
        "Adds a note or task to your Inbox, parsing due dates, tags and links as Quick Capture does.",
        categoryName: "Capture"
    )

    /// Runs without bringing the app forward.
    ///
    /// The point of capture is not to interrupt what you were doing. An intent that stole focus
    /// would be a slower version of switching to the app by hand.
    static let openAppWhenRun = false

    @Parameter(title: "Text", requestValueDialog: "What do you want to capture?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing to capture.")
        }

        // Its own stack, because the app may not be running. Capture has to work from a cold start,
        // which is most of when it is useful.
        let services = try CaptureBridge.services()

        guard let item = try services.capture.capture(text: trimmed) else {
            return .result(dialog: "Nothing to capture.")
        }

        return .result(dialog: "Added “\(item.displayTitle)” to your Inbox.")
    }
}

/// Opens a library for an intent running outside the app.
///
/// ### Why this is not just `AppEnvironment`
/// An intent can run while Elephruit is not, so it cannot borrow the app's already-open container —
/// and if the app *is* running, opening a second writable container on the same file would be two
/// writers on one SQLite store.
///
/// SwiftData and Core Data handle that correctly through file coordination, and the capture path is a
/// single small insert, so the risk is bounded. What is not bounded is doing it repeatedly, so the
/// stack is built once per process and reused.
@MainActor
enum CaptureBridge {
    private static var cached: AppServices?

    static func services() throws -> AppServices {
        if let cached { return cached }

        let location = try StoreLocation.application()
        let stack = try PersistenceStack.open(mode: .onDisk(location))
        let services = AppServices(stack: stack)
        cached = services
        return services
    }

    /// Called by the app once its own services exist, so an intent running in the same process uses
    /// the container that is already open rather than a second one.
    static func adopt(_ services: AppServices) {
        cached = services
    }
}

/// Makes the intent discoverable without the user going looking for it.
struct ElephruitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Add a note to \(.applicationName)",
                "New \(.applicationName) task",
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
    }
}
