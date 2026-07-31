import Foundation

/// The zone the calendar is *drawn* in.
///
/// ### The invariant this type exists to protect
/// **Changing the display zone never changes a stored date.** An event happens at an instant; a
/// calendar draws that instant somewhere. Those are different facts, and conflating them is how a
/// calendar quietly moves somebody's flight when they land.
///
/// So every function here takes dates and returns *positions* or *labels*. There is no method that
/// returns a new `Date`, and ``CalendarTimeZoneTests`` fails if one is added.
public struct TimeZoneDisplay: Sendable, Hashable, Codable {
    /// The zone the user's Mac is actually in.
    public var deviceZoneIdentifier: String

    /// The zone the grid is labelled in. `nil` means the device's own.
    public var displayZoneIdentifier: String?

    /// A second zone shown alongside the first, for a dual ruler.
    public var secondaryZoneIdentifier: String?

    /// Zones the user has pinned, for the picker and for person-local times.
    public var favouriteZoneIdentifiers: [String]

    /// Whether the app is treating the user as travelling.
    ///
    /// Travel mode is deliberately explicit rather than inferred from the system zone changing.
    /// Automatic detection means an app that reshuffles somebody's whole calendar the moment their
    /// laptop notices an airport's Wi-Fi, which is exactly when they are least able to check
    /// whether it got it right.
    public var isTravelling: Bool

    public init(
        deviceZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
        displayZoneIdentifier: String? = nil,
        secondaryZoneIdentifier: String? = nil,
        favouriteZoneIdentifiers: [String] = [],
        isTravelling: Bool = false
    ) {
        self.deviceZoneIdentifier = deviceZoneIdentifier
        self.displayZoneIdentifier = displayZoneIdentifier
        self.secondaryZoneIdentifier = secondaryZoneIdentifier
        self.favouriteZoneIdentifiers = favouriteZoneIdentifiers
        self.isTravelling = isTravelling
    }

    public var deviceZone: TimeZone {
        TimeZone(identifier: deviceZoneIdentifier) ?? .autoupdatingCurrent
    }

    /// The zone times are shown in.
    public var displayZone: TimeZone {
        displayZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? deviceZone
    }

    public var secondaryZone: TimeZone? {
        secondaryZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    /// Whether the display zone differs from where the Mac is.
    ///
    /// When it does, the interface says so permanently rather than in a toast. A calendar showing
    /// Tokyo time with no visible sign of it is a missed meeting waiting to happen.
    public var isShowingAnotherZone: Bool {
        displayZone.identifier != deviceZone.identifier
    }

    /// A calendar configured for the display zone.
    ///
    /// The one place a `Calendar` for drawing is built, so no view can accidentally lay out a week
    /// in the device's zone while labelling it in another.
    public func calendar(basedOn base: Calendar) -> Calendar {
        var calendar = base
        calendar.timeZone = displayZone
        return calendar
    }

    /// "3:00 PM for you · 1:00 PM for Maya".
    ///
    /// - Parameter otherLabel: How to name the other person or place.
    /// Returns `nil` when both zones show the same time, because saying it twice is noise.
    public func dualLabel(
        for instant: Date,
        otherZone: TimeZone,
        otherLabel: String
    ) -> String? {
        guard otherZone.secondsFromGMT(for: instant) != displayZone.secondsFromGMT(for: instant) else {
            return nil
        }

        var mine = Date.FormatStyle(date: .omitted, time: .shortened)
        mine.timeZone = displayZone
        var theirs = Date.FormatStyle(date: .omitted, time: .shortened)
        theirs.timeZone = otherZone

        return "\(instant.formatted(mine)) for you · \(instant.formatted(theirs)) for \(otherLabel)"
    }

    /// The offset between the two ruler columns, in hours, at a given instant.
    ///
    /// Read at an instant rather than taken as a constant: the gap between London and New York is
    /// four hours for two weeks each spring, and a ruler built on a fixed five would be wrong for
    /// exactly the fortnight somebody is most likely to be confused.
    public func secondaryOffsetHours(at instant: Date) -> Double? {
        guard let secondaryZone else { return nil }
        let difference = secondaryZone.secondsFromGMT(for: instant) - displayZone.secondsFromGMT(for: instant)
        return Double(difference) / 3_600
    }

    /// A short label for a zone — "New York", "GMT+9".
    public static func shortName(for zone: TimeZone, at instant: Date) -> String {
        if let city = zone.identifier.split(separator: "/").last {
            return city.replacingOccurrences(of: "_", with: " ")
        }
        let hours = Double(zone.secondsFromGMT(for: instant)) / 3_600
        return hours == 0 ? "GMT" : String(format: "GMT%+g", hours)
    }
}

// MARK: - Warnings

/// Something about an event's time that the user should be told before saving.
///
/// Each of these is a real way a calendar lies to somebody. None of them blocks a save — the app
/// does not know better than the user — but all of them are said plainly and before the fact.
public enum TimeZoneWarning: Sendable, Hashable, Identifiable {
    /// The event crosses a daylight-saving change, so its length in hours is not what it looks like.
    case crossesDaylightSaving(gainedHour: Bool)

