import ElephruitCore
import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// What clicking Today actually costs, end to end.
///
/// ### What this measures that `TaskBenchmarks` does not
/// The Tasks suite measures one fetch and the scheduling rules. Today is an *assembly*: the calendar
/// window, the library pass, celebrations, meeting context, per-person detail, and five days of
/// rules — and the page shows a spinner until the whole of it has run once. The number that matters
/// is the cold one, because that is the spinner.
///
/// The corpus is a heavy-but-real library: thousands of tasks, hundreds of people with linked
/// history, a year of daily notes, and a calendar with a working week's worth of meetings.
///
/// Disabled unless `ELEPHRUIT_BENCHMARKS=1`.
@MainActor
@Suite("Today benchmarks", .enabled(if: Benchmark.isEnabled), .serialized)
struct TodayBenchmarks {
    static let clock = FixedDateProvider.reference

    private static func at(_ hour: Int, dayOffset: Int) -> Date {
        let day = clock.startOfDay(daysFromToday: dayOffset)
        return clock.calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    /// A heavy library with a synthetic calendar attached.
    ///
    /// Nothing here touches EventKit or the developer's defaults: the calendar is a fixture and the
    /// defaults suite is a throwaway.
    private static func makeFixture() async throws -> AppServices {
        // Ten days of meetings around today, six a day, three attendees each — some known to the
        // library by email, the rest strangers. That mix exercises the person index rather than
        // skipping it.
        var events: [CalendarEventSummary] = []
        for dayOffset in -4...5 {
            for slot in 0..<6 {
                let start = at(9 + slot, dayOffset: dayOffset)
                events.append(
                    CalendarEventSummary(
                        identity: EventIdentity(externalIdentifier: "bench-\(dayOffset)-\(slot)"),
                        title: "Meeting \(dayOffset)/\(slot)",
                        startAt: start,
                        endAt: start.addingTimeInterval(30 * 60),
                        calendarIdentifier: "fixture.work",
                        calendarName: "Work",
                        attendees: [
                            EventAttendee(
                                name: "Person \(slot)",
                                emailAddress: "person\(slot)@bench.example"
                            ),
                            EventAttendee(name: "Person \(slot + 100)"),
                            EventAttendee(name: "Stranger \(dayOffset)-\(slot)"),
                        ]
                    )
                )
            }
        }

        let defaults = UserDefaults(suiteName: "today.bench.\(UUID().uuidString)") ?? .standard
        let fixtureEvents = events
        let services = AppServices.inMemory(
            dateProvider: clock,
            populated: false,
            calendarProvider: {
                FixtureCalendarProvider(events: fixtureEvents, authorization: .authorized)
            },
            defaults: defaults
        )
        _ = await services.calendar.enable()

        let items = services.items
        let tasks = services.tasks

        let projects = try (0..<40).map { index in
            try items.create(ItemDraft(kind: .project, title: "Project \(index)"))
        }

        // Five hundred people, most with some linked history, a third with a birthday.
        var people: [Item] = []
        for index in 0..<500 {
            var draft = PersonDraft(fullName: "Person \(index)")
            if index < 250 {
                draft.emails = [LabelledValue(label: "work", value: "person\(index)@bench.example")]
            }
            if index % 3 == 0 {
                draft.birthday = PartialDate(month: 1 + index % 12, day: 1 + index % 28)
            }
            let person = try services.persons.createPerson(draft)
            people.append(person)
        }

        // Interactions, so `context(for:)` has links to walk — the shape a used CRM has.
        for index in 0..<800 {
            let person = people[index % people.count]
            try services.people.recordInteraction(
                with: person,
                summary: "Call \(index)",
                at: clock.startOfDay(daysFromToday: -(index % 90))
            )
        }

        // Twenty-five hundred open tasks with a realistic spread of dates, plus some linked people.
        for index in 0..<2_500 {
            let task = try items.create(
                ItemDraft(
                    kind: .task,
                    title: "Task \(index)",
                    parentID: projects[index % projects.count].id
                )
            )
            switch index % 20 {
            case 0: try tasks.setDeadline(clock.startOfDay(daysFromToday: -3), on: task)
            case 1: try tasks.commitToToday(task)
            case 2: try tasks.setDeadline(clock.startOfDay(daysFromToday: 2), on: task)
            case 3: try tasks.setStartDate(clock.startOfDay(daysFromToday: 1), on: task)
            case 4: try tasks.setFlagged(true, on: task)
            case 5: try items.link(task, to: people[index % people.count], kind: .mentions)
            default: break
            }
        }

        // A logbook: recently finished work, some of it today.
        for index in 0..<300 {
            let task = try items.create(ItemDraft(kind: .task, title: "Done \(index)"))
            _ = try tasks.complete(task)
        }

        // A year of daily notes, which the notes query reads past.
        for index in 0..<365 {
            var draft = ItemDraft(kind: .dailyEntry, title: "Day \(index)")
            draft.dayKey = clock.dayKey(for: clock.startOfDay(daysFromToday: -index))
            _ = try items.create(draft)
        }

        return services
    }

    /// ### What running this actually found, and what the budgets therefore mean
    /// Cold assembly first measured ~465 ms, dominated by one thing: the open-items fetch (~185 ms)
    /// materialised every open work item so `couldAppearOnSomeDay` could keep the few hundred with
    /// a day anchor. That escalation has now been taken — `Item.dayRelevanceKey`, the same shape as
    /// `dueSortKey`, narrows the fetch in the store — and cold measured ~270 ms after it. The
    /// budgets are set from those measurements with headroom, not invented.
    ///
    /// `today.fetch.unwindowed` is kept as the floor this replaced: the windowed read staying well
    /// under it is the whole point of the column, and the gap collapsing means the key has stopped
    /// narrowing anything.
    ///
    /// The warm figure is the important ratio: a reassembly with the caches warm — a filter toggle,
    /// a tick — measured ~20 ms, and it staying an order of magnitude under cold is asserted below.
    /// It used to be ~110 ms, all of it container lookups run once per task instead of once per
    /// container.
    @Test("Assembling the Today window over a heavy library")
    func todayWindow() async throws {
        let services = try await Self.makeFixture()
        let plan = services.dailyPlan
        let today = Self.clock.startOfToday
        let last = Self.clock.startOfDay(daysFromToday: 4)

        // The calendar read the page awaits before it can assemble anything. The index absorb no
        // longer rides inside it — that write lands behind the answer, off the spinner path.
        let loadCalendar = await Benchmark.measure(
            "today.loadCalendar", budget: .milliseconds(50), iterations: 3
        ) {
            await plan.loadCalendar(from: today, through: last)
        }

        // The spinner: everything between clicking Today and seeing the day, calendar aside.
        let cold = Benchmark.measure("today.window.cold", budget: .milliseconds(400), iterations: 3) {
            plan.invalidateEverything()
            _ = try? plan.window(from: today, count: 5)
        }

        // A reassembly with the caches warm — a filter toggle, a tick.
        let warm = Benchmark.measure("today.window.warm", budget: .milliseconds(60), iterations: 5) {
            _ = try? plan.window(from: today, count: 5)
        }

        // The pieces, so a regression names its culprit.
        let celebrations = Benchmark.measure(
            "today.celebrations", budget: .milliseconds(60), iterations: 3
        ) {
            _ = try? services.persons.allCelebrations()
        }

        let contexts = Benchmark.measure(
            "today.people.contexts", budget: .milliseconds(400), iterations: 3
        ) {
            _ = try? services.people.allContexts()
        }

        // The floor the day-relevance key replaced, kept for the comparison below.
        var open = ItemQuery()
        open.kinds = ItemKind.workItemKindSet
        open.statuses = [.open]
        let unwindowed = Benchmark.measure(
            "today.fetch.unwindowed", budget: .milliseconds(300), iterations: 3
        ) {
            _ = try? services.items.items(matching: open)
        }

        // What the assembly actually runs: the same query bounded by the window's end.
        var windowed = open
        windowed.dayRelevantBefore = Self.clock.startOfDay(daysFromToday: 5)
        let fetch = Benchmark.measure("today.fetch.window", budget: .milliseconds(120), iterations: 3) {
            _ = try? services.items.items(matching: windowed)
        }

        let identities = services.calendar.events.map { $0.identity }
        let meetings = Benchmark.measure(
            "today.meetingContext", budget: .milliseconds(20), iterations: 3
        ) {
            _ = try? services.eventLinks.meetingContext(for: identities)
        }

        for measurement in [loadCalendar, cold, warm, celebrations, contexts, unwindowed, fetch, meetings] {
            #expect(measurement.passes, "\(measurement.report)")
        }

        // The shape, asserted rather than left in a comment: a warm reassembly reads nothing from
        // the store that matters, so it must stay far below a cold one. Approaching it means a
        // per-call fetch has crept back into the assembly path.
        #expect(
            warm.rawSeconds < cold.rawSeconds / 5,
            "A warm reassembly is fetching again — \(warm.report) vs \(cold.report)"
        )

        // The windowed read must stay well under the full scan it replaced. The two converging
        // means `dayRelevanceKey` has stopped narrowing anything — a regression the absolute
        // budgets above could absorb without anyone noticing.
        #expect(
            fetch.rawSeconds < unwindowed.rawSeconds / 2,
            "The window bound has stopped narrowing the fetch — \(fetch.report) vs \(unwindowed.report)"
        )
    }
}
