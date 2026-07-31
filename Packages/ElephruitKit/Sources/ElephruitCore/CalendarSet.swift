import Foundation

/// Which layout the calendar is showing.
///
/// Ordered as they appear in the view switcher, from the closest look at time to the furthest.
public enum CalendarViewKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case agenda
    case day
    case week
    case month
    case quarter
    case year

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agenda: "Agenda"
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        }
    }

    public var symbolName: String {
        switch self {
        case .agenda: "list.bullet"
        case .day: "calendar.day.timeline.left"
        case .week: "calendar"
        case .month: "square.grid.3x3"
        case .quarter: "square.grid.2x2"
        case .year: "square.grid.4x3.fill"
        }
    }

    /// The `⌘1`–`⌘6` position, matching the switcher's order.
    public var shortcutIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    /// How many days the view shows at once, for deciding what to fetch.
    ///
    /// `nil` for the overviews, which fetch by a calendar unit rather than a count of days.
    public var visibleDayCount: Int? {
        switch self {
        case .agenda: 30
        case .day: 1
        case .week: 7
        case .month, .quarter, .year: nil
        }
    }

    /// Whether this view draws events against a clock, and so needs positions rather than a list.
    public var isTimeGrid: Bool {
        self == .day || self == .week
    }

    /// Whether this view is an overview that summarises rather than showing every event.
    ///
    /// Quarter and year deliberately do not try to draw every event. A year grid with 2,000 events
    /// in it is a texture, not information, and the useful question at that zoom is "when was I
    /// busy" — which a density map answers and a wall of one-pixel bars does not.
    public var isOverview: Bool {
        self == .quarter || self == .year
    }
}

/// How much detail a day shows before it starts eliding.
public enum CalendarDensity: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case comfortable
    case standard
    case compact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: "Comfortable"
        case .standard: "Standard"
        case .compact: "Compact"
        }
    }

    /// Points per hour in a time grid.
    public var hourHeight: Double {
        switch self {
        case .comfortable: 72
        case .standard: 52
        case .compact: 38
        }
    }

    /// How many events a month cell lists before deferring to "+3 more".
    public var monthCellEventLimit: Int {
        switch self {
        case .comfortable: 4
        case .standard: 3
        case .compact: 2
        }
    }
}

/// The hours a person actually works, and on which days.
///
/// Used to shade a time grid rather than to restrict it: an evening event is still shown, it simply
/// sits outside the band. Restricting the grid to working hours is how a calendar hides the dinner
/// somebody is late for.
public struct WorkingHours: Sendable, Hashable, Codable {
    /// Minutes from midnight.
    public var startMinutes: Int
    public var endMinutes: Int

    /// Weekdays, 1-based with Sunday as 1.
    public var weekdays: Set<Int>

    public init(startMinutes: Int = 9 * 60, endMinutes: Int = 17 * 60, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.startMinutes = min(max(startMinutes, 0), 24 * 60)
        self.endMinutes = min(max(endMinutes, self.startMinutes), 24 * 60)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
    }

    public static let standard = WorkingHours()

    /// Whether a given weekday is a working day.
    public func includes(weekday: Int) -> Bool {
        weekdays.contains(weekday)
    }

    /// Whether an instant falls inside working hours, in the given calendar.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, includes(weekday: weekday) else { return false }

        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return minutes >= startMinutes && minutes < endMinutes
    }

    public var summary: String {
        "\(Self.timeLabel(startMinutes))–\(Self.timeLabel(endMinutes))"
    }

    public static func timeLabel(_ minutes: Int) -> String {
        let hour = minutes / 60
        let minute = minutes % 60
        return String(format: "%d:%02d", hour, minute)
    }
}

