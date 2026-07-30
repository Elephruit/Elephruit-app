import ElephruitCore
import ElephruitFeatures
import ElephruitPersistence
import Foundation
import Observation

/// The composition root.
///
/// The one place in the app that decides which concrete implementations are used. Nothing else
/// constructs a store, a repository, or a search engine; nothing anywhere reaches for a singleton.
///
/// It also owns the *outcome* of opening the store, which is why it holds a state enum rather than a
/// non-optional ``AppServices``: a store that will not open is a state the interface has to render,
/// not a reason to crash. See `docs/05-cloudkit-and-migrations.md` for the bootstrap sequence.
@Observable
@MainActor
final class AppEnvironment {
    enum State {
        /// The store is opening. Brief, but real — and rendering something for it beats a blank window.
        case opening

        /// Ready.
        case ready(AppServices)

        /// The store could not be opened or migrated. Recoverable; the shell shows the failure state
        /// with the recovery options the error itself defines.
        case failed(AppError)
    }

    private(set) var state: State = .opening

    /// Whether developer affordances are available.
    ///
    /// A launch argument, not a build configuration, so a release build can be inspected when needed
    /// without shipping a menu item that plants sample data in a real library. Set
    /// `-ElephruitDevelopmentMode YES` in the scheme's arguments.
    private let isDevelopmentMode: Bool

    init() {
        isDevelopmentMode = ProcessInfo.processInfo.arguments.contains("-ElephruitDevelopmentMode")
            || UserDefaults.standard.bool(forKey: "ElephruitDevelopmentMode")
    }

    /// Opens the store and builds the services.
    ///
    /// Idempotent, so the retry recovery option can simply call it again.
    func start() {
        state = .opening

        // A UI test needs a clean, isolated library that leaves the real one untouched.
        let useTemporaryStore = ProcessInfo.processInfo.arguments.contains("-ElephruitUseTemporaryStore")

        do {
            let location = useTemporaryStore
                ? StoreLocation.temporary(name: "UITests")
                : try StoreLocation.application()

            let stack = try PersistenceStack.open(mode: .onDisk(location))
            let services = AppServices(
                stack: stack,
                dateProvider: SystemDateProvider(),
                isDevelopmentMode: isDevelopmentMode
            )

            state = .ready(services)

            Diagnostics.shell.info(
                "Environment ready, development mode \(self.isDevelopmentMode, privacy: .public)"
            )
        } catch {
            Diagnostics.shell.error("Environment failed to start: \(String(describing: error), privacy: .public)")
            state = .failed(error)
        }
    }

    var services: AppServices? {
        if case .ready(let services) = state { return services }
        return nil
    }
}
