import Foundation

/// Getting to the things on the day, without asking anybody where you are.
///
/// ### Why this stage knows nothing about maps
/// Because "leave by a quarter to" is useful, needs no permission, and cannot be wrong in the way a
/// wrong ETA is wrong. A route lookup means a location service, a network call, and an address
/// leaving the device — all of which this app promises not to do without being asked — and it can
/// still tell somebody with total confidence that they have twenty minutes when the line is down.
///
/// So the first version does the honest, boring thing: it recognises which entries are somewhere you
/// have to *go*, and subtracts however long the user says that takes. The number is theirs, which is
/// why it is never wrong in a way they cannot fix, and remembering it per place is what stops them
/// having to say it twice about the same room.
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

    /// What a block of travel is called on the calendar.
    ///
    /// The place, not the meeting. "Travel to Room 2" is what the hour is for, and it keeps the
    /// meeting's own title — which may be somebody's name, or a subject they would rather not
    /// publish — out of a second event.
    public static func blockTitle(to location: String) -> String {
        "Travel to " + location.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
