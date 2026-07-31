import Foundation

/// What the app asks a calendar to become.
///
/// ### Why writing has its own type
/// ``CalendarEventSummary`` is a *reading*: it carries an identity, a detached flag, an organiser,
/// and a last-modified date, none of which anyone can set. Reusing it for writes would mean an
/// editor holding a value with fields it must not touch, and the compiler would be no help at all in
/// saying which those were.
///
/// A draft holds exactly what a person may decide, and nothing else. Everything EventKit fills in
/// itself — identifiers, occurrence dates, attendees, the organiser — is absent by construction, so
/// "the app never invents an attendee" is a property of the type rather than a rule in a review
/// checklist.
public struct EventDraft: Sendable, Hashable {
    /// Which calendar the event should live in.
    ///
    /// Required. There is no "the default calendar" here: the default is resolved once, by the
    /// service, and put in the draft, so the editor always shows where the event is actually going.
    public var calendarIdentifier: String

    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool

    /// The event's time zone. `nil` writes a floating event.
    public var timeZoneIdentifier: String?

    public var location: String
    public var notes: String
    public var url: URL?
    public var availability: EventAvailability
    public var alarms: [EventAlarm]
    public var recurrence: EventRecurrence?

    public init(
        calendarIdentifier: String,
        title: String = "",
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        location: String = "",
        notes: String = "",
        url: URL? = nil,
        availability: EventAvailability = .busy,
        alarms: [EventAlarm] = [],
        recurrence: EventRecurrence? = nil
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.alarms = alarms
        self.recurrence = recurrence
    }

    /// A draft matching an event that already exists, for editing it.
    ///
    /// Everything the user may change is copied; everything they may not is left behind, which is
    /// the whole point of the two types being different.
    public init(editing event: CalendarEventSummary, calendarIdentifier: String? = nil) {
        self.init(
            calendarIdentifier: calendarIdentifier ?? event.calendarIdentifier ?? "",
            title: event.title,
            startAt: event.startAt,
            endAt: event.endAt,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: event.locationName ?? "",
            notes: event.notes ?? "",
            url: event.url,
            availability: event.availability,
            alarms: event.alarms,
            recurrence: event.recurrence
        )
    }

    public var duration: TimeInterval {
        max(0, endAt.timeIntervalSince(startAt))
    }

    public var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    /// Moves the whole event, keeping its length.
    public mutating func move(to newStart: Date) {
        let length = duration
        startAt = newStart
        endAt = newStart.addingTimeInterval(length)
    }

    /// Changes the length, never letting the end precede the start.
    public mutating func setDuration(_ seconds: TimeInterval) {
        endAt = startAt.addingTimeInterval(max(60, seconds))
    }
}

// MARK: - Validation

/// Why a draft cannot be saved yet.
///
/// Each case is something the user can act on. Nothing here is a framework failure — those arrive as
/// ``CalendarWriteFailure`` after a save has actually been attempted.
public enum EventDraftProblem: Sendable, Hashable, Identifiable, CaseIterable {
    case titleMissing
    case calendarMissing
    case calendarReadOnly
    case endsBeforeItStarts
    case zeroLength
    case implausiblyLong

    public var id: String { String(describing: self) }

    /// Whether this stops the save, as opposed to being worth mentioning.
    ///
    /// An implausibly long event is *allowed* — a six-month sabbatical is a real thing to put in a
    /// calendar — so it warns rather than blocks. Refusing it would be the app deciding it knows the
    /// user's life better than they do.
    public var blocksSaving: Bool {
        switch self {
        case .titleMissing, .implausiblyLong: false
        case .calendarMissing, .calendarReadOnly, .endsBeforeItStarts, .zeroLength: true
        }
    }

    public var message: String {
        switch self {
        case .titleMissing: "This event has no title. It will show as “Untitled event”."
        case .calendarMissing: "Choose a calendar for this event."
        case .calendarReadOnly: "That calendar cannot be changed."
        case .endsBeforeItStarts: "The end is before the start."
        case .zeroLength: "The event has no length."
        case .implausiblyLong: "This event lasts more than a year. Is that right?"
        }
    }
}

extension EventDraft {
    /// Everything wrong with this draft, worst first.
    ///
    /// - Parameter calendar: The calendar it would be saved to, when it is known. Passing `nil`
    ///   skips the read-only check rather than assuming the worst — an unknown calendar is a
    ///   different problem, and it is reported separately.
    public func problems(savingTo calendar: CalendarInfo?) -> [EventDraftProblem] {
        var found: [EventDraftProblem] = []

        if calendarIdentifier.isEmpty { found.append(.calendarMissing) }
        if let calendar, !calendar.allowsModification { found.append(.calendarReadOnly) }

        if endAt < startAt {
            found.append(.endsBeforeItStarts)
        } else if endAt == startAt, !isAllDay {
            found.append(.zeroLength)
        } else if duration > 366 * 86_400 {
            found.append(.implausiblyLong)
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.titleMissing) }

