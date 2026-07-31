import ElephruitCore
import ElephruitIntegrations
import ElephruitFeatures
import ElephruitPersistence
import AppKit
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

    /// The floating capture panel, once there is a library to capture into.
    private(set) var quickJot: QuickJotController?

    /// System-wide shortcuts. Held for the life of the app, so a preference change can unregister
    /// and re-register rather than leaving a stale binding behind.
    private let hotKeys = GlobalHotKeyCenter()

    /// What the system said about each global shortcut, for Settings to report.
    private(set) var hotKeyResults: [ShortcutCommand: HotKeyRegistration] = [:]

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

        // A synthetic address book, for reviewing the Contacts import without handing the app
        // anybody's real contacts.
        //
        // The whole flow — onboarding, permission, review counts, the ambiguous match, refresh, a
        // deleted contact — is demonstrable against invented people with `example.com` addresses.
        // Gated on development mode as well as the argument, so a release build cannot be talked
        // into showing fiction where the user expects their own address book.
        let useFixtureContacts = isDevelopmentMode
            && ProcessInfo.processInfo.arguments.contains("-ElephruitUseFixtureContacts")

        // A synthetic calendar, for the same reason and on the same terms.
        //
        // The whole module — the week grid with a clashing morning, a four-day trip in the all-day
        // band, a recurring standup, a declined invitation, a read-only subscribed calendar
        // refusing an edit — is demonstrable against invented events. Gated on development mode as
        // well as the argument, so a release build can never be talked into showing fiction where
        // somebody expects their own calendar. `EKEventStore` is never constructed.
        let useFixtureCalendar = isDevelopmentMode
            && ProcessInfo.processInfo.arguments.contains("-ElephruitUseFixtureCalendar")

        do {
            let location = useTemporaryStore
                ? StoreLocation.temporary(name: "UITests")
                : try StoreLocation.application()

            let stack = try PersistenceStack.open(mode: .onDisk(location))
            // Hoisted and explicitly typed: a ternary between a closure and `nil` in an argument
            // position defeats the type checker here.
            let makeFixtureContacts: @Sendable () -> any ContactsProviding = {
                FixtureContactsProvider(
                    contacts: ContactFixtures.library,
                    containers: ContactFixtures.containers,
                    authorization: .notRequested
                )
            }
            let contactsProvider = useFixtureContacts ? makeFixtureContacts : nil

            let makeFixtureCalendar: @Sendable () -> any CalendarProviding = {
                FixtureCalendarProvider()
            }
            let calendarProvider = useFixtureCalendar ? makeFixtureCalendar : nil

            let services = AppServices(
                stack: stack,
                dateProvider: SystemDateProvider(),
                isDevelopmentMode: isDevelopmentMode,
                contactsProvider: contactsProvider,
                calendarProvider: calendarProvider
            )

            if useFixtureContacts {
                Diagnostics.features.info("Using a synthetic address book; no real contacts are read")
            }
            if useFixtureCalendar {
                Diagnostics.features.info("Using a synthetic calendar; no real events are read or written")
            }

            // An intent firing in this process now uses the container that is already open, rather
            // than opening a second writable one on the same SQLite file. `CaptureBridge` was
            // written for this and the call was never made, so the failure it exists to prevent was
            // live for as long as the intent has shipped.
            CaptureBridge.adopt(services)

            let quickJot = QuickJotController(services: services)
            self.quickJot = quickJot
            registerGlobalShortcuts(for: services)

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

    // MARK: - Reaching the calendar from outside a window

    /// What the menu bar and the intents have asked the calendar to do.
    ///
    /// A published request rather than a direct call, because neither the menu bar nor an intent has
    /// a window to act on: the window may not exist yet, and there may be several. The workspace
    /// picks the request up when it next renders, which is also what makes it work when the app was
    /// launched *by* the intent.
    private(set) var pendingCalendarRequest: CalendarRequest?

    typealias CalendarRequest = PendingCalendarRequest

    func openCalendar() {
        pendingCalendarRequest = .open
        NSApplication.shared.activate()
    }

    func openCalendarQuickEntry() {
        pendingCalendarRequest = .quickEntry
        NSApplication.shared.activate()
    }

    /// Opens the calendar on a particular day — the shape a deep link arrives in.
    func openCalendar(on day: Date) {
        pendingCalendarRequest = .day(day)
        NSApplication.shared.activate()
    }

    /// Consumed by the window that acted on it, so a request cannot fire twice.
    func consumeCalendarRequest() -> CalendarRequest? {
        defer { pendingCalendarRequest = nil }
        return pendingCalendarRequest
    }

    /// Picks up anything an intent left behind while the app was not frontmost.
    func adoptIntentRouting() {
        if CalendarIntentRouting.shouldOpenCalendar {
            CalendarIntentRouting.shouldOpenCalendar = false
            pendingCalendarRequest = .open
        }
        if let day = CalendarIntentRouting.requestedDay {
            CalendarIntentRouting.requestedDay = nil
            pendingCalendarRequest = .day(day)
        }
    }

    /// Offers the global shortcuts to the system and records what it said.
    ///
    /// Idempotent, so a preference change calls it again: the centre unregisters before it
    /// registers, which is what stops a stale binding surviving a rebind.
    ///
    /// A refusal is **not** an error. Another application having claimed the keys first is
    /// information the user needs, not a failure the app can fix — so it is recorded and shown in
    /// Settings rather than thrown. See ADR 0008.
    func registerGlobalShortcuts(for services: AppServices) {
        let result = hotKeys.register(
            .quickCapture,
            binding: services.shortcuts.binding(for: .quickCapture)
        ) { [weak self] in
            self?.quickJot?.show()
        }

        hotKeyResults[.quickCapture] = result

        // The calendar's quick entry, from anywhere.
        //
        // A second global shortcut rather than a mode on the first, because the two produce
        // different things and somebody reaching for one is not thinking about the other. A person
        // mid-conversation who needs to put a meeting in the calendar should not have to open a
        // capture field and then decide what kind of thing they are capturing.
        let eventResult = hotKeys.register(
            .newEvent,
            binding: services.shortcuts.binding(for: .newEvent)
        ) { [weak self] in
            self?.openCalendarQuickEntry()
        }

        hotKeyResults[.newEvent] = eventResult

        for outcome in [result, eventResult] {
            if let explanation = outcome.explanation {
                Diagnostics.shell.info("Global shortcut not taken: \(explanation, privacy: .public)")
            }
        }
    }
}