    /// The chosen local time does not exist, because the clocks go forward through it.
    case timeDoesNotExist(resolvedTo: Date)

    /// The chosen local time happens twice, because the clocks go back over it.
    case timeHappensTwice

    /// The event is shown in a zone other than the one the Mac is in.
    case shownInAnotherZone(displayZone: String, deviceZone: String)

    /// An all-day event given a time zone, which makes it move for people elsewhere.
    case allDayWithZone

    /// A recurring event whose rule crosses a daylight-saving change.
    case seriesCrossesDaylightSaving

    public var id: String { String(describing: self) }

    public var message: String {
        switch self {
        case .crossesDaylightSaving(let gained):
            gained
                ? "The clocks go back during this event, so it lasts an hour longer than it looks."
                : "The clocks go forward during this event, so it lasts an hour less than it looks."
        case .timeDoesNotExist(let resolved):
            """
            That time does not exist on this date — the clocks go forward through it. \
            The event will start at \(resolved.formatted(date: .omitted, time: .shortened)).
            """
        case .timeHappensTwice:
            "That time happens twice on this date, because the clocks go back. The first one is used."
        case .shownInAnotherZone(let display, let device):
            "Times are shown in \(display). Your Mac is in \(device)."
        case .allDayWithZone:
            "An all-day event with a time zone starts on a different day for people elsewhere."
        case .seriesCrossesDaylightSaving:
            "This series crosses a clock change. Every occurrence keeps the same local time."
        }
    }

    /// Whether this is worth interrupting for, as opposed to noting quietly.
    public var isProminent: Bool {
        switch self {
        case .timeDoesNotExist, .timeHappensTwice, .allDayWithZone: true
        case .crossesDaylightSaving, .shownInAnotherZone, .seriesCrossesDaylightSaving: false
        }
    }
}

/// Works out what is odd about a particular event's timing.
///
/// Pure and static, so every one of these can be asserted against a specific date in a specific zone
/// rather than reasoned about.
public enum TimeZoneInspector {
    /// Every warning that applies to a draft.
    public static func warnings(
        for draft: EventDraft,
        display: TimeZoneDisplay,
        calendar: Calendar
    ) -> [TimeZoneWarning] {
        var warnings: [TimeZoneWarning] = []

        let zone = draft.timeZone ?? display.displayZone
        var zoned = calendar
        zoned.timeZone = zone

        if draft.isAllDay, draft.timeZoneIdentifier != nil {
            warnings.append(.allDayWithZone)
        }

        if !draft.isAllDay {
            if let offsetChange = daylightSavingChange(in: draft.startAt..<draft.endAt, zone: zone) {
                warnings.append(.crossesDaylightSaving(gainedHour: offsetChange < 0))
            }

            if isAmbiguous(draft.startAt, zone: zone) {
                warnings.append(.timeHappensTwice)
            }

            if let recurrence = draft.recurrence,
               seriesCrossesTransition(recurrence, from: draft.startAt, zone: zone, calendar: zoned) {
                warnings.append(.seriesCrossesDaylightSaving)
            }
        }

        if display.isShowingAnotherZone {
            warnings.append(.shownInAnotherZone(
                displayZone: TimeZoneDisplay.shortName(for: display.displayZone, at: draft.startAt),
                deviceZone: TimeZoneDisplay.shortName(for: display.deviceZone, at: draft.startAt)
            ))
        }

        return warnings
    }

