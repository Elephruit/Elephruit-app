import AppKit
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
struct TodayActions {
    let services: AppServices
    let navigation: NavigationModel
    let model: TodayModel

    private var clock: any DateProvider { services.dateProvider }

    // MARK: - Tasks

    func toggleCompletion(_ task: Item) {
        act(on: task) { services in
            if task.status == .completed {
                try services.tasks.reopen(task)
            } else {
                _ = try services.tasks.complete(task)
            }
        }
    }

    func setFlagged(_ isFlagged: Bool, on task: Item) {
        act(on: task) { try $0.tasks.setFlagged(isFlagged, on: task) }
    }

    func setPriority(_ priority: Priority, on task: Item) {
        act(on: task) { try $0.tasks.setPriority(priority, on: task) }
    }

    /// Moves a task to a day.
    ///
    /// ### Why this sets a commitment rather than a start date
    /// Because "do this on Thursday" is a plan and a start date is an availability rule, and the
    /// scheduling model here keeps them apart on purpose — see ``TaskFacts``. Rescheduling from a
    /// day's plan is the user saying which day they intend to do it, so it writes the commitment.
    /// A start date is still reachable from the task's own editor, where the distinction is
    /// explained rather than implied.
    func reschedule(_ task: Item, to day: Date?) {
        act(on: task) { services in
            guard let day else {
                try services.tasks.removeFromToday(task)
                return
            }
            try services.tasks.commit(task, to: day)
        }
    }

    func moveToLaterToday(_ task: Item) {
        act(on: task) { try $0.tasks.moveToLaterToday(task) }
    }

    func setDeadline(_ date: Date?, on task: Item) {
        act(on: task) { try $0.tasks.setDeadline(date, on: task) }
    }

    func file(_ task: Item, under container: Item?) {
        act(on: task) { services in
            try services.items.update(task) { $0.parent = container }
        }
    }

    func startTimer(on task: Item) {
        services.timer.switchTo(item: task)
    }

    /// Opens the record itself, in the inspector beside the day.
    ///
    /// Selecting rather than navigating: leaving Today to read one task's fields is a round trip out
    /// of the page somebody is planning in, and the inspector is the right size for a task anyway.
    func select(_ id: UUID) {
        navigation.selectItem(id)
        navigation.isInspectorVisible = true
    }

    /// Opens the record in the module that owns it, for when the inspector is not enough.
    func openInModule(_ item: Item) {
        switch item.kind {
        case .task:
            navigation.select(.taskView(.today))
        case .person:
            navigation.select(.people(.all))
        default:
            navigation.select(.kind(item.kind))
        }
        navigation.selectItem(item.id)
    }

