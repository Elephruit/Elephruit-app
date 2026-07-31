import Foundation

/// A parsed calendar search.
///
/// Deterministic and inspectable, on the same terms as ``SearchQuery``: what the app understood is
/// shown back to the user, nothing is silently dropped, and there is no model in the loop.
///
/// The vocabulary is deliberately close to how people ask. "Meetings with Maya", "lunches last
/// year", "events in Austin", "events without notes" are all sentences somebody would say, and each
/// is a filter here rather than a special case in the engine.
public struct EventSearchQuery: Sendable, Hashable {
    /// Words matched against titles, locations, notes, and attendee names.
    public var terms: [String] = []

    /// `with:maya` — attendees or linked people, by name.
    public var peopleNames: Set<String> = []

    /// `in:austin` — the location field.
    public var locations: Set<String> = []

    /// `calendar:work` — matched against calendar titles.
    public var calendarNames: Set<String> = []

    /// `project:"Q3 Launch"` — events filed under a project.
    public var projectNames: Set<String> = []

    /// When the event happened.
    public var dateRange: Range<Date>?

    /// A phrase the range came from — "last year" — for showing back what was understood.
    public var datePhrase: String?

    public var flags: Set<EventSearchFlag> = []

    public var rawText: String = ""

    /// Fragments the parser did not understand, surfaced rather than discarded.
    public var unrecognisedTokens: [String] = []

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && peopleNames.isEmpty && locations.isEmpty && calendarNames.isEmpty
            && projectNames.isEmpty && dateRange == nil && flags.isEmpty
    }

    public var hasStructuralFilters: Bool {
        !peopleNames.isEmpty || !locations.isEmpty || !calendarNames.isEmpty
            || !projectNames.isEmpty || dateRange != nil || !flags.isEmpty
    }

    /// What the app understood, in the user's words, for the chips under the field.
    public var understoodTokens: [(label: String, value: String)] {
        var tokens: [(String, String)] = []
        if !terms.isEmpty { tokens.append(("Words", terms.joined(separator: " "))) }
        for name in peopleNames.sorted() { tokens.append(("With", name)) }
        for place in locations.sorted() { tokens.append(("In", place)) }
        for calendar in calendarNames.sorted() { tokens.append(("Calendar", calendar)) }
        for project in projectNames.sorted() { tokens.append(("Project", project)) }
        if let datePhrase { tokens.append(("When", datePhrase)) }
        for flag in flags.sorted(by: { $0.rawValue < $1.rawValue }) {
            tokens.append(("Only", flag.displayName))
        }
        return tokens.map { (label: $0.0, value: $0.1) }
    }
}

/// A yes-or-no filter on an event.
public enum EventSearchFlag: String, Sendable, Hashable, CaseIterable {
    case recurring
    case notRecurring
    case allDay
    case timed
    case withNotes
    case withoutNotes
    case withPeople
    case withAttachments
    case withLinks
    case declined
    case cancelled
    case past
    case upcoming

    public var displayName: String {
        switch self {
        case .recurring: "Repeating"
        case .notRecurring: "One-off"
        case .allDay: "All-day"
        case .timed: "Timed"
        case .withNotes: "With notes"
        case .withoutNotes: "Without notes"
        case .withPeople: "With people"
        case .withAttachments: "With attachments"
        case .withLinks: "Linked"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        case .past: "Past"
        case .upcoming: "Upcoming"
        }
    }
}

/// Reads a line of calendar search text.
///
/// ### Why the vocabulary includes bare words like "lunches"
/// Because that is what people type. A search language that only understands `title:lunch` is one
/// somebody has to learn before it helps them, and the whole point of searching a calendar is that
/// the thing you half-remember is a word, a person, or a rough time. So a bare word matches text,
/// `with:` narrows to people, and a handful of phrases — "last year", "next month" — are recognised
/// where they would otherwise be matched as words nobody put in a title.
public enum EventSearchParser {
    /// Phrases that name a period rather than a word to match.
    private static let periodPhrases: Set<String> = [
        "today", "yesterday", "tomorrow",
        "this week", "last week", "next week",
        "this month", "last month", "next month",
        "this quarter", "last quarter", "next quarter",
        "this year", "last year", "next year",
    ]

    public static func parse(_ input: String, now: Date, calendar: Calendar) -> EventSearchQuery {
        var query = EventSearchQuery()
        query.rawText = input

        var remaining = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return query }

        // Period phrases first, and removed from the text, so "lunches last year" does not also
        // search for the word "last".
        let lowered = remaining.lowercased()
        for phrase in periodPhrases.sorted(by: { $0.count > $1.count }) {
            guard let found = lowered.range(of: phrase) else { continue }
            guard let range = Range(NSRange(found, in: lowered), in: remaining) else { continue }

            if let interval = self.interval(for: phrase, now: now, calendar: calendar) {
                query.dateRange = interval
                query.datePhrase = phrase
                remaining.removeSubrange(range)
            }
            break
        }

