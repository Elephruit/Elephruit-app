import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation

/// A believable task library, covering every state the module has to draw.
///
/// ### Why this is a checklist rather than a scattering of plausible rows
/// Every state in the scheduling model has a way of looking fine when it is broken. A start date
/// that has quietly become a deadline looks like a deadline; a Someday task that still counts looks
/// like a task; a linked reminder that has silently unlinked looks local. None of those is visible
/// unless the state exists on screen, so each one exists here **exactly once** and is named after
/// what it is for.
///
/// Reachable only from previews and development mode — sample data in a real library would be a
/// data-integrity bug, not a convenience.
@MainActor
enum TaskSampleData {
    static func populate(services: AppServices) throws(AppError) {
        let items = services.items
        let tasks = services.tasks
        let clock = services.dateProvider

        func day(_ offset: Int) -> Date { clock.startOfDay(daysFromToday: offset) }
        func at(_ offset: Int, hour: Int) -> Date {
            clock.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day(offset)) ?? day(offset)
        }

        // MARK: People, for the promises to attach to

        let maya = try items.create(ItemDraft(kind: .person, title: "Maya Okafor"))
        let jordan = try items.create(ItemDraft(kind: .person, title: "Jordan Reyes"))

        // MARK: Areas, projects, and a list

        let home = try items.create(ItemDraft(kind: .area, title: "Home"))
        try items.update(home) { $0.colorName = "teal" }

        let trip = try items.create(
            ItemDraft(
                kind: .project,
                title: "Two weeks in Lisbon",
                body: "Flights booked. Everything else is open.",
                parentID: home.id
            )
        )

        // A list rather than a project: nobody finishes Groceries.
        let groceries = try items.create(ItemDraft(kind: .list, title: "Groceries", parentID: home.id))

        // Sections inside the project.
        let beforeTheTrip = try items.create(
            ItemDraft(kind: .heading, title: "Before the trip", parentID: trip.id)
        )
        let packing = try items.create(ItemDraft(kind: .heading, title: "Packing", parentID: trip.id))

        // MARK: Inbox — captured, not yet filed

        try items.create(ItemDraft(kind: .reminder, title: "Look into the bike-repair place on Mill Lane"))
        try items.create(ItemDraft(kind: .reminder, title: "Ask about the noise from the flat upstairs"))

        // MARK: A planned Today, in the user's own order

        let brief = try items.create(
            ItemDraft(kind: .reminder, title: "Write the client brief", parentID: trip.id)
        )
        try tasks.commitToToday(brief)

        let callback = try items.create(ItemDraft(kind: .reminder, title: "Ring the dentist back"))
        try tasks.commitToToday(callback)

        // Later Today: deliberately pushed to the back half of the day.
        let evening = try items.create(ItemDraft(kind: .reminder, title: "Book the airport transfer", parentID: trip.id))
        try tasks.moveToLaterToday(evening)

        // The plan, in an order that is not the project's order.
        try tasks.reorderToday([callback, brief])

        // MARK: Overdue — a deadline that has passed, and nothing else

        let overdue = try items.create(ItemDraft(kind: .reminder, title: "Renew the parking permit"))
        try tasks.setDeadline(day(-3), on: overdue)

        // MARK: A future start date — not late, not asked about yet

        let futureStart = try items.create(
            ItemDraft(kind: .reminder, title: "Start the tax return", parentID: home.id)
        )
        try tasks.setStartDate(day(21), on: futureStart)

        // MARK: A hard deadline with no start date

        let deadlineOnly = try items.create(ItemDraft(kind: .reminder, title: "File the annual accounts"))
        try tasks.setDeadline(day(34), on: deadlineOnly)

        // MARK: A reminder that is not a deadline

        let reminder = try items.create(ItemDraft(kind: .reminder, title: "Move the car before the street sweeper"))
        try tasks.setReminder(at(1, hour: 7), timed: true, on: reminder)

        // MARK: The project's sections

        let visa = try items.create(
            ItemDraft(kind: .reminder, title: "Check whether a visa is needed", parentID: beforeTheTrip.id)
        )
        try tasks.setDeadline(day(9), on: visa)