    /// Creates a task on a given day.
    ///
    /// The day is inherited from where it was typed, which is the whole point of a field that lives
    /// inside a day rather than in a sheet: a task added while looking at Thursday is Thursday's,
    /// and nobody has to go and find it again to say so.
    @discardableResult
    func createTask(titled title: String, on day: Date, under container: Item? = nil) -> Item? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var created: Item?
        services.perform {
            var draft = ItemDraft(kind: .task, title: trimmed)
            draft.parentID = container?.id
            let task = try services.items.create(draft)
            try services.tasks.commit(task, to: day)
            services.noteChange(to: task)
            created = task
        }
        return created
    }

    // MARK: - Meetings

    /// The link to join, if the organiser left one anywhere findable.
    func joinLink(for event: DayEvent) -> URL? {
        MeetingLink.url(in: event.event)
    }

    func join(_ event: DayEvent) {
        guard let url = joinLink(for: event) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shows the event in the calendar, on its own day.
    func openInCalendar(_ event: DayEvent) {
        navigation.requestedCalendarDay = event.event.startAt
        navigation.select(.calendar)
    }

    /// Opens the calendar on a day so the user can draw a block on it.
    ///
    /// Deliberately not "create a two-hour focus block at ten": where the block goes depends on what
    /// else is on the day and on what the person is trying to protect, and an app that guesses both
    /// has written an appointment somebody now has to delete.
    func openInCalendarForFocus(on day: Date) {
        navigation.requestedCalendarDay = day
        navigation.select(.calendar)
        navigation.isCalendarQuickEntryVisible = true
    }

    /// Opens the meeting's notes, creating the meeting record on first use.
    ///
    /// Created lazily and only here, which is the rule ``EventAnnotationService`` already keeps: a
    /// year of somebody's calendar is thousands of events, and writing a record for each so that
    /// eleven can have notes would make the store larger than the library.
    func openNotes(for event: DayEvent) {
        services.perform {
            guard let meeting = try services.eventLinks.meetingItem(for: event.event) else { return }
            services.noteChange(to: meeting)
            select(meeting.id)
        }
    }

    /// Adds something to do before the meeting, linked to it.
    func addPreparationTask(titled title: String, for event: DayEvent) {
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
            try services.tasks.commit(task, to: clock.calendar.startOfDay(for: event.event.startAt))
            services.noteChange(to: task)
        }
    }

    /// Records something that came out of the meeting, due tomorrow unless changed.
    func logFollowUp(titled title: String, for event: DayEvent) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.eventLinks.createFollowUp(
                title: trimmed,
                dueAt: nil,
                for: event.event,
                aboutPeople: event.participants.compactMap { model.person($0.personID) }
            )
            try services.tasks.commit(task, to: clock.startOfTomorrow)
            services.noteChange(to: task)
        }
    }

    func markPreparationComplete(for event: DayEvent) {
        services.perform {
            for id in event.preparation.openPreparationTaskIDs {
                guard let task = model.task(id) else { continue }
                _ = try services.tasks.complete(task)
                services.noteChange(to: task)
            }
        }
    }

    // MARK: - People

    /// Ways to reach somebody, in the order their own record makes sensible.
    ///
    /// Reads the profile that is already loaded rather than assembling a workspace context: a card
    /// on a busy day may be one of a dozen, and building each one's full portrait to decide whether
    /// to draw a Call button is work nobody asked for.
    func contactActions(for person: Item) -> [ContactActionPreview] {
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
    /// Because "when did we last speak" is the question the whole People module is built around, and
    /// it is answered from recorded contact rather than from mentions. A call placed from this page
    /// that leaves no trace makes the follow-up suggestions quietly wrong for the person you just
    /// rang, which is the worst possible person for them to be wrong about.
    func contact(_ preview: ContactActionPreview, person: Item) {
        guard let url = preview.url else { return }
        NSWorkspace.shared.open(url)

        services.perform {
            try services.people.recordInteraction(
                with: person,
                summary: "\(preview.channel.displayName) — \(person.displayTitle)"
            )
            services.noteChange(to: person)
        }
    }

    func logInteraction(with person: Item, summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let interaction = try services.people.recordInteraction(with: person, summary: trimmed)
            services.noteChange(to: interaction)
            services.noteChange(to: person)
        }
    }

    /// Creates a task about somebody, on the day being looked at.
    func createFollowUp(titled title: String, about person: Item, on day: Date) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        services.perform {
            let task = try services.items.create(ItemDraft(kind: .task, title: trimmed))
            try services.items.link(task, to: person, kind: .mentions)
            try services.tasks.commit(task, to: day)
            services.noteChange(to: task)
        }
    }

    // MARK: - The day's note

    /// Opens the day's note, creating it only if asked.
    ///
    /// Never created automatically. An app that writes a note every morning fills a library with
    /// empty days, and the emptiness is indistinguishable from a day somebody chose not to write
    /// about.
    func openDailyNote(for day: Date, creatingIfNeeded: Bool) {
        services.perform {
            guard let entry = try services.people.dailyEntry(for: day, creatingIfNeeded: creatingIfNeeded)
            else { return }
            if creatingIfNeeded { services.noteChange(to: entry) }
            select(entry.id)
        }
    }

    /// Adds a line to the day's note without leaving the page.
    func appendToDailyNote(_ text: String, on day: Date) {
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
}
