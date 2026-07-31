import ElephruitCore
import Foundation
import Observation

/// One window's view of the calendar: which day, which layout, what is selected.
///
/// Per-window rather than on ``CalendarService``, for the same reason ``NavigationModel`` is: two
/// windows should be able to show two different weeks, and a shortcut in one must never move the
/// other.
///
/// ### Everything here is a pure function of an anchor and a view kind
/// The anchor is a date; the view kind says how much of the calendar around it to show. Every
/// navigation action moves the anchor, and the window follows — which means "go to next week" and
/// "go to next month" are the same operation with a different unit, and neither can leave the
/// window and the anchor disagreeing.
@Observable
@MainActor
public final class CalendarWorkspaceModel {
    /// The day the view is centred on.
    public private(set) var anchor: Date

    public private(set) var viewKind: CalendarViewKind

    /// The event the inspector is showing.
    public var selectedEventID: String?

    /// The day the keyboard is on, for arrow navigation in the month and year grids.
    public var focusedDay: Date?

    /// A draft being composed, from a drag or from the natural-language field.
    public var pendingDraft: EventDraft?

    /// The event being edited, when an editor is open over an existing one.
    public var editingEvent: CalendarEventSummary?

    /// Whether the search field is showing.
    public var isSearching = false
    public var searchText = ""

    /// Whether the natural-language quick-entry field is showing.
    public var isQuickEntryVisible = false

    private let dateProvider: any DateProvider

    /// The calendar to compute windows with — the user's own, in the display zone.
    public var calendar: Calendar

    static let viewKindKey = "calendar.viewKind"

    public init(
        dateProvider: any DateProvider,
        calendar: Calendar? = nil,
        viewKind: CalendarViewKind = .week,
        defaults: UserDefaults = .standard
    ) {
        self.dateProvider = dateProvider
        self.calendar = calendar ?? dateProvider.calendar
        self.anchor = dateProvider.startOfToday

        // The last view is restored because it is a statement about how somebody works rather than
        // about a particular day, and having to pick Week again every launch is a small tax paid
        // daily.
        let stored = defaults.string(forKey: Self.viewKindKey).flatMap(CalendarViewKind.init(rawValue:))
        self.viewKind = stored ?? viewKind
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    // MARK: - The window

    /// The range of time the current view covers.
    ///
    /// Widened by a day at each end for the grid views, because an event running from 23:00 into the
    /// small hours belongs on the visible day and a window that stops at midnight would not fetch it.
    public var visibleRange: Range<Date> {
        let range = unpaddedRange
        let padding: TimeInterval = viewKind.isTimeGrid ? 86_400 : 0
        return range.lowerBound.addingTimeInterval(-padding)..<range.upperBound.addingTimeInterval(padding)
    }

    /// The range the view actually draws, without the fetch padding.
    public var unpaddedRange: Range<Date> {
        switch viewKind {
        case .agenda:
            let start = calendar.startOfDay(for: anchor)
            let end = calendar.date(byAdding: .day, value: 30, to: start) ?? start
            return start..<end

        case .day:
            let start = calendar.startOfDay(for: anchor)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return start..<end

        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else {
                let start = calendar.startOfDay(for: anchor)
                return start..<(calendar.date(byAdding: .day, value: 7, to: start) ?? start)
            }
            return week.start..<week.end

        case .month:
            return Self.monthGridRange(containing: anchor, calendar: calendar)

        case .quarter:
            return EventSearchParser.quarter(containing: anchor, offset: 0, calendar: calendar)
                ?? (anchor..<anchor)

        case .year:
            guard let year = calendar.dateInterval(of: .year, for: anchor) else { return anchor..<anchor }
            return year.start..<year.end
        }
    }

    /// The whole grid a month view draws, including the days either side that fill the first and
    /// last rows.
    ///
    /// A month grid is never just a month. Drawing only the month's own days leaves ragged corners
    /// and, worse, hides the fact that the deadline on the 1st is two days after the meeting on the
    /// 30th.
    public static func monthGridRange(containing date: Date, calendar: Calendar) -> Range<Date> {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return date..<date }

        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: month.start) else {
            return month.start..<month.end
        }

