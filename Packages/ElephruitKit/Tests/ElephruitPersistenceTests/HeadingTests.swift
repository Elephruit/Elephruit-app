import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData
import Testing

/// Headings are project organisation, not content. These tests pin down every rule from decision 8:
/// they stay out of ordinary views, they are findable inside a project, they never count as work,
/// an empty one is legitimate, and moving or removing one is never quietly destructive.
@MainActor
@Suite("Headings")
struct HeadingTests {
    /// A project with two headings, three tasks under them, and one loose task.
    private func makeProjectWithHeadings(_ fixture: StoreFixture) throws -> (
        project: Item, planning: Item, buying: Item
    ) {
        let project = try fixture.makeProject(title: "Vacation in Rome")

        let planning = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Planning", parentID: project.id)
        )
        let buying = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Items to buy", parentID: project.id)
        )

        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Book flights", parentID: planning.id))
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Read about the metro", parentID: planning.id))
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Power adapter", parentID: buying.id))
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Loose task", parentID: project.id))

        return (project, planning, buying)
    }

    // MARK: - Shape

    @Test("A heading holds tasks and lives in a project")
    func containment() throws {
        let fixture = try StoreFixture()
        let (project, planning, _) = try makeProjectWithHeadings(fixture)

        #expect(planning.parent?.id == project.id)
        #expect(project.orderedHeadings().count == 2)
        #expect((planning.children ?? []).count == 2)
    }

    @Test("A heading may not go anywhere but a project")
    func headingsOnlyBelongInProjects() throws {
        let fixture = try StoreFixture()
        let area = try fixture.makeArea(title: "Work")
        let task = try fixture.makeTask(title: "A task")
        let heading = try fixture.items.create(ItemDraft(kind: .heading, title: "Loose heading"))

        #expect(throws: AppError.self) { try fixture.items.setParent(heading, to: area) }
        #expect(throws: AppError.self) { try fixture.items.setParent(heading, to: task) }
    }

    @Test("A heading holds only tasks")
    func headingsHoldOnlyTasks() throws {
        let fixture = try StoreFixture()
        let (_, planning, _) = try makeProjectWithHeadings(fixture)
        let note = try fixture.makeNote(title: "A note")

        #expect(throws: AppError.self) { try fixture.items.setParent(note, to: planning) }
    }

    @Test("A heading carries no body and no tags")
    func headingsCarryNothingElse() throws {
        let fixture = try StoreFixture()
        let heading = try fixture.items.create(ItemDraft(kind: .heading, title: "Planning"))

        #expect(throws: AppError.self) {
            try fixture.items.update(heading) { $0.body = "Not allowed" }
        }
        #expect(throws: AppError.self) {
            try fixture.items.setTags(heading, slugs: ["work"])
        }
        #expect(heading.status == .none, "A heading is never open or completed")
    }

    @Test("An empty heading is legitimate and is never pruned")
    func emptyHeadingsAreValid() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")

        let empty = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Not written down yet", parentID: project.id)
        )

        #expect((empty.children ?? []).isEmpty)
        #expect(try fixture.requireItem(id: empty.id).kind == .heading)
        #expect(project.orderedHeadings().count == 1)
    }

    // MARK: - Exclusion from content views

    @Test("Headings never appear in the Inbox")
    func absentFromInbox() throws {
        let fixture = try StoreFixture()
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "A loose heading"))
        _ = try fixture.makeNote(title: "A real capture")

        let inbox = try fixture.items.items(matching: .inbox())

        #expect(inbox.count == 1)
        #expect(inbox.first?.kind == .note)
    }

    @Test("Headings never appear in ordinary content lists")
    func absentFromContentLists() throws {
        let fixture = try StoreFixture()
        _ = try makeProjectWithHeadings(fixture)

        // An unfiltered list of everything active is the broadest content view there is.
        let everything = try fixture.items.items(matching: ItemQuery())
        #expect(!everything.contains { $0.kind == .heading })

        // And the task list shows tasks, not the sections they sit in.
        let tasks = try fixture.items.items(matching: .kind(.task))
        #expect(tasks.count == 4)
        #expect(!tasks.contains { $0.kind == .heading })
    }

    @Test("Naming the kind explicitly asks for them — this is what type:heading does")
    func namingTheKindIncludesThem() throws {
        let fixture = try StoreFixture()
        _ = try makeProjectWithHeadings(fixture)

        let headings = try fixture.items.items(matching: .kind(.heading))
        #expect(headings.count == 2)
    }

    @Test("A project's own contents do include its headings")
    func projectContentsIncludeHeadings() throws {
        let fixture = try StoreFixture()
        let (project, _, _) = try makeProjectWithHeadings(fixture)

        let contents = try fixture.items.items(matching: .children(of: project.id))

        #expect(contents.count { $0.kind == .heading } == 2)
        #expect(contents.count { $0.kind == .task } == 1, "The loose task, not those inside headings")
    }

    @Test("A trashed or archived heading stays visible so it can be brought back")
    func recoverableViewsIncludeHeadings() throws {
        let fixture = try StoreFixture()
        let (_, planning, buying) = try makeProjectWithHeadings(fixture)

        try fixture.items.moveToTrash(planning)
        try fixture.items.setArchived(buying, true)

        #expect(try fixture.items.items(matching: .trash()).contains { $0.id == planning.id })
        #expect(try fixture.items.items(matching: .archive()).contains { $0.id == buying.id })
    }

    // MARK: - Not work

    @Test("Headings do not count towards project progress")
    func headingsAreNotWork() throws {
        let fixture = try StoreFixture()
        let (project, planning, _) = try makeProjectWithHeadings(fixture)

        let progress = project.taskProgress()
        #expect(progress.total == 4, "Four tasks, two headings — headings are not work")
        #expect(progress.completed == 0)

        // Completing everything leaves the headings behind, and the project still reads as finished.
        for task in project.descendantTasks() {
            try fixture.items.toggleCompletion(task)
        }

        #expect(project.taskProgress() == (completed: 4, total: 4))
        #expect(project.hasOpenTasks == false)
        #expect(planning.kind.countsAsWork == false)
    }

    @Test("A project holding only empty headings has no work and reads as finished")
    func emptyHeadingsLeaveNoWork() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Someday", parentID: project.id))

        #expect(project.hasAnyTasks == false)
        #expect(project.hasOpenTasks == false)
        #expect(project.taskProgress() == (completed: 0, total: 0))
    }

    @Test("Progress reaches through headings and subtasks alike")
    func progressFlattensTheTree() throws {
        let fixture = try StoreFixture()
        let (project, planning, _) = try makeProjectWithHeadings(fixture)

        let parentTask = try #require((planning.children ?? []).first { $0.kind == .task })
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "A subtask", parentID: parentTask.id))

        #expect(project.taskProgress().total == 5)
    }

    // MARK: - Moving and removing

    @Test("Trashing a heading takes its tasks, and restoring brings back exactly that set")
    func trashAndRestoreCascade() throws {
        let fixture = try StoreFixture()
        let (_, planning, _) = try makeProjectWithHeadings(fixture)
        let taskIDs = (planning.children ?? []).map(\.id)

        try fixture.items.moveToTrash(planning)

        for id in taskIDs {
            #expect(try fixture.requireItem(id: id).deletedAt != nil)
        }

        try fixture.items.restore(planning)

        for id in taskIDs {
            #expect(try fixture.requireItem(id: id).deletedAt == nil)
        }
        #expect((try fixture.requireItem(id: planning.id).children ?? []).count == 2)
    }

    @Test("A heading's tasks can be moved out before it goes — the non-destructive path")
    func tasksCanBeMovedOutFirst() throws {
        let fixture = try StoreFixture()
        let (project, planning, _) = try makeProjectWithHeadings(fixture)
        let taskIDs = (planning.children ?? []).map(\.id)

        // What "Move the tasks out of the heading" does: re-parent to the project, then remove.
        for id in taskIDs {
            let task = try fixture.sameContextItem(id: id)
            try fixture.items.setParent(task, to: project)
        }
        try fixture.items.moveToTrash(planning)

        for id in taskIDs {
            let task = try fixture.sameContextItem(id: id)
            #expect(task.deletedAt == nil, "Moved out first, so the heading's removal cannot take them")
            #expect(task.parent?.id == project.id)
        }
        #expect(project.taskProgress().total == 4)
    }

    @Test("Reordering headings is a single write and does not disturb their tasks")
    func reorderingIsCheapAndSafe() throws {
        let fixture = try StoreFixture()
        let (project, planning, buying) = try makeProjectWithHeadings(fixture)

        #expect(project.orderedHeadings().map(\.title) == ["Planning", "Items to buy"])

        try fixture.items.move(buying, after: nil, before: planning)

        #expect(project.orderedHeadings().map(\.title) == ["Items to buy", "Planning"])
        #expect((planning.children ?? []).count == 2, "Tasks travel with their heading, untouched")
    }

    @Test("Converting a heading to a task drops what a task cannot inherit")
    func conversionIsHonest() throws {
        let fixture = try StoreFixture()
        let (_, planning, _) = try makeProjectWithHeadings(fixture)

        // A heading can legitimately become a task — both live in a project and hold tasks.
        _ = try fixture.items.setKind(planning, to: .task)

        #expect(planning.kind == .task)
        #expect(planning.status == .open, "A task needs a status; a heading never had one")
        #expect((planning.children ?? []).count == 2, "Its tasks become subtasks rather than being orphaned")
    }
}

/// Global search must not surface headings; scoped search inside a project must.
@MainActor
@Suite("Headings and search")
struct HeadingSearchTests {
    @Test("Headings are absent from global search results")
    func absentFromGlobalSearch() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Rome")
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Planning", parentID: project.id))
        _ = try fixture.makeNote(title: "Planning notes")

        // The store-backed fallback path, which is what search uses before its index warms.
        var query = ItemQuery()
        query.text = "planning"
        let results = try fixture.items.items(matching: query)

        #expect(results.count == 1)
        #expect(results.first?.kind == .note)
    }

    @Test("Searching within a project does match its headings")
    func scopedSearchFindsHeadings() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Rome")
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Planning", parentID: project.id))
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Items to buy", parentID: project.id))

        // Scoping to a container is a different surface from global search, and there a heading is
        // exactly what the user is looking for.
        var query = ItemQuery.children(of: project.id)
        query.text = "planning"
        let results = try fixture.items.items(matching: query)

        #expect(results.count == 1)
        #expect(results.first?.kind == .heading)
        #expect(results.first?.title == "Planning")
    }
}
