import Foundation

/// A date that may be missing its year.
///
/// ### Why this is not a `Date`
/// Most birthdays are known as "October 12" and nothing more. Storing that as a `Date` forces a year
/// to be invented, and an invented year is indistinguishable from a real one the moment it is
/// written — so the app would confidently tell somebody their friend is turning 46 on the strength
/// of a placeholder. Keeping the year optional makes "we do not know how old they are" a
/// representable, renderable state instead of a wrong number.
public struct PartialDate: Sendable, Hashable, Codable {
    public var year: Int?
    public var month: Int
    public var day: Int

    public init?(year: Int? = nil, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        if let year, !(1...9999).contains(year) { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public var hasYear: Bool { year != nil }

    /// "12 October" · "12 October 1987".
    public var displayText: String {
        var components = DateComponents()
        components.year = year ?? 2000
        components.month = month
        components.day = day

        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "\(month)/\(day)" }

        return hasYear
            ? date.formatted(.dateTime.day().month(.wide).year())
            : date.formatted(.dateTime.day().month(.wide))
    }

    /// The next time this day comes round, today included.
    ///
    /// 29 February is deliberately *not* rolled into 1 March: a leap-day birthday genuinely does not
    /// occur in most years, and quietly moving it would make the celebrations list claim an
    /// anniversary that is not happening. It is surfaced on the 28th instead, labelled, by
    /// ``CelebrationCalendar``.
    public func nextOccurrence(onOrAfter date: Date, calendar: Calendar) -> Date? {
        DateExpression.nextOccurrence(ofMonth: month, day: day, onOrAfter: calendar.startOfDay(for: date), calendar: calendar)
    }

    /// The full date, when the year is known.
    public func resolved(calendar: Calendar) -> Date? {
        guard let year else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// Reads "October 12", "12 October", "10/12", "1987-10-12", "October 12 1987".
    ///
    /// Returns `nil` rather than guessing at an ambiguous numeric pair — `3/4` is March the fourth
    /// to half the world and the third of April to the other half, and a birthday reminder on the
    /// wrong day is a small betrayal.
    public static func parse(_ text: String) -> PartialDate? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: " ")
        guard !cleaned.isEmpty else { return nil }

        let words = cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        // ISO: 1987-10-12.
        if words.count == 1, words[0].contains("-") {
            let parts = words[0].split(separator: "-").map(String.init)
            if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
                return PartialDate(year: year, month: month, day: day)
            }
        }

        // A month name plus a day, in either order, plus an optional year.
        var month: Int?
        var day: Int?
        var year: Int?

        for word in words {
            if let named = monthNumber(word) {
                month = named
                continue
            }
            let numeric = word.trimmingCharacters(in: CharacterSet(charactersIn: "stndrdth"))
            guard let value = Int(numeric) else { continue }

            if value > 31 {
                year = value
            } else if day == nil {
                day = value
            }
        }

        guard let month, let day else { return nil }
        return PartialDate(year: year, month: month, day: day)
    }

    static func monthNumber(_ word: String) -> Int? {
        let names = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
        ]
        let lowered = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard lowered.count >= 3 else { return nil }

        for (index, name) in names.enumerated() where name.hasPrefix(lowered) || lowered == name {
            return index + 1
        }
        return nil
    }
}

// MARK: - Celebrations

/// What kind of date is being marked.
public enum CelebrationKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case birthday
    case anniversary

    /// The anniversary of somebody's death — shown quietly, and never with a gift suggestion.
    case memorial

    /// Anything the user names themselves: sobriety, a move, the day a dog was adopted.
    case milestone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .birthday: "Birthday"
        case .anniversary: "Anniversary"
        case .memorial: "Remembering"
        case .milestone: "Milestone"
        }
    }

    public var symbolName: String {
        switch self {
        case .birthday: "birthday.cake"
        case .anniversary: "heart.circle"
        case .memorial: "leaf"
        case .milestone: "star.circle"
        }
    }

    /// Whether the interface offers gift ideas and a celebratory tone.
    ///
    /// `false` for a memorial. An app that suggests buying somebody a present on the anniversary of
    /// a death has failed at the only thing this module is for.
    public var isCelebratory: Bool {
        switch self {
        case .birthday, .anniversary, .milestone: true
        case .memorial: false
        }
    }

    /// The count word — "turns 7", "10 years", "10 years ago".
    public func milestonePhrase(years: Int) -> String {
        switch self {
        case .birthday: "turns \(years)"
        case .anniversary: years == 1 ? "1 year" : "\(years) years"
        case .memorial: years == 1 ? "1 year ago" : "\(years) years ago"
        case .milestone: years == 1 ? "1 year" : "\(years) years"
        }
    }
}

/// A dated thing worth noticing, attached to somebody.
public struct Celebration: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var personID: UUID
    public var personName: String
    public var kind: CelebrationKind

    /// The user's own name for it, when the kind is not enough — "Sober since".
    public var title: String?

    public var date: PartialDate

    public init(
        id: UUID = UUID(),
        personID: UUID,
        personName: String,
        kind: CelebrationKind,
        title: String? = nil,
        date: PartialDate
    ) {
        self.id = id
        self.personID = personID
        self.personName = personName
        self.kind = kind
        self.title = title
        self.date = date
    }

    public var displayTitle: String {
        title ?? kind.displayName
    }
}

