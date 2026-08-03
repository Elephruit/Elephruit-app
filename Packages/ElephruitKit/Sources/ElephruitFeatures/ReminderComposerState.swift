import ElephruitCore
import Foundation

/// The keyboard stops in the reminder composer, in their deliberate traversal order.
///
/// Kept as a small state machine rather than relying on AppKit's incidental key-view order: some
/// stops live in popovers and the checklist rows are created on demand, so the view hierarchy is
/// not the product's focus order.
enum ReminderComposerField: Int, CaseIterable, Sendable, Hashable {
    case title
    case notes
    case project
    case when
    case tags
    case people
    case checklist
    case deadline

    func advanced(reverse: Bool = false) -> Self {
        let fields = Self.allCases
        guard let index = fields.firstIndex(of: self) else { return .title }
        let offset = reverse ? -1 : 1
        return fields[(index + offset + fields.count) % fields.count]
    }
}

/// Invalidates asynchronous popover work from an older focus traversal.
///
/// AppKit can finish dismissing a popover after the keyboard has already looped back to the same
/// field. Field identity alone cannot distinguish those two presentations, so every request also
/// carries this monotonically increasing generation.
struct ReminderPopoverPresentationGate: Sendable, Hashable {
    private(set) var generation = 0

    mutating func nextRequest() -> Int {
        generation += 1
        return generation
    }

    mutating func cancel() {
        generation += 1
    }

    func accepts(
        _ request: Int,
        for field: ReminderComposerField,
        activeField: ReminderComposerField
    ) -> Bool {
        request == generation && field == activeField
    }
}

/// One row in the Things-style date search shown by When and Deadline.
///
/// The row keeps its presentation alongside the resolved day so a keystroke can select the exact
/// same result the user sees. `kind` deliberately participates in identity: the query `8` can mean
/// both "August 8" and "in 8 days", even on the rare date where those land on the same day.
struct ReminderDateSuggestion: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case named
        case weekday
        case dayOfMonth
        case offset
        case parsed
    }

    var kind: Kind
    var date: Date
    var title: String
    var detail: String

    var id: String { "\(kind.rawValue):\(date.timeIntervalSinceReferenceDate)" }
}

/// Fast, deterministic date completion for the compact reminder editor.
///
/// This supplements `NaturalDateParser` rather than changing its grammar. Capture still only acts
/// on complete date phrases; this search surface can additionally show useful partial matches such
/// as `we`, `su`, or the two meanings of `8` without guessing silently.
enum ReminderDateSearch {
    private static let weekdays: [(name: String, aliases: [String], value: Int)] = [
        ("Sunday", ["sun"], 1),
        ("Monday", ["mon"], 2),
        ("Tuesday", ["tue", "tues"], 3),
        ("Wednesday", ["wed"], 4),
        ("Thursday", ["thu", "thur", "thurs"], 5),
        ("Friday", ["fri"], 6),
        ("Saturday", ["sat"], 7),
    ]

    private static let months: [(name: String, aliases: [String], value: Int)] = [
        ("January", ["jan"], 1), ("February", ["feb"], 2),
        ("March", ["mar"], 3), ("April", ["apr"], 4),
        ("May", [], 5), ("June", ["jun"], 6), ("July", ["jul"], 7),
        ("August", ["aug"], 8), ("September", ["sep", "sept"], 9),
        ("October", ["oct"], 10), ("November", ["nov"], 11),
        ("December", ["dec"], 12),
    ]

    static func suggestions(
        for query: String,
        using dateProvider: any DateProvider,
        limit: Int = 8
    ) -> [ReminderDateSuggestion] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard !normalized.isEmpty, limit > 0 else { return [] }

        let calendar = dateProvider.calendar
        let today = dateProvider.startOfToday

