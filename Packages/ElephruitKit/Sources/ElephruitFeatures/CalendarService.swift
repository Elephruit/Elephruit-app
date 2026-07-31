import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
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
///
/// ### What it owns
/// Authorisation, the list of calendars, the events for the window on screen, the active Calendar
/// Set, the display time zone, and every write. What it deliberately does not own is *navigation* —
/// which day is showing, which view — because that is per-window and two windows should be able to
/// look at different weeks. See ``CalendarWorkspaceModel``.
@Observable
@MainActor
public final class CalendarService {
    /// Whether the user has turned the feature on. Persisted per device — a preference, not content.
    public private(set) var isEnabled: Bool

    public private(set) var authorization: IntegrationAuthorization = .notRequested

    /// Every calendar configured on this Mac.
    public private(set) var calendars: [CalendarInfo] = []

    /// Events for the window the interface is currently showing.
    public private(set) var events: [CalendarEventSummary] = []

    public private(set) var isLoading = false

    /// Whether what is on screen came from the cache rather than from EventKit.
    ///
    /// Surfaced rather than hidden: a calendar showing last week's reading with no sign of it is
    /// worse than one that says "showing what was last read".
    public private(set) var isShowingCachedEvents = false

    /// The most recent write failure, shown once and then cleared.
    public var lastWriteFailure: CalendarWriteFailure?

    /// Saved ways of looking at the calendar.
    public private(set) var sets: [CalendarSetDefinition] = []

    /// The set currently applied, or `nil` for "everything".
    public private(set) var activeSet: CalendarSetDefinition?

    /// The zone the grid is drawn in, and any second zone beside it.
    public var timeZoneDisplay: TimeZoneDisplay {
        didSet { saveTimeZoneDisplay() }
    }

    private var provider: any CalendarProviding
    private let makeProvider: @Sendable () -> any CalendarProviding
    private let dateProvider: any DateProvider
    private let defaults: UserDefaults

    /// The cache and index. `nil` in the lightest tests, where nothing is being searched.
    private let index: (any CalendarSearching)?

    /// Saved sets and templates. `nil` before a store is open.
    private let setService: CalendarSetService?

    /// Which events have something attached, for the dot on a row.
    private let annotations: EventAnnotationService?

    private var watchTask: Task<Void, Never>?
    private var loadedRange: Range<Date>?

    static let enabledKey = "calendar.isEnabled"
    static let displayZoneKey = "calendar.displayTimeZone"
    static let secondaryZoneKey = "calendar.secondaryTimeZone"
    static let favouriteZonesKey = "calendar.favouriteTimeZones"
    static let travellingKey = "calendar.isTravelling"

    public init(
        dateProvider: any DateProvider,
        defaults: UserDefaults = .standard,
        index: (any CalendarSearching)? = nil,
        sets: CalendarSetService? = nil,
        annotations: EventAnnotationService? = nil,
        makeProvider: @escaping @Sendable () -> any CalendarProviding
    ) {
        self.dateProvider = dateProvider
        self.defaults = defaults
        self.index = index
        self.setService = sets
        self.annotations = annotations
        self.makeProvider = makeProvider

        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled

        // The device zone comes from the injected calendar rather than from `TimeZone.current`.
        // In production they are the same thing; in a test they are not, and reading the machine's
        // zone there means the grid is laid out on different day boundaries from the ones the test
        // is asserting against — which is a failure that looks like a date bug and is really a
        // dependency-injection one.
        self.timeZoneDisplay = TimeZoneDisplay(
            deviceZoneIdentifier: dateProvider.calendar.timeZone.identifier,
            displayZoneIdentifier: defaults.string(forKey: Self.displayZoneKey),
            secondaryZoneIdentifier: defaults.string(forKey: Self.secondaryZoneKey),
            favouriteZoneIdentifiers: defaults.stringArray(forKey: Self.favouriteZonesKey) ?? [],
            isTravelling: defaults.bool(forKey: Self.travellingKey)
        )

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
            await refreshCalendars()
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
    ///
    /// The cache is emptied too, for the same reason and one more: it holds titles and locations from
    /// somebody's calendar, and "I turned that off" should mean the app is no longer holding them.
    public func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)

        watchTask?.cancel()
        watchTask = nil
        provider = NoCalendarProvider()
        events = []
        calendars = []
        loadedRange = nil
        authorization = .notRequested
        isShowingCachedEvents = false

