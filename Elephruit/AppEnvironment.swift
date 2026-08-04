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

    /// Polls the tiny app-group inbox while Elephruit is open. The extension also launches the app
    /// after enqueueing, so this same path handles a cold start and a clip made beside an open app.
    private var webClipMonitor: Task<Void, Never>?

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

        // A synthetic Reminders store, on the same terms as the other two.
        //
        // `FixtureRemindersProvider` documents this flag and nothing read it, so the one integration
        // in this app that *writes* was the one that could not be exercised end to end without
        // pointing it at somebody's real reminders. It reports `.notRequested` to begin with, so
        // linking it walks the whole path — prompt, grant, list discovery, first import — rather
        // than starting halfway along it.
        let useFixtureReminders = isDevelopmentMode
            && ProcessInfo.processInfo.arguments.contains("-ElephruitUseFixtureReminders")

        // Whether the synthetic providers should start already granted.
        //
        // All three fixtures begin at `.notRequested`, which is right for exercising the permission
        // path and wrong for everything after it: the *working* state of the calendar, the address
        // book and Reminders is unreachable without a person clicking "Allow" in a dialog. That has
        // had a cost — the README records that the calendar module has never been reviewed on
        // screen in either appearance — and it makes an automated design review impossible on a
        // machine whose screen is locked.
        //
        // Gated on development mode with the rest, so no release build can start authorized against
        // fiction. It grants only the *fixtures*: with this flag and no `-ElephruitUseFixture…`
        // beside it, nothing changes, and no real store is ever constructed.
        let fixturesStartAuthorized = isDevelopmentMode
            && ProcessInfo.processInfo.arguments.contains("-ElephruitFixturesAuthorized")
        let fixtureAuthorization: IntegrationAuthorization = fixturesStartAuthorized
            ? .authorized
            : .notRequested

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
                    authorization: fixtureAuthorization
                )
            }
            let contactsProvider = useFixtureContacts ? makeFixtureContacts : nil

            let makeFixtureCalendar: @Sendable () -> any CalendarProviding = {
                FixtureCalendarProvider(authorization: fixtureAuthorization)
            }
            let calendarProvider = useFixtureCalendar ? makeFixtureCalendar : nil

            let makeFixtureReminders: @Sendable () -> any RemindersProviding = {
                FixtureRemindersProvider(authorization: fixtureAuthorization)
            }
            let remindersProvider = useFixtureReminders ? makeFixtureReminders : nil

            let services = AppServices(
                stack: stack,
                dateProvider: SystemDateProvider(),
                isDevelopmentMode: isDevelopmentMode,
                contactsProvider: contactsProvider,
                calendarProvider: calendarProvider,
                remindersProvider: remindersProvider
            )

            if useFixtureContacts {
                Diagnostics.features.info("Using a synthetic address book; no real contacts are read")
            }
            if useFixtureCalendar {
                Diagnostics.features.info("Using a synthetic calendar; no real events are read or written")
            }
            if useFixtureReminders {
                Diagnostics.features.info("Using a synthetic Reminders store; no real reminders are read or written")
            }

            // An intent firing in this process now uses the container that is already open, rather
            // than opening a second writable one on the same SQLite file. `CaptureBridge` was
            // written for this and the call was never made, so the failure it exists to prevent was
            // live for as long as the intent has shipped.
            CaptureBridge.adopt(services)

            let quickJot = QuickJotController(services: services)
            self.quickJot = quickJot
            registerGlobalShortcuts(for: services)

            // Development-only seeding, before the window renders, so a review never photographs a
            // half-populated list. Both are no-ops without their argument, and both refuse outside
            // development mode inside the service itself as well as here.
            if DesignReviewLaunch.loadsSampleData {
                services.loadSampleDataIfEmpty()

                // What the app knows about a few of the synthetic calendar's meetings — notes
                // written beforehand, something still to prepare, a linked person. Seeded here and
                // only with that calendar, because these records name events by identity: without
                // the fixture they would be rows about meetings nobody can open. See
                // `MeetingSampleData`.
                if useFixtureCalendar {
                    services.loadMeetingSampleData()
                }
            }
            if let peopleCount = DesignReviewLaunch.peopleCount {
                services.seedPeople(upTo: peopleCount)
            }
            if DesignReviewLaunch.removesSeededPeople {
                services.removeSeededPeople()
            }

            state = .ready(services)
            beginWebClipMonitoring()

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

    // MARK: - Safari web clips

    private func beginWebClipMonitoring() {
        webClipMonitor?.cancel()
        webClipMonitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.importPendingWebClips()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Imports only complete envelopes and acknowledges each after the item and its attachments are
    /// committed. Saving is idempotent, so a launch interrupted between those writes resumes the
    /// same clip rather than acknowledging a partial one or creating a duplicate.
    func importPendingWebClips() {
        guard case .ready(let services) = state else { return }

        do {
            let inbox = try WebClipInbox.applicationGroup()
            for pending in try inbox.pending() {
                do {
                    _ = try services.saveWebClip(pending.clip)
                    try inbox.acknowledge(pending)
                    Diagnostics.shell.info("Imported Safari web clip \(pending.id, privacy: .public)")
                } catch {
                    services.perform { throw error }
                    return
                }
            }
        } catch {
            // A missing app-group container is expected in unsigned package tests and previews. A
            // real malformed or unreadable envelope is retained and reported through diagnostics.
            Diagnostics.shell.debug("Safari clip inbox unavailable: \(error.localizedDescription, privacy: .public)")
        }
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

    /// Cleared by the window that acted on it, so a request cannot fire twice.
    ///
    /// Called *after* the window has acted rather than while it is rendering: consuming during a
    /// view's body is a mutation SwiftUI is entitled to run at any time and more than once.
    func clearCalendarRequest() {
        pendingCalendarRequest = nil
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

        // Starting to time something, from anywhere.
        //
        // A third global shortcut on the same terms as the other two, and the one with the strongest
        // claim of the three: a timer is wanted *at the moment work begins*, which is by definition a
        // moment somebody is looking at the work rather than at this app. Every second spent
        // switching to Elephruit to press Start is a second the entry is already wrong by, and the
        // reason people give up on time tracking is that the cost of starting exceeds the value of
        // the number. See ``QuickLogController``.
        let timerResult = hotKeys.register(
            .quickLog,
            binding: services.shortcuts.binding(for: .quickLog)
        ) { [weak services] in
            services?.quickLog.show()
        }

        hotKeyResults[.quickLog] = timerResult

        for outcome in [result, eventResult, timerResult] {
            if let explanation = outcome.explanation {
                Diagnostics.shell.info("Global shortcut not taken: \(explanation, privacy: .public)")
            }
        }
    }
}