        return found
    }

    /// Whether this draft can be saved at all.
    public func canSave(to calendar: CalendarInfo?) -> Bool {
        !problems(savingTo: calendar).contains { $0.blocksSaving }
    }
}

// MARK: - Confirmation

/// A change the app will not make without asking first.
///
/// ### Why these two and not others
/// Both are changes whose *effect* is larger than the gesture that caused them. Dragging an event
/// two columns left in a week view is one movement; if those columns happen to be different
/// calendars it has also moved somebody's private appointment onto a calendar their colleagues can
/// see, and it will have done so before the pointer was released. Dragging an occurrence of a weekly
/// meeting is likewise one movement that could rewrite a year.
///
/// Everything else — retitling, adding an alarm, changing a location — is proportionate to the
/// gesture and is not interrupted.
public enum EventChangeConfirmation: Sendable, Hashable, Identifiable {
    /// The event would move from one calendar to another.
    case movingBetweenCalendars(from: String, to: String)

    /// The event is one occurrence of a series, so the scope has to be chosen.
    case changingRecurringEvent(seriesTitle: String, isDeletion: Bool)

    public var id: String {
        switch self {
        case .movingBetweenCalendars(let from, let to): "move:\(from)->\(to)"
        case .changingRecurringEvent(let title, let isDeletion): "series:\(title):\(isDeletion)"
        }
    }

    public var title: String {
        switch self {
        case .movingBetweenCalendars(_, let destination):
            "Move this event to “\(destination)”?"
        case .changingRecurringEvent(let series, let isDeletion):
            isDeletion ? "Delete “\(series)”?" : "Change “\(series)”?"
        }
    }

    public var message: String {
        switch self {
        case .movingBetweenCalendars(let origin, let destination):
            """
            This event is on “\(origin)”. Moving it to “\(destination)” changes who can see it and \
            which account it syncs through.
            """
        case .changingRecurringEvent(_, let isDeletion):
            isDeletion
                ? "This event repeats. Choose which occurrences to remove."
                : "This event repeats. Choose which occurrences to change."
        }
    }

    /// Whether the sheet has to offer a recurrence scope as well as a yes and a no.
    public var needsScopeChoice: Bool {
        if case .changingRecurringEvent = self { return true }
        return false
    }
}

extension EventDraft {
    /// What has to be confirmed before this draft replaces `original`, if anything.
    ///
    /// Pure, so the rule lives in one testable place rather than being re-decided by the week view,
    /// the month view, and the editor — which is how three surfaces end up with three behaviours.
    public func confirmationsRequired(
        replacing original: CalendarEventSummary,
        calendarNames: [String: String]
    ) -> [EventChangeConfirmation] {
        var required: [EventChangeConfirmation] = []

        if let originalCalendar = original.calendarIdentifier, originalCalendar != calendarIdentifier {
            required.append(.movingBetweenCalendars(
                from: calendarNames[originalCalendar] ?? original.calendarName ?? "another calendar",
                to: calendarNames[calendarIdentifier] ?? "this calendar"
            ))
        }

        if original.isRecurring {
            required.append(.changingRecurringEvent(seriesTitle: original.displayTitle, isDeletion: false))
        }

        return required
    }
}

// MARK: - Failure

/// Why a write did not happen.
///
/// Distinct from ``EventDraftProblem``: these are answers from the system rather than things the
/// user could have seen before pressing Save. Every case says what to do next, because "could not
/// save event" on its own leaves somebody retrying a thing that will never work.
public enum CalendarWriteFailure: Sendable, Hashable, Error {
    case notAuthorized
    case calendarNotFound(identifier: String)
    case calendarReadOnly(title: String)
    case eventNotFound
    case saveRejected(reason: String)
    case deleteRejected(reason: String)

    public var message: String {
        switch self {
        case .notAuthorized:
            "Elephruit does not have permission to change your calendar."
        case .calendarNotFound:
            "That calendar is no longer available on this Mac."
        case .calendarReadOnly(let title):
            "“\(title)” is read-only."
        case .eventNotFound:
            "That event no longer exists. Someone may have deleted it elsewhere."
        case .saveRejected(let reason):
            "The event could not be saved. \(reason)"
        case .deleteRejected(let reason):
            "The event could not be deleted. \(reason)"
        }
    }

    /// Whether trying the same thing again could plausibly work.
    public var isWorthRetrying: Bool {
        switch self {
        case .saveRejected, .deleteRejected: true
        case .notAuthorized, .calendarNotFound, .calendarReadOnly, .eventNotFound: false
        }
    }
}
