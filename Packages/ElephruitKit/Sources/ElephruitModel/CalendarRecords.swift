import ElephruitCore
import Foundation
import SwiftData

/// A saved way of looking at the calendar, as it lives in the store.
///
/// ### Why this is in the store rather than in preferences
/// The obvious reading is that a Calendar Set is a preference — it is about *display*, and the
/// storage matrix sends "selected view, sort order, sidebar width" to `UserDefaults`. But a set is
/// something a person composes: it has a name they chose, working hours they decided, and a list of
/// people whose context it surfaces. Losing it when a Mac is replaced would be losing work, which is
/// the line the matrix actually draws. Which set is *currently active* is the preference, and that
/// does live in `UserDefaults`.
///
/// **CloudKit compliance**, on the same terms as every other entity here: every attribute has a
/// default, no unique constraints, every to-one relationship optional with a declared inverse, and
/// no `.deny` delete rule.
@Model
public final class CalendarSetRecord {
    public var id: UUID = UUID()
    public var name: String = ""
    public var symbolName: String = "calendar"
    public var colorName: String?

    /// JSON `[CalendarReference]`.
    ///
    /// A blob rather than rows, because a set's calendars are read and written as a whole and are
    /// never queried individually — the same argument that keeps ``RecurrenceRule`` in one column.
    public var calendarReferencesData: Data?

    public var showsEveryCalendar: Bool = true

    /// JSON `CalendarReference`.
    public var defaultCalendarData: Data?

    /// ``ElephruitCore/CalendarViewKind`` raw value.
    public var preferredViewRaw: String = CalendarViewKind.week.rawValue

    public var displayTimeZoneIdentifier: String?

    public var workingHoursStartMinutes: Int = 9 * 60
    public var workingHoursEndMinutes: Int = 17 * 60

    /// Working weekdays as a sorted, comma-separated list — "2,3,4,5,6".
    ///
    /// A string rather than a `Set<Int>`, because SwiftData stores a `Set` as an opaque archive that
    /// no other tool can read, and a set of at most seven small integers is more useful as something
    /// an export or a person can see.
    public var workingWeekdaysRaw: String = "2,3,4,5,6"

    /// ``ElephruitCore/CalendarDensity`` raw value.
    public var densityRaw: String = CalendarDensity.standard.rawValue

    /// JSON `[UUID]` — people whose context this set surfaces.
    public var emphasisedPersonIDsData: Data?

    public var showsPersonContext: Bool = true
    public var hidesDeclinedEvents: Bool = true

    public var sortOrder: Double = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID(), name: String = "", sortOrder: Double = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

extension CalendarSetRecord {
    /// The value everything else reasons about.
    ///
    /// One bridge in each direction, so no rule about resolving a calendar or shading working hours
    /// is implemented twice.
    public func asValue() -> CalendarSetDefinition {
        CalendarSetDefinition(
            id: id,
            name: name,
            symbolName: symbolName,
            colorName: colorName,
            calendars: Self.decode([CalendarReference].self, from: calendarReferencesData) ?? [],
            showsEveryCalendar: showsEveryCalendar,
            defaultCalendar: Self.decode(CalendarReference.self, from: defaultCalendarData),
            preferredView: CalendarViewKind(rawValue: preferredViewRaw) ?? .week,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier,
            workingHours: WorkingHours(
                startMinutes: workingHoursStartMinutes,
                endMinutes: workingHoursEndMinutes,
                weekdays: Set(workingWeekdaysRaw.split(separator: ",").compactMap { Int($0) })
            ),
            density: CalendarDensity(rawValue: densityRaw) ?? .standard,
            emphasisedPersonIDs: Self.decode([UUID].self, from: emphasisedPersonIDsData) ?? [],
            showsPersonContext: showsPersonContext,
            hidesDeclinedEvents: hidesDeclinedEvents,
            sortOrder: sortOrder
        )
    }

    /// Writes a value back over this record.
    public func absorb(_ definition: CalendarSetDefinition, at now: Date) {
        name = definition.name
        symbolName = definition.symbolName
        colorName = definition.colorName
        calendarReferencesData = Self.encode(definition.calendars)
        showsEveryCalendar = definition.showsEveryCalendar
        defaultCalendarData = definition.defaultCalendar.flatMap(Self.encode)
        preferredViewRaw = definition.preferredView.rawValue
        displayTimeZoneIdentifier = definition.displayTimeZoneIdentifier
        workingHoursStartMinutes = definition.workingHours.startMinutes
        workingHoursEndMinutes = definition.workingHours.endMinutes
        workingWeekdaysRaw = definition.workingHours.weekdays.sorted().map(String.init).joined(separator: ",")
        densityRaw = definition.density.rawValue
        emphasisedPersonIDsData = Self.encode(definition.emphasisedPersonIDs)
        showsPersonContext = definition.showsPersonContext
        hidesDeclinedEvents = definition.hidesDeclinedEvents
        sortOrder = definition.sortOrder
        updatedAt = now
    }

