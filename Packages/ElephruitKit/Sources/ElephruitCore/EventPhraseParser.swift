import Foundation

// MARK: - What the parser is told

/// Everything the phrase parser is allowed to recognise.
///
/// Handed in rather than looked up, so parsing stays pure: the store and the calendar are consulted
/// once, by the caller, and the grammar never learns what a `ModelContext` or an `EKEventStore` is.
public struct EventPhraseContext: Sendable {
    public var people: [KnownPerson]

    /// Calendar titles, so "on Personal" can be told from "on Tuesday".
    public var calendarNames: [String]

    /// Zones worth recognising by city name — the user's favourites plus wherever they are.
    public var timeZoneIdentifiers: [String]

    /// How long an event is when nobody says.
    public var defaultDurationMinutes: Int

    public init(
        people: [KnownPerson] = [],
        calendarNames: [String] = [],
        timeZoneIdentifiers: [String] = [],
        defaultDurationMinutes: Int = 60
    ) {
        self.people = people
        self.calendarNames = calendarNames
        self.timeZoneIdentifiers = timeZoneIdentifiers
        self.defaultDurationMinutes = defaultDurationMinutes
    }

    public static let empty = EventPhraseContext()
}

// MARK: - What it produces

/// One thing the parser recognised in a phrase, and where it was.
public struct EventPhraseToken: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case date
        case time
        case endTime
        case duration
        case dateRange
        case recurrence
        case location
        case calendar
        case person
        case timeZone
        case alarm

        public var displayLabel: String {
            switch self {
            case .date: "Date"
            case .time: "Time"
            case .endTime: "Ends"
            case .duration: "Length"
            case .dateRange: "Dates"
            case .recurrence: "Repeats"
            case .location: "Where"
            case .calendar: "Calendar"
            case .person: "With"
            case .timeZone: "Zone"
            case .alarm: "Alert"
            }
        }

        public var symbolName: String {
            switch self {
            case .date, .dateRange: "calendar"
            case .time, .endTime, .duration: "clock"
            case .recurrence: "repeat"
            case .location: "mappin.and.ellipse"
            case .calendar: "square.stack"
            case .person: "person"
            case .timeZone: "globe"
            case .alarm: "bell"
            }
        }
    }

    public var id: UUID
    public var kind: Kind

    /// The recognised value, in the app's own words rather than the user's.
    public var text: String

    /// Character offsets into the input, so the field can underline what it understood.
    public var range: Range<Int>

    /// The person or calendar this resolved to, when it resolved to one.
    public var resolvedID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        range: Range<Int>,
        resolvedID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.range = range
        self.resolvedID = resolvedID
    }
}

/// A phrase, understood.
///
/// Deliberately a *description* rather than a draft. The draft is built from this by a caller that
/// knows what today is and which calendars exist — which keeps the parser testable without a clock
/// and means a phrase typed before midnight still means the right thing when it is saved after.
public struct EventPhraseInterpretation: Sendable, Hashable {
    /// What is left after every recognised span is removed.
    public var title: String

    public var tokens: [EventPhraseToken]

    public var day: DateExpression?
    public var endDay: DateExpression?
    public var time: TimeOfDay?
    public var endTime: TimeOfDay?
    public var durationMinutes: Int?
    public var isAllDay: Bool
    public var recurrence: EventRecurrence?
    public var location: String?
    public var calendarName: String?
    public var personName: String?
    public var personID: UUID?
    public var timeZoneIdentifier: String?
    public var alarmMinutesBefore: Int?

    /// The text as typed, verbatim.
    public var originalText: String

    public init(
        title: String = "",
        tokens: [EventPhraseToken] = [],
        day: DateExpression? = nil,
        endDay: DateExpression? = nil,
        time: TimeOfDay? = nil,
        endTime: TimeOfDay? = nil,
        durationMinutes: Int? = nil,
        isAllDay: Bool = false,
        recurrence: EventRecurrence? = nil,
        location: String? = nil,
        calendarName: String? = nil,
        personName: String? = nil,
        personID: UUID? = nil,
        timeZoneIdentifier: String? = nil,
        alarmMinutesBefore: Int? = nil,
        originalText: String = ""
    ) {
        self.title = title
        self.tokens = tokens
        self.day = day
        self.endDay = endDay
        self.time = time
        self.endTime = endTime
        self.durationMinutes = durationMinutes
        self.isAllDay = isAllDay
        self.recurrence = recurrence
        self.location = location
        self.calendarName = calendarName
        self.personName = personName
        self.personID = personID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.alarmMinutesBefore = alarmMinutesBefore
        self.originalText = originalText
    }