        try items.create(ItemDraft(kind: .reminder, title: "Tell the bank about the travel dates", parentID: beforeTheTrip.id))

        // A task with steps: one action, several small parts.
        let suitcase = try items.create(ItemDraft(kind: .reminder, title: "Pack", parentID: packing.id))
        try tasks.setChecklist(
            TaskChecklist.parse("- passport\n- adapters\n- swimming things\n- [x] sun cream"),
            on: suitcase
        )

        // A task with real subtasks: each has its own dates and its own row everywhere.
        let insurance = try items.create(
            ItemDraft(kind: .reminder, title: "Sort the travel insurance", parentID: beforeTheTrip.id)
        )
        let quotes = try items.create(ItemDraft(kind: .reminder, title: "Get three quotes", parentID: insurance.id))
        try tasks.setDeadline(day(4), on: quotes)
        try items.create(ItemDraft(kind: .reminder, title: "Read what the excess actually covers", parentID: insurance.id))

        // MARK: The list, which never finishes

        for line in ["Oat milk", "Coffee", "Something for Sunday"] {
            try items.create(ItemDraft(kind: .reminder, title: line, parentID: groceries.id))
        }

        // MARK: Someday — parked, and in no count

        let piano = try items.create(ItemDraft(kind: .reminder, title: "Learn enough piano to be annoying"))
        try tasks.setSomeday(true, on: piano)

        // MARK: Waiting on a person, with a follow-up

        let budget = try items.create(ItemDraft(kind: .reminder, title: "Sign off the Q3 budget"))
        try tasks.markWaiting(budget, on: jordan, since: day(-6), followUp: day(2))

        // MARK: A promise made to somebody

        let promise = try items.create(ItemDraft(kind: .reminder, title: "Send Maya the reading list"))
        try tasks.markPromised(promise, to: maya)
        try tasks.setDeadline(day(5), on: promise)

        // MARK: Repeating, both anchors

        let timesheet = try items.create(ItemDraft(kind: .reminder, title: "Submit the timesheet"))
        try items.update(timesheet) { $0.recurrence = RecurrenceRule(frequency: .weekly, weekdays: [6]) }
        try tasks.setDeadline(day(4), on: timesheet)

        let plants = try items.create(ItemDraft(kind: .reminder, title: "Water the plants"))
        try items.update(plants) {
            $0.recurrence = RecurrenceRule(frequency: .daily, interval: 3, anchor: .completion)
        }
        try tasks.setStartDate(day(0), on: plants)

        // MARK: Flagged, without implying anything else

        let flagged = try items.create(ItemDraft(kind: .reminder, title: "Reread the contract clause about renewal"))
        try tasks.setFlagged(true, on: flagged)

        // MARK: A task made from a note, keeping its provenance

        let note = try items.create(
            ItemDraft(
                kind: .note,
                title: "Notes from the Tuesday call",
                body: "Jordan wants the revised numbers before the board pack goes out."
            )
        )
        let fromNote = try items.create(
            ItemDraft(
                kind: .reminder,
                title: "Revise the numbers for the board pack",
                source: ItemSource(kind: .manual, identifier: "note:\(note.id.uuidString)")
            )
        )
        try items.link(fromNote, to: note, kind: .related)
        try tasks.setDeadline(day(6), on: fromNote)

        // MARK: History — one finished, one deliberately abandoned

        let finished = try items.create(ItemDraft(kind: .reminder, title: "Book the flights", parentID: beforeTheTrip.id))
        try tasks.complete(finished)

        let abandoned = try items.create(ItemDraft(kind: .reminder, title: "Hire a car for the whole fortnight"))
        try tasks.cancel(abandoned)

        // MARK: The four Reminders states

        // Local-only: the default, and the private one.
        try items.create(ItemDraft(kind: .reminder, title: "Draft the birthday message"))

        try link(
            items: items,
            title: "Oat milk",
            externalID: "rem-milk",
            listID: "list-groceries",
            state: .linked,
            parentID: groceries.id,
            clock: clock
        )

