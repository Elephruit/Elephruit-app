import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// Assembles one date's worth of everything, from the records that already exist.
///
/// ### Why one assembler rather than three sections that each fetch
/// Because the interesting part of a day is where its three subjects *meet*. The person in your ten
/// o'clock is also the person a task is waiting on and also the person whose birthday it is; showing
/// them once, with all three reasons, is only possible if something has seen all three. Three
/// independent sections each doing their own fetch cannot deduplicate, and the page they produce is
/// the thing this redesign exists to stop being — a feed of unrelated records.
///
/// ### Nothing here is stored
/// Every value returned is derived from tasks, events, people, celebrations and notes that already
/// live in the library. There is no Today table, nothing is written on assembly, and an edit made
/// anywhere else is visible here on the next pass — which is what makes the page a view of the
/// truth rather than a copy of it.
///
/// ### One fetch, rules in Swift
/// The same split ``ReminderQueryService`` established, for the same reason: none of the relevance rules
/// translate to a predicate. They compare against *today* in the user's calendar, read a commitment
/// made on an earlier day, and consult a lifecycle derived from four columns and a traversal.
@MainActor
public final class DailyPlanService {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    private var clock: any DateProvider { services.dateProvider }
    private var calendar: Calendar { clock.calendar }

    // MARK: - Loading the window