        // Six rows always, so the grid does not change height as the months go by — which is
        // otherwise a jolt every time somebody pages through a year.
        let end = calendar.date(byAdding: .day, value: 42, to: start) ?? month.end
        return start..<end
    }

    /// The days the current view draws, in order.
    public var visibleDays: [Date] {
        let range = unpaddedRange
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: range.lowerBound)

        // Bounded by the year view's own length, so a corrupt anchor cannot build an endless array.
        while cursor < range.upperBound, days.count < 400 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// The days of the week the week view draws, honouring the locale's first weekday.
    public var visibleWeekDays: [Date] {
        guard viewKind == .week else { return visibleDays }
        return Array(visibleDays.prefix(7))
    }

    // MARK: - Navigation

    public func setViewKind(_ kind: CalendarViewKind) {
        guard viewKind != kind else { return }
        viewKind = kind
        defaults.set(kind.rawValue, forKey: Self.viewKindKey)
    }

    /// Moves forward or back by whatever unit the current view shows.
    ///
    /// One function rather than six, so "next" always means "the next screenful" and no view can
    /// disagree about what its own unit is.
    public func step(_ direction: Int) {
        let component: Calendar.Component
        let magnitude: Int

        switch viewKind {
        case .agenda: (component, magnitude) = (.day, 30)
        case .day: (component, magnitude) = (.day, 1)
        case .week: (component, magnitude) = (.weekOfYear, 1)
        case .month: (component, magnitude) = (.month, 1)
        case .quarter: (component, magnitude) = (.month, 3)
        case .year: (component, magnitude) = (.year, 1)
        }

        guard let moved = calendar.date(byAdding: component, value: direction * magnitude, to: anchor) else {
            return
        }
        anchor = moved
        focusedDay = nil
    }

    /// Moves the keyboard focus by days, paging the view when it walks off the edge.
    public func moveFocus(byDays days: Int) {
        let current = focusedDay ?? anchor
        guard let moved = calendar.date(byAdding: .day, value: days, to: current) else { return }

        focusedDay = moved
        if !unpaddedRange.contains(moved) {
            anchor = moved
        }
    }

    public func goToToday() {
        anchor = dateProvider.startOfToday
        focusedDay = nil
    }

    public func go(to date: Date) {
        anchor = date
        focusedDay = date
    }

    /// Opens a day in the day view, which is what clicking a month cell should do.
    public func drillInto(day: Date) {
        anchor = day
        focusedDay = day
        setViewKind(.day)
    }

    /// Whether the current window contains today, for enabling "Jump to Today".
    public func showsToday(now: Date) -> Bool {
        unpaddedRange.contains(now)
    }

    // MARK: - Titles

    /// What the toolbar says the view is showing.
    public var title: String {
        var style: Date.FormatStyle
        switch viewKind {
        case .agenda, .day:
            style = Date.FormatStyle(date: .complete, time: .omitted)
        case .week:
            return weekTitle
        case .month:
            style = Date.FormatStyle().month(.wide).year()
        case .quarter:
            let quarter = (calendar.component(.month, from: anchor) - 1) / 3 + 1
            return "Q\(quarter) \(calendar.component(.year, from: anchor))"
        case .year:
            style = Date.FormatStyle().year()
        }
        style.timeZone = calendar.timeZone
        return anchor.formatted(style)
    }

    /// "15–21 June 2026", collapsing whatever the two ends share.
    private var weekTitle: String {
        let days = visibleWeekDays
        guard let first = days.first, let last = days.last else { return "" }

        var dayMonth = Date.FormatStyle().day().month(.abbreviated)
        dayMonth.timeZone = calendar.timeZone
        var dayOnly = Date.FormatStyle().day()
        dayOnly.timeZone = calendar.timeZone
        var full = Date.FormatStyle().day().month(.abbreviated).year()
        full.timeZone = calendar.timeZone

        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let leading = sameMonth ? first.formatted(dayOnly) : first.formatted(dayMonth)
        return "\(leading) – \(last.formatted(full))"
    }
}
