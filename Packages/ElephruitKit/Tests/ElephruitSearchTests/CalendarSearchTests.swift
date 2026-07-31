import ElephruitCore
import ElephruitSearch
import Foundation
import Testing

@Suite("Reading a calendar search")
struct EventSearchParsingTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }()

    private static var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: components) ?? Date()
    }

    private static func parse(_ text: String) -> EventSearchQuery {
        EventSearchParser.parse(text, now: now, calendar: calendar)
    }

    @Test("A bare phrase is words to match")
    func plainWords() {
        let query = Self.parse("quarterly review")
        #expect(query.terms == ["quarterly", "review"])
        #expect(!query.hasStructuralFilters)
    }

    @Test("“Meetings with Maya” narrows to a person, not to the word")
    func withNarrowsToPeople() {
        let query = Self.parse("meetings with:maya")
        #expect(query.peopleNames == ["maya"])
        #expect(query.terms == ["meetings"], """
            A meeting whose notes merely mention Maya is not a meeting with Maya, and conflating the \
            two makes the filter useless on any calendar where people are discussed
            """)
    }

    @Test("“Lunches last year” takes the period out of the words")
    func periodPhrasesAreLifted() {
        let query = Self.parse("lunches last year")

        #expect(query.terms == ["lunches"], "Otherwise the search is also looking for the word “last”")
        #expect(query.datePhrase == "last year")

        let year = Self.calendar.component(.year, from: query.dateRange?.lowerBound ?? Date())
        #expect(year == 2025)
    }

    @Test("Each named period resolves to the right window")
    func periodsResolve() {
        #expect(Self.parse("today").dateRange != nil)
        #expect(Self.parse("events next month").datePhrase == "next month")

        let quarter = Self.parse("this quarter").dateRange
        #expect(quarter != nil)
        if let quarter {
            // June sits in the second quarter, which runs April to July.
            #expect(Self.calendar.component(.month, from: quarter.lowerBound) == 4)
        }
    }

    @Test("A quarter is three whole months, starting in January, April, July, or October")
    func quartersAreComputed() {
        // Computed by hand rather than through `dateInterval(of: .quarter,)`, whose behaviour has
        // varied by platform and release. Three months from a fixed origin is a definition that
        // does not move.
        for (month, expectedStart) in [(1, 1), (5, 4), (8, 7), (12, 10)] {
            var components = DateComponents()
            components.year = 2026
            components.month = month
            components.day = 15
            components.timeZone = TimeZone(secondsFromGMT: 0)
            guard let date = Self.calendar.date(from: components) else { continue }

            let quarter = EventSearchParser.quarter(containing: date, offset: 0, calendar: Self.calendar)
            #expect(Self.calendar.component(.month, from: quarter?.lowerBound ?? date) == expectedStart)
        }

        // The previous quarter is three months before, including across a year boundary.
        var february = DateComponents()
        february.year = 2026
        february.month = 2
        february.day = 1
        february.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = Self.calendar.date(from: february),
           let previous = EventSearchParser.quarter(containing: date, offset: -1, calendar: Self.calendar) {
            #expect(Self.calendar.component(.year, from: previous.lowerBound) == 2025)
            #expect(Self.calendar.component(.month, from: previous.lowerBound) == 10)
        }
    }

    @Test("“Events in Austin” is a place")
    func locationFilter() {
        let query = Self.parse("events in:austin")
        #expect(query.locations == ["austin"])
    }

    @Test("“Events on my Work calendars” names a calendar")
    func calendarFilter() {
        let query = Self.parse("calendar:work")
        #expect(query.calendarNames == ["work"])
    }

    @Test("“Events without notes” is a flag")
    func withoutNotes() {
        #expect(Self.parse("without:notes").flags.contains(.withoutNotes))
        #expect(Self.parse("no:notes").flags.contains(.withoutNotes))
    }

    @Test("“Recurring events” works as a bare word")
    func recurringBareWord() {
        let query = Self.parse("recurring events")
        #expect(query.flags.contains(.recurring))
        #expect(query.terms == ["events"])
    }

    @Test("A quoted phrase stays together")
    func quotedPhrases() {
        let query = Self.parse("project:\"Q3 Launch\"")
        #expect(query.projectNames == ["q3 launch"])
    }

    @Test("A fragment the parser cannot read is reported rather than dropped")
    func unrecognisedTokensSurface() {
        let query = Self.parse("colour:purple")
        #expect(query.unrecognisedTokens == ["colour:purple"], """
            Silently ignoring half a query produces results that look right and are not
            """)
    }

    @Test("What was understood reads back as chips")
    func understoodTokens() {
        let query = Self.parse("lunch with:maya in:austin last year")
        let labels = query.understoodTokens.map(\.label)

        #expect(labels.contains("With"))
        #expect(labels.contains("In"))
        #expect(labels.contains("When"))
        #expect(labels.contains("Words"))
    }

    @Test("An empty query filters nothing")
    func emptyQuery() {
        #expect(Self.parse("").isEmpty)
        #expect(Self.parse("   ").isEmpty)
    }
}

@Suite("Searching the calendar index")
struct CalendarIndexTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private static func engine() -> FTSCalendarSearchEngine {
        let url = URL.temporaryDirectory.appending(path: "CalendarIndexTests-\(UUID().uuidString).sqlite")
        return FTSCalendarSearchEngine(indexURL: url)
    }

    private static func event(
        _ title: String,
        daysFromNow: Int = 0,
        hours: Double = 1,
        calendar name: String = "Work",
        calendarID: String = "work",
        location: String? = nil,
        notes: String? = nil,
        attendees: [String] = [],
        recurring: Bool = false,
        declined: Bool = false,
        allDay: Bool = false
    ) -> CalendarEventSummary {
        let start = now.addingTimeInterval(Double(daysFromNow) * 86_400)
        return CalendarEventSummary(
            identity: EventIdentity(externalIdentifier: title.lowercased().replacingOccurrences(of: " ", with: "-")),
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(hours * 3_600),
            isAllDay: allDay,
            calendarIdentifier: calendarID,
            calendarName: name,
            calendarColorName: "blue",
            accountName: "iCloud",
            locationName: location,
            notes: notes,
            participation: declined ? .declined : .accepted,
            attendees: attendees.map { EventAttendee(name: $0) },
            isRecurring: recurring
        )
    }

    private static var window: Range<Date> {
        now.addingTimeInterval(-400 * 86_400)..<now.addingTimeInterval(400 * 86_400)
    }

    private static func populated() async -> FTSCalendarSearchEngine {
        let engine = engine()
        await engine.prepare()
        await engine.absorb(
            [
                event("Lunch with Maya", daysFromNow: -200, location: "Austin", attendees: ["Maya Chen"]),
                event("Quarterly Review", daysFromNow: 5, notes: "Bring the numbers", recurring: true),
                event("Standup", daysFromNow: 1, hours: 0.25, recurring: true),
                event("Dentist", daysFromNow: 12, calendar: "Personal", calendarID: "personal"),
                event("Team offsite", daysFromNow: 30, location: "Austin", allDay: true),
                event("Declined thing", daysFromNow: 2, declined: true),
            ],
            inWindow: window,
            calendarIdentifiers: nil,
            links: [
                "lunch-with-maya": IndexedEventLinks(
                    identityKey: "lunch-with-maya",
                    personNames: ["Maya Chen"],
                    projectTitles: ["Q3 Launch"]
                ),
            ]
        )
        return engine
    }

    @Test("A word finds an event by its title")
    func titleSearch() async {
        let engine = await Self.populated()
        let results = await engine.search("dentist", now: Self.now, calendar: Self.calendar, limit: 50)

        #expect(results.events.map(\.title) == ["Dentist"])
        #expect(results.isIndexAvailable)
    }

    @Test("A person finds the meetings they were at")
    func personSearch() async {
        let engine = await Self.populated()
        let results = await engine.search("with:maya", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(results.events.map(\.title) == ["Lunch with Maya"])
    }

    @Test("A linked project finds the event it is filed under")
    func projectSearch() async {
        let engine = await Self.populated()
        let results = await engine.search("project:\"Q3 Launch\"", now: Self.now, calendar: Self.calendar, limit: 50)

        #expect(results.events.map(\.title) == ["Lunch with Maya"], """
            The project link lives only in Elephruit, so this is the query that proves the two \
            sources are indexed together rather than separately
            """)
    }

    @Test("A place finds events there")
    func locationSearch() async {
        let engine = await Self.populated()
        let results = await engine.search("in:austin", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(Set(results.events.map(\.title)) == ["Lunch with Maya", "Team offsite"])
    }

    @Test("A calendar name matches loosely, because people type half of it")
    func calendarSearch() async {
        let engine = await Self.populated()
        let results = await engine.search("calendar:personal", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(results.events.map(\.title) == ["Dentist"])
    }

    @Test("Structural queries need no words at all")
    func structuralOnly() async {
        let engine = await Self.populated()
        let results = await engine.search("is:recurring", now: Self.now, calendar: Self.calendar, limit: 50)

        #expect(Set(results.events.map(\.title)) == ["Quarterly Review", "Standup"])
        #expect(results.events.allSatisfy { $0.snippet == nil }, "Nothing was matched textually to snippet")
    }

    @Test("Events without notes are findable")
    func withoutNotes() async {
        let engine = await Self.populated()
        let results = await engine.search("without:notes", now: Self.now, calendar: Self.calendar, limit: 50)

        #expect(!results.events.contains { $0.title == "Quarterly Review" })
        #expect(results.events.contains { $0.title == "Standup" })
    }

    @Test("Declined events stay out unless asked for by name")
    func declinedAreHidden() async {
        let engine = await Self.populated()

        let ordinary = await engine.search("thing", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(ordinary.events.isEmpty, "A meeting somebody said no to is not part of their history")

        let asked = await engine.search("is:declined", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(asked.events.map(\.title) == ["Declined thing"])
    }

    @Test("A period narrows to the window it names")
    func periodNarrows() async {
        let engine = await Self.populated()
        let results = await engine.search("upcoming", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(results.events.allSatisfy { $0.startAt >= Self.now })
    }

    @Test("A text match carries a snippet with the matched words marked")
    func snippetsAreMarked() async {
        let engine = await Self.populated()
        let results = await engine.search("numbers", now: Self.now, calendar: Self.calendar, limit: 50)

        #expect(results.events.count == 1)
        let highlighted = results.events.first?.highlightedSnippet
        #expect(highlighted?.matches.isEmpty == false)
        #expect(highlighted?.text.contains("\u{2}") == false, "The sentinels must not reach the screen")
    }

    @Test("Refreshing a window replaces it without touching anything outside")
    func windowReplacementIsBounded() async {
        let engine = await Self.populated()

        // A narrow window covering only the next week.
        let narrow = Self.now..<Self.now.addingTimeInterval(7 * 86_400)
        await engine.absorb([Self.event("Standup", daysFromNow: 1, hours: 0.25, recurring: true)],
                            inWindow: narrow, calendarIdentifiers: nil, links: [:])

        let all = await engine.cachedEvents(in: Self.window, calendarIdentifiers: nil)
        let titles = Set(all.map(\.title))

        #expect(titles.contains("Standup"))
        #expect(titles.contains("Lunch with Maya"), """
            Refreshing this week must not discard last year — an event outside the window was never \
            asked about and cannot have changed
            """)
        #expect(!titles.contains("Quarterly Review"), """
            …and an event that was inside the window and is no longer returned has gone, which is \
            what a bounded replace is for
            """)
    }

    @Test("An event that moves out of a window leaves no ghost behind")
    func movedEventsLeaveNoGhost() async {
        let engine = Self.engine()
        await engine.prepare()

        let window = Self.now..<Self.now.addingTimeInterval(7 * 86_400)
        await engine.absorb([Self.event("Moving", daysFromNow: 1)], inWindow: window,
                            calendarIdentifiers: nil, links: [:])
        #expect(await engine.cachedEvents(in: window, calendarIdentifiers: nil).count == 1)

        // The same window, now empty: the meeting was dragged into next month.
        await engine.absorb([], inWindow: window, calendarIdentifiers: nil, links: [:])
        #expect(await engine.cachedEvents(in: window, calendarIdentifiers: nil).isEmpty)
    }

    @Test("The cache answers a window without the calendar being present")
    func cacheServesOffline() async {
        let engine = await Self.populated()
        let cached = await engine.cachedEvents(
            in: Self.now..<Self.now.addingTimeInterval(3 * 86_400), calendarIdentifiers: nil
        )

        #expect(!cached.isEmpty, """
            A calendar the app cannot currently read should show what it last knew rather than \
            going blank
            """)
        #expect(cached.first?.isAllDay == false)
    }

    @Test("A calendar filter is honoured by the cache too")
    func cacheRespectsCalendarFilter() async {
        let engine = await Self.populated()
        let cached = await engine.cachedEvents(in: Self.window, calendarIdentifiers: ["personal"])
        #expect(cached.map(\.title) == ["Dentist"])
    }

    @Test("An empty calendar selection reads as nothing rather than everything")
    func emptySelectionShowsNothing() async {
        let engine = await Self.populated()
        let cached = await engine.cachedEvents(in: Self.window, calendarIdentifiers: [])
        #expect(cached.isEmpty)
    }

    @Test("One event can be updated on its own")
    func incrementalUpdate() async {
        let engine = await Self.populated()

        var renamed = Self.event("Dentist", daysFromNow: 12, calendar: "Personal", calendarID: "personal")
        renamed.title = "Dentist — moved"
        await engine.absorb(renamed, links: nil)

        let results = await engine.search("moved", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(results.events.map(\.title) == ["Dentist — moved"])

        let stale = await engine.search("dentist", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(stale.events.count == 1, "The old row must go, not sit beside the new one")
    }

    @Test("An event can be forgotten")
    func removal() async {
        let engine = await Self.populated()
        await engine.forget(identityKey: "dentist")

        let results = await engine.search("dentist", now: Self.now, calendar: Self.calendar, limit: 50)
        #expect(results.events.isEmpty)
    }

    @Test("Punctuation in a query is a character, not an operator")
    func punctuationIsSafe() async {
        let engine = await Self.populated()

        for text in ["lunch -", "\"unclosed", "review*", "a AND OR b"] {
            let results = await engine.search(text, now: Self.now, calendar: Self.calendar, limit: 50)
            #expect(results.isIndexAvailable, "“\(text)” must not throw a syntax error at the user")
        }
    }

    @Test("The index reports what it holds")
    func statistics() async {
        let engine = await Self.populated()
        let stats = await engine.statistics()
        #expect(stats.events == 6)
        #expect(stats.lastIndexedAt != nil)
    }

    @Test("Invalidating starts from nothing")
    func invalidation() async {
        let engine = await Self.populated()
        await engine.invalidate()
        await engine.prepare()

        let stats = await engine.statistics()
        #expect(stats.events == 0)
    }

    @Test("A narrowed refresh leaves the calendars it never asked about alone")
    func narrowedRefreshKeepsOtherCalendars() async {
        let engine = await Self.populated()
        let window = Self.now.addingTimeInterval(-400 * 86_400)..<Self.now.addingTimeInterval(400 * 86_400)

        // What happens when somebody ticks "Personal" off: the fetch narrows to the Work calendar,
        // and this window is replaced from a result set that never mentioned Personal.
        await engine.absorb(
            [Self.event("Standup", daysFromNow: 1, hours: 0.25, recurring: true)],
            inWindow: window,
            calendarIdentifiers: ["work"],
            links: [:]
        )

        let dentist = await engine.search("dentist", now: Self.now, calendar: Self.calendar, limit: 20)
        #expect(dentist.events.count == 1, """
            Ticking a calendar off must not make its past unsearchable. The fetch never asked about \
            it, so its absence from the results says nothing at all.
            """)

        let work = await engine.search("lunch", now: Self.now, calendar: Self.calendar, limit: 20)
        #expect(work.events.isEmpty, "…while the calendar that *was* asked about is replaced as usual")
    }
}