    /// The change in offset across a range, in seconds, or `nil` when there is none.
    ///
    /// Negative means the offset went down — the clocks went back and the day gained an hour.
    public static func daylightSavingChange(in range: Range<Date>, zone: TimeZone) -> Int? {
        let before = zone.secondsFromGMT(for: range.lowerBound)
        let after = zone.secondsFromGMT(for: range.upperBound)
        return before == after ? nil : after - before
    }

    /// Whether a wall-clock time the user asked for is one the clocks skip, and what it becomes.
    ///
    /// ### Why this takes an hour and a minute rather than a `Date`
    /// It cannot take a `Date`. A `Date` is an instant, and the instant "02:30 on 8 March in New
    /// York" does not exist — anything that produced such a value has already resolved it to 03:30,
    /// and asking the same question of the result round-trips perfectly and reports nothing wrong.
    /// The information is only available at the moment somebody chose an hour, which is why the
    /// editor calls this with the day and time it is about to combine rather than with the
    /// combination.
    ///
    /// Returns `nil` when the time exists, which is every time except two hours a year.
    public static func nonexistentLocalTime(
        day: Date,
        hour: Int,
        minute: Int,
        zone: TimeZone,
        calendar: Calendar
    ) -> Date? {
        var zoned = calendar
        zoned.timeZone = zone

        var components = zoned.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let rebuilt = zoned.date(from: components) else { return nil }

        let rebuiltHour = zoned.component(.hour, from: rebuilt)
        let rebuiltMinute = zoned.component(.minute, from: rebuilt)

        guard rebuiltHour != hour || rebuiltMinute != minute else { return nil }
        return rebuilt
    }

    /// The warning for a time somebody has just chosen, if any.
    ///
    /// Separate from ``warnings(for:display:calendar:)`` for the reason above: this one has the
    /// question in front of it, and that one only has the answer.
    public static func warningForRequestedTime(
        day: Date,
        hour: Int,
        minute: Int,
        zone: TimeZone,
        calendar: Calendar
    ) -> TimeZoneWarning? {
        if let resolved = nonexistentLocalTime(day: day, hour: hour, minute: minute, zone: zone, calendar: calendar) {
            return .timeDoesNotExist(resolvedTo: resolved)
        }

        var zoned = calendar
        zoned.timeZone = zone
        var components = zoned.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute

        guard let instant = zoned.date(from: components), isAmbiguous(instant, zone: zone) else { return nil }
        return .timeHappensTwice
    }

    /// Whether a wall-clock time occurs twice, because the clocks go back over it.
    ///
    /// An instant is ambiguous when the same local time an hour later maps back onto a *different*
    /// offset — which only happens inside a repeated hour.
    public static func isAmbiguous(_ date: Date, zone: TimeZone) -> Bool {
        let hourLater = date.addingTimeInterval(3_600)
        let hourEarlier = date.addingTimeInterval(-3_600)

        // The repeated hour is the one where the offset drops between an hour before and an hour
        // after. Checking both sides catches the instant on either side of the transition.
        let before = zone.secondsFromGMT(for: hourEarlier)
        let current = zone.secondsFromGMT(for: date)
        let after = zone.secondsFromGMT(for: hourLater)

        return before > current || current > after
    }

    /// Whether a series' first few occurrences straddle a clock change.
    ///
    /// Only the near future is checked: an unbounded weekly series crosses a transition eventually,
    /// and warning about something six months away every time somebody makes a meeting is noise.
    public static func seriesCrossesTransition(
        _ recurrence: EventRecurrence,
        from start: Date,
        zone: TimeZone,
        calendar: Calendar,
        withinDays days: Int = 120
    ) -> Bool {
        guard let horizon = calendar.date(byAdding: .day, value: days, to: start) else { return false }
        guard let transition = zone.nextDaylightSavingTimeTransition(after: start), transition < horizon else {
            return false
        }

        let occurrences = recurrence.occurrences(
            startingAt: start, calendar: calendar, limit: 60, notAfter: horizon
        )
        return occurrences.contains { $0 > transition }
    }
}