    /// Whether anything at all was understood.
    public var isEmpty: Bool {
        title.isEmpty && tokens.isEmpty
    }

    /// Whether enough was understood to make an event.
    ///
    /// A title alone is enough: "Dentist" with no date is an event today, which is a reasonable
    /// reading and one the preview shows before anything is saved.
    public var isUsable: Bool {
        !title.isEmpty || day != nil || time != nil
    }

    /// Turns this into a draft, given a clock and the calendars that exist.
    public func draft(
        defaultCalendarIdentifier: String,
        calendars: [CalendarInfo],
        dateProvider: any DateProvider,
        defaultDurationMinutes: Int = 60
    ) -> EventDraft? {
        let calendarIdentifier = resolvedCalendar(among: calendars)?.id ?? defaultCalendarIdentifier
        let calendar = dateProvider.calendar

        // A phrase with no day at all means today, which is what somebody typing "lunch at noon"
        // into a calendar means.
        let dayExpression = day ?? .today
        guard let dayStart = dayExpression.resolve(using: dateProvider) else { return nil }

        if isAllDay {
            let endExpression = endDay ?? dayExpression
            let endStart = endExpression.resolve(using: dateProvider) ?? dayStart
            // An all-day range is inclusive as people say it — "August 10 through August 17" is
            // eight days — and exclusive as EventKit stores it, so the end moves on by one.
            let end = calendar.date(byAdding: .day, value: 1, to: max(dayStart, endStart)) ?? dayStart

            return EventDraft(
                calendarIdentifier: calendarIdentifier,
                title: title,
                startAt: dayStart,
                endAt: end,
                isAllDay: true,
                location: location ?? "",
                alarms: alarms,
                recurrence: recurrence
            )
        }

        guard let start = dayExpression.resolve(using: dateProvider, at: time) else { return nil }

        let end: Date
        if let endTime, let candidate = dayExpression.resolve(using: dateProvider, at: endTime) {
            // "9 to 5" is a working day; "11pm to 1am" is two hours across midnight rather than a
            // negative twenty-two.
            end = candidate > start
                ? candidate
                : (calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
        } else {
            let minutes = durationMinutes ?? defaultDurationMinutes
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        }

        return EventDraft(
            calendarIdentifier: calendarIdentifier,
            title: title,
            startAt: start,
            endAt: end,
            isAllDay: false,
            timeZoneIdentifier: timeZoneIdentifier,
            location: location ?? "",
            alarms: alarms,
            recurrence: recurrence
        )
    }

    private var alarms: [EventAlarm] {
        guard let alarmMinutesBefore else { return [] }
        return [.minutesBefore(alarmMinutesBefore)]
    }

    /// The calendar this phrase named, matched loosely because people type half a name.
    public func resolvedCalendar(among calendars: [CalendarInfo]) -> CalendarInfo? {
        guard let calendarName else { return nil }
        let wanted = TextNormalizer.foldedForMatching(calendarName)

        if let exact = calendars.first(where: { TextNormalizer.foldedForMatching($0.title) == wanted }) {
            return exact
        }
        return calendars.first {
            TextNormalizer.foldedForMatching($0.title).hasPrefix(wanted) && $0.allowsModification
        }
    }
}

// MARK: - The parser

/// Reads a sentence about an event.
///
/// ### Why this is a scanner rather than a grammar
/// The phrases people type are not a language with a syntax. "Dentist Friday at 9 for 45 minutes"
/// and "Friday 9am dentist 45min" mean the same thing, and no ordering rule covers both. So the
/// parser looks for *recognisable spans* — a date, a time, a duration, a person, a calendar — claims
/// each one, and treats whatever is left as the title. Nothing is guessed at: an unrecognised word
/// stays in the title, where the user can see it.
///
/// ### The one genuinely ambiguous word
/// `at` introduces both a time and a place: "at 7" and "at Aba". The rule is that `at` followed by
/// something that parses as a time is a time, and `at` followed by anything else is a place — which
/// gets "Dinner at Aba Saturday at 7" right, and is visible in the preview when it does not.
public enum EventPhraseParser {
    /// A word, with where it was.
    struct Word {
        var text: String
        var range: Range<Int>
        var claimed = false
    }