        if let index {
            Task { await index.invalidate() }
        }
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
            // Revoked while running. Fall back to the cache rather than pretending the calendar is
            // empty — what was read before the permission went away is still true.
            Diagnostics.integrations.info("Calendar access was revoked while running")
            await loadFromCache()
        }
    }

    /// Starts watching if the feature was already on when the app launched.
    public func start() async {
        await refreshSets()

        guard isEnabled else { return }

        authorization = await provider.authorization
        guard authorization.canRead else {
            await loadFromCache()
            return
        }

        await refreshCalendars()
        watchForChanges()
        await reload()
    }

    // MARK: - Calendars

    public func refreshCalendars() async {
        guard isEnabled, authorization.canRead else { return }
        calendars = await provider.calendars()
    }

    public func calendar(withIdentifier identifier: String?) -> CalendarInfo? {
        guard let identifier else { return nil }
        return calendars.first { $0.id == identifier }
    }

    /// Calendars grouped by the account that holds them, in display order.
    public var calendarsByAccount: [(account: String, calendars: [CalendarInfo])] {
        let grouped = Dictionary(grouping: calendars, by: \.accountName)
        return grouped
            .sorted { $0.key < $1.key }
            .map { (account: $0.key.isEmpty ? "Other" : $0.key, calendars: $0.value) }
    }

    /// Where a new event lands: the active set's choice, then the system default, then anything
    /// writable.
    public var defaultCalendarIdentifier: String? {
        if let chosen = activeSet?.defaultCalendar?.resolve(among: calendars), chosen.allowsModification {
            return chosen.id
        }
        if let system = calendars.first(where: { $0.isDefaultForNewEvents && $0.allowsModification }) {
            return system.id
        }
        return calendars.first { $0.allowsModification }?.id
    }

    /// A lookup from identifier to title, for the confirmation sheet's sentence.
    public var calendarNames: [String: String] {
        Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0.title) })
    }

    /// The identifiers the active set restricts to, or `nil` for everything.
    public var visibleCalendarIdentifiers: [String]? {
        activeSet?.calendarIdentifiers(among: calendars)
    }

    // MARK: - Sets

    public func refreshSets() async {
        guard let setService else { return }
        do {
            sets = try setService.sets()
            activeSet = try setService.activeSet()
        } catch {
            Diagnostics.features.error("Calendar sets unreadable: \(error.summary, privacy: .public)")
            sets = []
            activeSet = nil
        }
    }

    /// Switches to a set and reloads what it makes visible.
    public func activate(setID: UUID?) async {
        setService?.setActive(setID)
        await refreshSets()
        await reload()
    }

    /// The set after this one, for cycling from the keyboard.
    public func setAfterActive() -> CalendarSetDefinition? {
        guard !sets.isEmpty else { return nil }
        guard let active = activeSet, let index = sets.firstIndex(where: { $0.id == active.id }) else {
            return sets.first
        }
        // Past the last set is "everything", which is a real state and part of the cycle rather than
        // something a person has to leave the keyboard to get back to.
        return index + 1 < sets.count ? sets[index + 1] : nil
    }

    // MARK: - Reading

    /// Loads events for a window, if the feature is on and permitted.
    public func load(range: Range<Date>) async {
        loadedRange = range
        await reload()
    }

    private func reload() async {
        guard isEnabled, let range = loadedRange else {
            events = []
            isShowingCachedEvents = false
            return
        }

        guard authorization.canRead else {
            await loadFromCache()
            return
        }

        isLoading = true
        defer { isLoading = false }

        let identifiers = visibleCalendarIdentifiers
        let fetched = await provider.events(in: range, calendarIdentifiers: identifiers)

        events = applyingSetRules(to: fetched)
        isShowingCachedEvents = false

        await absorbIntoIndex(fetched, window: range)
    }

    /// Falls back to what was last read.
    private func loadFromCache() async {
        guard let index, let range = loadedRange else {
            events = []
            return
        }

        let cached = await index.cachedEvents(in: range, calendarIdentifiers: visibleCalendarIdentifiers)
        events = applyingSetRules(to: cached.map(Self.summary(from:)))
        isShowingCachedEvents = !events.isEmpty
    }

    /// Turns a cached row back into the shape the interface draws.
    ///
    /// Lossy on purpose: the cache holds what a row needs, not what an editor does. Anything opening
    /// an event for editing re-reads it from EventKit, which is the only place the full record lives.
    static func summary(from indexed: IndexedEvent) -> CalendarEventSummary {
        CalendarEventSummary(
            identity: indexed.identity,
            title: indexed.title,
            startAt: indexed.startAt,
            endAt: indexed.endAt,
            isAllDay: indexed.isAllDay,
            calendarIdentifier: indexed.calendarIdentifier,
            calendarName: indexed.calendarName,
            calendarColorName: indexed.calendarColorName,
            accountName: indexed.accountName,
            locationName: indexed.locationName,
            notes: indexed.notesExcerpt.isEmpty ? nil : indexed.notesExcerpt,
            status: indexed.isCancelled ? .cancelled : .confirmed,
            participation: indexed.isDeclined ? .declined : .unknown,
            attendees: indexed.attendeeNames.map { EventAttendee(name: $0) },
            isRecurring: indexed.isRecurring,
            // A cached event is never offered for editing without being re-read, and saying it is
            // editable when the app cannot currently reach the calendar would be a lie.
            isEditable: false
        )
    }

    /// The rules the active set applies to what is shown.
    private func applyingSetRules(to events: [CalendarEventSummary]) -> [CalendarEventSummary] {
        guard activeSet?.hidesDeclinedEvents ?? true else { return events }
        return events.filter(\.appearsInPlan)
    }

    /// Events happening on a given day, in plan order.
    public func events(on date: Date) -> [CalendarEventSummary] {
        events.filter { $0.occurs(on: date, calendar: displayCalendar) && $0.appearsInPlan }
    }

    /// The calendar to lay out with: the user's own, in the display zone.
    public var displayCalendar: Calendar {
        timeZoneDisplay.calendar(basedOn: dateProvider.calendar)
    }

    /// Looks a stored link back up in the calendar.
    public func event(matching identity: EventIdentity) async -> CalendarEventSummary? {
        guard isEnabled, authorization.canRead else {
            // The cache still knows what it was, which is what keeps a linked meeting readable when
            // the calendar is off.
            guard let index, let range = loadedRange else { return nil }
            let cached = await index.cachedEvents(in: range, calendarIdentifiers: nil)
            return cached.first { $0.identity == identity }.map(Self.summary(from:))
        }
        return await provider.event(matching: identity)
    }

    // MARK: - Writing

    /// Creates an event.
    ///
    /// The caller is responsible for having asked whatever ``EventDraft/confirmationsRequired(replacing:calendarNames:)``
    /// demanded — creation demands nothing, since a new event replaces nothing.
    @discardableResult
    public func create(_ draft: EventDraft) async -> Result<CalendarEventSummary, CalendarWriteFailure> {
        let outcome = await provider.createEvent(draft)

        switch outcome {
        case .success(let event):
            await absorbSingle(event)
            await reload()
        case .failure(let failure):
            lastWriteFailure = failure
        }
        return outcome
    }

    /// Applies a draft to an event that already exists.
    @discardableResult
    public func update(
        _ identity: EventIdentity,
        with draft: EventDraft,
        scope: EventEditScope
    ) async -> Result<CalendarEventSummary, CalendarWriteFailure> {
        let outcome = await provider.updateEvent(matching: identity, with: draft, scope: scope)

        switch outcome {
        case .success(let event):
            await absorbSingle(event)
            await reload()
        case .failure(let failure):
            lastWriteFailure = failure
        }
        return outcome
    }

    /// Moves an event by dragging, keeping its length.
    ///
    /// A separate entry point from ``update(_:with:scope:)`` because a drag has no editor open and
    /// no draft in hand — and because it is the one write that can happen by accident, so it is worth
    /// having one place that decides what a drag is allowed to do.
    @discardableResult
    public func move(
        _ event: CalendarEventSummary,
        to newStart: Date,
        scope: EventEditScope
    ) async -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard event.isEditable else {
            let failure = CalendarWriteFailure.calendarReadOnly(title: event.calendarName ?? "That calendar")
            lastWriteFailure = failure
            return .failure(failure)
        }

        var draft = EventDraft(editing: event)
        draft.move(to: newStart)
        return await update(event.identity, with: draft, scope: scope)
    }

    /// Changes an event's end by dragging its lower edge.
    @discardableResult
    public func resize(
        _ event: CalendarEventSummary,
        newEnd: Date,
        scope: EventEditScope
    ) async -> Result<CalendarEventSummary, CalendarWriteFailure> {
        guard event.isEditable else {
            let failure = CalendarWriteFailure.calendarReadOnly(title: event.calendarName ?? "That calendar")
            lastWriteFailure = failure
            return .failure(failure)
        }

        var draft = EventDraft(editing: event)
        draft.setDuration(newEnd.timeIntervalSince(event.startAt))
        return await update(event.identity, with: draft, scope: scope)
    }

    @discardableResult
    public func delete(
        _ identity: EventIdentity,
        scope: EventEditScope
    ) async -> Result<Void, CalendarWriteFailure> {
        let outcome = await provider.deleteEvent(matching: identity, scope: scope)

        switch outcome {
        case .success:
            await index?.forget(identityKey: identity.storageKey)
            await reload()
        case .failure(let failure):
            lastWriteFailure = failure
        }
        return outcome
    }

    /// What has to be confirmed before a draft replaces an event.
    public func confirmations(
        for draft: EventDraft,
        replacing event: CalendarEventSummary
    ) -> [EventChangeConfirmation] {
        draft.confirmationsRequired(replacing: event, calendarNames: calendarNames)
    }

    // MARK: - The index

    private func absorbIntoIndex(_ events: [CalendarEventSummary], window: Range<Date>) async {
        guard let index else { return }
        let links = linkSnapshot(for: events)
        await index.absorb(events, inWindow: window, links: links)
    }

    private func absorbSingle(_ event: CalendarEventSummary) async {
        guard let index else { return }
        await index.absorb(event, links: linkSnapshot(for: [event])[event.identity.storageKey])
    }

    /// What Elephruit has attached to each of these events, in the shape the index stores.
    ///
    /// Read here rather than inside the index because the store is main-actor-bound and the index is
    /// an actor of its own — so the values cross the boundary, never the models.
    private func linkSnapshot(for events: [CalendarEventSummary]) -> [String: IndexedEventLinks] {
        guard let annotations else { return [:] }

        do {
            let found = try annotations.annotations(for: events.map(\.identity))
            var snapshot: [String: IndexedEventLinks] = [:]

            for (key, annotation) in found {
                snapshot[key] = IndexedEventLinks(
                    identityKey: key,
                    personNames: titles(of: annotation.personIDs),
                    noteTitles: titles(of: annotation.noteIDs),
                    projectTitles: titles(of: annotation.projectIDs),
                    hasAttachments: annotation.attachmentCount > 0
                )
            }
            return snapshot
        } catch {
            Diagnostics.features.error("Event links unreadable: \(error.summary, privacy: .public)")
            return [:]
        }
    }

    /// Resolved by the owner, which holds the repository. Set once at composition.
    var titleResolver: ((UUID) -> String?)?

    private func titles(of ids: [UUID]) -> [String] {
        guard let titleResolver else { return [] }
        return ids.compactMap(titleResolver)
    }

    // MARK: - Time zones

    /// Adds or removes a favourite zone.
    public func toggleFavourite(zoneIdentifier: String) {
        var display = timeZoneDisplay
        if let index = display.favouriteZoneIdentifiers.firstIndex(of: zoneIdentifier) {
            display.favouriteZoneIdentifiers.remove(at: index)
        } else {
            display.favouriteZoneIdentifiers.append(zoneIdentifier)
        }
        timeZoneDisplay = display
    }

    /// Draws the calendar in another zone, without moving a single event.
    public func showTimes(in zoneIdentifier: String?) {
        var display = timeZoneDisplay
        display.displayZoneIdentifier = zoneIdentifier
        timeZoneDisplay = display
    }

    /// Turns travel mode on, which shows the destination's times and says so.
    public func setTravelling(_ travelling: Bool, destinationZone: String?) {
        var display = timeZoneDisplay
        display.isTravelling = travelling
        display.displayZoneIdentifier = travelling ? destinationZone : nil
        timeZoneDisplay = display
    }

    private func saveTimeZoneDisplay() {
        defaults.set(timeZoneDisplay.displayZoneIdentifier, forKey: Self.displayZoneKey)
        defaults.set(timeZoneDisplay.secondaryZoneIdentifier, forKey: Self.secondaryZoneKey)
        defaults.set(timeZoneDisplay.favouriteZoneIdentifiers, forKey: Self.favouriteZonesKey)
        defaults.set(timeZoneDisplay.isTravelling, forKey: Self.travellingKey)
    }

    // MARK: - Changes

    /// Re-reads whenever the calendar database changes.
    ///
    /// An edit made in Calendar.app should appear here without the user having to do anything, and
    /// `EKEventStoreChanged` is how that arrives. Coalesced, because a sync can deliver a burst of
    /// them and re-reading a month per notification is how a background sync becomes a beachball.
    private func watchForChanges() {
        watchTask?.cancel()
        let stream = provider.changes

        watchTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }

                await refreshCalendars()
                await reload()
            }
        }
    }
}
