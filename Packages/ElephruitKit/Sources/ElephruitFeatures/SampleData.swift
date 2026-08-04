import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation

/// A realistic library, for previews and development mode only.
///
/// Realistic on purpose: a design that looks right against three items called "Test 1" often falls
/// apart against a real library. This one has long titles, empty titles, overdue work, nested
/// projects, hierarchical tags, unresolved links, archived and trashed items — the cases that break
/// layouts.
///
/// Reachable only through ``AppServices/loadSampleData()``, which refuses outside development mode.
/// Sample data in a real library would be a data-integrity bug.
public enum SampleData {
    @MainActor
    public static func populate(services: AppServices) throws(AppError) {
        let items = services.items
        let clock = services.dateProvider

        // MARK: Areas

        let work = try items.create(ItemDraft(kind: .area, title: "Work"))
        try items.update(work) { $0.colorName = "blue" }

        let personal = try items.create(ItemDraft(kind: .area, title: "Personal"))
        try items.update(personal) { $0.colorName = "green" }

        // MARK: Projects

        let launch = try items.create(
            ItemDraft(
                kind: .project,
                title: "Q3 Product Launch",
                body: """
                    # Brief

                    Ship the new pricing page and announcement by the end of the quarter.

                    ## Open questions
                    - Do we announce the pricing change before or after the migration?
                    - Who owns the customer email — see [[Pricing Change Communications]].
                    """,
                tagSlugs: ["work/clients/northwind"],
                parentID: work.id
            )
        )
        try items.update(launch) { subject in
            subject.colorName = "indigo"
            subject.dueAt = clock.startOfDay(daysFromToday: 24)
        }

        let migration = try items.create(
            ItemDraft(
                kind: .project,
                title: "Database migration",
                body: "Move the reporting tables off the primary instance.",
                tagSlugs: ["work/infrastructure"],
                parentID: work.id
            )
        )
        try items.update(migration) { $0.colorName = "orange" }

        let houseMove = try items.create(
            ItemDraft(kind: .project, title: "House move", tagSlugs: ["home"], parentID: personal.id)
        )

        // MARK: Tasks — including the awkward cases

        // Headings, so the project workspace has real structure to show.
        let planning = try items.create(
            ItemDraft(kind: .heading, title: "Planning", parentID: launch.id)
        )
        let writing = try items.create(
            ItemDraft(kind: .heading, title: "Writing", parentID: launch.id)
        )
        // An empty heading is legitimate — a placeholder for work not yet written down.
        _ = try items.create(
            ItemDraft(kind: .heading, title: "After launch", parentID: launch.id)
        )

        let overdue = try items.create(
            ItemDraft(
                kind: .reminder,
                title: "Send the revised pricing table to Priya for review",
                tagSlugs: ["urgent"],
                parentID: planning.id,
                dueAt: clock.startOfDay(daysFromToday: -4),
                priority: .high
            )
        )

        _ = try items.create(
            ItemDraft(
                kind: .reminder,
                title: "Draft the announcement post",
                body: "Tone: matter-of-fact. Reference [[Positioning Notes]] for the framing.",
                tagSlugs: ["writing"],
                parentID: writing.id,
                dueAt: clock.startOfToday,
                priority: .high
            )
        )

        _ = try items.create(
            ItemDraft(kind: .reminder, title: "Book the venue", parentID: planning.id, dueAt: clock.startOfDay(daysFromToday: 2))
        )

        let completedTask = try items.create(
            ItemDraft(kind: .reminder, title: "Agree the launch date with Sales", parentID: planning.id)
        )
        try items.toggleCompletion(completedTask)

        // A subtask, to exercise Task ▸ Subtask containment.
        _ = try items.create(
            ItemDraft(kind: .reminder, title: "Check the figures against last quarter", parentID: overdue.id)
        )

        // Deferred, so Today has something to correctly hide.
        let deferred = try items.create(
            ItemDraft(kind: .reminder, title: "Review the migration rollback plan", parentID: migration.id, dueAt: clock.startOfToday)
        )
        try items.update(deferred) { $0.deferUntil = clock.startOfDay(daysFromToday: 6) }

        // Recurring, anchored to completion.
        let recurring = try items.create(
            ItemDraft(kind: .reminder, title: "Weekly review", dueAt: clock.startOfDay(daysFromToday: 1), priority: .normal)
        )
        try items.update(recurring) { subject in
            subject.recurrence = RecurrenceRule(frequency: .weekly, weekdays: [6], anchor: .schedule)
        }

        _ = try items.create(
            ItemDraft(kind: .reminder, title: "Get quotes from three removal firms", tagSlugs: ["home"], parentID: houseMove.id)
        )

        // A finished project, so the completion suggestion has somewhere to appear.
        let finished = try items.create(
            ItemDraft(kind: .project, title: "Renew the domain", parentID: work.id)
        )
        for title in ["Check the registrar", "Pay the invoice"] {
            let task = try items.create(ItemDraft(kind: .reminder, title: title, parentID: finished.id))
            try items.toggleCompletion(task)
        }

        // MARK: Inbox — unfiled captures awaiting triage

        _ = try items.create(
            ItemDraft(
                kind: .note,
                title: "Idea: usage-based tier for small teams",
                body: "Came up in the call with Northwind. Worth costing out before the launch.",
                source: .quickCapture
            )
        )

        _ = try items.create(
            ItemDraft(kind: .reminder, title: "Chase the invoice from February", source: .quickCapture)
        )

        // An untitled capture, so the placeholder-title path is exercised.
        _ = try items.create(
            ItemDraft(
                kind: .note,
                body: "Rough thought with no title yet — the list should still show something readable.",
                source: .quickCapture
            )
        )

        // MARK: Notes

        let positioning = try items.create(
            ItemDraft(
                kind: .note,
                title: "Positioning Notes",
                body: """
                    The pitch is *less bookkeeping*, not *more features*.

                    Three things people actually say:

                    1. "I have the same list in four places."
                    2. "I know I wrote it down somewhere."
                    3. "I do not trust it to still be there next year."

                    The third is why export matters more than it looks like it should.
                    See [[Q3 Product Launch]] for how this lands in the announcement.
                    """,
                tagSlugs: ["work", "writing"]
            )
        )
        try items.fileItem(positioning, under: launch)
        try items.update(positioning) { subject in
            subject.isPinned = true
            subject.isFavorite = true
            subject.userMetadata = ["reviewedBy": .text("Priya"), "confidence": .number(0.7)]
        }

        // Deliberately links to something that does not exist, so the unresolved-link state shows.
        let runbook = try items.create(
            ItemDraft(
                kind: .note,
                title: "Migration runbook",
                body: """
                    Steps, in order. Do not skip step 3.

                    Related: [[Database migration]], [[Rollback Procedure]].

                    The second link is deliberately unresolved — it shows what an unwritten
                    note looks like before you write it.
                    """,
                tagSlugs: ["work/infrastructure"]
            )
        )
        try items.fileItem(runbook, under: migration)

        // Filed under two projects at once — the thing containment could never express.
        let sharedNote = try items.create(
            ItemDraft(
                kind: .note,
                title: "Pricing history at Acme",
                body: "Relevant to both the launch and the migration billing work.",
                tagSlugs: ["work"]
            )
        )
        try items.fileItem(sharedNote, under: launch)
        try items.fileItem(sharedNote, under: migration)

        _ = try items.create(
            ItemDraft(
                kind: .note,
                title: "A note with a title long enough to need truncating in a narrow list column, which is exactly the case that breaks layouts",
                body: "Short body.",
                tagSlugs: ["writing"]
            )
        )

        // MARK: Bookmarks

        _ = try items.create(
            ItemDraft(
                kind: .bookmark,
                title: "Human Interface Guidelines",
                tagSlugs: ["reading", "work"],
                source: ItemSource(kind: .quickCapture, url: URL(string: "https://developer.apple.com/design/human-interface-guidelines")),
                url: URL(string: "https://developer.apple.com/design/human-interface-guidelines")
            )
        )

        // MARK: People

        let priya = try items.create(ItemDraft(kind: .person, title: "Priya Raman"))
        let profile = PersonProfile(givenName: "Priya", familyName: "Raman", roleTitle: "Head of Product")
        profile.emails = [LabelledValue(label: "work", value: "priya@example.com")]
        profile.item = priya
        services.context.insert(profile)

        services.context.insert(
            ItemLink(kind: .mentions, source: positioning, target: priya, createdAt: clock.now)
        )

        // MARK: Archived and trashed, so both states have contents

        let archived = try items.create(
            ItemDraft(kind: .note, title: "Q2 retrospective", body: "Kept for reference.", tagSlugs: ["work"])
        )
        try items.setArchived(archived, true)

        let trashed = try items.create(
            ItemDraft(kind: .note, title: "Abandoned draft", body: "Deleted, but recoverable.")
        )
        try items.moveToTrash(trashed)

        // MARK: Collections and saved searches

        let reading = ItemCollection(
            name: "Launch reading",
            summary: "In the order I mean to read them.",
            symbolName: "book",
            colorName: "teal",
            createdAt: clock.now
        )
        services.context.insert(reading)
        services.context.insert(
            CollectionMembership(collection: reading, item: positioning, position: 0, note: "Start here", addedAt: clock.now)
        )

        for (index, search) in savedSearchDefinitions.enumerated() {
            services.context.insert(
                SavedSearch(
                    name: search.name,
                    queryString: search.query,
                    symbolName: search.symbol,
                    sortOrder: Double(index) * 1024,
                    createdAt: clock.now
                )
            )
        }

        do {
            try services.context.save()
        } catch {
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }

        // The People fixture, which is substantial enough to live in its own file and which needs
        // the store already populated: it links interactions to notes and projects that exist above.
        try PeopleSampleData.populate(services: services)

        Diagnostics.features.info("Loaded sample data")
    }

    private static let savedSearchDefinitions: [(name: String, query: String, symbol: String)] = [
        ("Overdue", "is:overdue type:reminder", "exclamationmark.triangle"),
        ("Urgent this week", "tag:urgent is:open due:<7d", "flame"),
        ("Unfiled notes", "type:note is:unfiled", "tray.2"),
    ]
}