    public static func parse(
        _ input: String,
        context: EventPhraseContext = .empty,
        calendar: Calendar
    ) -> EventPhraseInterpretation {
        var interpretation = EventPhraseInterpretation(originalText: input)

        var words = tokenize(input)
        guard !words.isEmpty else { return interpretation }

        // Order matters, and each of these consumes the words it recognised so a later matcher
        // cannot claim them again. Recurrence first because "every Tuesday at 10" contains a
        // weekday that the date matcher would otherwise take as a one-off.
        matchRecurrence(&words, into: &interpretation, calendar: calendar)
        matchAlarm(&words, into: &interpretation)
        matchDateRange(&words, into: &interpretation)
        matchTimeZone(&words, into: &interpretation, context: context)
        matchDuration(&words, into: &interpretation)
        matchTimeRange(&words, into: &interpretation)
        matchTime(&words, into: &interpretation)
        matchDate(&words, into: &interpretation)
        matchCalendar(&words, into: &interpretation, context: context)
        matchPerson(&words, into: &interpretation, context: context)
        matchLocation(&words, into: &interpretation)

        interpretation.title = remainingTitle(words)
        interpretation.tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        return interpretation
    }

    // MARK: Tokenizing

    static func tokenize(_ input: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var start = 0
        var offset = 0

        func flush() {
            guard !current.isEmpty else { return }
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if !trimmed.isEmpty {
                words.append(Word(text: trimmed, range: start..<(start + trimmed.count)))
            }
            current = ""
        }

        for character in input {
            if character.isWhitespace {
                flush()
                offset += 1
                start = offset
            } else {
                current.append(character)
                offset += 1
            }
        }
        flush()

        return words
    }

    /// The words nobody claimed, rejoined.
    static func remainingTitle(_ words: [Word]) -> String {
        words
            .filter { !$0.claimed }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
    }

    static func claim(_ words: inout [Word], _ indices: Range<Int>) {
        for index in indices where index < words.count {
            words[index].claimed = true
        }
    }

    static func span(_ words: [Word], _ indices: Range<Int>) -> Range<Int> {
        let lower = words[indices.lowerBound].range.lowerBound
        let upper = words[indices.upperBound - 1].range.upperBound
        return lower..<upper
    }

    // MARK: Recurrence

    /// "every Tuesday", "every day", "every 2 weeks", "weekly", "daily", "every month".
    static func matchRecurrence(
        _ words: inout [Word],
        into interpretation: inout EventPhraseInterpretation,
        calendar: Calendar
    ) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()

            if let simple = simpleFrequency(word) {
                interpretation.recurrence = simple
                claim(&words, index..<(index + 1))
                interpretation.tokens.append(
                    EventPhraseToken(kind: .recurrence, text: simple.summary, range: words[index].range)
                )
                return
            }

            guard word == "every" else { continue }

            var end = index + 1
            var interval = 1

            // "every 2 weeks"
            if end < words.count, let number = Int(words[end].text) {
                interval = max(1, number)
                end += 1
            }

