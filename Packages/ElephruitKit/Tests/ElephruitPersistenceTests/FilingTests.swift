import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// **Criteria A2-2 through A2-5** — a note is filed by link, may be filed in several places at once,
/// and is never owned by any of them.
///
/// Containment implies exactly one owner and cascades on archive and trash. That is right for a task
/// inside a project and wrong for a note, and this suite is what holds the distinction in place.
@MainActor
@Suite("Filing")
struct FilingTests {
    @Test("Containment is the work-breakdown structure and nothing else")
    func containmentIsWorkOnly() {
        #expect(ItemKind.area.canContain(.project))
        #expect(ItemKind.area.canContain(.goal))
        #expect(ItemKind.goal.canContain(.project))
        #expect(ItemKind.project.canContain(.task))
        #expect(ItemKind.project.canContain(.heading))
        #expect(ItemKind.heading.canContain(.task))
        #expect(ItemKind.task.canContain(.task))

        // Everything else links.
        #expect(ItemKind.project.canContain(.note) == false)
        #expect(ItemKind.project.canContain(.bookmark) == false)
        #expect(ItemKind.project.canContain(.meeting) == false)
        #expect(ItemKind.area.canContain(.note) == false)
        #expect(ItemKind.dailyEntry.canContain(.task) == false)
        #expect(ItemKind.meeting.canContain(.task) == false)
    }

    @Test("A note cannot be put inside a project")
    func notesCannotBeContained() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let note = try fixture.makeNote(title: "Positioning")

        #expect(throws: AppError.self) {
            try fixture.items.setParent(note, to: project)
        }
    }

    @Test("A note is filed under a project instead")
    func notesAreFiled() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let note = try fixture.makeNote(title: "Positioning")

        try fixture.items.fileItem(note, under: project)

        #expect(try fixture.requireItem(id: project.id).filedItems().map(\.id) == [note.id])
        #expect(note.filedUnderContainers().map(\.id) == [project.id])
        #expect(note.parent == nil, "Filed is not contained")
    }

    /// **A2-2.**
    @Test("A note can be filed under several projects at once, and is owned by none")
    func notesFileInSeveralPlaces() throws {
        let fixture = try StoreFixture()
        let first = try fixture.makeProject(title: "First")
        let second = try fixture.makeProject(title: "Second")
        let third = try fixture.makeProject(title: "Third")
        let note = try fixture.makeNote(title: "Shared context")

        for project in [first, second, third] {
            try fixture.items.fileItem(note, under: project)
        }

        #expect(note.filedUnderContainers().count == 3)
        for project in [first, second, third] {
            #expect(try fixture.requireItem(id: project.id).filedItems().contains { $0.id == note.id })
        }
    }

    @Test("Filing twice under the same project is a no-op, not a duplicate")
    func filingIsIdempotent() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")
        let note = try fixture.makeNote(title: "Note")

        try fixture.items.fileItem(note, under: project)
        try fixture.items.fileItem(note, under: project)

        #expect(note.filedUnderContainers().count == 1)
    }

    @Test("Unfiling from one place leaves the others")
    func unfilingIsSurgical() throws {
        let fixture = try StoreFixture()
        let first = try fixture.makeProject(title: "First")
        let second = try fixture.makeProject(title: "Second")
        let note = try fixture.makeNote(title: "Note")

        try fixture.items.fileItem(note, under: first)
        try fixture.items.fileItem(note, under: second)
        try fixture.items.unfileItem(note, from: first)

        #expect(note.filedUnderContainers().map(\.id) == [second.id])
    }

    /// **A2-4.** The promise the whole change exists to keep.
    @Test("Archiving a project leaves its filed notes untouched and reachable")
    func archivingSparesFiledNotes() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let note = try fixture.makeNote(title: "Positioning")
        let task = try fixture.items.create(ItemDraft(kind: .task, title: "A task", parentID: project.id))

        try fixture.items.fileItem(note, under: project)
        try fixture.items.setArchived(project, true)

        // The task is contained, so it goes. The note is linked, so it does not.
        #expect(try fixture.requireItem(id: task.id).archivedAt != nil)
        #expect(try fixture.requireItem(id: note.id).archivedAt == nil)

        // And it is still reachable in the ordinary note list.
        #expect(try fixture.items.items(matching: .kind(.note)).contains { $0.id == note.id })
    }

    @Test("Completing a project leaves its filed notes untouched")
    func completingSparesFiledNotes() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let note = try fixture.makeNote(title: "Positioning")
        try fixture.items.fileItem(note, under: project)

        try fixture.items.completeProject(project)

        let stored = try fixture.requireItem(id: note.id)
        #expect(stored.status == .none)
        #expect(stored.archivedAt == nil)
        #expect(stored.deletedAt == nil)
    }

    @Test("Trashing a project leaves its filed notes in place")
    func trashingSparesFiledNotes() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")
        let note = try fixture.makeNote(title: "Positioning")
        try fixture.items.fileItem(note, under: project)

        try fixture.items.moveToTrash(project)

        #expect(try fixture.requireItem(id: note.id).deletedAt == nil)
    }

    /// **A2-5.** The two groups the project workspace shows, without naming a link type.
    @Test("Filed notes and mentioning notes are distinct groups")
    func filedAndMentioningAreDistinct() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")

        let filed = try fixture.makeNote(title: "Positioning")
        try fixture.items.fileItem(filed, under: project)

        // A note that merely mentions the project by wiki link.
        let mentioning = try fixture.items.create(
            ItemDraft(kind: .note, title: "Weekly notes", body: "Touched on [[Q3 Launch]] today.")
        )

        let stored = try fixture.requireItem(id: project.id)
        #expect(stored.filedItems().map(\.id) == [filed.id])
        #expect(stored.mentioningItems().map(\.id) == [mentioning.id])
    }

    @Test("A note both filed and mentioning appears only as filed")
    func filedWinsOverMentioning() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Q3 Launch")

        let note = try fixture.items.create(
            ItemDraft(kind: .note, title: "Positioning", body: "About [[Q3 Launch]].")
        )
        try fixture.items.fileItem(note, under: project)

        let stored = try fixture.requireItem(id: project.id)
        #expect(stored.filedItems().map(\.id) == [note.id])
        #expect(stored.mentioningItems().isEmpty, "It should not appear in both groups")
    }

    @Test("Filing under something that is not a container is refused")
    func onlyContainersAcceptFilings() throws {
        let fixture = try StoreFixture()
        let note = try fixture.makeNote(title: "Note")
        let other = try fixture.makeNote(title: "Not a container")

        #expect(throws: AppError.self) {
            try fixture.items.fileItem(note, under: other)
        }
    }

    @Test("A trashed note disappears from its project's filed list")
    func trashedNotesLeaveTheList() throws {
        let fixture = try StoreFixture()
        let project = try fixture.makeProject(title: "Project")
        let note = try fixture.makeNote(title: "Note")
        try fixture.items.fileItem(note, under: project)

        try fixture.items.moveToTrash(note)

        #expect(try fixture.requireItem(id: project.id).filedItems().isEmpty)
    }
}
