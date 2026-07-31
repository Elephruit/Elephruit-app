import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

/// **Criteria A1-6 and A1-7** — `⌘Z` reverses move, delete, retag, status change, and archive, each
/// with a named menu item; and a batch over twenty items is a single undo step.
///
/// Structural undo is the difference between a mis-drop being an inconvenience and being a
/// half-hour of manual repair. The tests below are deliberately about *what comes back*, not about
/// whether a method was called.
@MainActor
@Suite("Structural undo")
struct StructuralUndoTests {
    private func makeCoordinator(_ fixture: StoreFixture) -> (StructuralUndoCoordinator, UndoManager) {
        let undoManager = UndoManager()
        // A test has no run loop turn to close an event group, so grouping-by-event would leave the
        // group open and `undo()` would do nothing. Each operation registers exactly one inverse, so
        // one registration is one step regardless.
        undoManager.groupsByEvent = false
        return (StructuralUndoCoordinator(items: fixture.items, undoManager: undoManager), undoManager)
    }

    // MARK: Trash

    @Test("Undoing a trash brings the item back")
    func undoTrash() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let note = try fixture.makeNote(title: "Doomed")

        try undo.moveToTrash([note])
        #expect(try fixture.requireItem(id: note.id).deletedAt != nil)

        manager.undo()
        #expect(try fixture.requireItem(id: note.id).deletedAt == nil)
    }

    @Test("Undoing a trash restores its children too")
    func undoTrashRestoresCascade() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        let project = try fixture.makeProject(title: "Project")
        let task = try fixture.items.create(ItemDraft(kind: .task, title: "Task", parentID: project.id))

        try undo.moveToTrash([project])
        #expect(try fixture.requireItem(id: task.id).deletedAt != nil)

        manager.undo()
        #expect(try fixture.requireItem(id: task.id).deletedAt == nil, "The cascade is reversed whole")
    }

    // MARK: Archive

    @Test("Undoing an archive unarchives")
    func undoArchive() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let note = try fixture.makeNote(title: "Filed away")

        try undo.setArchived([note], true)
        #expect(try fixture.requireItem(id: note.id).archivedAt != nil)

        manager.undo()
        #expect(try fixture.requireItem(id: note.id).archivedAt == nil)
    }

    // MARK: Tags

    @Test("Undoing a retag restores each item's own previous tags")
    func undoRetagIsPerItem() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        let first = try fixture.makeNote(title: "First", tags: ["alpha"])
        let second = try fixture.makeNote(title: "Second", tags: ["beta", "gamma"])

        try undo.setTags([first, second], slugs: ["shared"])
        #expect(first.tagSlugs == ["shared"])
        #expect(second.tagSlugs == ["shared"])

        manager.undo()

        // The naive implementation restores one shared "previous" and flattens both. This asserts
        // each item gets back exactly what it had.
        #expect(try fixture.requireItem(id: first.id).tagSlugs == ["alpha"])
        #expect(try fixture.requireItem(id: second.id).tagSlugs == ["beta", "gamma"])
    }

    // MARK: Status

    @Test("Undoing a completion re-opens it, with the date cleared")
    func undoCompletion() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let task = try fixture.makeTask(title: "Do it")

        try undo.toggleCompletion([task])
        #expect(task.status == .completed)
        #expect(task.completedAt != nil)

        manager.undo()

        let restored = try fixture.requireItem(id: task.id)
        #expect(restored.status == .open)
        #expect(restored.completedAt == nil, "The invariant holds through the undo")
    }

    // MARK: Move

    @Test("Undoing a move puts each item back where it was")
    func undoMoveIsPerItem() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        let origin = try fixture.makeProject(title: "Origin")
        let destination = try fixture.makeProject(title: "Destination")
        let filed = try fixture.items.create(ItemDraft(kind: .task, title: "Filed", parentID: origin.id))
        let loose = try fixture.makeTask(title: "Loose")

        try undo.setParent([filed, loose], to: destination)
        #expect(filed.parent?.id == destination.id)
        #expect(loose.parent?.id == destination.id)

        manager.undo()

        // One came from a project, the other from nowhere. Both must return to their own origin.
        #expect(try fixture.requireItem(id: filed.id).parent?.id == origin.id)
        #expect(try fixture.requireItem(id: loose.id).parent == nil)
    }

    // MARK: Batching and naming

    @Test("A batch over twenty items is a single undo step")
    func batchIsOneStep() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        let notes = try (1...20).map { try fixture.makeNote(title: "Note \($0)") }

        try undo.moveToTrash(notes)
        #expect(try fixture.items.items(matching: .trash()).count == 20)

        // One press, not twenty.
        manager.undo()
        #expect(try fixture.items.items(matching: .trash()).isEmpty)
    }

    @Test("Every action is named, so the menu says what it will do")
    func actionsAreNamed() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let note = try fixture.makeNote(title: "A note")

        try undo.moveToTrash([note])
        #expect(manager.undoActionName == "Move to Trash")

        manager.undo()

        try undo.setArchived([note], true)
        #expect(manager.undoActionName == "Archive")
    }

    @Test("A batch names its size")
    func batchNamesItsSize() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let notes = try (1...3).map { try fixture.makeNote(title: "Note \($0)") }

        try undo.moveToTrash(notes)
        #expect(manager.undoActionName == "Move 3 Items to Trash")
    }

    @Test("Undo is reversible — redo puts it back")
    func redoWorks() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)
        let note = try fixture.makeNote(title: "A note")

        try undo.moveToTrash([note])
        manager.undo()
        #expect(try fixture.requireItem(id: note.id).deletedAt == nil)

        manager.redo()
        #expect(try fixture.requireItem(id: note.id).deletedAt != nil)
    }

    @Test("Undo survives an item being deleted underneath it")
    func undoToleratesMissingItems() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        let kept = try fixture.makeNote(title: "Kept")
        let removed = try fixture.makeNote(title: "Removed")

        try undo.setArchived([kept, removed], true)
        try fixture.items.deletePermanently(removed)

        // The undo stack refers to identifiers, not objects, so a vanished row is skipped rather
        // than trapping.
        manager.undo()
        #expect(try fixture.requireItem(id: kept.id).archivedAt == nil)
    }

    @Test("Nothing is registered for an empty selection")
    func emptySelectionIsANoOp() throws {
        let fixture = try StoreFixture()
        let (undo, manager) = makeCoordinator(fixture)

        try undo.moveToTrash([])
        #expect(manager.canUndo == false, "An action over nothing is not an action")
    }
}