        if let number = Int(normalized), (1...31).contains(number) {
            var results: [ReminderDateSuggestion] = []
            if let day = nextDayOfMonth(number, onOrAfter: today, calendar: calendar) {
                results.append(
                    ReminderDateSuggestion(
                        kind: .dayOfMonth,
                        date: day,
                        title: format(day, calendar: calendar, month: .wide),
                        detail: weekday(day, calendar: calendar)
                    )
                )
            }
            if let offset = calendar.date(byAdding: .day, value: number, to: today) {
                results.append(
                    ReminderDateSuggestion(
                        kind: .offset,
                        date: offset,
                        title: number == 1 ? "in 1 day" : "in \(number) days",
                        detail: format(offset, calendar: calendar, includesWeekday: true)
                    )
                )
            }
            return Array(results.prefix(limit))
        }

        if let monthDay = matchingMonthDay(normalized),
           let date = nextOccurrence(
               month: monthDay.month,
               day: monthDay.day,
               onOrAfter: today,
               calendar: calendar
           ) {
            return [
                ReminderDateSuggestion(
                    kind: .dayOfMonth,
                    date: date,
                    title: format(date, calendar: calendar, month: .wide),
                    detail: weekday(date, calendar: calendar)
                ),
            ]
        }

        let matchingWeekdays = weekdays.filter { weekday in
            weekday.name.lowercased().hasPrefix(normalized)
                || weekday.aliases.contains(where: { $0.hasPrefix(normalized) })
        }
        if !matchingWeekdays.isEmpty {
            var results: [ReminderDateSuggestion] = []
            for match in matchingWeekdays {
                var cursor = today
                for _ in 0..<3 {
                    guard let date = nextWeekday(match.value, after: cursor, calendar: calendar) else {
                        break
                    }
                    results.append(
                        ReminderDateSuggestion(
                            kind: .weekday,
                            date: date,
                            title: format(date, calendar: calendar, includesWeekday: true),
                            detail: relativeDescription(date, from: today, calendar: calendar)
                        )
                    )
                    cursor = date
                }
            }
            return Array(results.sorted { $0.date < $1.date }.prefix(limit))
        }