            guard end < words.count else { continue }
            let unit = words[end].text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ","))

            let rule: EventRecurrence?
            if let weekday = weekdayNumber(unit) {
                rule = EventRecurrence(frequency: .weekly, interval: interval, daysOfWeek: [.init(weekday)])
            } else {
                rule = switch unit {
                case "day", "days": EventRecurrence(frequency: .daily, interval: interval)
                case "week", "weeks": EventRecurrence(frequency: .weekly, interval: interval)
                case "month", "months": EventRecurrence(frequency: .monthly, interval: interval)
                case "year", "years": EventRecurrence(frequency: .yearly, interval: interval)
                case "weekday", "weekdays": EventRecurrence(frequency: .weekly, daysOfWeek: (2...6).map { .init($0) })
                default: nil
                }
            }

            guard let rule else { continue }

            interpretation.recurrence = rule
            let range = span(words, index..<(end + 1))
            claim(&words, index..<(end + 1))
            interpretation.tokens.append(EventPhraseToken(kind: .recurrence, text: rule.summary, range: range))
            return
        }
    }

    static func simpleFrequency(_ word: String) -> EventRecurrence? {
        switch word {
        case "daily": EventRecurrence(frequency: .daily)
        case "weekly": EventRecurrence(frequency: .weekly)
        case "fortnightly", "biweekly": EventRecurrence(frequency: .weekly, interval: 2)
        case "monthly": EventRecurrence(frequency: .monthly)
        case "yearly", "annually": EventRecurrence(frequency: .yearly)
        default: nil
        }
    }

    static func weekdayNumber(_ word: String) -> Int? {
        switch word.lowercased() {
        case "sunday", "sun", "sundays": 1
        case "monday", "mon", "mondays": 2
        case "tuesday", "tue", "tues", "tuesdays": 3
        case "wednesday", "wed", "wednesdays": 4
        case "thursday", "thu", "thur", "thurs", "thursdays": 5
        case "friday", "fri", "fridays": 6
        case "saturday", "sat", "saturdays": 7
        default: nil
        }
    }

    // MARK: Alarms

    /// "remind me 10 minutes before", "alert 15 min before", "with a 30 minute reminder".
    static func matchAlarm(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()
            guard ["remind", "reminder", "alert", "alarm", "notify"].contains(word) else { continue }

            // Look either side for a number followed by a unit.
            let window = max(0, index - 3)..<min(words.count, index + 5)
            for candidate in window where candidate + 1 < words.count {
                guard let number = Int(words[candidate].text) else { continue }
                guard let unit = durationUnit(words[candidate + 1].text) else { continue }

                let minutes = number * unit
                interpretation.alarmMinutesBefore = minutes

                let lower = min(index, candidate)
                var upper = max(index, candidate + 1) + 1
                // Swallow "before" and "me" so they do not end up in the title.
                if upper < words.count, ["before", "beforehand", "ahead"].contains(words[upper].text.lowercased()) {
                    upper += 1
                }

                let range = span(words, lower..<upper)
                claim(&words, lower..<upper)
                interpretation.tokens.append(
                    EventPhraseToken(
                        kind: .alarm,
                        text: EventAlarm.minutesBefore(minutes).displayName,
                        range: range
                    )
                )
                return
            }
        }
    }

    /// Minutes per unit, for "45 minutes", "2 hours", "3 days".
    static func durationUnit(_ word: String) -> Int? {
        switch word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.")) {
        case "min", "mins", "minute", "minutes", "m": 1
        case "hour", "hours", "hr", "hrs", "h": 60
        case "day", "days": 1_440
        case "week", "weeks": 10_080
        default: nil
        }
    }

    // MARK: All-day ranges

    /// "August 10 through August 17", "10 August to 17 August", "Monday through Friday".
    ///
    /// A range of *days* rather than times, so it produces an all-day event. Somebody who types
    /// "through" means whole days; a range of times uses "to" with two clock times and is handled by
    /// ``matchTimeRange(_:into:)``.
    static func matchDateRange(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()
            guard ["through", "thru", "til", "till", "until", "to", "-", "–"].contains(word) else { continue }
            guard index > 0, index + 1 < words.count else { continue }

            // The longest date phrase ending just before the connector, and the longest starting
            // just after it. Both have to parse, or this is not a date range at all.
            guard let before = longestDate(in: words, endingAt: index) else { continue }
            guard let after = longestDate(in: words, startingAt: index + 1) else { continue }

            interpretation.day = before.expression
            interpretation.endDay = after.expression
            interpretation.isAllDay = true

            let range = span(words, before.indices.lowerBound..<after.indices.upperBound)
            claim(&words, before.indices.lowerBound..<after.indices.upperBound)
            interpretation.tokens.append(
                EventPhraseToken(
                    kind: .dateRange,
                    text: "\(before.expression.summary) – \(after.expression.summary)",
                    range: range
                )
            )
            return
        }
    }

    /// The longest run of words ending at `end` that parses as a date.
    static func longestDate(
        in words: [Word],
        endingAt end: Int
    ) -> (expression: DateExpression, indices: Range<Int>)? {
        for start in stride(from: max(0, end - 3), to: end, by: 1) {
            guard !words[start...(end - 1)].contains(where: \.claimed) else { continue }
            let phrase = words[start..<end].map(\.text).joined(separator: " ")
            if let parsed = NaturalDateParser.interpret(phrase)?.day {
                return (parsed, start..<end)
            }
        }
        return nil
    }

    /// The longest run of words starting at `start` that parses as a date.
    static func longestDate(
        in words: [Word],
        startingAt start: Int
    ) -> (expression: DateExpression, indices: Range<Int>)? {
        var best: (DateExpression, Range<Int>)?

        for end in (start + 1)...min(words.count, start + 3) {
            guard !words[start..<end].contains(where: \.claimed) else { break }
            let phrase = words[start..<end].map(\.text).joined(separator: " ")
            if let parsed = NaturalDateParser.interpret(phrase)?.day {
                best = (parsed, start..<end)
            }
        }
        return best.map { (expression: $0.0, indices: $0.1) }
    }

    // MARK: Time zones

    /// "London time", "in Tokyo time", "PT", "UTC".
    static func matchTimeZone(
        _ words: inout [Word],
        into interpretation: inout EventPhraseInterpretation,
        context: EventPhraseContext
    ) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()

            // A city followed by the word "time" — the shape people actually use.
            if index + 1 < words.count, words[index + 1].text.lowercased() == "time",
               let identifier = zoneIdentifier(matching: word, among: context.timeZoneIdentifiers) {
                interpretation.timeZoneIdentifier = identifier
                let range = span(words, index..<(index + 2))
                claim(&words, index..<(index + 2))
                interpretation.tokens.append(
                    EventPhraseToken(kind: .timeZone, text: shortZoneName(identifier), range: range)
                )
                return
            }

            // A bare abbreviation. Kept to a short list on purpose: "CET" is unambiguous, "IST"
            // means three different things, and guessing wrong moves a meeting by hours.
            if let identifier = abbreviationZone(word) {
                interpretation.timeZoneIdentifier = identifier
                claim(&words, index..<(index + 1))
                interpretation.tokens.append(
                    EventPhraseToken(kind: .timeZone, text: shortZoneName(identifier), range: words[index].range)
                )
                return
            }
        }
    }

    static func zoneIdentifier(matching word: String, among identifiers: [String]) -> String? {
        let wanted = word.lowercased()

        // The user's own favourites first, then every zone the system knows, so "Reykjavik time"
        // works without anybody having pinned it.
        for identifier in identifiers + TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            if city.replacingOccurrences(of: "_", with: " ").lowercased() == wanted { return identifier }
        }
        return nil
    }

    static func abbreviationZone(_ word: String) -> String? {
        switch word.uppercased() {
        case "UTC", "GMT": "GMT"
        case "PT", "PST", "PDT": "America/Los_Angeles"
        case "MT", "MST", "MDT": "America/Denver"
        case "CT", "CST", "CDT": "America/Chicago"
        case "ET", "EST", "EDT": "America/New_York"
        case "BST": "Europe/London"
        case "CET", "CEST": "Europe/Paris"
        case "JST": "Asia/Tokyo"
        case "AEST", "AEDT": "Australia/Sydney"
        default: nil
        }
    }

    static func shortZoneName(_ identifier: String) -> String {
        identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
    }

    // MARK: Duration

    /// "for 45 minutes", "for 2 hours", "45min", "for an hour".
    static func matchDuration(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()

            // "45min" written as one word.
            if let compact = compactDuration(word) {
                interpretation.durationMinutes = compact
                claim(&words, index..<(index + 1))
                interpretation.tokens.append(
                    EventPhraseToken(
                        kind: .duration,
                        text: EventAlarm.durationPhrase(compact),
                        range: words[index].range
                    )
                )
                return
            }

            guard word == "for" || word == "lasting" else { continue }
            guard index + 2 < words.count + 1 else { continue }

            var cursor = index + 1
            var amount: Int?

            if cursor < words.count {
                if let number = Int(words[cursor].text) {
                    amount = number
                    cursor += 1
                } else if ["a", "an", "one"].contains(words[cursor].text.lowercased()) {
                    amount = 1
                    cursor += 1
                } else if ["half"].contains(words[cursor].text.lowercased()) {
                    // "for half an hour" — the fraction is carried by the unit below.
                    amount = 1
                    cursor += 1
                    if cursor < words.count, ["a", "an"].contains(words[cursor].text.lowercased()) {
                        cursor += 1
                    }
                    guard cursor < words.count, let unit = durationUnit(words[cursor].text) else { continue }

                    let minutes = max(1, unit / 2)
                    interpretation.durationMinutes = minutes
                    let range = span(words, index..<(cursor + 1))
                    claim(&words, index..<(cursor + 1))
                    interpretation.tokens.append(
                        EventPhraseToken(
                            kind: .duration, text: EventAlarm.durationPhrase(minutes), range: range
                        )
                    )
                    return
                }
            }

            guard let amount, cursor < words.count, let unit = durationUnit(words[cursor].text) else { continue }

            let minutes = amount * unit
            interpretation.durationMinutes = minutes
            let range = span(words, index..<(cursor + 1))
            claim(&words, index..<(cursor + 1))
            interpretation.tokens.append(
                EventPhraseToken(kind: .duration, text: EventAlarm.durationPhrase(minutes), range: range)
            )
            return
        }
    }

    /// "45min", "2h", "90m" — a number glued to a unit.
    static func compactDuration(_ word: String) -> Int? {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty, let amount = Int(digits) else { return nil }

        let suffix = String(word.dropFirst(digits.count))
        guard !suffix.isEmpty, let unit = durationUnit(suffix) else { return nil }
        return amount * unit
    }

    // MARK: Times

    /// "3-4pm", "from 9 to 11", "9am to 5pm".
    static func matchTimeRange(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()
            guard ["to", "until", "til", "till", "-", "–"].contains(word) else { continue }
            guard index > 0, index + 1 < words.count else { continue }
            guard !words[index - 1].claimed, !words[index + 1].claimed else { continue }

            guard let start = clockTime(words[index - 1].text),
                  let end = clockTime(words[index + 1].text)
            else { continue }

            interpretation.time = start
            interpretation.endTime = end

            var lower = index - 1
            // "from 9 to 11" — take the preposition too.
            if lower > 0, ["from", "at"].contains(words[lower - 1].text.lowercased()) { lower -= 1 }

            let range = span(words, lower..<(index + 2))
            claim(&words, lower..<(index + 2))
            interpretation.tokens.append(
                EventPhraseToken(kind: .time, text: start.summary, range: range)
            )
            interpretation.tokens.append(
                EventPhraseToken(kind: .endTime, text: end.summary, range: range)
            )
            return
        }
    }

    /// "at noon", "at 3 PM", "at 9", "9:30am".
    static func matchTime(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        guard interpretation.time == nil else { return }

        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()

            // "at 3 PM" — the meridiem is its own word.
            if index + 1 < words.count, !words[index + 1].claimed {
                let next = words[index + 1].text.lowercased()
                if ["am", "pm", "a.m.", "p.m."].contains(next),
                   let time = NaturalDateParser.parseTimeOfDay(word + next.replacingOccurrences(of: ".", with: "")) {
                    var lower = index
                    if lower > 0, words[lower - 1].text.lowercased() == "at", !words[lower - 1].claimed {
                        lower -= 1
                    }
                    interpretation.time = time
                    let range = span(words, lower..<(index + 2))
                    claim(&words, lower..<(index + 2))
                    interpretation.tokens.append(
                        EventPhraseToken(kind: .time, text: time.summary, range: range)
                    )
                    return
                }
            }

            // "noon", "midday", "midnight".
            if let named = namedTime(word) {
                var lower = index
                if lower > 0, words[lower - 1].text.lowercased() == "at", !words[lower - 1].claimed {
                    lower -= 1
                }
                interpretation.time = named
                let range = span(words, lower..<(index + 1))
                claim(&words, lower..<(index + 1))
                interpretation.tokens.append(EventPhraseToken(kind: .time, text: named.summary, range: range))
                return
            }

            // "3pm", "10:30", written as one word.
            if let time = NaturalDateParser.parseTimeOfDay(word) {
                var lower = index
                if lower > 0, words[lower - 1].text.lowercased() == "at", !words[lower - 1].claimed {
                    lower -= 1
                }
                interpretation.time = time
                let range = span(words, lower..<(index + 1))
                claim(&words, lower..<(index + 1))
                interpretation.tokens.append(EventPhraseToken(kind: .time, text: time.summary, range: range))
                return
            }

            // "at 7" — a bare number, and only after the word `at`, which is what makes it a time
            // rather than a quantity. See `NaturalDateParser.appointmentTime`.
            if word == "at", index + 1 < words.count, !words[index + 1].claimed {
                // "at 3 PM" reaches here rather than the pair branch above, because that one looks
                // at the *first* word of the pair and this one starts at the preposition. Taking the
                // meridiem here is what stops a stray "PM" ending up in the title.
                var end = index + 2
                var time: TimeOfDay?

                if end < words.count, !words[end].claimed,
                   ["am", "pm", "a.m.", "p.m."].contains(words[end].text.lowercased()) {
                    let joined = words[index + 1].text
                        + words[end].text.lowercased().replacingOccurrences(of: ".", with: "")
                    time = NaturalDateParser.parseTimeOfDay(joined)
                    end += 1
                } else {
                    time = appointmentTime(words[index + 1].text, phrase: interpretation.originalText)
                }

                if let time {
                    interpretation.time = time
                    let range = span(words, index..<end)
                    claim(&words, index..<end)
                    interpretation.tokens.append(EventPhraseToken(kind: .time, text: time.summary, range: range))
                    return
                }
            }
        }
    }

    /// A bare hour, read the way the rest of the sentence suggests.
    ///
    /// ### Why the phrase gets a say
    /// ``NaturalDateParser/appointmentTime(_:)`` reads a bare hour as an appointment — one to six in
    /// the afternoon, seven to eleven in the morning — which is right for "meet Maya at 2" and wrong
    /// for "dinner at 7". Nobody eats dinner at seven in the morning, and the words are right there.
    ///
    /// So a short list of words that name a time of day shifts the reading, and nothing else does.
    /// The list is deliberately small: a heuristic that grows to cover every noun starts guessing
    /// about words people meant literally, and this one is visible in the preview before anything is
    /// saved.
    static func appointmentTime(_ token: String, phrase: String) -> TimeOfDay? {
        guard let base = NaturalDateParser.appointmentTime(token) else { return nil }

        let lowered = phrase.lowercased()
        let evening = ["dinner", "supper", "drinks", "party", "concert", "movie", "film", "show", "gig"]
        let morning = ["breakfast", "standup", "stand-up", "gym", "run", "swim", "flight"]

        if evening.contains(where: lowered.contains), (5...11).contains(base.hour) {
            return TimeOfDay(hour: base.hour + 12, minute: base.minute) ?? base
        }
        if morning.contains(where: lowered.contains), (13...18).contains(base.hour) {
            return TimeOfDay(hour: base.hour - 12, minute: base.minute) ?? base
        }
        return base
    }

    static func namedTime(_ word: String) -> TimeOfDay? {
        switch word {
        case "noon", "midday": TimeOfDay(hour: 12, minute: 0)
        case "midnight": TimeOfDay(hour: 0, minute: 0)
        default: nil
        }
    }

    /// A clock time in any of the forms a range's ends come in.
    static func clockTime(_ word: String) -> TimeOfDay? {
        if let named = namedTime(word.lowercased()) { return named }
        if let parsed = NaturalDateParser.parseTimeOfDay(word) { return parsed }
        return NaturalDateParser.appointmentTime(word)
    }

    // MARK: Dates

    static func matchDate(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        guard interpretation.day == nil else { return }

        for index in words.indices where !words[index].claimed {
            guard let found = longestDate(in: words, startingAt: index) else { continue }

            interpretation.day = found.expression
            let range = span(words, found.indices)
            claim(&words, found.indices)
            interpretation.tokens.append(
                EventPhraseToken(kind: .date, text: found.expression.summary, range: range)
            )
            return
        }
    }

    // MARK: Calendars

    /// "on Personal", "on my Work calendar".
    static func matchCalendar(
        _ words: inout [Word],
        into interpretation: inout EventPhraseInterpretation,
        context: EventPhraseContext
    ) {
        guard !context.calendarNames.isEmpty else { return }

        for index in words.indices where !words[index].claimed {
            guard ["on", "in", "to"].contains(words[index].text.lowercased()) else { continue }

            var start = index + 1
            if start < words.count, ["my", "the"].contains(words[start].text.lowercased()) { start += 1 }
            guard start < words.count, !words[start].claimed else { continue }

            // The longest calendar name that matches from here.
            for length in stride(from: min(3, words.count - start), to: 0, by: -1) {
                let end = start + length
                guard !words[start..<end].contains(where: \.claimed) else { continue }

                let phrase = words[start..<end].map(\.text).joined(separator: " ")
                guard let matched = matchCalendarName(phrase, among: context.calendarNames) else { continue }

                interpretation.calendarName = matched

                var upper = end
                if upper < words.count, words[upper].text.lowercased() == "calendar" { upper += 1 }

                let range = span(words, index..<upper)
                claim(&words, index..<upper)
                interpretation.tokens.append(
                    EventPhraseToken(kind: .calendar, text: matched, range: range)
                )
                return
            }
        }
    }

    static func matchCalendarName(_ phrase: String, among names: [String]) -> String? {
        let wanted = TextNormalizer.foldedForMatching(phrase)
        guard !wanted.isEmpty else { return nil }
        return names.first { TextNormalizer.foldedForMatching($0) == wanted }
    }

    // MARK: People

    /// "with Maya", "with Maya Chen".
    static func matchPerson(
        _ words: inout [Word],
        into interpretation: inout EventPhraseInterpretation,
        context: EventPhraseContext
    ) {
        for index in words.indices where !words[index].claimed {
            guard words[index].text.lowercased() == "with" else { continue }
            let start = index + 1
            guard start < words.count, !words[start].claimed else { continue }

            // Longest known name first, so "Maya Chen" wins over "Maya" when both are known.
            for length in stride(from: min(3, words.count - start), to: 0, by: -1) {
                let end = start + length
                guard !words[start..<end].contains(where: \.claimed) else { continue }

                let phrase = TextNormalizer.foldedForMatching(
                    words[start..<end].map(\.text).joined(separator: " ")
                )

                guard let person = context.people.first(where: { $0.matchKeys.contains(phrase) }) else {
                    continue
                }

                interpretation.personName = person.fullName
                interpretation.personID = person.id

                // The person's *name* stays in the title — "Lunch with Maya" is what the event is
                // called, and stripping it leaves an event called "Lunch" that says nothing on a
                // shared calendar. Only the link is taken.
                interpretation.tokens.append(
                    EventPhraseToken(
                        kind: .person,
                        text: person.fullName,
                        range: span(words, start..<end),
                        resolvedID: person.id
                    )
                )
                return
            }

            // A name nobody knows. Recorded so the preview can offer to create them, and left in the
            // title either way.
            let name = words[start].text
            guard name.first?.isUppercase == true else { return }
            interpretation.personName = name
            interpretation.tokens.append(
                EventPhraseToken(kind: .person, text: name, range: words[start].range)
            )
            return
        }
    }

    // MARK: Locations

    /// "at Aba", "in Room 3".
    ///
    /// Runs last, after every time has been claimed, which is what makes `at` unambiguous: anything
    /// still following `at` by this point is not a time.
    static func matchLocation(_ words: inout [Word], into interpretation: inout EventPhraseInterpretation) {
        for index in words.indices where !words[index].claimed {
            let word = words[index].text.lowercased()
            guard ["at", "in"].contains(word) else { continue }

            var start = index + 1
            if start < words.count, ["the"].contains(words[start].text.lowercased()) { start += 1 }
            guard start < words.count, !words[start].claimed else { continue }

            // Everything up to the next claimed word, which is where the recognised structure
            // resumes — so "Dinner at Aba Saturday at 7" keeps "Aba" and stops before "Saturday".
            var end = start
            while end < words.count, !words[end].claimed { end += 1 }
            guard end > start else { continue }

            let text = words[start..<end].map(\.text).joined(separator: " ")
            interpretation.location = text

            let range = span(words, index..<end)
            claim(&words, index..<end)
            interpretation.tokens.append(EventPhraseToken(kind: .location, text: text, range: range))
            return
        }
    }
}
