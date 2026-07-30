import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The calendar, as the rest of the app sees it.
///
/// ### Off until asked for
/// Calendar access is a **preference**, stored per-device, and it starts off. Until it is turned on
/// the app holds a `NoCalendarProvider` and never touches EventKit — no prompt appears, no
/// entitlement is exercised, and every view runs the same code path it would with an empty calendar.
///
/// That ordering matters: a permission dialogue on first launch, before anyone has decided the
/// feature is wanted, is the thing that gets an app denied permanently.
@Observable
@MainActor
public final class CalendarService {
    /// Whether the user has turned the feature on. Persisted per device — a preference, not content.
    public private(set) var isEnabled: Bool

    public private(set) var authorization: IntegrationAuthorization = .notRequested

    /// Events for the window the interface is currently showing.
    public private(set) var events: [CalendarEventSummary] = []

    public private(set) var isLoading = false

    private var provider: any CalendarProviding
    private let makeProvider: @Sendable () -> any CalendarProviding
    private let dateProvider: any DateProvider
    private let defaults: UserDefaults

    private var watchTask: Task<Void, Never>?
    private var loadedRange: Range<Date>?

    static let enabledKey = "calendar.isEnabled"

    public init(
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard,
        makeProvider: @escaping @Sendable () -> any CalendarProviding
    ) {
        self.dateProvider = dateProvider
        self.defaults = defaults
        self.makeProvider = makeProvider
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled

        // The inert provider until enabled, so nothing reaches EventKit by accident.
        self.provider = enabled ? makeProvider() : NoCalendarProvider()
    }

    // MARK: - Enabling

    /// Turns the feature on and asks for access, in that order.
    ///
    /// Returns the resulting authorisation so the caller can explain a refusal rather than silently
    /// showing an empty calendar.
    @discardableResult
    public func enable() async -> IntegrationAuthorization {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)

        provider = makeProvider()
        authorization = await provider.requestAccess()

        if authorization.canRead {
            watchForChanges()
            await reload()
        }
        return authorization
    }

    /// Turns it off and forgets what was read.
    ///
    /// The events are dropped rather than left on screen: the user has said they do not want their
    /// calendar here, and a stale copy of it lingering would be exactly the wrong answer. macOS keeps
    /// the *permission* — only System Settings can revoke that, and the interface says so.
    public func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)

        watchTask?.cancel()
        watchTask = nil
        provider = NoCalendarProvider()
        events = []
        loadedRange = nil
        authorization = .notRequested
    }

    /// Re-reads the authorisation, without prompting.
    ///
    /// Called when the app becomes active, because permission can be revoked in System Settings while
    /// the app is running and the first sign of it should not be a silently empty day.
    public func refreshAuthorization() async {
        guard isEnabled else { return }

        let current = await provider.authorization
        let wasReadable = authorization.canRead
        authorization = current

        if wasReadable, !current.canRead {
            // Revoked while running. Degrade to an explained state rather than pretending the
            // calendar is empty.
            events = []
            loadedRange = nil
            Diagnostics.integrations.info("Calendar access was revoked while running")
        }
    }

    // MARK: - Reading

    /// Loads events for a window, if the feature is on and permitted.
    public func load(range: Range<Date>) async {
        loadedRange = range
        await reload()
    }

    private func reload() async {
        guard isEnabled, authorization.canRead, let range = loadedRange else {
            events = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        events = await provider.events(in: range)
    }

    /// Events happening on a given day, in plan order, excluding ones the user declined.
    public func events(on date: Date) -> [CalendarEventSummary] {
        events.filter { $0.occurs(on: date, calendar: dateProvider.calendar) && $0.appearsInPlan }
    }

    /// Looks a stored link back up in the calendar.
    public func event(matching identity: EventIdentity) async -> CalendarEventSummary? {
        guard isEnabled, authorization.canRead else { return nil }
        return await provider.event(matching: identity)
    }

    // MARK: - Changes

    /// Re-reads whenever the calendar database changes.
    ///
    /// An edit made in Calendar.app should appear here without the user having to do anything, and
    /// `EKEventStoreChanged` is how that arrives.
    private func watchForChanges() {
        watchTask?.cancel()
        let stream = provider.changes

        watchTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await reload()
            }
        }
    }

    /// Starts watching if the feature was already on when the app launched.
    public func start() async {
        guard isEnabled else { return }

        authorization = await provider.authorization
        guard authorization.canRead else { return }

        watchForChanges()
        await reload()
    }
}
