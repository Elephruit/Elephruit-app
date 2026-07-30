import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// **Criterion A1-15** — the completion suggestion appears only when a project has work and none of
/// it is open; dismissal survives; and it re-arms on exactly one transition.
///
/// The rule the tests exist to protect: *suggestions never decide anything on their own*. Completing
/// a project is always the user's action, "Not yet" is remembered, and an unrelated edit can never
/// make a dismissed suggestion reappear.
@MainActor
@Suite("Project completion suggestion")
struct ProjectCompletionTests {
    private func makeProject(_ fixture: StoreFixture, taskCount: Int) throws -> Item {
        let project = try fixture.makeProject(title: "Q3 Launch")
        for index in 1...max(0, taskCount) {
            _ = try fixture.items.create(
                ItemDraft(kind: .task, title: "Task \(index)", parentID: project.id)
            )
        }
        return project
    }

    // MARK: When it appears

    @Test("Nothing is suggested while work is still open")
    func silentWhileWorkRemains() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 2)

        #expect(project.shouldSuggestCompletion == false)

        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        #expect(project.shouldSuggestCompletion == false, "One of two done is not finished")
    }

    @Test("The suggestion appears when the last task is completed")
    func appearsWhenTheLastTaskIsDone() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 2)

        for task in project.descendantTasks() {
            try fixture.items.toggleCompletion(task)
        }

        #expect(project.shouldSuggestCompletion)
    }

    @Test("An empty project is not a finished project")
    func emptyProjectsAreNeverSuggested() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Not started")

        #expect(project.hasAnyTasks == false)
        #expect(project.shouldSuggestCompletion == false)
    }

    @Test("A project holding only empty headings is still not finished")
    func headingsAloneAreNotWork() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Planned but not written")
        _ = try fixture.items.create(ItemDraft(kind: .heading, title: "Someday", parentID: project.id))

        #expect(project.shouldSuggestCompletion == false, "Headings are structure, never work")
    }

    @Test("Tasks inside headings count, and the suggestion follows them")
    func tasksInsideHeadingsCount() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Rome")
        let heading = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Planning", parentID: project.id)
        )
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "Book flights", parentID: heading.id))

        #expect(project.shouldSuggestCompletion == false)

        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        #expect(project.shouldSuggestCompletion)
    }

    @Test("Areas are ongoing and are never suggested for completion")
    func areasAreNeverSuggested() throws {
        let fixture = try StoreFixture()
        let area = try fixture.makeArea(title: "Work")
        let project = try fixture.makeProject(title: "Project", parentID: area.id)
        _ = try fixture.items.create(ItemDraft(kind: .task, title: "A task", parentID: project.id))

        for task in area.descendantTasks() {
            try fixture.items.toggleCompletion(task)
        }

        #expect(area.shouldSuggestCompletion == false)
    }

    // MARK: Dismissal

    @Test("Dismissal is remembered and survives a refetch")
    func dismissalPersists() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)
        try fixture.items.toggleCompletion(project.descendantTasks()[0])

        #expect(project.shouldSuggestCompletion)

        try fixture.items.dismissCompletionSuggestion(for: project)

        #expect(project.shouldSuggestCompletion == false)
        #expect(try fixture.requireItem(id: project.id).completionPromptDismissedAt != nil)
        #expect(try fixture.requireItem(id: project.id).status == .open, "Declining does not complete it")
    }

    @Test("An unrelated edit does not bring a dismissed suggestion back")
    func unrelatedEditsDoNotRearm() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)
        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        try fixture.items.dismissCompletionSuggestion(for: project)

        // Renaming, tagging, favouriting — none of these are the transition.
        try fixture.items.update(project) { $0.title = "Renamed" }
        try fixture.items.setTags(project, slugs: ["work"])
        try fixture.items.update(project) { $0.isFavorite = true }

        #expect(project.shouldSuggestCompletion == false)
    }

    // MARK: Re-arming — exactly three transitions

    @Test("Adding an open task re-arms it")
    func addingWorkRearms() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)
        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        try fixture.items.dismissCompletionSuggestion(for: project)

        _ = try fixture.items.create(ItemDraft(kind: .task, title: "More work", parentID: project.id))
        #expect(project.completionPromptDismissedAt == nil, "New work re-arms the suggestion")
        #expect(project.shouldSuggestCompletion == false, "…but it has open work again")

        try fixture.items.toggleCompletion(project.descendantTasks().first { $0.status == .open } ?? project)
        #expect(project.shouldSuggestCompletion, "…and returns when that work is done")
    }

    @Test("Re-opening a completed task re-arms it")
    func reopeningWorkRearms() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)
        let task = project.descendantTasks()[0]

        try fixture.items.toggleCompletion(task)
        try fixture.items.dismissCompletionSuggestion(for: project)

        try fixture.items.toggleCompletion(task)
        #expect(project.completionPromptDismissedAt == nil)
    }

    @Test("Moving open work into the project re-arms it")
    func movingWorkInRearms() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)
        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        try fixture.items.dismissCompletionSuggestion(for: project)

        let loose = try fixture.makeTask(title: "Came from elsewhere")
        try fixture.items.setParent(loose, to: project)

        #expect(project.completionPromptDismissedAt == nil)
    }

    @Test("Completing the project is the user's action and nothing else's")
    func completionIsAlwaysExplicit() throws {
        let fixture = try StoreFixture()
        let project = try makeProject(fixture, taskCount: 1)

        try fixture.items.toggleCompletion(project.descendantTasks()[0])
        #expect(project.status == .open, "Finishing the work never completes the project by itself")

        try fixture.items.completeProject(project)
        #expect(project.status == .completed)
        #expect(project.completedAt != nil)
    }
}

