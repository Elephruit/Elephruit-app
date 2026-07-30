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
/// **Everything here is read.** There is no initialiser that writes back, no mutating operation, and
/// no reference to the store it came from — see ``CalendarProviding``.
public struct CalendarEventSummary: Sendable, Hashable, Identifiable {
    public var identity: EventIdentity
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var calendarName: String?
    public var calendarColorName: String?
    public var locationName: String?
    public var notes: String?

    public var status: EventStatus
    public var participation: EventParticipation

    /// Whether this event belongs to a repeating series.
    public var isRecurring: Bool

    /// Whether this occurrence has been edited away from the series — "this event only".
    public var isDetached: Bool

    /// Names of the other attendees, for offering links to people.
    public var attendeeNames: [String]

    public var id: String { identity.storageKey }

    public init(
        identity: EventIdentity,
        title: String,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        calendarColorName: String? = nil,
        locationName: String? = nil,
        notes: String? = nil,
        status: EventStatus = .none,
        participation: EventParticipation = .unknown,
        isRecurring: Bool = false,
        isDetached: Bool = false,
        attendeeNames: [String] = []
    ) {
        self.identity = identity
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.calendarColorName = calendarColorName
        self.locationName = locationName
        self.notes = notes
        self.status = status
        self.participation = participation
        self.isRecurring = isRecurring
        self.isDetached = isDetached
        self.attendeeNames = attendeeNames
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
        return startAt < dayEnd && endAt > dayStart
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