    /// Reads the calendar for the span of days a page is about to draw.
    ///
    /// Separate from ``plan(for:filters:)`` because it is the only part that can be slow and the only
    /// part that is asynchronous — the calendar is an actor behind a permission. Loading a whole
    /// window once and then assembling each day from what is already in memory is the difference
    /// between one round trip and one per day on screen.
    public func loadCalendar(from first: Date, through last: Date) async {
        guard services.calendar.isEnabled else { return }
        let start = calendar.startOfDay(for: first)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)),
              start < end
        else { return }
        await services.calendar.load(range: start..<end)
    }

    /// Whether the calendar can already answer for this span without being asked again.
    ///
    /// True when the feature is off — there is nothing to wait for — and when a load covering the
    /// span has returned. What it decides is whether a page may assemble *now*, from memory, rather
    /// than holding a spinner through a round trip. The one case that answers false is the honest
    /// one: a window the calendar has never been asked about, where drawing immediately would tell
    /// somebody their day is clear before it has been read.
    public func canAnswerForCalendar(from first: Date, through last: Date) -> Bool {
        guard services.calendar.isEnabled else { return true }
        let start = calendar.startOfDay(for: first)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)),
              start < end
        else { return true }
        return services.calendar.hasAnswered(range: start..<end)
    }

    // MARK: - Assembling a day

    /// Everything one date holds.
    ///
    /// Throws only what the store throws. A missing calendar, a person with no profile, or a day
    /// with nothing in it are all ordinary and produce an ordinary, empty-ish plan.
    public func plan(for date: Date, filters: TodayFilters = .standard) throws(AppError) -> DayPlan {
        var sources = try sources(filters: filters, windowEnd: windowEnd(from: date, count: 1))
        sources.dailyNotes = notes(from: date, count: 1, reusing: sources)
        return try plan(for: date, filters: filters, sources: sources)
    }

    /// The exclusive end of a window of days, for the relevance bound.
    private func windowEnd(from first: Date, count: Int) -> Date {
        let start = calendar.startOfDay(for: first)
        return calendar.date(byAdding: .day, value: max(1, count), to: start) ?? Date.distantFuture
    }

    /// Everything one pass over the library found, shared by every day on screen.
    ///
    /// ### Why this is read once and not per day
    /// Because none of the scheduling rules translate to a predicate — they compare against *today*
    /// in the user's calendar, read a commitment made on an earlier day, and consult a lifecycle
    /// derived from four columns and a traversal — so answering "what is on Thursday" means walking
    /// every open task. A page showing five days did that five times, and a real library is
    /// thousands of rows. One walk, five days.
    private struct LibrarySources {
        /// Open tasks that could belong to *some* day, with their facts already derived.
        ///
        /// Both halves matter. Narrowing first is what keeps this small; deriving once is what keeps
        /// it cheap. See ``couldAppearOnSomeDay(_:)`` and the note on ``sources(filters:)``.
        var candidates: [(item: Item, facts: TaskFacts)] = []

        /// Work finished or abandoned inside the window, likewise already derived.
        var resolved: [(item: Item, facts: TaskFacts)] = []

        var celebrations: [Celebration] = []

        /// What is prepared for, and who is linked to, every meeting in the window — keyed by the
        /// event's storage key.
        ///
        /// Read once for the whole window rather than once per day. Both halves come from a scan of
        /// every meeting item, and a page showing five days was running that scan ten times to draw
        /// one screen.
        var meetings: [String: MeetingContext] = [:]

        /// The day's own note, by day key, for every day in the window.
        var dailyNotes: [String: Item] = [:]

        /// Which task belongs to which meeting, for the whole window.
        var meetingTaskIDs: [UUID: (id: String, title: String)] = [:]

        /// The window the daily notes were read for, so a different window re-reads them.
        var noteWindow: ClosedRange<Date>?
    }

    /// What the last library pass found, and what it was true of.
    ///
    /// ### Why this is cached and the plans are not
    /// Because filters change what is *shown* and never what is *read*. Hiding meetings does not
    /// make the tasks different; it makes them not drawn. So a filter toggle used to re-fetch every
    /// open task, every person and every meeting item to arrive at the same answer, and at fifteen
    /// hundred tasks that is a quarter of a second of pure waste per click.
    ///
    /// Keyed on the two counters that say the underlying records actually moved — the library's own
    /// ``AppServices/changeToken`` and the calendar's ``CalendarService/revision``. Anything else is
    /// a question about the same records, and the same records give the same answer.
    private struct CachedSources {
        var changeToken: Int
        var calendarRevision: Int

        /// The relevance bound the candidates were fetched under. A pass read for a *later* bound
        /// answers for any earlier one — the rules narrow per day either way — so the cache is
        /// reusable whenever it covers the window being asked about, not only when it matches.
        var windowEnd: Date

        var sources: LibrarySources
    }

    private var cachedSources: CachedSources?

    private func sources(filters: TodayFilters, windowEnd: Date) throws(AppError) -> LibrarySources {
        if let cached = cachedSources,
           cached.changeToken == services.changeToken,
           cached.calendarRevision == services.calendar.revision,
           cached.windowEnd >= windowEnd {
            return cached.sources
        }

        let fresh = try readSources(windowEnd: windowEnd)
        cachedSources = CachedSources(
            changeToken: services.changeToken,
            calendarRevision: services.calendar.revision,
            windowEnd: windowEnd,
            sources: fresh
        )
        return fresh
    }

    /// One pass over the library.
    ///
    /// Reads everything the page could need rather than what the current filters happen to want:
    /// the cost of a fetch nobody draws is one fetch, and keying the cache on the filters as well
    /// would mean re-reading the library every time somebody changed their mind.
    ///
    /// ### Why the tasks are narrowed before their facts are derived
    /// The rules have to run in Swift over the open tasks — none of them translate to a predicate.
    /// But `TaskFacts` is not free: deriving one walks the parent chain, both link collections, the
    /// children, the attachments and the checklist. At fifteen hundred open tasks that is several
    /// thousand relationship fault-ins, and the page was doing it **once per task per day** — about
    /// seven and a half thousand times to draw one screen.
    ///
    /// The narrowing is what fixes it, and it is safe because it reads only *columns*. A task can
    /// only reach a day through a deadline, a start date, a commitment, a reminder, a follow-up
    /// date, a flag, or a meeting it is attached to — every one of which is a stored value that
    /// costs nothing to test. Of fifteen hundred open tasks, a working week touches a few dozen.
    ///
    /// ### And narrowed in the store before that
    /// The column test used to run over rows already materialised, which meant the fetch itself was
    /// the cost: every open item brought into memory to keep the few with a date. The dates now
    /// have a derived floor — ``ElephruitModel/Item/dayRelevanceKey``, the same shape as
    /// `dueSortKey` — so the store hands back only work that could matter before the window ends,
    /// plus the flagged (a flag is not a date, so it is a second small fetch), plus anything a
    /// meeting in the window named, read by identifier. `couldAppearOnSomeDay` still runs over the
    /// result: the store clauses are a superset by construction, never the decision.
    private func readSources(windowEnd: Date) throws(AppError) -> LibrarySources {
        var sources = LibrarySources()

        if services.calendar.isEnabled {
            // The events already in memory for the loaded window — see `loadCalendar(from:through:)`.
            let identities = services.calendar.events.map(\.identity)
            sources.meetings = try services.eventLinks.meetingContext(for: identities)

            for (key, context) in sources.meetings {
                guard let event = services.calendar.events.first(where: { $0.identity.storageKey == key })
                else { continue }
                for taskID in context.preparation.openPreparationTaskIDs {
                    sources.meetingTaskIDs[taskID] = (id: event.id, title: event.displayTitle)
                }
            }
        }

        do {
            var relevant = ItemQuery()
            relevant.kinds = ItemKind.workItemKindSet
            relevant.statuses = [.open]
            relevant.sort = .manual
            relevant.dayRelevantBefore = windowEnd

            var flagged = relevant
            flagged.dayRelevantBefore = nil
            flagged.isFlagged = true

            let prepared = Set(sources.meetingTaskIDs.keys)
            var seen = Set<UUID>()

            for task in try services.items.items(matching: relevant) + services.items.items(matching: flagged) {
                guard seen.insert(task.id).inserted else { continue }
                guard Self.couldAppearOnSomeDay(task) || prepared.contains(task.id) else { continue }
                sources.candidates.append((item: task, facts: task.taskFacts()))
            }

            // A task attached to a meeting has no date of its own, so neither windowed fetch may
            // have seen it. A window's meetings name a handful of tasks at most, read by identifier.
            for id in prepared where !seen.contains(id) {
                guard let task = try? services.items.item(id: id),
                      task.kind.isWorkItem, task.status == .open, task.deletedAt == nil,
                      task.archivedAt == nil
                else { continue }
                seen.insert(id)
                sources.candidates.append((item: task, facts: task.taskFacts()))
            }

            var resolvedQuery = ItemQuery()
            resolvedQuery.kinds = ItemKind.workItemKindSet
            resolvedQuery.statuses = [.completed, .cancelled]
            resolvedQuery.sort = .updatedNewestFirst
            // Bounded: a logbook of five thousand entries has nothing to say about this week, and
            // the rows that do are the most recent ones by construction.
            resolvedQuery.limit = 200

            for task in try services.items.items(matching: resolvedQuery) {
                // Narrowed on columns before the facts are derived, for the same reason as above.
                guard task.completedAt != nil || task.cancelledAt != nil else { continue }
                sources.resolved.append((item: task, facts: task.taskFacts()))
            }
        }

        sources.celebrations = try services.persons.allCelebrations()

        return sources
    }

    /// Whether a task could reach any day at all, decided from stored values alone.
    ///
    /// Deliberately generous: it is a *superset* of what the rules will accept, because the rules
    /// are the thing that decides and this only exists to stop them being asked about work that
    /// plainly has no date on it. Getting it wrong in the other direction would silently drop work
    /// from somebody's day, so every route a task has onto a day is listed here — and a task
    /// attached to a meeting, which has no date of its own, is added by identifier by the caller.
    private static func couldAppearOnSomeDay(_ task: Item) -> Bool {
        guard task.status == .open, !task.isSomeday else { return false }
        return task.dueAt != nil
            || task.availableFrom != nil
            || task.todayCommittedOn != nil
            || task.reminderAt != nil
            || task.followUpAt != nil
            || task.isFlagged
    }

    /// The day's notes for a window, in one fetch.
    ///
    /// `ItemQuery.dayKey` is not part of the predicate and not part of the post-filter, so asking for
    /// one day's note fetches every daily entry in the library. Asking five times fetched them five
    /// times; a library with a note for every day of a year made that the single most expensive
    /// thing on the page.
    /// The window's notes, re-read only when the window has actually moved.
    private func notes(from first: Date, count: Int, reusing sources: LibrarySources) -> [String: Item] {
        let start = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: .day, value: max(0, count - 1), to: start) ?? start

        if let cached = sources.noteWindow, cached == start...end { return sources.dailyNotes }

        var found = dailyNotes(from: first, count: count)
        cachedSources?.sources.dailyNotes = found
        cachedSources?.sources.noteWindow = start...end
        // Returned rather than read back out of the cache, so a caller with no cache still works.
        if found.isEmpty { found = [:] }
        return found
    }

    private func dailyNotes(from first: Date, count: Int) -> [String: Item] {
        var query = ItemQuery()
        query.kinds = [.dailyEntry]
        query.scope = .active

        guard let entries = try? services.items.items(matching: query) else { return [:] }

        var wanted = Set<String>()
        var cursor = calendar.startOfDay(for: first)
        for _ in 0..<max(0, count) {
            wanted.insert(clock.dayKey(for: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var found: [String: Item] = [:]
        for entry in entries {
            guard let key = entry.dayKey, wanted.contains(key), found[key] == nil else { continue }
            found[key] = entry
        }
        return found
    }

    private func plan(
        for date: Date,
        filters: TodayFilters,
        sources: LibrarySources
    ) throws(AppError) -> DayPlan {
        let day = calendar.startOfDay(for: date)
        let now = clock.now
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)

        let events = filters.showsMeetings ? dayEvents(on: day, filters: filters, sources: sources) : []

        let taskContext = filters.showsTasks
            ? dayTasks(on: day, now: now, isToday: isToday, filters: filters, sources: sources)
            : DayTaskContext()

        let celebrations = celebrations(on: day, isToday: isToday, from: sources.celebrations)

        let people = filters.showsPeople
            ? try roster(
                events: events,
                tasks: taskContext,
                celebrations: celebrations,
                isToday: isToday
            )
            : []

        var noteID: UUID?
        var noteExcerpt: String?
        if filters.showsDailyNote, let entry = sources.dailyNotes[clock.dayKey(for: day)] {
            noteID = entry.id
            noteExcerpt = entry.body.isEmpty ? nil : TextNormalizer.excerpt(from: entry.body)
        }

        let briefing = briefing(
            on: day,
            isToday: isToday,
            events: events,
            tasks: taskContext,
            celebrations: celebrations,
            people: people,
            now: now
        )

        return DayPlan(
            date: day,
            isToday: isToday,
            isPast: isPast,
            briefing: briefing,
            events: events,
            tasks: taskContext.tasks,
            completedTaskIDs: filters.showsCompleted ? taskContext.completedIDs : [],
            people: people,
            dailyNoteID: noteID,
            dailyNoteExcerpt: noteExcerpt
        )
    }

    /// Several days at once, sharing one pass over the library.
    ///
    /// A future strip draws five days; assembling each independently would run the scheduling rules
    /// over every open task five times.
    public func plans(from first: Date, count: Int, filters: TodayFilters = .standard) throws(AppError) -> [DayPlan] {
        try window(from: first, count: count, filters: filters).days
    }

    /// A run of days, and every record needed to draw them.
    ///
    /// ### Why the records travel with the days
    /// A `DayPlan` names tasks and people by identifier, because the rules that produced it are pure
    /// values over a clock. The rows that draw them need the `Item`. The page used to look each one
    /// up, which is a fetch per visible row — forty of them across five days, on every reload, and
    /// a fetch during a render is the thing `FetchAudit` fails a build over.
    ///
    /// The assembler has already read every one of these. Handing them back costs nothing and
    /// removes the lookup entirely.
    public struct DayWindow {
        public var days: [DayPlan] = []

        /// Every task the days name, open and finished.
        public var tasks: [UUID: Item] = [:]

        /// Every person the days name, for the ones the library knows.
        public var people: [UUID: Item] = [:]

        /// The projects and lists the days draw work from, for the filter menu.
        public var containers: [Item] = []
    }

    public func window(
        from first: Date,
        count: Int,
        filters: TodayFilters = .standard
    ) throws(AppError) -> DayWindow {
        var sources = try sources(filters: filters, windowEnd: windowEnd(from: first, count: count))
        sources.dailyNotes = notes(from: first, count: count, reusing: sources)

        var window = DayWindow()
        var cursor = calendar.startOfDay(for: first)
        for _ in 0..<max(0, count) {
            window.days.append(try plan(for: cursor, filters: filters, sources: sources))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Everything the days named, out of what was already in hand.
        var named = Set<UUID>()
        for day in window.days {
            named.formUnion(day.tasks.map(\.taskID))
            named.formUnion(day.completedTaskIDs)
            for event in day.events { named.formUnion(event.preparation.openPreparationTaskIDs) }
        }

        var containers: [UUID: Item] = [:]
        for candidate in sources.candidates + sources.resolved where named.contains(candidate.facts.id) {
            window.tasks[candidate.facts.id] = candidate.item
            // From the facts already derived rather than a second walk of the parent chain — and
            // fetched once per *container*, not once per task. A window naming a few hundred tasks
            // across forty projects was running a few hundred fetches to fill a forty-entry map,
            // which was most of what a warm reassembly cost.
            if let container = candidate.facts.projectID ?? candidate.facts.listID,
               containers[container] == nil,
               let item = try? services.items.item(id: container) {
                containers[container] = item
            }
        }

        // A preparation task lives on a meeting rather than on the day, so it may not be in either
        // list above. Read individually, which is a handful of rows at most.
        for id in named where window.tasks[id] == nil {
            if let task = try? services.items.item(id: id) { window.tasks[id] = task }
        }

        window.people = personItems

        // Anything already hidden stays offerable whether or not it contributed this time — a switch
        // you cannot find again is a switch that has trapped you.
        for id in filters.hiddenContainerIDs where containers[id] == nil {
            if let container = try? services.items.item(id: id) { containers[id] = container }
        }
        window.containers = containers.values.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }

        return window
    }

    // MARK: - Events

    private func dayEvents(on day: Date, filters: TodayFilters, sources: LibrarySources) -> [DayEvent] {
        guard services.calendar.isEnabled else { return [] }

        let raw = services.calendar.events(on: day).filter { event in
            guard DayEventRules.appearsInPlan(event) else { return false }
            guard let identifier = event.calendarIdentifier else { return true }
            return !filters.hiddenCalendarIdentifiers.contains(identifier)
        }
        guard !raw.isEmpty else { return [] }

        let clashes = DayEventRules.conflicts(among: raw, calendar: calendar)

        return raw
            .map { event in
                let kind = DayEventRules.kind(of: event)
                let context = sources.meetings[event.identity.storageKey] ?? MeetingContext()
                return DayEvent(
                    event: event,
                    kind: kind,
                    conflictingEventIDs: clashes[event.id] ?? [],
                    participants: kind.hasAttendees
                        ? participants(of: event, linkedPersonIDs: context.linkedPersonIDs)
                        : [],
                    preparation: context.preparation
                )
            }
            .sorted { left, right in
                let leftAllDay = left.event.occupiesAllDayRow(calendar: calendar)
                let rightAllDay = right.event.occupiesAllDayRow(calendar: calendar)
                if leftAllDay != rightAllDay { return leftAllDay }
                if left.event.startAt != right.event.startAt { return left.event.startAt < right.event.startAt }
                return left.event.displayTitle < right.event.displayTitle
            }
    }

    /// Attendees, joined to the library where the library knows them.
    ///
    /// ### Why the link is offered rather than made
    /// Two people called James Wilson is not a rare case, and attaching somebody's private history to
    /// a stranger because their names fold to the same string is not a mistake that announces itself.
    /// So an email address — which is an identity — resolves, and a name alone resolves only when it
    /// matches exactly one person in the library. Everybody else stays an unlinked attendee, drawn as
    /// such, with a way to link them by hand. This is the same rule ``EventInspectorView`` applies,
    /// deliberately: the two surfaces must not disagree about who somebody is.
    private func participants(of event: CalendarEventSummary, linkedPersonIDs: [UUID]) -> [DayParticipant] {
        let index = personIndex()
        var linkedByID: [UUID: Item] = [:]
        for id in linkedPersonIDs {
            if let person = try? services.items.item(id: id) { linkedByID[id] = person }
        }

        var seen = Set<String>()
        var participants: [DayParticipant] = []

        for attendee in event.attendees where !attendee.isCurrentUser {
            let resolved = index.match(name: attendee.displayName, email: attendee.emailAddress)
            let person = resolved ?? linkedByID.values.first { candidate in
                TextNormalizer.foldedForMatching(candidate.displayTitle)
                    == TextNormalizer.foldedForMatching(attendee.displayName)
            }

            let key = person.map { "person:\($0.id.uuidString)" }
                ?? attendee.emailAddress?.lowercased()
                ?? "name:\(TextNormalizer.foldedForMatching(attendee.displayName))"
            guard seen.insert(key).inserted else { continue }

            participants.append(
                DayParticipant(
                    personID: person?.id,
                    key: key,
                    name: person?.displayTitle ?? attendee.displayName,
                    emailAddress: attendee.emailAddress,
                    participation: attendee.participation,
                    isOrganizer: attendee.isOrganizer
                )
            )
        }

        // People linked by hand who are not on the invitation. Somebody who joins a standing meeting
        // without being re-invited is still in the room.
        for (id, person) in linkedByID {
            let key = "person:\(id.uuidString)"
            guard seen.insert(key).inserted else { continue }
            participants.append(
                DayParticipant(personID: id, key: key, name: person.displayTitle)
            )
        }

        return participants.sorted { left, right in
            if left.isOrganizer != right.isOrganizer { return left.isOrganizer }
            if left.isKnown != right.isKnown { return left.isKnown }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    // MARK: - Tasks

    /// What one pass over the task library found for a day.
    private struct DayTaskContext {
        var tasks: [DayTask] = []
        var completedIDs: [UUID] = []

        /// Tasks by identifier, so the people roster can name them without a second fetch.
        var titles: [UUID: String] = [:]

        /// People each of the day's tasks points at, and how.
        var relatedPeople: [(personID: UUID, taskID: UUID, title: String, isWaiting: Bool)] = []
    }

    private func dayTasks(
        on day: Date,
        now: Date,
        isToday: Bool,
        filters: TodayFilters,
        sources: LibrarySources
    ) -> DayTaskContext {
        var context = DayTaskContext()

        for candidate in sources.candidates {
            let facts = candidate.facts
            guard !isHidden(facts, by: filters) else { continue }

            let reasons = DayTaskRules.reasons(
                for: facts,
                on: day,
                now: now,
                calendar: calendar,
                meetingTaskIDs: sources.meetingTaskIDs
            )
            guard !reasons.isEmpty else { continue }

            context.tasks.append(
                DayTask(
                    taskID: facts.id,
                    reasons: named(reasons, for: facts),
                    pinnedAt: DayTaskRules.pinnedTime(for: facts, on: day, calendar: calendar)
                )
            )
            context.titles[facts.id] = candidate.item.displayTitle

            if let waitingOn = facts.waitingOnPersonID {
                context.relatedPeople.append(
                    (personID: waitingOn, taskID: facts.id, title: candidate.item.displayTitle, isWaiting: true)
                )
            }
            for personID in facts.relatedPersonIDs where personID != facts.waitingOnPersonID {
                context.relatedPeople.append(
                    (personID: personID, taskID: facts.id, title: candidate.item.displayTitle, isWaiting: false)
                )
            }
        }

        context.tasks.sort { left, right in
            let leftRank = left.primaryReason?.rank ?? Int.max
            let rightRank = right.primaryReason?.rank ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            switch (left.pinnedAt, right.pinnedAt) {
            case (let a?, let b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (context.titles[left.taskID] ?? "") < (context.titles[right.taskID] ?? "")
            }
        }

        context.completedIDs = sources.resolved
            .filter { candidate in
                guard !isHidden(candidate.facts, by: filters) else { return false }
                guard let resolvedAt = candidate.facts.completedAt ?? candidate.facts.cancelledAt
                else { return false }
                return calendar.isDate(resolvedAt, inSameDayAs: day)
            }
            .map(\.facts.id)

        return context
    }

    /// Puts the person's name into a follow-up reason, which the pure rule cannot know.
    private func named(_ reasons: [DayTaskReason], for facts: TaskFacts) -> [DayTaskReason] {
        guard let waitingOn = facts.waitingOnPersonID,
              let person = try? services.items.item(id: waitingOn)
        else { return reasons }

        return reasons.map { reason in
            if case .followUp = reason { return .followUp(personName: person.displayTitle) }
            return reason
        }
    }

    private func isHidden(_ facts: TaskFacts, by filters: TodayFilters) -> Bool {
        guard !filters.hiddenContainerIDs.isEmpty else { return false }
        for container in [facts.projectID, facts.listID, facts.areaID] {
            if let container, filters.hiddenContainerIDs.contains(container) { return true }
        }
        return false
    }

    // MARK: - Celebrations

    private func celebrations(
        on day: Date,
        isToday: Bool,
        from all: [Celebration]
    ) -> [UpcomingCelebration] {
        guard !all.isEmpty else { return [] }

        // A window rather than a single day, and only on today. A birthday tomorrow is something you
        // act on today — a card does not post itself — whereas a birthday eight days after next
        // Thursday is not a fact about next Thursday.
        let window = isToday ? 7 : 0
        return CelebrationCalendar.upcoming(from: all, within: window, asOf: day, calendar: calendar)
    }

    // MARK: - People

    private func roster(
        events: [DayEvent],
        tasks: DayTaskContext,
        celebrations: [UpcomingCelebration],
        isToday: Bool
    ) throws(AppError) -> [DayPerson] {
        var roster = DayPeopleRoster()

        // Meetings first, so somebody you are about to sit down with is the identity everything else
        // merges into.
        for event in events where event.kind.hasAttendees {
            for participant in event.participants {
                roster.add(
                    personID: participant.personID,
                    key: participant.key,
                    name: participant.name,
                    colorName: colorName(of: participant.personID),
                    roleLine: roleLine(of: participant.personID),
                    reason: .meeting(
                        eventID: event.id,
                        title: event.event.displayTitle,
                        startAt: event.event.startAt,
                        isAllDay: event.event.occupiesAllDayRow(calendar: calendar)
                    ),
                    lastContact: lastContact(of: participant.personID),
                    quickFacts: quickFacts(of: participant.personID)
                )
            }
        }

        for upcoming in celebrations {
            let personID = upcoming.celebration.personID
            roster.add(
                personID: personID,
                key: "person:\(personID.uuidString)",
                name: upcoming.celebration.personName,
                colorName: colorName(of: personID),
                roleLine: roleLine(of: personID),
                reason: .celebration(upcoming),
                lastContact: lastContact(of: personID),
                quickFacts: quickFacts(of: personID)
            )
        }

        for related in tasks.relatedPeople {
            guard let person = try? services.items.item(id: related.personID) else { continue }
            roster.add(
                personID: related.personID,
                key: "person:\(related.personID.uuidString)",
                name: person.displayTitle,
                colorName: person.colorName,
                roleLine: roleLine(of: related.personID),
                reason: related.isWaiting
                    ? .waitingOn(taskID: related.taskID, title: related.title)
                    : .taskAbout(taskID: related.taskID, title: related.title),
                lastContact: lastContact(of: related.personID),
                openTaskIDs: [related.taskID],
                quickFacts: quickFacts(of: related.personID)
            )
        }

        // Follow-up suggestions are opt-in and only ever about today. An app that opens on Thursday
        // of next week and tells you who you have been neglecting is answering a question nobody
        // asked from a date nobody is standing on.
        if isToday, services.showsFollowUpSuggestions {
            let suggestions = try services.people.followUpSuggestions(
                thresholdDays: services.followUpThresholdDays
            )
            for suggestion in suggestions.prefix(5) {
                roster.add(
                    personID: suggestion.personID,
                    key: "person:\(suggestion.personID.uuidString)",
                    name: suggestion.displayName,
                    colorName: colorName(of: suggestion.personID),
                    roleLine: roleLine(of: suggestion.personID),
                    reason: .followUpDue(days: suggestion.daysSinceContact),
                    lastContact: suggestion.lastContact,
                    quickFacts: quickFacts(of: suggestion.personID)
                )
            }
        }

        return roster.people()
    }

    // MARK: - Person details, fetched once each

    private var personDetailCache: [UUID: PersonDetail] = [:]

    /// The person records this assembly touched, handed back with the days so the page draws them
    /// without a fetch of its own.
    private var personItems: [UUID: Item] = [:]

    private struct PersonDetail {
        var colorName: String?
        var roleLine: String?
        var lastContact: ContactMoment?
        var quickFacts: [String]
    }

    /// Reads a person's supporting detail once per assembly.
    ///
    /// The same person can arrive through three doors — a meeting, a task, a birthday — and each
    /// would otherwise re-read their profile, their observations and their contact history.
    private func detail(of personID: UUID?) -> PersonDetail? {
        guard let personID else { return nil }
        if let cached = personDetailCache[personID] { return cached }
        guard let person = try? services.items.item(id: personID) else { return nil }
        personItems[personID] = person

        let profile = person.personProfile
        var role: [String] = []
        if let title = profile?.roleTitle, !title.isEmpty { role.append(title) }
        if let organization = profile?.organizationName, !organization.isEmpty {
            role.append(organization)
        }

        let detail = PersonDetail(
            colorName: person.colorName,
            roleLine: role.isEmpty ? nil : role.joined(separator: ", "),
            lastContact: services.people.context(for: person).lastContact,
            quickFacts: Self.quickFacts(from: (try? services.persons.observations(for: person)) ?? [])
        )
        personDetailCache[personID] = detail
        return detail
    }

    private func colorName(of personID: UUID?) -> String? { detail(of: personID)?.colorName }
    private func roleLine(of personID: UUID?) -> String? { detail(of: personID)?.roleLine }
    private func lastContact(of personID: UUID?) -> ContactMoment? { detail(of: personID)?.lastContact }
    private func quickFacts(of personID: UUID?) -> [String] { detail(of: personID)?.quickFacts ?? [] }

    /// The two or three facts worth having in mind before speaking to somebody.
    ///
    /// ### What is deliberately not here
    /// Anything marked sensitive or private, and health and private reflections regardless of how
    /// they were marked. A briefing surface is read in the seconds before a conversation and is the
    /// most likely screen in the app to be visible to somebody else in the room. The rule is not
    /// "hide what the user hid"; it is that a *summary* only ever carries what the user would say out
    /// loud, and the full record stays one click away on the person's own page where they went
    /// looking for it.
    static func quickFacts(from observations: [PersonObservationRecord], limit: Int = 3) -> [String] {
        let allowed: Set<FactAttribute> = [
            .significance, .conversationTopic, .quickFact, .lifeEvent, .lookingFor, .interest,
        ]

        return observations
            .compactMap { record -> (attribute: FactAttribute, value: String, observedOn: Date)? in
                guard record.supersededOn == nil else { return nil }
                guard record.sensitivity == .normal else { return nil }
                guard allowed.contains(record.attribute) else { return nil }
                let value = record.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return (record.attribute, value, record.observedOn)
            }
            // Newest first: what changed most recently is what the reader is least likely to know.
            .sorted { $0.observedOn > $1.observedOn }
            .prefix(limit)
            .map(\.value)
    }

    // MARK: - Matching an address book to an invitation

    /// A name-and-address index over the library's people, built once per assembly.
    private struct PersonIndex {
        var byEmail: [String: Item] = [:]

        /// Folded name to every person with that name. A name matching two people resolves to
        /// neither — see ``participants(of:linkedPersonIDs:)``.
        var byName: [String: [Item]] = [:]

        func match(name: String, email: String?) -> Item? {
            if let email {
                let normalized = ContactDetailRecognizer.normalizedEmail(email)
                if !normalized.isEmpty, let person = byEmail[normalized] { return person }
            }
            let folded = TextNormalizer.foldedForMatching(name)
            guard !folded.isEmpty, let candidates = byName[folded], candidates.count == 1 else {
                return nil
            }
            return candidates[0]
        }
    }

    private var cachedPersonIndex: PersonIndex?

    private func personIndex() -> PersonIndex {
        if let cachedPersonIndex { return cachedPersonIndex }

        var index = PersonIndex()
        for person in (try? services.persons.allPeople(includingPlaceholders: false)) ?? [] {
            let folded = TextNormalizer.foldedForMatching(person.displayTitle)
            if !folded.isEmpty { index.byName[folded, default: []].append(person) }

            for email in person.personProfile?.emails ?? [] {
                let normalized = ContactDetailRecognizer.normalizedEmail(email.value)
                guard !normalized.isEmpty, index.byEmail[normalized] == nil else { continue }
                index.byEmail[normalized] = person
            }
        }

        cachedPersonIndex = index
        return index
    }

    /// Throws away the per-assembly caches.
    ///
    /// Called by the page before a reload. The caches exist to stop one assembly reading the same
    /// person four times; carrying them across a reload would mean an edit to somebody's role never
    /// appearing.
    /// Drops anything that is no longer true of the library.
    ///
    /// ### Why this is a stamp and not a clear
    /// It was a clear, called at the start of every assembly so that an edit to somebody's role
    /// could not be missed. That is the right instinct and the wrong mechanism: it also threw the
    /// person index away when nothing about people had changed, so re-ticking a filter re-read every
    /// person in the library to draw the same cards.
    ///
    /// ``AppServices/changeToken`` already says *something in the library changed*, which is exactly
    /// the question being asked. Stamping the caches with it keeps the guarantee — an edit is never
    /// missed, because any write moves the counter — and makes the case where nothing was written
    /// free.
    public func invalidateCaches() {
        guard personCacheToken != services.changeToken else { return }
        personCacheToken = services.changeToken
        personDetailCache = [:]
        personItems = [:]
        cachedPersonIndex = nil
    }

    private var personCacheToken: Int?

    /// Forgets everything, including the library pass. For a test that wants a cold read.
    public func invalidateEverything() {
        personCacheToken = nil
        personDetailCache = [:]
        personItems = [:]
        cachedPersonIndex = nil
        cachedSources = nil
    }

    // MARK: - The briefing

    private func briefing(
        on day: Date,
        isToday: Bool,
        events: [DayEvent],
        tasks: DayTaskContext,
        celebrations: [UpcomingCelebration],
        people: [DayPerson],
        now: Date
    ) -> DayBriefing {
        let meetings = events.filter { $0.kind.countsAsMeeting && !$0.event.isCancelled }
        let others = events.filter { !$0.kind.countsAsMeeting && !$0.event.isCancelled }

        let overdue = tasks.tasks.count {
            if case .overdue = $0.primaryReason { return true } else { return false }
        }

        let focus = FocusTimeRules.focusTime(
            on: day,
            events: events.map(\.event),
            // The active calendar set's own hours, so the briefing and the time grid cannot disagree
            // about when the working day ends.
            workingHours: services.calendar.activeSet?.workingHours ?? .standard,
            now: now,
            calendar: calendar
        )

        let followUps = people.count { person in
            person.reasons.contains { if case .followUpDue = $0 { return true } else { return false } }
        }

        return DayBriefing(
            date: day,
            isToday: isToday,
            overdueCount: overdue,
            taskCount: tasks.tasks.count - overdue,
            completedTaskCount: tasks.completedIDs.count,
            meetingCount: meetings.count,
            otherEventCount: others.count,
            focus: focus,
            next: isToday ? nextCommitment(events: events, tasks: tasks, now: now) : firstCommitment(events: events),
            celebrations: celebrations,
            followUpCount: followUps
        )
    }

    /// The next thing with a time on it, including one already under way.
    private func nextCommitment(events: [DayEvent], tasks: DayTaskContext, now: Date) -> NextCommitment? {
        var candidates: [NextCommitment] = []

        for event in events where !event.event.isCancelled {
            guard !event.event.occupiesAllDayRow(calendar: calendar) else { continue }
            if event.isInProgress(at: now) {
                candidates.append(
                    NextCommitment(
                        subject: .event(id: event.id, kind: event.kind),
                        title: event.event.displayTitle,
                        startAt: event.event.startAt,
                        isInProgress: true
                    )
                )
            } else if event.event.startAt > now {
                candidates.append(
                    NextCommitment(
                        subject: .event(id: event.id, kind: event.kind),
                        title: event.event.displayTitle,
                        startAt: event.event.startAt
                    )
                )
            }
        }

        for task in tasks.tasks {
            guard let pinnedAt = task.pinnedAt, pinnedAt > now else { continue }
            candidates.append(
                NextCommitment(
                    subject: .task(id: task.taskID),
                    title: tasks.titles[task.taskID] ?? "Reminder",
                    startAt: pinnedAt
                )
            )
        }

        // Something happening now outranks something happening later, whatever the clock says.
        return candidates.sorted { left, right in
            if left.isInProgress != right.isInProgress { return left.isInProgress }
            return left.startAt < right.startAt
        }.first
    }

    /// The first thing on a day that is not today, where "next" has no meaning.
    private func firstCommitment(events: [DayEvent]) -> NextCommitment? {
        events
            .filter { !$0.event.isCancelled && !$0.event.occupiesAllDayRow(calendar: calendar) }
            .min { $0.event.startAt < $1.event.startAt }
            .map { event in
                NextCommitment(
                    subject: .event(id: event.id, kind: event.kind),
                    title: event.event.displayTitle,
                    startAt: event.event.startAt
                )
            }
    }
}
