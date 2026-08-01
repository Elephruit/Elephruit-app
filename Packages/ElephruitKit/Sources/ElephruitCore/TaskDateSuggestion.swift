import Foundation

/// A date phrase, resolved.
public struct TaskDateSuggestion: Sendable, Hashable {
    /// The day itself.
    public var date: Date

    /// How the day reads — "Tue, 4 Aug".
    public var title: String

    /// How far away it is — "in 3 days". Empty when the day is today.
    public var detail: String

    /// Resolves `text` the way quick entry resolves it, or returns `nil`.
    ///
    /// One function, called from both date popovers, delegating to the parser the capture field
    /// uses. That delegation is the whole point: see the suite that asserts the two agree.
    public static func resolving(
        _ text: String,
        using dateProvider: any DateProvider
    ) -> TaskDateSuggestion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let interpretation = NaturalDateParser.interpret(trimmed),
              let date = interpretation.resolve(using: dateProvider)
        else { return nil }

        return TaskDateSuggestion(
            date: date,
            title: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
            detail: relativeDescription(of: date, using: dateProvider)
        )
    }

    /// "today", "tomorrow", "in 3 days", "5 days ago". Plain words rather than a duration format,
    /// because the question being answered is *how soon*, not *how long*.
    private static func relativeDescription(
        of date: Date,
        using dateProvider: any DateProvider
    ) -> String {
        let calendar = dateProvider.calendar
        let from = calendar.startOfDay(for: dateProvider.now)
        let to = calendar.startOfDay(for: date)
        guard let days = calendar.dateComponents([.day], from: from, to: to).day else { return "" }

        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let ahead where ahead > 0: return "in \(ahead) days"
        default: return "\(-days) days ago"
        }
    }
}
