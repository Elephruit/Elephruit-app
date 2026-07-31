import ElephruitCore
import ElephruitFeatures
import Foundation
import Testing

@Suite("Moving around the calendar")
@MainActor
struct CalendarWorkspaceTests {
    private static let clock = FixedDateProvider.reference

    private static func workspace(_ kind: CalendarViewKind = .week) -> CalendarWorkspaceModel {
        let defaults = UserDefaults(suiteName: "calendar-workspace-\(UUID().uuidString)") ?? .standard
        return CalendarWorkspaceModel(
            dateProvider: clock,
            calendar: clock.calendar,
            viewKind: kind,
            defaults: defaults
        )
    }

    @Test("Each view covers the period it names")
    func windowsMatchTheirViews() {
        let day = Self.workspace(.day)
        #expect(day.visibleDays.count == 1)

        let week = Self.workspace(.week)
        #expect(week.visibleWeekDays.count == 7)

        let month = Self.workspace(.month)
        #expect(month.visibleDays.count == 42, """
            Six rows always, so the grid does not change height as the months go by — otherwise \
            paging through a year is a series of jolts
            """)

        let year = Self.workspace(.year)
        #expect(year.visibleDays.count >= 365)
    }

    @Test("A month grid includes the days either side that fill its corners")
    func monthGridsAreNotJustTheMonth() {
        let month = Self.workspace(.month)
        let anchorMonth = Self.clock.calendar.component(.month, from: month.anchor)

        let outside = month.visibleDays.filter {
            Self.clock.calendar.component(.month, from: $0) != anchorMonth
        }
        #expect(!outside.isEmpty, """
            Drawing only the month's own days leaves ragged corners and hides the fact that the 1st \
            is two days after the 30th
            """)
    }

    @Test("A time grid fetches a day either side of what it draws")
    func gridsFetchWiderThanTheyDraw() {
        let week = Self.workspace(.week)

        #expect(week.visibleRange.lowerBound < week.unpaddedRange.lowerBound, """
            An event running from 23:00 into the small hours belongs on the visible day, and a \
            window stopping at midnight would never fetch it
            """)
        #expect(week.visibleRange.upperBound > week.unpaddedRange.upperBound)
    }

    @Test("A list view fetches exactly what it draws")
    func listsDoNotPad() {
        let agenda = Self.workspace(.agenda)
        #expect(agenda.visibleRange == agenda.unpaddedRange)
    }

    @Test("Stepping moves by whatever the view shows")
    func steppingUsesTheViewsOwnUnit() {
        let calendar = Self.clock.calendar

        let day = Self.workspace(.day)
        let dayStart = day.anchor
        day.step(1)
        #expect(calendar.dateComponents([.day], from: dayStart, to: day.anchor).day == 1)

        let week = Self.workspace(.week)
        let weekStart = week.anchor
        week.step(1)
        #expect(calendar.dateComponents([.day], from: weekStart, to: week.anchor).day == 7)

        let month = Self.workspace(.month)
        let monthStart = month.anchor
        month.step(1)
        #expect(calendar.dateComponents([.month], from: monthStart, to: month.anchor).month == 1)

        let quarter = Self.workspace(.quarter)
        let quarterStart = quarter.anchor
        quarter.step(1)
        #expect(calendar.dateComponents([.month], from: quarterStart, to: quarter.anchor).month == 3)

        let year = Self.workspace(.year)
        let yearStart = year.anchor
        year.step(1)
        #expect(calendar.dateComponents([.year], from: yearStart, to: year.anchor).year == 1)
    }

    @Test("Jumping to today returns from anywhere")
    func jumpToToday() {
        let workspace = Self.workspace(.month)
        workspace.step(7)
        #expect(!workspace.showsToday(now: Self.clock.now))

        workspace.goToToday()
        #expect(workspace.showsToday(now: Self.clock.now))
        #expect(workspace.focusedDay == nil, "Jumping clears a stale keyboard focus rather than keeping it")
    }

    @Test("Keyboard focus pages the view when it walks off the edge")
    func focusPagesTheView() {
        let workspace = Self.workspace(.month)
        let anchorBefore = workspace.anchor

        // Far enough to leave a six-week grid whatever day the month starts on.
        for _ in 0..<50 { workspace.moveFocus(byDays: 1) }

        #expect(workspace.anchor != anchorBefore)
        #expect(workspace.focusedDay != nil)
        #expect(workspace.unpaddedRange.contains(workspace.focusedDay ?? Date()))
    }

    @Test("Opening a day from the month grid lands in the day view on that day")
    func drillingIn() {
        let workspace = Self.workspace(.month)
        let target = Self.clock.startOfDay(daysFromToday: 5)

        workspace.drillInto(day: target)

        #expect(workspace.viewKind == .day)
        #expect(Self.clock.calendar.isDate(workspace.anchor, inSameDayAs: target))
    }

    @Test("The title says what is on screen")
    func titles() {
        let day = Self.workspace(.day)
        #expect(!day.title.isEmpty)

        let quarter = Self.workspace(.quarter)
        #expect(quarter.title.hasPrefix("Q"))

        let week = Self.workspace(.week)
        #expect(week.title.contains("–"), "A week is a range, and its title says so")
    }

    @Test("The chosen view is remembered across launches")
    func viewIsRestored() {
        let suite = "calendar-workspace-restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard

        let first = CalendarWorkspaceModel(dateProvider: Self.clock, viewKind: .week, defaults: defaults)
        first.setViewKind(.month)

        let second = CalendarWorkspaceModel(dateProvider: Self.clock, viewKind: .week, defaults: defaults)
        #expect(second.viewKind == .month, """
            Which view somebody works in is a statement about how they work rather than about a \
            particular day, and picking it again every launch is a small tax paid daily
            """)
    }

    @Test("A view switcher position matches the shortcut that selects it")
    func shortcutsMatchTheSwitcher() {
        for (index, kind) in CalendarViewKind.allCases.enumerated() {
            #expect(kind.shortcutIndex == index + 1)
        }
    }
}

@Suite("Typing an event")
@MainActor
struct EventQuickEntryModelTests {
    private static let clock = FixedDateProvider.reference

    private static let maya = KnownPerson(id: UUID(), fullName: "Maya Chen", aliases: ["Maya"])

    private static func model() -> EventQuickEntryModel {
        let model = EventQuickEntryModel(dateProvider: clock)
        model.updateContext(
            EventPhraseContext(people: [maya], calendarNames: ["Work", "Personal"])
        )
        return model
    }

    private static let calendars = [
        CalendarInfo(id: "work", title: "Work", accountKind: .iCloud),
        CalendarInfo(id: "personal", title: "Personal", accountKind: .iCloud),
    ]

    @Test("Typing re-parses without touching the text")
    func parsingDoesNotRewriteText() {
        let model = Self.model()
        model.text = "Lunch with Maya tomorrow at noon"

        #expect(model.text == "Lunch with Maya tomorrow at noon", """
            The text is the user's. If parsing could change it, every one of the failures this \
            design exists to prevent — a lost space, a re-ordered paste, a jumping caret — becomes \
            possible again.
            """)
        #expect(model.interpretation.title == "Lunch with Maya")
    }

    @Test("A correction survives more typing")
    func overridesSurviveReparsing() {
        let model = Self.model()
        model.text = "Dentist tomorrow at 9"
        model.setCalendar("personal")

        model.text = "Dentist tomorrow at 9 for 45 minutes"

        let draft = model.draft(defaultCalendarIdentifier: "work", calendars: Self.calendars)
        #expect(draft?.calendarIdentifier == "personal", """
            A correction that a further keystroke undoes is worse than no correction: it looks like \
            it worked
            """)
        #expect(draft?.duration == TimeInterval(45 * 60), "…and the new words are still read")
    }

    @Test("A correction can be taken back")
    func clearingOverrides() {
        let model = Self.model()
        model.text = "Dentist tomorrow at 9 on Personal"
        model.setCalendar("work")

        #expect(model.draft(defaultCalendarIdentifier: "work", calendars: Self.calendars)?
            .calendarIdentifier == "work")

        model.clearOverrides()
        #expect(model.draft(defaultCalendarIdentifier: "work", calendars: Self.calendars)?
            .calendarIdentifier == "personal", "Clearing a correction returns to what the words say")
    }

    @Test("Removing a chip changes the reading and leaves the words alone")
    func removingATokenKeepsTheText() {
        let model = Self.model()
        model.text = "Standup every day at 9"
        #expect(model.interpretation.recurrence != nil)

        model.remove(kind: .recurrence)

        #expect(model.interpretation.recurrence == nil)
        #expect(model.text == "Standup every day at 9", "The words stay; only what they mean changes")
        #expect(!model.interpretation.tokens.contains { $0.kind == .recurrence })
    }

    @Test("A removed chip stays removed as more is typed")
    func suppressionPersists() {
        let model = Self.model()
        model.text = "Standup every day"
        model.remove(kind: .recurrence)

        model.text = "Standup every day at 9"
        #expect(model.interpretation.recurrence == nil)
    }

    @Test("Resetting starts from nothing")
    func resetting() {
        let model = Self.model()
        model.text = "Dentist tomorrow"
        model.setCalendar("personal")

        model.reset()

        #expect(model.text.isEmpty)
        #expect(model.overrides.isEmpty)
        #expect(model.interpretation.isEmpty)
    }

    @Test("The summary says what will actually be created")
    func summaryDescribesTheOutcome() {
        let model = Self.model()
        model.text = "Lunch with Maya tomorrow at noon"

        let summary = model.summary(calendars: Self.calendars, defaultCalendarIdentifier: "work")
        #expect(summary?.contains("Lunch with Maya") == true)
        #expect(summary?.contains("Work") == true, "Where it lands is the part people forget to check")
    }

    @Test("An empty field promises nothing")
    func emptyFieldHasNoDraft() {
        let model = Self.model()
        #expect(model.draft(defaultCalendarIdentifier: "work", calendars: Self.calendars) == nil)
        #expect(model.summary(calendars: Self.calendars, defaultCalendarIdentifier: "work") == nil)
    }

    @Test("A suggested start is used until the words say otherwise")
    func suggestedStart() {
        let model = Self.model()
        let suggested = Self.clock.startOfToday.addingTimeInterval(14 * 3_600)

        model.text = "Coffee"
        model.setStart(suggested)

        let draft = model.draft(defaultCalendarIdentifier: "work", calendars: Self.calendars)
        #expect(draft?.startAt == suggested, """
            Dragging out a block and then typing a title should land where the drag was, not at the \
            parser's default
            """)
    }
}