/// A saved way of looking at the calendar.
///
/// ### Why this is one object rather than a set of preferences
/// Switching context is not one decision. Going from work to family changes which calendars are
/// visible, where a new event lands by default, which view is useful, what counts as working hours,
/// and how much of somebody's private history should be on screen. Making each of those a separate
/// preference means switching context is five actions that a person will do four of.
///
/// Everything here is a *view* onto the calendar. A set never owns an event, never changes one, and
/// deleting a set deletes nothing but itself.
public struct CalendarSetDefinition: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var colorName: String?

    /// Which calendars are visible. Empty means every calendar, which is what a new set starts as
    /// and is distinct from a set whose calendars have all been removed.
    public var calendars: [CalendarReference]

    /// Whether `calendars` is a deliberate selection or simply "all of them".
    public var showsEveryCalendar: Bool

    /// Where a new event lands. `nil` uses the system default.
    public var defaultCalendar: CalendarReference?

    public var preferredView: CalendarViewKind

    /// The zone times are *shown* in. Never the zone they are stored in — see ``TimeZoneDisplay``.
    public var displayTimeZoneIdentifier: String?

    public var workingHours: WorkingHours
    public var density: CalendarDensity

    /// People whose context should be surfaced while this set is active.
    ///
    /// Local, and never written to a calendar event. This is what makes a Family set show birthdays
    /// and open promises where a Work set does not.
    public var emphasisedPersonIDs: [UUID]

    /// Whether a person's CRM context appears at all in this set.
    ///
    /// Off for sets somebody might screen-share. The context is not deleted, only hidden.
    public var showsPersonContext: Bool

    /// Whether events the user declined are hidden.
    public var hidesDeclinedEvents: Bool

    public var sortOrder: Double

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "calendar",
        colorName: String? = nil,
        calendars: [CalendarReference] = [],
        showsEveryCalendar: Bool = true,
        defaultCalendar: CalendarReference? = nil,
        preferredView: CalendarViewKind = .week,
        displayTimeZoneIdentifier: String? = nil,
        workingHours: WorkingHours = .standard,
        density: CalendarDensity = .standard,
        emphasisedPersonIDs: [UUID] = [],
        showsPersonContext: Bool = true,
        hidesDeclinedEvents: Bool = true,
        sortOrder: Double = 0
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
        self.calendars = calendars
        self.showsEveryCalendar = showsEveryCalendar
        self.defaultCalendar = defaultCalendar
        self.preferredView = preferredView
        self.displayTimeZoneIdentifier = displayTimeZoneIdentifier
        self.workingHours = workingHours
        self.density = density
        self.emphasisedPersonIDs = emphasisedPersonIDs
        self.showsPersonContext = showsPersonContext
        self.hidesDeclinedEvents = hidesDeclinedEvents
        self.sortOrder = sortOrder
    }

    /// The identifiers to fetch with, given what currently exists.
    ///
    /// `nil` means "every calendar", which the provider treats as no filter at all. A set that names
    /// calendars none of which currently exist returns an empty array rather than `nil` — showing
    /// everything because a Work set's calendars are temporarily offline would be the opposite of
    /// what the set is for.
    public func calendarIdentifiers(among available: [CalendarInfo]) -> [String]? {
        guard !showsEveryCalendar else { return nil }
        return calendars.compactMap { $0.resolve(among: available)?.id }
    }

    /// Calendars this set names that are not currently available.
    ///
    /// Reported rather than pruned. A calendar can be missing because an account is offline, and
    /// silently dropping it from the set would mean the set quietly shrinks every time the network
    /// does — with no way back.
    public func unavailableCalendars(among available: [CalendarInfo]) -> [CalendarReference] {
        calendars.filter { $0.resolve(among: available) == nil }
    }

    public var displayTimeZone: TimeZone? {
        displayTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    /// The sets a new library starts with.
    ///
    /// Suggested rather than created: they are offered once, with their calendars unchosen, and a
    /// person who wants none of them dismisses the offer. Creating five sets nobody asked for in
    /// somebody's sidebar is how an app feels presumptuous on first launch.
    public static func suggestions() -> [CalendarSetDefinition] {
        [
            CalendarSetDefinition(
                name: "Work", symbolName: "briefcase", colorName: "indigo",
                preferredView: .week, sortOrder: 0
            ),
            CalendarSetDefinition(
                name: "Personal", symbolName: "house", colorName: "teal",
                preferredView: .week, workingHours: WorkingHours(startMinutes: 8 * 60, endMinutes: 22 * 60,
                                                                 weekdays: Set(1...7)),
                sortOrder: 1
            ),
            CalendarSetDefinition(
                name: "Family", symbolName: "figure.2.and.child.holdinghands", colorName: "orange",
                preferredView: .month,
                workingHours: WorkingHours(startMinutes: 7 * 60, endMinutes: 21 * 60, weekdays: Set(1...7)),
                sortOrder: 2
            ),
            CalendarSetDefinition(
                name: "Travel", symbolName: "airplane", colorName: "cyan",
                preferredView: .agenda, density: .comfortable, showsPersonContext: false, sortOrder: 3
            ),
        ]
    }
}
