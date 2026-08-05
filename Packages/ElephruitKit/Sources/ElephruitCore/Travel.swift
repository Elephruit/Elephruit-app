import Foundation

/// Getting to the things on the day.
///
/// ### This stage still knows nothing about maps, and that is now a division of labour
/// It recognises which entries are somewhere you have to *go*, and subtracts however long the
/// journey takes. Where that number comes from is not its business: for a long time the only source
/// was the user, and ``RouteRules`` has since added a measured one that the user can switch on.
/// Neither changes the arithmetic here, which is the point of the split — a wrong ETA and a wrong
/// guess produce the same "leave by", and only one of them costs a location permission.
///
/// The told number remains the floor rather than a fallback of last resort. It needs no permission,
/// no network, and no map, it is never wrong in a way its owner cannot fix, and remembering it per
/// place is what stops anybody saying it twice about the same room. A measurement is allowed to
/// improve on it and is never required to exist.
public enum TravelRules {
    /// The buffer used until somebody says otherwise.
    ///
    /// Fifteen minutes: long enough to be worth blocking, short enough that a wrong default is a
    /// small annoyance rather than a missed meeting.
    public static let defaultMinutes = 15

    /// Whether this entry is somewhere you have to go.
    ///
    /// Three refusals, and each is a way an eager version of this gets it wrong:
    ///
    /// - **No place named.** Nothing to travel to.
    /// - **A conferencing link in the location field**, which is where half the world puts one. A
    ///   "leave by" line under a video call is the app telling somebody to set off for their own
    ///   desk. ``MeetingLink/url(in:)`` already knows how to read that field.
    /// - **All-day entries.** A trip to Berlin is not something you leave for at a quarter to.
    public static func isJourney(to event: CalendarEventSummary) -> Bool {
        guard !event.isAllDay, !event.isCancelled else { return false }
        guard let location = event.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty
        else { return false }
        return MeetingLink.url(in: event) == nil
    }

    /// When to set off, given how long the journey takes.
    public static func leaveBy(_ event: CalendarEventSummary, minutes: Int) -> Date {
        event.startAt.addingTimeInterval(-TimeInterval(max(1, minutes) * 60))
    }

    /// Whether it is already too late for this to be worth saying.
    ///
    /// A "leave by 9:45" under a meeting that started at ten is a reproach, not a plan. The line
    /// disappears once the moment has passed, which is also why this takes the clock rather than
    /// reading it: a page assembled against a fixed moment must not disagree with itself halfway
    /// down.
    public static func isWorthSaying(_ event: CalendarEventSummary, minutes: Int, now: Date) -> Bool {
        isJourney(to: event) && leaveBy(event, minutes: minutes) > now
    }

    /// The key a place is remembered under.
    ///
    /// Case- and space-insensitive, because "Room 2", "room 2" and "Room 2 " are one room and
    /// nobody should have to tell the app twice.
    public static func placeKey(for location: String) -> String {
        location
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Leave by 9:45 AM · 15 min".
    public static func summary(leavingAt moment: Date, minutes: Int) -> String {
        "Leave by " + moment.formatted(date: .omitted, time: .shortened)
            + " · " + DurationPhrase.exact(TimeInterval(minutes * 60))
    }

    /// The same line, saying so when the number was measured rather than given.
    ///
    /// "Leave by 9:45 AM · 12 min drive" against "Leave by 9:45 AM · 15 min". One word, and it is
    /// the difference between a figure the app looked up and a figure its owner supplied. Drawing
    /// them identically would let a guess borrow a measurement's authority, which matters most
    /// exactly when the measurement is unavailable and nobody has been told.
    ///
    /// `nil` for a journey nobody has a number for. There is deliberately no sentence for that case
    /// here — see ``TravelAnswer/invitesAnAnswer``, which decides between silence and an offer.
    public static func summary(leavingAt moment: Date, travel: TravelAnswer) -> String? {
        guard let minutes = travel.minutes else { return nil }
        let base = summary(leavingAt: moment, minutes: minutes)
        guard case .measured(_, let transport, _) = travel else { return base }
        return base + " " + transport.journeyNoun
    }

    /// What a block of travel is called on the calendar.
    ///
    /// The place, not the meeting. "Travel to Room 2" is what the hour is for, and it keeps the
    /// meeting's own title — which may be somebody's name, or a subject they would rather not
    /// publish — out of a second event.
    public static func blockTitle(to location: String) -> String {
        "Travel to " + location.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