/// A celebration placed on the calendar.
public struct UpcomingCelebration: Sendable, Hashable, Identifiable {
    public var celebration: Celebration

    /// The next date it falls on.
    public var occursOn: Date

    /// Days from today. Zero is today.
    public var daysAway: Int

    /// Which anniversary this is, when the original year is known.
    public var milestoneYears: Int?

    /// Set when the real date does not exist this year — 29 February in a common year.
    public var isShiftedFromLeapDay: Bool

    public var id: UUID { celebration.id }

    public init(
        celebration: Celebration,
        occursOn: Date,
        daysAway: Int,
        milestoneYears: Int? = nil,
        isShiftedFromLeapDay: Bool = false
    ) {
        self.celebration = celebration
        self.occursOn = occursOn
        self.daysAway = daysAway
        self.milestoneYears = milestoneYears
        self.isShiftedFromLeapDay = isShiftedFromLeapDay
    }

    /// "Maya Chen · turns 39 · in 12 days".
    public var summary: String {
        var parts = [celebration.personName]
        if let milestoneYears {
            parts.append(celebration.kind.milestonePhrase(years: milestoneYears))
        } else {
            parts.append(celebration.displayTitle.lowercased())
        }
        parts.append(relativeText)
        return parts.joined(separator: " · ")
    }

    public var relativeText: String {
        switch daysAway {
        case 0: "today"
        case 1: "tomorrow"
        case 2...13: "in \(daysAway) days"
        case 14...59: "in \(daysAway / 7) weeks"
        default: "in \(daysAway / 30) months"
        }
    }

    /// Whether this is close enough to act on.
    public var isImminent: Bool { daysAway <= 14 }
}

/// Puts celebrations in order, handling the dates that do not behave.
public enum CelebrationCalendar {
    /// Everything falling within `days` of the given date, soonest first.
    public static func upcoming(
        from celebrations: [Celebration],
        within days: Int,
        asOf date: Date,
        calendar: Calendar
    ) -> [UpcomingCelebration] {
        let today = calendar.startOfDay(for: date)
        guard let horizon = calendar.date(byAdding: .day, value: days, to: today) else { return [] }

        return celebrations
            .compactMap { celebration -> UpcomingCelebration? in
                guard let placed = place(celebration, asOf: today, calendar: calendar) else { return nil }
                guard placed.occursOn <= horizon else { return nil }
                return placed
            }
            .sorted { left, right in
                left.daysAway == right.daysAway
                    ? left.celebration.personName < right.celebration.personName
                    : left.daysAway < right.daysAway
            }
    }

    /// Where one celebration lands next.
    public static func place(
        _ celebration: Celebration,
        asOf today: Date,
        calendar: Calendar
    ) -> UpcomingCelebration? {
        let start = calendar.startOfDay(for: today)

        var shifted = false
        var occurrence = celebration.date.nextOccurrence(onOrAfter: start, calendar: calendar)

        // 29 February. The real date does occur — just not for up to eight years — and waiting for
        // it would drop somebody off the celebrations list for three years in four. So the 28th is
        // considered too and whichever comes first wins, which puts the day back on the calendar
        // every year while still landing on the 29th itself in a leap year.
        if celebration.date.month == 2, celebration.date.day == 29,
           let eve = PartialDate(month: 2, day: 28)?.nextOccurrence(onOrAfter: start, calendar: calendar) {
            // Compared by *year* rather than by date, because the 28th is always a day earlier than
            // the 29th and comparing the dates directly would shift every leap year too. The real
            // date wins whenever it falls in the same February the 28th does — and on the 29th
            // itself, where it is this year's and the 28th has already passed.
            let eveYear = calendar.component(.year, from: eve)
            let realYear = occurrence.map { calendar.component(.year, from: $0) }

            if realYear == nil || (realYear ?? 0) > eveYear {
                occurrence = eve
                shifted = true
            }
        }

        guard let occurrence else { return nil }

        let daysAway = calendar.dateComponents([.day], from: start, to: occurrence).day ?? 0

        var milestone: Int?
        if let year = celebration.date.year {
            let occurrenceYear = calendar.component(.year, from: occurrence)
            let years = occurrenceYear - year
            // A milestone of zero is the year itself — a birth, not a birthday.
            milestone = years > 0 ? years : nil
        }

        return UpcomingCelebration(
            celebration: celebration,
            occursOn: occurrence,
            daysAway: max(0, daysAway),
            milestoneYears: milestone,
            isShiftedFromLeapDay: shifted
        )
    }

    /// Groups a list into the months it falls across, for a year-at-a-glance view.
    public static func byMonth(
        _ upcoming: [UpcomingCelebration],
        calendar: Calendar
    ) -> [(month: Date, celebrations: [UpcomingCelebration])] {
        Dictionary(grouping: upcoming) { entry in
            calendar.date(from: calendar.dateComponents([.year, .month], from: entry.occursOn)) ?? entry.occursOn
        }
        .sorted { $0.key < $1.key }
        .map { (month: $0.key, celebrations: $0.value.sorted { $0.occursOn < $1.occursOn }) }
    }
}
