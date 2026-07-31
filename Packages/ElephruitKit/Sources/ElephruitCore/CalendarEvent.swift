import Foundation

/// Which occurrence of which event.
///
/// ### Why an identifier is not enough
/// A recurring event is one record in EventKit with many occurrences. `eventIdentifier` names the
/// *series*, so a note linked to "the standup" would follow the whole series rather than the Tuesday
/// it was written about — and when someone edits the series, an identifier-only link either points
/// at the wrong day or stops resolving.
///
/// The pair is what survives. `externalIdentifier` is `EKCalendarItem.calendarItemExternalIdentifier`,
/// which is stable across a sync and across the same event on another Mac;
/// ``occurrenceDate`` is `EKEvent.occurrenceDate`, the *original* start of that occurrence, which does
/// not move when the series is edited around it.
public struct EventIdentity: Sendable, Hashable, Codable {
    /// `EKCalendarItem.calendarItemExternalIdentifier`.
    ///
    /// Deliberately not `eventIdentifier`: that one is local to a device's store and changes when a
    /// calendar is removed and re-added, which would break every link a user had made.
    public var externalIdentifier: String

    /// `EKEvent.occurrenceDate` — the occurrence's original start, not its current one.
    ///
    /// `nil` for a non-recurring event, where the identifier alone is unambiguous.
    public var occurrenceDate: Date?

    public init(externalIdentifier: String, occurrenceDate: Date? = nil) {
        self.externalIdentifier = externalIdentifier
        self.occurrenceDate = occurrenceDate
    }

    /// A single string, for storing in one column and comparing with `==`.
    ///
    /// The occurrence is written as a whole number of seconds since the reference date. Sub-second
    /// precision is noise here — EventKit occurrence dates land on minute boundaries — and rounding
    /// it away means a stored key cannot fail to match itself because of a floating-point tail.
    public var storageKey: String {
        guard let occurrenceDate else { return externalIdentifier }
        let seconds = Int(occurrenceDate.timeIntervalSinceReferenceDate.rounded())
        return "\(externalIdentifier)#\(seconds)"
    }

    public static func fromStorageKey(_ key: String) -> EventIdentity? {
        guard !key.isEmpty else { return nil }

        guard let separator = key.lastIndex(of: "#") else {
            return EventIdentity(externalIdentifier: key)
        }

        let identifier = String(key[key.startIndex..<separator])
        let suffix = String(key[key.index(after: separator)...])

        guard !identifier.isEmpty, let seconds = Int(suffix) else {
            // A `#` inside an identifier rather than a separator. Treat the whole thing as the
            // identifier rather than silently truncating it.
            return EventIdentity(externalIdentifier: key)
        }

        return EventIdentity(
            externalIdentifier: identifier,
            occurrenceDate: Date(timeIntervalSinceReferenceDate: TimeInterval(seconds))
        )
    }
}

/// Whether an event is still happening, as its organiser sees it.
public enum EventStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case confirmed
    case tentative
    case cancelled
}

/// What *you* said about attending.
///
/// Distinct from ``EventStatus``: a confirmed meeting you declined is still confirmed, and the
/// difference is the whole reason declined events can be hidden without hiding cancelled ones.
public enum EventParticipation: String, Sendable, Hashable, Codable, CaseIterable {
    case unknown
    case pending
    case accepted
    case declined
    case tentative

    /// Whether this belongs in a day's plan.
    ///
    /// Declined is the one that does not. Somebody else's meeting that you said no to is not part of
    /// your day, and showing it makes Today a list of everything rather than a list of what to do.
    public var appearsInPlan: Bool {
        self != .declined
    }
}

/// A calendar event, as the app understands it.
///
/// A value type rather than an `EKEvent`, so nothing outside the integrations module depends on
/// EventKit, the inert provider needs no framework, and a test can build one in a line.
///
/// **Reading and writing are separate types.** This is what a calendar *contains*; ``EventDraft`` is
/// what the app asks a calendar to become. Nothing here can be saved back, and no value here holds a
/// reference to the store it came from — see ``CalendarProviding``.
public struct CalendarEventSummary: Sendable, Hashable, Identifiable {
    public var identity: EventIdentity
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool

    /// `EKCalendar.calendarIdentifier` — which calendar holds this event.
    public var calendarIdentifier: String?
    public var calendarName: String?

    /// A ``Theme.Palette`` key rather than a colour. See ``CalendarPalette``.
    public var calendarColorName: String?

    /// The account behind the calendar — "iCloud", a Google address, an Exchange server.
    public var accountName: String?

    public var locationName: String?
    public var notes: String?
    public var url: URL?

    public var status: EventStatus
    public var participation: EventParticipation
    public var availability: EventAvailability

    /// The event's own time zone identifier. `nil` means a floating event, which happens at the same
    /// wall-clock time wherever you are.
    public var timeZoneIdentifier: String?

    public var alarms: [EventAlarm]
    public var attendees: [EventAttendee]
    public var organizerName: String?

    /// Whether this event belongs to a repeating series.
    public var isRecurring: Bool

    /// The series' rule, when this event repeats and the rule could be read.
    public var recurrence: EventRecurrence?

    /// Whether this occurrence has been edited away from the series — "this event only".
    public var isDetached: Bool

    /// Whether the calendar holding this event allows changes at all.
    ///
    /// Carried on the event rather than looked up when the editor opens, so a read-only event can be
    /// shown as read-only in a list without a second round trip.
    public var isEditable: Bool

    public var createdAt: Date?
    public var lastModifiedAt: Date?

    public var id: String { identity.storageKey }

