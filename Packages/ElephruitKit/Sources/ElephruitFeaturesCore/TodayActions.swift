#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Everything Today can do to what it is showing.
///
/// ### Why the actions are here and not in the rows
/// Because the same action is offered from three places — a row's context menu, a hover control, and
/// a keyboard shortcut — and each was going to grow its own copy of "complete the task, tell the
/// index, refresh the page". Three copies is three chances to forget the third line, and forgetting
/// it is the class of bug where a task is ticked off and stays on screen until you navigate away.
///
/// Every method here goes through the services that already own the rule. Nothing writes to the
/// store directly, nothing invents a second way to complete a task, and every mutation ends by
/// announcing the change so that the search index, the sidebar counts and this page all hear about
/// it once.
@MainActor
public struct TodayActions {
    let services: AppServices
    let navigation: NavigationModel
    public let model: TodayModel

    public init(services: AppServices, navigation: NavigationModel, model: TodayModel) {
        self.services = services
        self.navigation = navigation
        self.model = model
    }

    private var clock: any DateProvider { services.dateProvider }

    // MARK: - Tasks

    public func toggleCompletion(_ task: Item) {
        act(on: task) { services in
            if task.status == .completed {
                try services.reminderLifecycle.reopen(task)
            } else {
                _ = try services.reminderLifecycle.complete(task)
            }
        }
    }

    public func setFlagged(_ isFlagged: Bool, on task: Item) {
        act(on: task) { try $0.reminderLifecycle.setFlagged(isFlagged, on: task) }
    }

    public func setPriority(_ priority: Priority, on task: Item) {
        act(on: task) { try $0.reminderLifecycle.setPriority(priority, on: task) }
    }

    /// Moves a task to a day.
    ///
    /// ### Why this sets a commitment rather than a start date
    /// Because "do this on Thursday" is a plan and a start date is an availability rule, and the
    /// scheduling model here keeps them apart on purpose — see ``TaskFacts``. Rescheduling from a
    /// day's plan is the user saying which day they intend to do it, so it writes the commitment.
    /// A start date is still reachable from the task's own editor, where the distinction is
    /// explained rather than implied.
    public func reschedule(_ task: Item, to day: Date?) {
        act(on: task) { services in
            guard let day else {
                try services.reminderLifecycle.removeFromToday(task)
                return
            }
            try services.reminderLifecycle.commit(task, to: day)
        }
    }

    public func moveToLaterToday(_ task: Item) {
        act(on: task) { try $0.reminderLifecycle.moveToLaterToday(task) }
    }

    /// Opens the calendar popover for one task — the route to an arbitrary day.
    public func beginPickingDate(for task: Item) {
        model.datePickerTaskID = task.id
    }

    public func setDeadline(_ date: Date?, on task: Item) {
        act(on: task) { try $0.reminderLifecycle.setDeadline(date, on: task) }
    }

    public func file(_ task: Item, under container: Item?) {
        act(on: task) { services in
            try services.items.update(task) { $0.parent = container }
        }
    }

    public func startTimer(on task: Item) {
        services.timer.switchTo(item: task)
    }

    /// Sends a task to the Trash, undoably — the canonical deletion every list already offers,
    /// which Today alone did not: a task could be completed, rescheduled, reprioritised and
    /// flagged from the day it was planned on, but never deleted from there.
    public func moveToTrash(_ task: Item) {
        services.perform { try services.undo.moveToTrash([task]) }
        services.refreshDerivedState()
        services.noteRemoval(of: task.id)
    }

    /// Removes a Reminders-linked task, here alone or in both places. Mirrors the task list's
    /// two-command pattern — see `TaskRowMenu` for why this is never a dialog.
    public func deleteLinked(_ task: Item, choice: LinkedDeletionChoice) {
        Task {
            _ = await services.reminderSync.delete(task, choice: choice)
            services.noteRemoval(of: task.id)
        }
    }

    /// Opens the record itself, in the inspector beside the day.
    ///
    /// Selecting rather than navigating: leaving Today to read one task's fields is a round trip out
    /// of the page somebody is planning in, and the inspector is the right size for a task anyway.
    public func select(_ id: UUID) {
        navigation.selectItem(id)
        navigation.isInspectorVisible = true
    }

    /// Opens the record in the module that owns it, for when the inspector is not enough.
    public func openInModule(_ item: Item) {
        switch item.kind {
        case .task, .reminder:
            navigation.select(.reminders)
        case .person:
            navigation.select(.records(.people))
        default:
            navigation.select(.kind(item.kind))
        }
        navigation.selectItem(item.id)
    }