        var named: [ReminderDateSuggestion] = []
        if "today".hasPrefix(normalized) {
            named.append(
                ReminderDateSuggestion(
                    kind: .named,
                    date: today,
                    title: "Today",
                    detail: format(today, calendar: calendar, includesWeekday: true)
                )
            )
        }
        if "tomorrow".hasPrefix(normalized),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            named.append(
                ReminderDateSuggestion(
                    kind: .named,
                    date: tomorrow,
                    title: "Tomorrow",
                    detail: format(tomorrow, calendar: calendar, includesWeekday: true)
                )
            )
        }
        if !named.isEmpty { return Array(named.prefix(limit)) }

        guard let parsed = TaskDateSuggestion.resolving(normalized, using: dateProvider) else {
            return []
        }
        return [
            ReminderDateSuggestion(
                kind: .parsed,
                date: parsed.date,
                title: parsed.title,
                detail: parsed.detail
            ),
        ]
    }

    private static func matchingMonthDay(_ query: String) -> (month: Int, day: Int)? {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
        guard words.count == 2 else { return nil }

        let candidates: [(monthText: String, dayText: String)] = [
            (words[0], words[1]),
            (words[1], words[0]),
        ]
        for candidate in candidates {
            guard let day = Int(candidate.dayText), (1...31).contains(day) else { continue }
            let matches = months.filter { month in
                month.name.lowercased().hasPrefix(candidate.monthText)
                    || month.aliases.contains(where: { $0.hasPrefix(candidate.monthText) })
            }
            if matches.count == 1, let match = matches.first { return (match.value, day) }
        }
        return nil
    }

    private static func nextWeekday(
        _ weekday: Int,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        var cursor = date
        for _ in 1...7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
            if calendar.component(.weekday, from: cursor) == weekday { return cursor }
        }
        return nil
    }

    private static func nextDayOfMonth(
        _ day: Int,
        onOrAfter today: Date,
        calendar: Calendar
    ) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let year = components.year, let month = components.month else { return nil }

        for offset in 0...12 {
            guard let monthDate = calendar.date(
                from: DateComponents(year: year, month: month + offset, day: 1)
            ) else { continue }
            let candidateComponents = calendar.dateComponents([.year, .month], from: monthDate)
            guard let candidateYear = candidateComponents.year,
                  let candidateMonth = candidateComponents.month,
                  let candidate = calendar.date(
                      from: DateComponents(year: candidateYear, month: candidateMonth, day: day)
                  ),
                  calendar.component(.month, from: candidate) == candidateMonth,
                  candidate >= today
            else { continue }
            return candidate
        }
        return nil
    }

    private static func nextOccurrence(
        month: Int,
        day: Int,
        onOrAfter today: Date,
        calendar: Calendar
    ) -> Date? {
        let year = calendar.component(.year, from: today)
        for candidateYear in year...(year + 1) {
            guard let candidate = calendar.date(
                from: DateComponents(year: candidateYear, month: month, day: day)
            ),
                  calendar.component(.month, from: candidate) == month,
                  calendar.component(.day, from: candidate) == day,
                  candidate >= today
            else { continue }
            return candidate
        }
        return nil
    }

    private static func format(
        _ date: Date,
        calendar: Calendar,
        month: Date.FormatStyle.Symbol.Month = .abbreviated,
        includesWeekday: Bool = false
    ) -> String {
        var style = Date.FormatStyle().month(month).day()
        if includesWeekday { style = style.weekday(.abbreviated) }
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private static func weekday(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private static func relativeDescription(
        _ date: Date,
        from today: Date,
        calendar: Calendar
    ) -> String {
        let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        return switch days {
        case 0: "today"
        case 1: "tomorrow"
        case let value where value > 1: "in \(value) days"
        default: ""
        }
    }
}

/// Keyboard highlight within a reminder date popover.
enum ReminderDateNavigationTarget: Sendable, Hashable {
    case quick(Int)
    case search(Int)
    case day(Date)
}

/// Arrow-key movement shared by When and Deadline.
struct ReminderDateNavigationState: Sendable, Hashable {
    var target: ReminderDateNavigationTarget?

    mutating func reset() {
        target = nil
    }

    @discardableResult
    mutating func moveSearch(_ direction: Int, count: Int) -> Bool {
        guard count > 0, direction != 0 else { return false }
        let current: Int
        if case .search(let index) = target {
            current = index
        } else {
            // The first row is already the visual/default selection. Down advances to the second;
            // Up remains on the first, matching a native completion menu.
            current = 0
        }
        target = .search(max(0, min(count - 1, current + direction)))
        return true
    }

    @discardableResult
    mutating func moveVertical(
        _ direction: Int,
        selected: Date?,
        today: Date,
        calendar: Calendar
    ) -> Bool {
        guard direction != 0 else { return false }
        let anchor = calendar.startOfDay(for: selected ?? today)

        switch target {
        case .none, .search:
            target = .quick(direction > 0 ? 0 : 1)
        case .quick(let index):
            let next = index + direction
            if next >= 2 {
                target = .day(anchor)
            } else {
                target = .quick(max(0, next))
            }
        case .day(let date):
            if direction < 0, calendar.isDate(date, inSameDayAs: anchor) {
                target = .quick(1)
            } else if let next = calendar.date(byAdding: .day, value: direction * 7, to: date) {
                target = .day(next)
            }
        }
        return true
    }

    @discardableResult
    mutating func moveHorizontal(
        _ direction: Int,
        selected: Date?,
        today: Date,
        calendar: Calendar
    ) -> Bool {
        guard direction != 0 else { return false }
        let base: Date
        if case .day(let date) = target {
            base = date
        } else {
            base = selected ?? today
        }
        guard let next = calendar.date(byAdding: .day, value: direction, to: base) else {
            return false
        }
        target = .day(calendar.startOfDay(for: next))
        return true
    }

    var searchIndex: Int? {
        guard case .search(let index) = target else { return nil }
        return index
    }

    var quickIndex: Int? {
        guard case .quick(let index) = target else { return nil }
        return index
    }

    var day: Date? {
        guard case .day(let date) = target else { return nil }
        return date
    }
}

/// Everything typed into a new reminder before it becomes a stored item.
///
/// A value type is the performance boundary: keystrokes only mutate this value. Store validation,
/// tag creation, search indexing and list reconciliation happen once, when the draft is committed.
struct ReminderComposerDraft: Sendable, Hashable {
    var title = ""
    var notes = ""
    var startAt: Date?
    var dueAt: Date?
    var isSomeday = false
    var tagSlugs: [String] = []
    var personNames: [String] = []
    var projectTitle: String?
    var checklist: [ReminderChecklistItem] = []
    var pendingStep = ""

    init() {}

    init(reminder: LightweightReminder) {
        title = reminder.title
        notes = reminder.notes
        startAt = reminder.startAt
        dueAt = reminder.dueAt
        isSomeday = reminder.isSomeday
        tagSlugs = reminder.tagSlugs
        personNames = reminder.personNames
        projectTitle = reminder.projectTitle
        checklist = reminder.checklist
    }

    var hasChecklistContent: Bool {
        !pendingStep.isEmpty || !checklist.isEmpty
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func commitPendingStep() {
        let title = pendingStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { checklist.append(ReminderChecklistItem(title: title)) }
        pendingStep = ""
    }

    mutating func reset() {
        self = ReminderComposerDraft()
    }
}

/// The three Quick Jot-style instructions a lightweight reminder understands.
///
/// Parsing is shared with Quick Jot so multi-word people and projects have exactly the same
/// boundaries. Only reminder metadata is extracted: this never changes item kind or sends the
/// reminder through capture, filing, or task services.
struct ReminderShortcutExtraction: Sendable, Hashable {
    var text: String
    var tagSlugs: [String]
    var personNames: [String]
    var projectTitle: String?
}

enum ReminderShortcutParser {
    static func extract(
        from text: String,
        knowing vocabulary: CaptureVocabulary
    ) -> ReminderShortcutExtraction {
        var tagSlugs: [String] = []
        var personNames: [String] = []
        var projectTitle: String?
        var cleanedLines: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let parsed = CaptureParser.parse(line, knowing: vocabulary)
            let shortcuts = parsed.tokens.filter { token in
                switch token.kind {
                case .tag, .kind, .person, .project: true
                case .dueDate, .followDate, .priority, .unrecognised: false
                }
            }

            for token in shortcuts {
                switch token.kind {
                case .tag, .kind:
                    let slug = TextNormalizer.slug(token.text)
                    if !slug.isEmpty, !tagSlugs.contains(slug) { tagSlugs.append(slug) }
                case .person:
                    let folded = TextNormalizer.foldedForMatching(token.text)
                    if !personNames.contains(where: {
                        TextNormalizer.foldedForMatching($0) == folded
                    }) {
                        personNames.append(token.text)
                    }
                case .project:
                    projectTitle = token.text
                case .dueDate, .followDate, .priority, .unrecognised:
                    break
                }
            }

            cleanedLines.append(removing(shortcuts.map(\.range), from: line))
        }

        return ReminderShortcutExtraction(
            text: cleanedLines.joined(separator: "\n"),
            tagSlugs: tagSlugs,
            personNames: personNames,
            projectTitle: projectTitle
        )
    }

    private static func removing(_ ranges: [Range<Int>], from text: String) -> String {
        guard !ranges.isEmpty else { return text }
        let characters = Array(text)
        var removed: Set<Int> = []

        for range in ranges {
            let expanded: Range<Int>
            if range.upperBound < characters.count,
               characters[range.upperBound].isWhitespace {
                expanded = range.lowerBound..<(range.upperBound + 1)
            } else if range.lowerBound > 0,
                      characters[range.lowerBound - 1].isWhitespace {
                expanded = (range.lowerBound - 1)..<range.upperBound
            } else {
                expanded = range
            }
            removed.formUnion(expanded)
        }

        return String(characters.enumerated().compactMap { index, character in
            removed.contains(index) ? nil : character
        })
        .trimmingCharacters(in: .whitespaces)
    }
}
