import Foundation
import SwiftUI

/// One month, laid out as seven columns, with the caller deciding what a day looks like.
///
/// ### Why this is shared rather than written twice
/// Two surfaces draw a month: the menu bar's mini calendar, which shades a day by how busy it is,
/// and the task date popovers, which let you pick one. They disagree about the *cell* and agree
/// about everything else — which days are in this month, how many blanks come before the first one,
/// and where the week starts. That agreement is the part worth getting right once: the leading-blank
/// calculation is off-by-one bait, it depends on `Calendar.firstWeekday`, and a version of it that is
/// wrong in one place and right in the other is a bug nobody notices until a Sunday.
///
/// So this owns the geometry and nothing else. It draws no fills, no rings, no selection and no
/// colour; the cell builder does all of that, which is why a density shade and a chosen day can be
/// two different pictures of the same grid.
public struct MonthGrid<Cell: View>: View {
    enum GridElement: Hashable {
        case weekday(index: Int, initial: String)
        case blank(Int)
        case day(Date)
    }

    private let month: Date
    private let calendar: Calendar
    private let cellSize: CGSize
    private let spacing: CGFloat
    private let showsWeekdayHeader: Bool
    private let cell: (Date) -> Cell

    public init(
        month: Date,
        calendar: Calendar,
        cellSize: CGSize = CGSize(width: 20, height: 18),
        spacing: CGFloat = 1,
        showsWeekdayHeader: Bool = false,
        @ViewBuilder cell: @escaping (Date) -> Cell
    ) {
        self.month = month
        self.calendar = calendar
        self.cellSize = cellSize
        self.spacing = spacing
        self.showsWeekdayHeader = showsWeekdayHeader
        self.cell = cell
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cellSize.width), spacing: spacing), count: 7),
            spacing: spacing
        ) {
            // A single identity domain matters here. Separate sibling `ForEach` blocks keyed by
            // zero-based indices make the weekday header and leading blanks both identify cells as
            // 0, 1, 2…; `LazyVGrid` then reports duplicate explicit IDs and may reuse the wrong
            // view. The enum namespaces all three kinds while retaining stable day identities.
            ForEach(Self.gridElements(
                of: month,
                calendar: calendar,
                showsWeekdayHeader: showsWeekdayHeader
            ), id: \.self) { element in
                switch element {
                case let .weekday(_, initial):
                    Text(initial)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: cellSize.width, height: cellSize.height)
                        .accessibilityHidden(true)
                case .blank:
                    Color.clear.frame(width: cellSize.width, height: cellSize.height)
                case let .day(day):
                    cell(day)
                }
            }
        }
    }

    // MARK: - Geometry

    /// Every day in `month`, in order.
    ///
    /// Bounded at 31 so a malformed calendar cannot spin here. `DateInterval` is what decides the
    /// month rather than arithmetic on components, because a month is a calendar's opinion — see any
    /// timezone that has skipped a day.
    public static func days(of month: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end, days.count < 31 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// How many empty cells precede the first of the month, honouring where the user's week starts.
    public static func leadingBlanks(of month: Date, calendar: Calendar) -> Int {
        guard let first = days(of: month, calendar: calendar).first else { return 0 }
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }

    static func gridElements(
        of month: Date,
        calendar: Calendar,
        showsWeekdayHeader: Bool
    ) -> [GridElement] {
        var elements: [GridElement] = []
        if showsWeekdayHeader {
            elements.append(contentsOf: weekdayInitials(calendar: calendar).enumerated().map {
                .weekday(index: $0.offset, initial: $0.element)
            })
        }
        elements.append(contentsOf: (0..<leadingBlanks(of: month, calendar: calendar)).map {
            .blank($0)
        })
        elements.append(contentsOf: days(of: month, calendar: calendar).map(GridElement.day))
        return elements
    }

    /// S M T W T F S, rotated to the user's first weekday and localised.
    public static func weekdayInitials(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }
}
