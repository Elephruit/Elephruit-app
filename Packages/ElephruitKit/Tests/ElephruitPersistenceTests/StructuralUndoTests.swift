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

    // MARK: The window's manager

    /// The manager `⌘Z` dispatches to is the window's, and the coordinator was registering on one
    /// no window had ever heard of — so every structural change was silently un-undoable from the
    /// Edit menu. Adoption is what closes that: the shell hands over the focused window's manager
    /// and registrations follow it.
    @Test("An adopted manager takes the registrations, and the menu path works")
    func adoptedManagerTakesRegistrations() throws {
        let fixture = try StoreFixture()
        let (undo, standalone) = makeCoordinator(fixture)

        let window = UndoManager()
        window.groupsByEvent = false
        undo.adopt(window)

        let note = try fixture.makeNote(title: "Doomed")
        try undo.moveToTrash([note])

        #expect(standalone.canUndo == false, "the fallback saw nothing")
        #expect(window.canUndo, "the window's manager holds the step")
        #expect(window.undoActionName == "Move to Trash", "and it is named for the menu")

        window.undo()
        #expect(try fixture.requireItem(id: note.id).deletedAt == nil)
    }

    /// The redo of an undo must land on the manager that ran the undo — not on whichever window
    /// happens to be focused by then. Otherwise ⌘Z in one window hands its ⇧⌘Z to another.
    @Test("Redo stays on the manager that ran the undo, wherever focus went")
    func redoStaysWithItsWindow() throws {
        let fixture = try StoreFixture()
        let (undo, _) = makeCoordinator(fixture)

        let first = UndoManager()
        first.groupsByEvent = false
        undo.adopt(first)

        let note = try fixture.makeNote(title: "Doomed")
        try undo.moveToTrash([note])

        // Focus moves to a second window before the user undoes in the first.
        let second = UndoManager()
        second.groupsByEvent = false
        undo.adopt(second)

        first.undo()
        #expect(try fixture.requireItem(id: note.id).deletedAt == nil)

        #expect(first.canRedo, "the redo belongs to the window that undid")
        #expect(second.canRedo == false, "the newly focused window gained nothing")

        first.redo()
        #expect(try fixture.requireItem(id: note.id).deletedAt != nil)
    }

    /// `adopt(nil)` restores the standalone fallback, which is also the state every test above
    /// runs in — the default must stay the default.
    @Test("Dropping the adoption falls back to the standalone manager")
    func droppingAdoptionFallsBack() throws {
        let fixture = try StoreFixture()
        let (undo, standalone) = makeCoordinator(fixture)

        let window = UndoManager()
        window.groupsByEvent = false
        undo.adopt(window)
        undo.adopt(nil)

        let note = try fixture.makeNote(title: "Doomed")
        try undo.moveToTrash([note])

        #expect(window.canUndo == false)
        #expect(standalone.canUndo)
    }
}
