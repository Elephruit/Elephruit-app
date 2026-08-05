import ElephruitCore
import ElephruitFeaturesCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The iPhone app's composition root.
///
/// The same job, the same order, and the same launch arguments as the Mac's `AppEnvironment`,
/// because the store, the services, and the QA tooling are the same code — what differs is
/// everything the Mac type does *besides* booting: global hotkeys, floating panels, menu bar
/// extras. None of those exist here, so this type is only the boot.
///
/// ### The launch arguments are the test harness
/// `-ElephruitDevelopmentMode -ElephruitUseTemporaryStore -ElephruitUseFixtureCalendar …`
/// launch the app against a throwaway store and fictional providers, exactly as the macOS
/// design-review sessions do. Screenshots and UI tests use these; a release build ignores
/// them entirely, so the app can never start authorized against fiction in the field.
@Observable
@MainActor
final class MobileAppEnvironment {
    enum State {
        case opening
        case ready(AppServices)
        case failed(AppError)
    }

    private(set) var state: State = .opening

    /// Whether the QA/launch-argument switches are honoured this run.
    private let isDevelopmentMode: Bool

    init() {
        // Simulator and debug builds accept the switches; a release build on a device does not.
        #if targetEnvironment(simulator) || DEBUG
            isDevelopmentMode = ProcessInfo.processInfo.arguments.contains("-ElephruitDevelopmentMode")
        #else
            isDevelopmentMode = false
        #endif
    }

    var services: AppServices? {
        if case .ready(let services) = state { return services }
        return nil
    }

    /// Opens the store and builds the service graph. Synchronous, deliberately: the work is
    /// one SQLite open plus object construction, and a launch screen that resolves in one
    /// frame beats a spinner that promises the app is slower than it is.
    func start() {
        guard case .opening = state else { return }

        let arguments = ProcessInfo.processInfo.arguments

        do {
            let stack: PersistenceStack

            /// Where per-device preferences live for this run.
            ///
            /// ### Why a temporary store implies temporary preferences
            /// Because half an isolated launch is worse than none. `-ElephruitUseTemporaryStore`
            /// promises a run that leaves nothing behind, and it was keeping that promise for the
            /// library and breaking it for every switch: a UI test that turned free time off left it
            /// off for the *next* test, which then failed for a reason that was nowhere in its own
            /// code. Three runs went into finding that, which is three more than the bug is worth to
            /// anybody who meets it next.
            ///
            /// One fixed suite, wiped at launch, rather than a fresh name each time — a new suite per
            /// run would leave a plist behind on every launch and never collect them.
            var preferences: UserDefaults = .standard

            if isDevelopmentMode, arguments.contains("-ElephruitUseTemporaryStore") {
                let location = StoreLocation.temporary(name: "MobileDevelopment-\(UUID().uuidString)")
                stack = try PersistenceStack.open(mode: .onDisk(location))

                let suiteName = "com.elephruit.development"
                if let scratch = UserDefaults(suiteName: suiteName) {
                    scratch.removePersistentDomain(forName: suiteName)
                    preferences = scratch
                }
            } else {
                let location = try StoreLocation.application()
                // The setting asks; the stack decides — same line, same rule as the Mac.
                stack = try PersistenceStack.open(
                    mode: .onDisk(location),
                    syncEnabled: SyncSetting.isEnabled()
                )
            }

            let fixturesAuthorized = isDevelopmentMode && arguments.contains("-ElephruitFixturesAuthorized")
            let fixtureAuthorization: IntegrationAuthorization = fixturesAuthorized ? .authorized : .notRequested

            var contactsProvider: (@Sendable () -> any ContactsProviding)?
            var calendarProvider: (@Sendable () -> any CalendarProviding)?
            var remindersProvider: (@Sendable () -> any RemindersProviding)?
            var routeProvider: (@Sendable () -> any RouteProviding)?

            if isDevelopmentMode, arguments.contains("-ElephruitUseFixtureContacts") {
                contactsProvider = {
                    FixtureContactsProvider(
                        contacts: ContactFixtures.library,
                        containers: ContactFixtures.containers,
                        authorization: fixtureAuthorization
                    )
                }
            }
            if isDevelopmentMode, arguments.contains("-ElephruitUseFixtureCalendar") {
                calendarProvider = { FixtureCalendarProvider(authorization: fixtureAuthorization) }
            }
            if isDevelopmentMode, arguments.contains("-ElephruitUseFixtureReminders") {
                remindersProvider = { FixtureRemindersProvider(authorization: fixtureAuthorization) }
            }
            // Without this the travel feature cannot be looked at: a simulator has no location and
            // no route to anywhere, so the real adapter answers "no" to everything and the page
            // shows the told number forever — which is indistinguishable from the feature not
            // being wired up at all.
            if isDevelopmentMode, arguments.contains("-ElephruitUseFixtureRoutes") {
                routeProvider = { FixtureRouteProvider(authorization: fixtureAuthorization) }
            }

            let services = AppServices(
                stack: stack,
                dateProvider: SystemDateProvider(),
                isDevelopmentMode: isDevelopmentMode,
                contactsProvider: contactsProvider,
                calendarProvider: calendarProvider,
                remindersProvider: remindersProvider,
                routeProvider: routeProvider,
                defaults: preferences
            )

            if isDevelopmentMode, arguments.contains("-ElephruitLoadSampleData") {
                services.loadSampleDataIfEmpty()
            }
            if isDevelopmentMode, arguments.contains("-ElephruitLoadMeetingSampleData") {
                services.loadMeetingSampleData()
            }
            if isDevelopmentMode,
                let index = arguments.firstIndex(of: "-ElephruitPeopleCount"),
                let count = arguments.dropFirst(index + 1).first.flatMap({ Int($0) }) {
                services.seedPeople(upTo: count)
            }

            // The Mac's `RootView` calls the same method for the same reasons, and calling
            // `timer.start()` directly here was a quiet divergence: the phone got a ticking
            // clock, but not the stored focus lengths and not the calendar mirror's hook on a
            // finished entry. Two apps sharing a store must not disagree about what stopping a
            // timer does.
            services.startTimeTracking()
            Task { await services.warmSearchIndex() }
            // Everything derived is computed on change and never during a render; at launch
            // this is the change. Without it the project tree and the badges start empty —
            // the exact "no projects until you create one" failure the Mac shell fixed.
            services.refreshDerivedState()

            // A fixture calendar that starts authorized should also start *enabled* —
            // the flag exists to photograph the working state without a hand reaching
            // for the toggle first. Real providers are never enabled this way.
            if isDevelopmentMode, fixturesAuthorized {
                if calendarProvider != nil {
                    Task { _ = await services.calendar.enable() }
                }
                if remindersProvider != nil {
                    Task { _ = await services.reminders.enable() }
                }
                if contactsProvider != nil {
                    Task { _ = await services.contacts.enable() }
                }
                if routeProvider != nil {
                    Task { await services.travel.enableEstimates() }
                }
            }

            state = .ready(services)
        } catch {
            state = .failed(error)
        }
    }

    /// Recovery chosen from the failure screen.
    func retry() {
        state = .opening
        start()
    }
}