        // A conflict awaiting a decision.
        try link(
            items: items,
            title: "Call the dentist",
            externalID: "rem-call",
            listID: "list-personal",
            state: .conflicted,
            parentID: nil,
            clock: clock
        )

        // On a shared list that refuses writes.
        try link(
            items: items,
            title: "Boiler service",
            externalID: "rem-boiler",
            listID: "list-shared",
            state: .externalReadOnly,
            parentID: home.id,
            clock: clock
        )

        // A reminder that has gone from the system store, with everything local intact.
        try link(
            items: items,
            title: "Return the library books",
            externalID: "rem-gone",
            listID: "list-personal",
            state: .externalMissing,
            parentID: nil,
            clock: clock
        )

        // MARK: A smart list the user built

        let smart = SavedSearch(name: "Owed to people", createdAt: clock.now)
        smart.taskFilter = TaskFilter(match: .any, rules: [.waiting, .linkedToAnyPerson])
        smart.symbolName = "hand.raised"
        services.context.insert(smart)

        // MARK: A date the migration would not interpret

        let ambiguous = try items.create(ItemDraft(kind: .reminder, title: "Send the draft over"))
        try items.update(ambiguous) {
            $0.dueAt = at(2, hour: 17)
            $0.dateReview = .deadlineMayHaveBeenAReminder
        }

        do {
            try services.context.save()
        } catch {
            throw .writeFailed(path: "sample data", reason: error.localizedDescription)
        }
    }

    /// A task carrying a Reminders link in a chosen state.
    ///
    /// Written directly rather than through `ReminderSyncEngine`, deliberately: sample data must not
    /// require the integration to be switched on, and it must never touch a real store. The
    /// identifiers match `FixtureRemindersProvider`, so launching with the fixture flag makes these
    /// four rows genuinely reconcilable.
    private static func link(
        items: any ItemRepository,
        title: String,
        externalID: String,
        listID: String,
        state: TaskSyncState,
        parentID: UUID?,
        clock: any DateProvider
    ) throws(AppError) {
        let task = try items.create(
            ItemDraft(
                kind: .reminder,
                title: title,
                parentID: parentID,
                source: ItemSource(kind: .systemStore, identifier: externalID)
            )
        )
        // ### The fingerprint has to be the real one
        // This used to plant the literal string "sample", which can never equal a fingerprint of
        // anything. Every one of these four rows therefore read as "changed in Reminders" on the
        // first pass, so the states they exist to demonstrate — in step, read-only, gone — all came
        // out as conflicts instead, and the fixture flag demonstrated a broken sync rather than a
        // working one.
        //
        // `.conflicted` is the exception: that row is *meant* to disagree, so it keeps a fingerprint
        // that deliberately does not match. It is a comparable one, so the disagreement is a real
        // comparison rather than an artefact of the format.
        let planted = FixtureRemindersProvider.defaultReminders.first { $0.id == externalID }
        let fingerprint = switch state {
        case .conflicted:
            ReminderSnapshot.fingerprintPrefix + "changedelsewhere"
        default:
            planted?.fingerprint ?? ReminderSnapshot.fingerprintPrefix + "absent"
        }

        // A conflict needs *both* sides to have moved. A mismatched fingerprint on its own only says
        // the reminder changed, which resolves to `.adoptRemote` — so backdating the local stamp is
        // what makes this row demonstrate a disagreement rather than a quiet remote win.
        let localStampOffset: TimeInterval = state == .conflicted ? -60 : 0

        // Through `recordSyncMetadata`, for the reason given on it: `update` stamps `updatedAt`
        // after the closure runs, so a local stamp written inside would be older than the value the
        // write leaves behind, and the first pass would read a local edit nobody made.
        try items.recordSyncMetadata(on: task) { subject in
            subject.setReminderLink(
                ReminderLinkState(
                    externalID: externalID,
                    listID: listID,
                    lastSyncedFingerprint: fingerprint,
                    lastSyncedAt: clock.now,
                    lastSyncedLocalStamp: subject.updatedAt.addingTimeInterval(localStampOffset)
                )
            )
            subject.syncState = state
        }
    }
}