/// Removing a heading is never quietly destructive — criteria A1-12 and A1-13.
@MainActor
@Suite("Heading removal and archiving")
struct HeadingRemovalTests {
    private func makeHeading(_ fixture: StoreFixture) throws -> (project: Item, heading: Item) {
        let project = try fixture.makeProject(title: "Rome")
        let heading = try fixture.items.create(
            ItemDraft(kind: .heading, title: "Planning", parentID: project.id)
        )
        for index in 1...4 {
            _ = try fixture.items.create(
                ItemDraft(kind: .task, title: "Task \(index)", parentID: heading.id)
            )
        }
        return (project, heading)
    }

    @Test("The task count is knowable before acting, so the interface can name it")
    func countIsAvailableUpFront() throws {
        let fixture = try StoreFixture()
        let (_, heading) = try makeHeading(fixture)

        // "Archive Planning and its 4 tasks?" — the 4 comes from here.
        #expect(heading.descendantTasks().count == 4)
    }

    @Test("Moving tasks out leaves the heading empty and the work intact")
    func movingOutPreservesWork() throws {
        let fixture = try StoreFixture()
        let (project, heading) = try makeHeading(fixture)

        try fixture.items.moveTasksOut(of: heading)

        #expect(heading.children.isEmpty)
        #expect(project.taskProgress().total == 4, "The work survives, now directly in the project")
        #expect(project.ungroupedTasks().count == 4)
    }

    @Test("After moving out, removing the heading takes nothing with it")
    func theNonDestructivePath() throws {
        let fixture = try StoreFixture()
        let (project, heading) = try makeHeading(fixture)
        let taskIDs = heading.descendantTasks().map(\.id)

        try fixture.items.moveTasksOut(of: heading)
        try fixture.items.moveToTrash(heading)

        for id in taskIDs {
            #expect(try fixture.requireItem(id: id).deletedAt == nil)
        }
        #expect(project.taskProgress().total == 4)
    }

    @Test("Archiving a heading takes its tasks with it")
    func archivingCascades() throws {
        let fixture = try StoreFixture()
        let (_, heading) = try makeHeading(fixture)
        let taskIDs = heading.descendantTasks().map(\.id)

        try fixture.items.setArchived(heading, true)

        for id in taskIDs {
            #expect(try fixture.requireItem(id: id).archivedAt != nil)
        }
    }

    @Test("Unarchiving brings them back together")
    func unarchivingCascadesToo() throws {
        let fixture = try StoreFixture()
        let (_, heading) = try makeHeading(fixture)
        let taskIDs = heading.descendantTasks().map(\.id)

        try fixture.items.setArchived(heading, true)
        try fixture.items.setArchived(heading, false)

        for id in taskIDs {
            #expect(try fixture.requireItem(id: id).archivedAt == nil)
        }
    }

    @Test("Archiving a project archives its tasks but not the work it merely links to")
    func archivingAProjectSparesLinkedContent() throws {
        let fixture = try StoreFixture()
        let (project, heading) = try makeHeading(fixture)

        // A note that references the project rather than living inside it.
        let note = try fixture.makeNote(title: "Positioning", body: "About [[Rome]].")

        try fixture.items.setArchived(project, true)

        #expect(try fixture.requireItem(id: heading.id).archivedAt != nil)
        #expect(
            try fixture.requireItem(id: note.id).archivedAt == nil,
            "Linked content is not owned by the project and must not be swept up"
        )
    }
}