    /// Unreadable data reads as absent rather than throwing: a set whose calendar list cannot be
    /// decoded is still a set, and showing every calendar is a recoverable state where a crash is not.
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }
}

/// A pre-filled event, saved to be used again.
///
/// Stored alongside Calendar Sets and for the same reason: a template is something a person composed
/// and would be sorry to lose.
@Model
public final class EventTemplateRecord {
    public var id: UUID = UUID()
    public var name: String = ""
    public var symbolName: String = "doc.on.doc"
    public var colorName: String?

    public var title: String = ""
    public var durationMinutes: Int = 30

    /// JSON `CalendarReference`.
    public var calendarData: Data?

    public var location: String = ""
    public var notes: String = ""
    public var urlString: String?

    /// ``ElephruitCore/EventAvailability`` raw value.
    public var availabilityRaw: String = EventAvailability.busy.rawValue

    /// JSON `[EventAlarm]`.
    public var alarmsData: Data?

    /// JSON ``ElephruitCore/EventRecurrence``.
    public var recurrenceData: Data?

    /// JSON ``ElephruitCore/TemplateTimeZoneBehaviour``.
    public var timeZoneBehaviourData: Data?

    /// A project the created event is filed under. An identifier rather than a relationship, so a
    /// deleted project leaves a template that still works rather than one that has to be repaired.
    public var linkedProjectID: UUID?

    /// JSON `[UUID]`.
    public var linkedPersonIDsData: Data?

    public var sortOrder: Double = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var lastUsedAt: Date?
    public var useCount: Int = 0

    public init(id: UUID = UUID(), name: String = "", sortOrder: Double = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

extension EventTemplateRecord {
    public func asValue() -> EventTemplate {
        EventTemplate(
            id: id,
            name: name,
            symbolName: symbolName,
            colorName: colorName,
            title: title,
            durationMinutes: durationMinutes,
            calendar: CalendarSetRecord.decode(CalendarReference.self, from: calendarData),
            location: location,
            notes: notes,
            url: urlString.flatMap(URL.init(string:)),
            availability: EventAvailability(rawValue: availabilityRaw) ?? .busy,
            alarms: CalendarSetRecord.decode([EventAlarm].self, from: alarmsData) ?? [],
            recurrence: EventRecurrence.decode(from: recurrenceData),
            timeZoneBehaviour: CalendarSetRecord.decode(
                TemplateTimeZoneBehaviour.self, from: timeZoneBehaviourData
            ) ?? .currentZone,
            linkedProjectID: linkedProjectID,
            linkedPersonIDs: CalendarSetRecord.decode([UUID].self, from: linkedPersonIDsData) ?? [],
            sortOrder: sortOrder,
            lastUsedAt: lastUsedAt,
            useCount: useCount
        )
    }

    public func absorb(_ template: EventTemplate, at now: Date) {
        name = template.name
        symbolName = template.symbolName
        colorName = template.colorName
        title = template.title
        durationMinutes = template.durationMinutes
        calendarData = template.calendar.flatMap(CalendarSetRecord.encode)
        location = template.location
        notes = template.notes
        urlString = template.url?.absoluteString
        availabilityRaw = template.availability.rawValue
        alarmsData = CalendarSetRecord.encode(template.alarms)
        recurrenceData = template.recurrence?.encoded()
        timeZoneBehaviourData = CalendarSetRecord.encode(template.timeZoneBehaviour)
        linkedProjectID = template.linkedProjectID
        linkedPersonIDsData = CalendarSetRecord.encode(template.linkedPersonIDs)
        sortOrder = template.sortOrder
        lastUsedAt = template.lastUsedAt
        useCount = template.useCount
        updatedAt = now
    }

    /// Records that the template was used, for ordering the menu by what somebody actually reaches for.
    public func noteUse(at now: Date) {
        lastUsedAt = now
        useCount += 1
        updatedAt = now
    }
}
