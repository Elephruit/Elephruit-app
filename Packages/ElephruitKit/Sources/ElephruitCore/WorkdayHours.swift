import Foundation

/// The hours the user actually works, and where that answer came from.
///
/// ### Why the source travels with the hours
/// Because there are three possible answers and two of them are wrong to state as fact. A calendar
/// set says nine to six; the app's own setting says eight to four; a library that has neither gets
/// nine to five because something has to be assumed. Only the first two were chosen by anybody, and
/// a settings screen that shows the third as though the user had picked it is lying quietly — which
/// is exactly what the phone did before this existed. See ``Source/isChosen``.
///
/// The order is deliberate and is the one the calendar module already implies: a set is a context
/// somebody switched into, and switching into Family should change what "the working day" means for
/// as long as you are in it. The app default is what applies the rest of the time.
public struct WorkdayHours: Sendable, Hashable {
    /// Which of the three answers this is.
    public enum Source: Sendable, Hashable {
        /// An active calendar set's own hours, which override everything.
        case calendarSet(name: String)

        /// The app-wide setting, which is what most people will ever have.
        case appDefault

        /// Nobody has said. Nine to five, Monday to Friday, and the interface should say so rather
        /// than presenting it as a decision.
        case assumed

        /// Whether a person actually chose these hours.
        public var isChosen: Bool { self != .assumed }
    }

    public var hours: WorkingHours
    public var source: Source

    public init(hours: WorkingHours, source: Source) {
        self.hours = hours
        self.source = source
    }

    /// What is used when nothing has been said.
    public static let assumed = WorkdayHours(hours: .standard, source: .assumed)

    /// The whole answer in one line — "9:00 AM – 5:00 PM, Mon–Fri".
    ///
    /// ### Why not ``WorkingHours/summary``
    /// Because that one is hard 24-hour — `%d:%02d` — and it is read beside time pickers, which are
    /// not. The first screenshot of the settings screen had "Starts 9:00 AM" three lines above
    /// "assuming 9:00–17:00", which is one screen disagreeing with itself about a number the user is
    /// being asked to trust. The other summary stays as it is: it labels a grid axis on the Mac,
    /// where compactness wins and there is nothing beside it to contradict.
    public var summary: String {
        WorkdayHours.timeLabel(hours.startMinutes) + " – " + WorkdayHours.timeLabel(hours.endMinutes)
            + ", " + WorkdayHours.weekdaySummary(hours.weekdays)
    }

    /// Minutes from midnight, said the way this reader's system says times.
    ///
    /// Anchored to an arbitrary day, because minutes-from-midnight carry no date and the formatter
    /// wants one. Which day is immaterial: only the hour and minute are ever shown.
    public static func timeLabel(_ minutes: Int, calendar: Calendar = .current) -> String {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let moment = midnight.addingTimeInterval(TimeInterval(minutes * 60))
        return moment.formatted(date: .omitted, time: .shortened)
    }

    /// How long the working day is on a given date, or `nil` when it is not a working day.
    ///
    /// The denominator behind "4h 20m free of 8h": free time on its own says how much room is left
    /// and not how much of the day that is, and half an hour free is a different day depending on
    /// whether the day is two hours long or ten.
    public func length(on day: Date, calendar: Calendar) -> TimeInterval? {
        guard let window = hours.window(on: day, calendar: calendar) else { return nil }
        return window.upperBound.timeIntervalSince(window.lowerBound)
    }

    /// "Mon–Fri", "Mon, Wed, Fri", "Every day", "No days".
    ///
    /// Contracts a run only when it is genuinely contiguous, so a Tuesday-to-Saturday week reads as
    /// a range and a Monday/Wednesday/Friday week does not get flattened into one.
    public static func weekdaySummary(_ weekdays: Set<Int>) -> String {
        let ordered = weekdays.filter { (1...7).contains($0) }.sorted()
        guard !ordered.isEmpty else { return "No days" }
        guard ordered.count < 7 else { return "Every day" }

        let names = ordered.map { shortName($0) }
        guard ordered.count > 2, isContiguous(ordered) else {
            return ListPhrase.joined(names)
        }
        return (names.first ?? "") + "–" + (names.last ?? "")
    }

    private static func isContiguous(_ ordered: [Int]) -> Bool {
        zip(ordered, ordered.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// Three-letter weekday names, 1-based with Sunday as 1, matching ``WorkingHours/weekdays``.
    ///
    /// From the calendar's own symbols rather than a literal list, so this is not the one place in
    /// the app that only speaks English.
    public static func shortName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "\(weekday)" }
        return symbols[index]
    }
}
