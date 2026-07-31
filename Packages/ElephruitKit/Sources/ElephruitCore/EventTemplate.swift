import Foundation

/// What a template does about time zones.
///
/// The three answers are genuinely different and picking one for the user is wrong in two thirds of
/// cases. A daily standup happens at nine wherever you are. A call with a colleague in London
/// happens at their nine, whatever your clock says. A gym session simply happens at six, and does
/// not want a zone at all.
public enum TemplateTimeZoneBehaviour: Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Use whatever zone the Mac is in when the event is created.
    case currentZone

    /// Always the same named zone.
    case fixedZone(identifier: String)

    /// No zone: the same wall-clock time everywhere.
    case floating

    public var id: String {
        switch self {
        case .currentZone: "current"
        case .fixedZone(let identifier): "fixed:\(identifier)"
        case .floating: "floating"
        }
    }

    /// The cases a picker offers before the user names a zone.
    public static var allCases: [TemplateTimeZoneBehaviour] {
        [.currentZone, .floating]
    }

    public var displayName: String {
        switch self {
        case .currentZone: "Wherever I am"
        case .fixedZone(let identifier): identifier.replacingOccurrences(of: "_", with: " ")
        case .floating: "The same time everywhere"
        }
    }

    /// The zone identifier to write, given the zone the Mac is in now.
    public func resolve(currentZone: TimeZone) -> String? {
        switch self {
        case .currentZone: currentZone.identifier
        case .fixedZone(let identifier): identifier
        case .floating: nil
        }
    }
}

/// A pre-filled event, saved to be used again.
///
/// ### What a template is not
/// It is not a recurring event. A recurring event is one series the calendar keeps producing;
/// a template is a shape somebody applies when they decide to, at a time they choose. "One-to-one
/// with Maya, 30 minutes, in the Work calendar, with a 10-minute alarm and a link to the project"
/// is a template. Making it recurring would put it in the calendar on weeks it did not happen.
public struct EventTemplate: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID

    /// What the template is called in the menu — often, but not always, the event's title.
    public var name: String

    public var symbolName: String
    public var colorName: String?

    public var title: String
    public var durationMinutes: Int

    /// Where the event lands. `nil` uses the active Calendar Set's default.
    public var calendar: CalendarReference?

    public var location: String
    public var notes: String
    public var url: URL?
    public var availability: EventAvailability
    public var alarms: [EventAlarm]
    public var recurrence: EventRecurrence?
    public var timeZoneBehaviour: TemplateTimeZoneBehaviour

    /// A project the created event is filed under.
    ///
    /// Local, and applied to the app's own annotation rather than written into the calendar event —
    /// which is what keeps a project name out of a work calendar somebody else can read.
    public var linkedProjectID: UUID?

    /// People linked to the created event, again locally.
    public var linkedPersonIDs: [UUID]

    public var sortOrder: Double
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "doc.on.doc",
        colorName: String? = nil,
        title: String = "",
        durationMinutes: Int = 30,
        calendar: CalendarReference? = nil,
        location: String = "",
        notes: String = "",
        url: URL? = nil,
        availability: EventAvailability = .busy,
        alarms: [EventAlarm] = [],
        recurrence: EventRecurrence? = nil,
        timeZoneBehaviour: TemplateTimeZoneBehaviour = .currentZone,
        linkedProjectID: UUID? = nil,
        linkedPersonIDs: [UUID] = [],
        sortOrder: Double = 0,
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
        self.title = title.isEmpty ? name : title
        self.durationMinutes = max(1, durationMinutes)
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.alarms = alarms
        self.recurrence = recurrence
        self.timeZoneBehaviour = timeZoneBehaviour
        self.linkedProjectID = linkedProjectID
        self.linkedPersonIDs = linkedPersonIDs
        self.sortOrder = sortOrder
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    /// A draft for an event starting at `start`.
    ///
    /// - Parameters:
    ///   - fallbackCalendar: Used when the template names no calendar, or names one that no longer
    ///     exists. A template whose calendar was deleted still works; it lands in the set's default
    ///     rather than failing.
    ///   - available: The calendars that currently exist, for resolving the reference.
    public func draft(
        startingAt start: Date,
        fallbackCalendar: String,
        available: [CalendarInfo],
        currentZone: TimeZone
    ) -> EventDraft {
        let identifier = calendar?.resolve(among: available)?.id ?? fallbackCalendar

        return EventDraft(
            calendarIdentifier: identifier,
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            isAllDay: false,
            timeZoneIdentifier: timeZoneBehaviour.resolve(currentZone: currentZone),
            location: location,
            notes: notes,
            url: url,
            availability: availability,
            alarms: alarms,
            recurrence: recurrence
        )
    }

    /// A one-line description for the template's row.
    public var summary: String {
        var parts = [EventAlarm.durationPhrase(durationMinutes)]
        if !location.isEmpty { parts.append(location) }
        if let calendar, !calendar.title.isEmpty { parts.append(calendar.title) }
        if let recurrence { parts.append(recurrence.summary) }
        if !alarms.isEmpty { parts.append(alarms.count == 1 ? "1 alarm" : "\(alarms.count) alarms") }
        return parts.joined(separator: " · ")
    }

    /// A template built from an event somebody already has.
    ///
    /// The commonest way a template is actually made: a meeting happens, it was set up correctly,
    /// and the next one should look the same. Local links are *not* carried over — they belong to
    /// that meeting, and copying them would attach last month's notes to next month's event.
    public static func from(event: CalendarEventSummary, named name: String) -> EventTemplate {
        EventTemplate(
            name: name,
            title: event.title,
            durationMinutes: max(1, Int(event.duration / 60)),
            calendar: event.calendarIdentifier.map {
                CalendarReference(
                    identifier: $0,
                    title: event.calendarName ?? "",
                    accountName: event.accountName ?? ""
                )
            },
            location: event.locationName ?? "",
            notes: event.notes ?? "",
            url: event.url,
            availability: event.availability,
            alarms: event.alarms,
            recurrence: event.recurrence,
            timeZoneBehaviour: event.timeZoneIdentifier.map { .fixedZone(identifier: $0) } ?? .currentZone
        )
    }
}