    /// Creates a task on a given day, reading the same grammar every capture surface reads.
    ///
    /// The day is inherited from where it was typed, which is the whole point of a field that lives
    /// inside a day rather than in a sheet: a task added while looking at Thursday is Thursday's,
    /// and nobody has to go and find it again to say so.
    ///
    /// ### One grammar, at last
    /// This field was title-only while Quick Jot and the Reminders composer both read
    /// `>project @person #tag !friday` — the third capture surface with the third capability set.
    /// It parses now, with one addition to the rule: a date the grammar names wins over the day
    /// being looked at, because typing `!friday` *is* choosing a day.
    @discardableResult
    public func createTask(titled title: String, on day: Date, under container: Item? = nil) -> Item? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let vocabulary = (try? services.capture.vocabulary()) ?? .empty
        var composition = QuickJotComposition()
        composition.titleText = trimmed
        _ = composition.flush(knowing: vocabulary)

        var draft = composition.captured(knowing: vocabulary)
        guard !draft.isEmpty else { return nil }
        draft.kind = .reminder
        let grammarChoseADay = draft.dueDate != nil || draft.followDate != nil

        var created: Item?
        services.perform {
            guard let task = try services.captureDraft(draft) else { return }
            if let container, task.parent == nil {
                try services.items.setParent(task, to: container)
            }
            if !grammarChoseADay {
                try services.reminderLifecycle.commit(task, to: day)
            }
            services.noteChange(to: task)
            created = task
        }
        return created
    }

    /// Creates a reminder that interrupts at a particular time of day.
    ///
    /// The third thing a gap in the day can become, after work moved into it and a block defending
    /// it: something to be reminded of *then*. It writes a reminder and nothing on the calendar,
    /// because "nudge me at two" is not an appointment and drawing it as one is how an agenda starts
    /// lying about how full a day is.
    @discardableResult
    public func createTask(titled title: String, remindingAt moment: Date) -> Item? {
        guard let task = createTask(titled: title, on: clock.calendar.startOfDay(for: moment))
        else { return nil }

        act(on: task) { services in
            try services.reminderLifecycle.setReminder(moment, timed: true, on: task)
        }
        return task
    }

    // MARK: - Meetings

    /// The link to join, if the organiser left one anywhere findable.
    public func joinLink(for event: DayEvent) -> URL? {
        MeetingLink.url(in: event.event)
    }

    public func join(_ event: DayEvent) {
        guard let url = joinLink(for: event) else { return }
        Self.openExternally(url)
    }

    /// Shows the event in the calendar, on its own day.
    public func openInCalendar(_ event: DayEvent) {
        navigation.requestedCalendarDay = event.event.startAt
        navigation.select(.calendar)
    }

    /// Opens the calendar on a day so the user can draw a block on it.
    ///
    /// Deliberately not "create a two-hour focus block at ten": where the block goes depends on what
    /// else is on the day and on what the person is trying to protect, and an app that guesses both
    /// has written an appointment somebody now has to delete.
    public func openInCalendarForFocus(on day: Date) {
        navigation.requestedCalendarDay = day
        navigation.select(.calendar)
        navigation.isCalendarQuickEntryVisible = true
    }

    /// Opens the meeting's notes, creating the meeting record on first use.
    ///
    /// Created lazily and only here, which is the rule ``EventAnnotationService`` already keeps: a
    /// year of somebody's calendar is thousands of events, and writing a record for each so that
    /// eleven can have notes would make the store larger than the library.
    public func openNotes(for event: DayEvent) {
        services.perform {
            guard let meeting = try services.eventLinks.meetingItem(for: event.event) else { return }
            services.noteChange(to: meeting)
            select(meeting.id)
        }
    }

    /// Adds something to do before the meeting, linked to it.
    public func addPreparationTask(titled title: String, for event: DayEvent) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.eventLinks.createFollowUp(
                title: trimmed,
                dueAt: nil,
                for: event.event,
                aboutPeople: event.participants.compactMap { model.person($0.personID) }
            )
            // Committed to the meeting's own day, so preparation for Thursday's review appears on
            // Thursday rather than in a pile with no date on it.
            try services.reminderLifecycle.commit(task, to: clock.calendar.startOfDay(for: event.event.startAt))
            services.noteChange(to: task)
        }
    }

    /// Records something that came out of the meeting, due tomorrow unless changed.
    public func logFollowUp(titled title: String, for event: DayEvent) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.eventLinks.createFollowUp(
                title: trimmed,
                dueAt: nil,
                for: event.event,
                aboutPeople: event.participants.compactMap { model.person($0.personID) }
            )
            try services.reminderLifecycle.commit(task, to: clock.startOfTomorrow)
            services.noteChange(to: task)
        }
    }

    public func markPreparationComplete(for event: DayEvent) {
        services.perform {
            for id in event.preparation.openPreparationTaskIDs {
                guard let task = model.task(id) else { continue }
                _ = try services.reminderLifecycle.complete(task)
                services.noteChange(to: task)
            }
        }
    }

    // MARK: - Blocking time

    /// The day's unscheduled work, ranked for one gap.
    ///
    /// Only what has no time of its own: a task already pinned to half past three has been given a
    /// place in the day, and offering to give it a second one is offering to double-book somebody
    /// against themselves.
    public func work(for slot: DayFreeSlot, in plan: DayPlan) -> [TimeBlockCandidate] {
        let unscheduled = model.openTasks(in: plan).filter { $0.day.pinnedAt == nil }
        return TimeBlockRules.candidates(
            in: slot,
            from: unscheduled.map { entry in
                TimeBlockCandidate(
                    id: entry.item.id,
                    title: entry.item.displayTitle,
                    estimateMinutes: entry.item.estimateMinutes
                )
            }
        )
    }

    /// What the app would write, before it writes anything.
    ///
    /// Every part of this is shown and changeable in the sheet: the calendar it lands on, whether it
    /// defends the time, how long it lasts. Nothing here is a silent guess — see ``TimeBlockRules``
    /// for how the length is arrived at, and why an estimate never outgrows the gap it is going into.
    ///
    /// Returns `nil` when there is no calendar that can be written to at all, which is a state the
    /// interface has to explain rather than a failure to report after the fact.
    ///
    /// - Parameters:
    ///   - task: The work the block is for. `nil` is a plain focus block.
    ///   - slot: The gap it is going into, when the user chose one. Without it the day's own free
    ///     time is consulted, and failing that a sensible hour is proposed and shown.
    public func proposal(
        blocking task: Item?,
        in slot: DayFreeSlot?,
        on plan: DayPlan
    ) -> TimeBlockProposal? {
        guard let calendarIdentifier = services.calendar.defaultCalendarIdentifier else { return nil }

        let estimate = task?.estimateMinutes
        let chosen = slot ?? TimeBlockRules.slot(forEstimate: estimate, among: plan.briefing.focus.slots)

        let start: Date
        var room = chosen
        if let chosen {
            start = TimeBlockRules.start(in: chosen, calendar: clock.calendar)
            // The gap as it is *from the start actually proposed*, so a rounded start cannot produce
            // a block that runs past the meeting the gap ends at.
            if start > chosen.range.lowerBound, start < chosen.range.upperBound {
                room = DayFreeSlot(range: start..<chosen.range.upperBound, isCurrent: chosen.isCurrent)
            }
        } else {
            start = defaultStart(on: plan)
        }

        return TimeBlockProposal(
            taskID: task?.id,
            title: task?.displayTitle ?? "Focus",
            startAt: start,
            length: TimeBlockRules.length(forEstimate: estimate, in: room),
            calendarIdentifier: calendarIdentifier
        )
    }

    /// What to write to get to something on the day, before writing it.
    ///
    /// A block that ends where the meeting starts, named after the place rather than the meeting —
    /// see ``TravelRules/blockTitle(to:)`` for why the two are not the same choice. The length is
    /// the user's own answer for that place and nothing else; nothing here consults a map, a network
    /// or a location.
    public func proposal(travellingTo event: DayEvent, minutes: Int) -> TimeBlockProposal? {
        guard let calendarIdentifier = services.calendar.defaultCalendarIdentifier,
              let location = event.event.locationName,
              TravelRules.isJourney(to: event.event)
        else { return nil }

        return TimeBlockProposal(
            title: TravelRules.blockTitle(to: location),
            startAt: TravelRules.leaveBy(event.event, minutes: minutes),
            length: TimeInterval(max(1, minutes) * 60),
            calendarIdentifier: calendarIdentifier
        )
    }

    /// Writes the block, and remembers locally what it was for.
    ///
    /// The link back to the task is the second half of this and not an optional extra: without it a
    /// block is an event called "Draft the brief" with no relationship to the brief, and every
    /// surface that could show one beside the other has nothing to go on. It is written through
    /// ``EventAnnotationService``, on this device, and the calendar account never learns of it.
    ///
    /// A failed link does not fail the write. The event exists by then, and reporting "could not
    /// save" for something that was saved is the worse of the two wrong answers.
    @discardableResult
    public func write(_ proposal: TimeBlockProposal) async -> Result<CalendarEventSummary, CalendarWriteFailure> {
        let outcome = await services.calendar.create(
            proposal.draft(timeZoneIdentifier: clock.calendar.timeZone.identifier)
        )

        if case .success(let event) = outcome, let id = proposal.taskID, let task = model.task(id) {
            services.perform {
                try services.eventLinks.link(task: task, to: event)
                services.noteChange(to: task)
            }
        }
        return outcome
    }

    /// Takes back a block just written.
    ///
    /// ### Why undo is part of the feature rather than a later refinement
    /// Because the fastest way to make somebody distrust a button that writes to their calendar is
    /// for the first thing it writes to be wrong and hard to remove. The confirmation says what was
    /// written and offers this in the same breath.
    @discardableResult
    public func removeBlock(_ event: CalendarEventSummary) async -> Result<Void, CalendarWriteFailure> {
        await services.calendar.delete(event.identity, scope: .thisEvent)
    }

    /// When to propose a block on a day with no free time left in it.
    ///
    /// Today gets the next quarter hour, which is the soonest anybody can act on. Another day gets
    /// the hour their working day starts, because there is no "now" on a day that has not happened
    /// and the start of the day is the only honest default.
    private func defaultStart(on plan: DayPlan) -> Date {
        guard !plan.isToday else {
            return TimeBlockRules.nextRoundStart(after: clock.now, calendar: clock.calendar)
        }
        let minutes = services.workday.hours.startMinutes
        let midnight = clock.calendar.startOfDay(for: plan.date)
        return clock.calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
    }

    // MARK: - People

    /// Ways to reach somebody, in the order their own record makes sensible.
    ///
    /// Reads the profile that is already loaded rather than assembling a workspace context: a card
    /// on a busy day may be one of a dozen, and building each one's full portrait to decide whether
    /// to draw a Call button is work nobody asked for.
    public func contactActions(for person: Item) -> [ContactActionPreview] {
        let destinations = person.personProfile?.destinations() ?? []
        guard !destinations.isEmpty else { return [] }

        return ContactChannel.allCases.compactMap { channel in
            guard let destination = ContactDestinationPolicy.automatic(for: channel, from: destinations)
            else { return nil }
            return ContactActionPreview(
                channel: channel,
                personName: person.displayTitle,
                destination: destination,
                url: ContactActionURL.url(for: channel, destination: destination.value)
            )
        }
    }

    /// Opens the channel and records that it happened.
    ///
    /// ### Why the interaction is written
    /// Because "when did we last speak" is a core question for a human record, and
    /// it is answered from recorded contact rather than from mentions. A call placed from this page
    /// that leaves no trace makes the follow-up suggestions quietly wrong for the person you just
    /// rang, which is the worst possible person for them to be wrong about.
    public func contact(_ preview: ContactActionPreview, person: Item) {
        guard let url = preview.url else { return }
        Self.openExternally(url)

        services.perform {
            try services.people.recordInteraction(
                with: person,
                summary: "\(preview.channel.displayName) — \(person.displayTitle)"
            )
            services.noteChange(to: person)
        }
    }

    public func logInteraction(with person: Item, summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let interaction = try services.people.recordInteraction(with: person, summary: trimmed)
            services.noteChange(to: interaction)
            services.noteChange(to: person)
        }
    }

    /// Creates a task about somebody, on the day being looked at.
    public func createFollowUp(titled title: String, about person: Item, on day: Date) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.items.create(ItemDraft(kind: .reminder, title: trimmed))
            try services.items.link(task, to: person, kind: .mentions)
            try services.reminderLifecycle.commit(task, to: day)
            services.noteChange(to: task)
        }
    }

    // MARK: - The day's note

    /// Opens the day's note, creating it only if asked.
    ///
    /// Never created automatically. An app that writes a note every morning fills a library with
    /// empty days, and the emptiness is indistinguishable from a day somebody chose not to write
    /// about.
    public func openDailyNote(for day: Date, creatingIfNeeded: Bool) {
        services.perform {
            guard let entry = try services.people.dailyEntry(for: day, creatingIfNeeded: creatingIfNeeded)
            else { return }
            if creatingIfNeeded { services.noteChange(to: entry) }
            select(entry.id)
        }
    }

    /// Adds a line to the day's note without leaving the page.
    public func appendToDailyNote(_ text: String, on day: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            guard let entry = try services.people.dailyEntry(for: day, creatingIfNeeded: true) else { return }
            try services.items.update(entry) { item in
                item.body = item.body.isEmpty ? trimmed : item.body + "\n" + trimmed
            }
            services.noteChange(to: entry)
        }
    }

    // MARK: - Plumbing

    /// Runs a mutation and tells everything that has to hear about it.
    ///
    /// One helper rather than three lines at every call site, because the third line — announcing
    /// the change — is the one that gets left out, and leaving it out means the row stays on screen
    /// after being ticked off.
    private func act(on item: Item, _ work: (AppServices) throws -> Void) {
        services.perform {
            try work(services)
            services.noteChange(to: item)
        }
    }

    /// Hands a URL to the system, whichever system this is.
    ///
    /// The behavioural contract is the one `ContactActionURL` documents: the app composes and
    /// hands off, and the user presses send in their own chosen app.
    private static func openExternally(_ url: URL) {
        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
            UIApplication.shared.open(url)
        #endif
    }
}