    /// Names of the other attendees, for offering links to people.
    ///
    /// Derived from ``attendees`` rather than stored beside it, so the two cannot disagree.
    public var attendeeNames: [String] {
        attendees.filter { !$0.isCurrentUser }.map(\.displayName).filter { !$0.isEmpty }
    }

    public init(
        identity: EventIdentity,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        calendarIdentifier: String? = nil,
        calendarName: String? = nil,
        calendarColorName: String? = nil,
        accountName: String? = nil,
        locationName: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        status: EventStatus = .none,
        participation: EventParticipation = .unknown,
        availability: EventAvailability = .busy,
        timeZoneIdentifier: String? = nil,
        alarms: [EventAlarm] = [],
        attendees: [EventAttendee] = [],
        organizerName: String? = nil,
        isRecurring: Bool = false,
        recurrence: EventRecurrence? = nil,
        isDetached: Bool = false,
        isEditable: Bool = true,
        createdAt: Date? = nil,
        lastModifiedAt: Date? = nil
    ) {
        self.identity = identity
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.calendarColorName = calendarColorName
        self.accountName = accountName
        self.locationName = locationName
        self.notes = notes
        self.url = url
        self.status = status
        self.participation = participation
        self.availability = availability
        self.timeZoneIdentifier = timeZoneIdentifier
        self.alarms = alarms
        self.attendees = attendees
        self.organizerName = organizerName
        self.isRecurring = isRecurring
        self.recurrence = recurrence
        self.isDetached = isDetached
        self.isEditable = isEditable
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
    }

    public var displayTitle: String {
        title.isEmpty ? "Untitled event" : title
    }

    public var isCancelled: Bool { status == .cancelled }

    /// Whether this event should appear in a day's plan at all.
    ///
    /// Declined events are hidden; cancelled ones are **not**, because a meeting cancelled an hour
    /// beforehand is information you need, and silently removing it makes the app look wrong to
    /// someone who remembers it being there.
    public var appearsInPlan: Bool {
        participation.appearsInPlan
    }

    public var duration: TimeInterval {
        max(0, endAt.timeIntervalSince(startAt))
    }

    /// Whether the event covers `date`, in the given calendar.
    public func occurs(on date: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }

        // A zero-length event at exactly midnight belongs to the day it starts, not to neither.
        if endAt == startAt { return startAt >= dayStart && startAt < dayEnd }
        return startAt < dayEnd && endAt > dayStart
    }

    /// Whether the event spans more than one calendar day.
    ///
    /// Asked in the day and week views, where a multi-day event is drawn as a bar across the top
    /// rather than as a column that would otherwise be taller than the grid.
    public func spansMultipleDays(calendar: Calendar) -> Bool {
        let startDay = calendar.startOfDay(for: startAt)
        // An event ending exactly at midnight ends on the previous day as far as a reader is
        // concerned; without this, every 23:00–00:00 event would claim two days.
        let effectiveEnd = endAt > startAt ? endAt.addingTimeInterval(-1) : endAt
        return calendar.startOfDay(for: effectiveEnd) > startDay
    }

    /// Whether this belongs in the band above a day grid rather than in the grid itself.
    public func occupiesAllDayRow(calendar: Calendar) -> Bool {
        isAllDay || spansMultipleDays(calendar: calendar)
    }

    /// The event's own time zone, when it named one.
    public var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    /// Whether the event floats — the same wall-clock time wherever the user happens to be.
    public var isFloating: Bool {
        timeZoneIdentifier == nil && !isAllDay
    }

    /// Every calendar day this event touches, in order.
    ///
    /// Bounded, because a corrupt event claiming to end in the year 3000 must not be allowed to
    /// build a million-element array while a view is drawing.
    public func days(in calendar: Calendar, limit: Int = 400) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: startAt)
        let effectiveEnd = endAt > startAt ? endAt.addingTimeInterval(-1) : endAt
        let last = calendar.startOfDay(for: effectiveEnd)

        while cursor <= last, days.count < limit {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return days
    }

    /// A one-line description of when this happens, in the reader's own zone.
    public func timeSummary(in zone: TimeZone, calendar: Calendar) -> String {
        guard !isAllDay else {
            return spansMultipleDays(calendar: calendar) ? "All day, several days" : "All day"
        }

        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return "\(startAt.formatted(style))–\(endAt.formatted(style))"
    }
}

// MARK: - Authorisation

/// Whether an integration may be used.
///
/// `notRequested` is distinct from `denied` so the interface can offer to ask rather than reporting a
/// refusal the user never made, and `restricted` is distinct from both because a managed device
/// refusing is not something the user can fix by changing their mind.
public enum IntegrationAuthorization: Sendable, Hashable {
    case notRequested
    case authorized
    case denied
    case restricted
    case unavailable

    public var canRead: Bool { self == .authorized }

    /// Whether asking again could change the answer.
    ///
    /// Only `notRequested`. Once macOS has recorded a decision, asking again does nothing at all —
    /// the prompt never reappears — so a button offering to "try again" would be a button that
    /// visibly does nothing. The interface sends the user to System Settings instead.
    public var isWorthAsking: Bool { self == .notRequested }

    /// What to tell the user, in their terms rather than the framework's.
    public var explanation: String? {
        switch self {
        case .notRequested:
            "Elephruit can show your calendar alongside your work. It only ever reads."
        case .authorized:
            nil
        case .denied:
            "Calendar access is turned off. You can turn it on in System Settings under Privacy & Security."
        case .restricted:
            "Calendar access is not available on this Mac. It may be managed by an administrator."
        case .unavailable:
            "Calendar is not available in this build."
        }
    }
}
