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
/// The same split ``TaskViewService`` established, for the same reason: none of the relevance rules
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

    // MARK: - Assembling a day

    /// Everything one date holds.
    ///
    /// Throws only what the store throws. A missing calendar, a person with no profile, or a day
    /// with nothing in it are all ordinary and produce an ordinary, empty-ish plan.
    public func plan(for date: Date, filters: TodayFilters = .standard) throws(AppError) -> DayPlan {
        let day = calendar.startOfDay(for: date)
        let now = clock.now
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)

        let events = filters.showsMeetings ? dayEvents(on: day, filters: filters) : []
        let meetingTaskIDs = meetingPrepIndex(for: events)

        let taskContext = filters.showsTasks
            ? try dayTasks(on: day, now: now, isToday: isToday, meetingTaskIDs: meetingTaskIDs, filters: filters)
            : DayTaskContext()

        let celebrations = try celebrations(on: day, isToday: isToday)

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
        if filters.showsDailyNote, let entry = try services.people.dailyEntry(for: day, creatingIfNeeded: false) {
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
        var plans: [DayPlan] = []
        var cursor = calendar.startOfDay(for: first)
        for _ in 0..<max(0, count) {
            plans.append(try plan(for: cursor, filters: filters))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return plans
    }

    // MARK: - Events

    private func dayEvents(on day: Date, filters: TodayFilters) -> [DayEvent] {
        guard services.calendar.isEnabled else { return [] }

        let raw = services.calendar.events(on: day).filter { event in
            guard DayEventRules.appearsInPlan(event) else { return false }
            guard let identifier = event.calendarIdentifier else { return true }
            return !filters.hiddenCalendarIdentifiers.contains(identifier)
        }
        guard !raw.isEmpty else { return [] }

        let clashes = DayEventRules.conflicts(among: raw, calendar: calendar)
        let identities = raw.map(\.identity)
        let preparation = (try? services.eventLinks.preparation(for: identities)) ?? [:]
        let annotations = (try? services.eventLinks.annotations(for: identities)) ?? [:]

        return raw
            .map { event in
                let kind = DayEventRules.kind(of: event)
                return DayEvent(
                    event: event,
                    kind: kind,
                    conflictingEventIDs: clashes[event.id] ?? [],
                    participants: kind.hasAttendees
                        ? participants(
                            of: event,
                            linkedPersonIDs: annotations[event.identity.storageKey]?.personIDs ?? []
                        )
                        : [],
                    preparation: preparation[event.identity.storageKey] ?? MeetingPreparation()
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

    /// Which tasks belong to which meeting, so a preparation task can say what it is for.
    private func meetingPrepIndex(for events: [DayEvent]) -> [UUID: (id: String, title: String)] {
        var index: [UUID: (id: String, title: String)] = [:]
        for event in events {
            for taskID in event.preparation.openPreparationTaskIDs {
                index[taskID] = (id: event.id, title: event.event.displayTitle)
            }
        }
        return index
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
        meetingTaskIDs: [UUID: (id: String, title: String)],
        filters: TodayFilters
    ) throws(AppError) -> DayTaskContext {
        var query = ItemQuery()
        query.kinds = [.task]
        query.statuses = [.open]
        query.sort = .manual
        let open = try services.items.items(matching: query)

        var context = DayTaskContext()

        for task in open {
            let facts = task.taskFacts()
            guard !isHidden(facts, by: filters) else { continue }

            let reasons = DayTaskRules.reasons(
                for: facts,
                on: day,
                now: now,
                calendar: calendar,
                meetingTaskIDs: meetingTaskIDs
            )
            guard !reasons.isEmpty else { continue }

            context.tasks.append(
                DayTask(
                    taskID: facts.id,
                    reasons: named(reasons, for: facts),
                    pinnedAt: DayTaskRules.pinnedTime(for: facts, on: day, calendar: calendar)
                )
            )
            context.titles[facts.id] = task.displayTitle

            if let waitingOn = facts.waitingOnPersonID {
                context.relatedPeople.append(
                    (personID: waitingOn, taskID: facts.id, title: task.displayTitle, isWaiting: true)
                )
            }
            for personID in facts.relatedPersonIDs where personID != facts.waitingOnPersonID {
                context.relatedPeople.append(
                    (personID: personID, taskID: facts.id, title: task.displayTitle, isWaiting: false)
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

        context.completedIDs = try completedTasks(on: day, filters: filters)
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

    private func completedTasks(on day: Date, filters: TodayFilters) throws(AppError) -> [UUID] {
        var query = ItemQuery()
        query.kinds = [.task]
        query.statuses = [.completed, .cancelled]
        query.sort = .updatedNewestFirst
        // Bounded: a logbook of five thousand entries has nothing to say about today, and the rows
        // that do are the most recent ones by construction.
        query.limit = 200

        return try services.items.items(matching: query)
            .filter { task in
                let facts = task.taskFacts()
                guard !isHidden(facts, by: filters) else { return false }
                let resolvedAt = facts.completedAt ?? facts.cancelledAt
                guard let resolvedAt else { return false }
                return calendar.isDate(resolvedAt, inSameDayAs: day)
            }
            .map(\.id)
    }

    private func isHidden(_ facts: TaskFacts, by filters: TodayFilters) -> Bool {
        guard !filters.hiddenContainerIDs.isEmpty else { return false }
        for container in [facts.projectID, facts.listID, facts.areaID] {
            if let container, filters.hiddenContainerIDs.contains(container) { return true }
        }
        return false
    }

    // MARK: - Celebrations

    private func celebrations(on day: Date, isToday: Bool) throws(AppError) -> [UpcomingCelebration] {
        let all = try services.persons.allCelebrations()
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
    public func invalidateCaches() {
        personDetailCache = [:]
        cachedPersonIndex = nil
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
