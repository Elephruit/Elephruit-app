import Foundation

/// A link into the calendar.
///
/// ### Read-only by construction
/// Every case here **navigates**. There is no case that creates, changes, or deletes anything, and
/// there is no initialiser that could produce one — which matters because a URL can be clicked from
/// an email, a web page, or a document, by anything, with no confirmation step in front of it. A
/// scheme that could write would be a write nobody agreed to.
///
/// That is the same rule the App Intents follow, arrived at from the other direction: an intent runs
/// unattended and a link arrives from outside, and neither can ask a person which occurrences an
/// edit should reach.
public enum CalendarDeepLink: Sendable, Hashable {
    /// `elephruit://calendar` — the calendar as it was left.
    case calendar

    /// `elephruit://calendar/day/2026-08-14` — a particular day.
    case day(DayKeyComponents)

    /// `elephruit://calendar/event/<identity>` — one event, if it still exists.
    case event(EventIdentity)

    /// `elephruit://calendar/set/Work` — switch to a Calendar Set and show it.
    ///
    /// The one link with a side effect, and it is a *display* one: it changes which calendars are on
    /// screen and nothing about their contents. Reversible with one click, and visible the moment it
    /// happens.
    case set(name: String)

    /// A year, month, and day, kept as components rather than a `Date`.
    ///
    /// A link names a calendar day — "the fourteenth of August" — not an instant, and resolving it
    /// to a `Date` inside the parser would bake in whatever time zone the parser happened to run in.
    /// The workspace resolves it in the zone the calendar is being drawn in, which is the only one
    /// that gives the right day.
    public struct DayKeyComponents: Sendable, Hashable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public func resolve(in calendar: Calendar) -> Date? {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components)
        }
    }

    /// Reads a URL, or `nil` when it is not one of ours.
    ///
    /// Deliberately strict. An unrecognised path is refused rather than falling back to "open the
    /// calendar", because a link that silently does something *other* than what it says is worse
    /// than one that does nothing.
    public static func parse(_ url: URL) -> CalendarDeepLink? {
        guard url.scheme?.lowercased() == "elephruit" else { return nil }

        // `elephruit://calendar/day/2026-08-14` puts "calendar" in the host and the rest in the path.
        let host = url.host()?.lowercased()
        let components = url.pathComponents.filter { $0 != "/" }

        guard host == "calendar" else { return nil }
        guard let first = components.first else { return .calendar }

        switch first.lowercased() {
        case "day":
            guard components.count >= 2, let day = parseDay(components[1]) else { return nil }
            return .day(day)

        case "event":
            guard components.count >= 2 else { return nil }
            let raw = components[1].removingPercentEncoding ?? components[1]
            guard let identity = EventIdentity.fromStorageKey(raw) else { return nil }
            return .event(identity)

        case "set":
            guard components.count >= 2 else { return nil }
            let name = components[1].removingPercentEncoding ?? components[1]
            return name.isEmpty ? nil : .set(name: name)

        default:
            return nil
        }
    }

    /// `2026-08-14`.
    static func parseDay(_ text: String) -> DayKeyComponents? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }

        return DayKeyComponents(year: year, month: month, day: day)
    }

    /// The URL for this link, so the app can offer one to copy.
    public var url: URL? {
        switch self {
        case .calendar:
            return URL(string: "elephruit://calendar")
        case .day(let components):
            let text = DayKey.string(year: components.year, month: components.month, day: components.day)
            return URL(string: "elephruit://calendar/day/\(text)")
        case .event(let identity):
            let encoded = identity.storageKey
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? identity.storageKey
            return URL(string: "elephruit://calendar/event/\(encoded)")
        case .set(let name):
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
            return URL(string: "elephruit://calendar/set/\(encoded)")
        }
    }
}