        for token in tokenize(remaining) {
            apply(token, to: &query)
        }

        return query
    }

    /// Splits on whitespace while keeping quoted phrases together.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in input {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func apply(_ token: String, to query: inout EventSearchQuery) {
        guard let separator = token.firstIndex(of: ":") else {
            applyBareWord(token, to: &query)
            return
        }

        let keyword = String(token[token.startIndex..<separator]).lowercased()
        let value = String(token[token.index(after: separator)...])
        guard !value.isEmpty else {
            query.unrecognisedTokens.append(token)
            return
        }

        switch keyword {
        case "with", "person", "attendee":
            query.peopleNames.insert(value.lowercased())
        case "in", "at", "location", "where":
            query.locations.insert(value.lowercased())
        case "calendar", "cal", "on":
            query.calendarNames.insert(value.lowercased())
        case "project":
            query.projectNames.insert(value.lowercased())
        case "is", "has":
            if let flag = self.flag(for: value.lowercased(), keyword: keyword) {
                query.flags.insert(flag)
            } else {
                query.unrecognisedTokens.append(token)
            }
        case "no", "without":
            switch value.lowercased() {
            case "notes": query.flags.insert(.withoutNotes)
            default: query.unrecognisedTokens.append(token)
            }
        default:
            query.unrecognisedTokens.append(token)
        }
    }

    /// Bare words that are really filters — "recurring", "declined" — and everything else as text.
    ///
    /// Kept short on purpose. A word list that grows to cover every synonym starts stealing words
    /// people meant literally, and "cancelled" appearing in a title is a real thing.
    private static func applyBareWord(_ token: String, to query: inout EventSearchQuery) {
        switch token.lowercased() {
        case "recurring", "repeating":
            query.flags.insert(.recurring)
        case "all-day", "allday":
            query.flags.insert(.allDay)
        default:
            query.terms.append(token)
        }
    }

    private static func flag(for value: String, keyword: String) -> EventSearchFlag? {
        switch (keyword, value) {
        case (_, "recurring"), (_, "repeating"): .recurring
        case (_, "one-off"), (_, "single"): .notRecurring
        case (_, "allday"), (_, "all-day"): .allDay
        case (_, "timed"): .timed
        case ("has", "notes"): .withNotes
        case ("has", "people"), ("has", "attendees"): .withPeople
        case ("has", "attachments"), ("has", "files"): .withAttachments
        case ("has", "links"), ("has", "notes-linked"): .withLinks
        case (_, "declined"): .declined
        case (_, "cancelled"), (_, "canceled"): .cancelled
        case (_, "past"): .past
        case (_, "upcoming"), (_, "future"): .upcoming
        default: nil
        }
    }

    /// The half-open range a named period covers.
    static func interval(for phrase: String, now: Date, calendar: Calendar) -> Range<Date>? {
        func unit(_ component: Calendar.Component, offset: Int) -> Range<Date>? {
            guard let anchor = calendar.date(byAdding: component, value: offset, to: now),
                  let interval = calendar.dateInterval(of: component, for: anchor)
            else { return nil }
            return interval.start..<interval.end
        }

        switch phrase {
        case "today": return unit(.day, offset: 0)
        case "yesterday": return unit(.day, offset: -1)
        case "tomorrow": return unit(.day, offset: 1)
        case "this week": return unit(.weekOfYear, offset: 0)
        case "last week": return unit(.weekOfYear, offset: -1)
        case "next week": return unit(.weekOfYear, offset: 1)
        case "this month": return unit(.month, offset: 0)
        case "last month": return unit(.month, offset: -1)
        case "next month": return unit(.month, offset: 1)
        case "this quarter": return quarter(containing: now, offset: 0, calendar: calendar)
        case "last quarter": return quarter(containing: now, offset: -1, calendar: calendar)
        case "next quarter": return quarter(containing: now, offset: 1, calendar: calendar)
        case "this year": return unit(.year, offset: 0)
        case "last year": return unit(.year, offset: -1)
        case "next year": return unit(.year, offset: 1)
        default: return nil
        }
    }

    /// The three-month block containing a date, offset by whole quarters.
    ///
    /// Built by hand because `Calendar` has a `.quarter` component that it cannot actually produce
    /// an interval for — `dateInterval(of: .quarter, for:)` returns `nil` on every platform this
    /// runs on, which is a fact worth writing down rather than rediscovering.
    public static func quarter(containing date: Date, offset: Int, calendar: Calendar) -> Range<Date>? {
        let month = calendar.component(.month, from: date)
        let quarterIndex = (month - 1) / 3

        var components = calendar.dateComponents([.year], from: date)
        components.month = quarterIndex * 3 + 1
        components.day = 1

        guard let base = calendar.date(from: components),
              let start = calendar.date(byAdding: .month, value: offset * 3, to: base),
              let end = calendar.date(byAdding: .month, value: 3, to: start)
        else { return nil }

        return start..<end
    }
}
