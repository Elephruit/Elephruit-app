import ElephruitCore
import ElephruitDesign
@testable import ElephruitFeatures
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Testing

@MainActor
private func makeServices() -> AppServices {
    let suite = UserDefaults(suiteName: "swipe.tests.\(UUID().uuidString)") ?? .standard
    return AppServices.inMemory(
        populated: false,
        remindersProvider: { FixtureRemindersProvider(authorization: .authorized) },
        defaults: suite
    )
}

/// What a swipe is allowed to do, per row.
///
/// The gesture thresholds are tested in `SwipeGestureTests`, without a store. This is the other
/// half: *which* actions each kind of row offers, which of them a gesture may finish on its own,
/// and whether the deletions behave the way the rest of the app's deletions do.
@MainActor
@Suite("Swipe actions per row")
struct RowSwipeActionTests {
    // MARK: - Tasks

    @Test("A task Elephruit owns can be deleted by the gesture alone, and undone")
    func localTaskFullSwipeTrashes() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Write the thing"))

        #expect(RowSwipeActions.taskAllowsFullSwipe(task))

        let trailing = RowSwipeActions.taskTrailing(
            task,
            services: services,
            onLinkedDeletion: { _ in Issue.record("An owned task must not ask about a reminder") },
            onChange: {}
        )

        #expect(trailing.count == 1)
        let delete = try #require(trailing.first)
        #expect(delete.role == .destructive)
        #expect(delete.isFullSwipeDefault, "A full swipe must be able to finish this one")

        delete.handler()
        #expect(try services.items.item(id: task.id)?.isInTrash == true, "Trashed, not destroyed")

        // Through the undo coordinator, so ⌘Z brings it back — which is the difference between the
        // Trash and a deletion, and the reason a gesture is allowed to reach it at all.
        services.undoManager.undo()
        #expect(try services.items.item(id: task.id)?.isInTrash == false)
    }

    @Test("A task linked to a reminder asks first, and no gesture can answer for it")
    func linkedTaskAsksBeforeDeleting() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Buy milk"))
        try services.items.update(task) { $0.syncState = .linked }

        // Deleting somebody's reminder out of an iCloud account — where it may be shared with other
        // people — is not recoverable, so the distance a finger travelled must not be what decides
        // it.
        #expect(!RowSwipeActions.taskAllowsFullSwipe(task))

        var asked: Item?
        let trailing = RowSwipeActions.taskTrailing(
            task,
            services: services,
            onLinkedDeletion: { asked = $0 },
            onChange: { Issue.record("Nothing should have changed yet") }
        )

        let delete = try #require(trailing.first)
        #expect(!delete.isFullSwipeDefault)

        delete.handler()
        #expect(asked?.id == task.id, "The button asks; it does not delete")
        #expect(try services.items.item(id: task.id)?.isInTrash == false)
    }

    @Test("Swiping a task the other way offers what its context menu already offers")
    func taskLeadingActions() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Ring the bank"))

        let leading = RowSwipeActions.taskLeading(task, services: services, onChange: {})
        #expect(leading.map(\.id) == ["task.complete", "task.today", "task.flag"])

        // Nothing on the leading side is destructive, which is what stops a full swipe right from
        // ever being offered a default to run.
        #expect(leading.allSatisfy { $0.role == .standard })
        #expect(leading.allSatisfy { !$0.isFullSwipeDefault })
    }

    @Test("Completing from a swipe completes the task")
    func completingFromASwipe() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Send the invoice"))

        let complete = try #require(
            RowSwipeActions.taskLeading(task, services: services, onChange: {})
                .first { $0.id == "task.complete" }
        )
        complete.handler()

        #expect(try services.items.item(id: task.id)?.status == .completed)
    }

    @Test("Flagging from a swipe flags the task, and the label follows the state")
    func flaggingFromASwipe() throws {
        let services = makeServices()
        let task = try services.items.create(ItemDraft(kind: .task, title: "Read the contract"))

        let flag = try #require(
            RowSwipeActions.taskLeading(task, services: services, onChange: {})
                .first { $0.id == "task.flag" }
        )
        #expect(flag.title == "Flag")
        flag.handler()

        #expect(try services.items.item(id: task.id)?.isFlagged == true)

        let unflag = try #require(
            RowSwipeActions.taskLeading(task, services: services, onChange: {})
                .first { $0.id == "task.flag" }
        )
        #expect(unflag.title == "Unflag", "A row must say what pressing it will do now")
    }

    // MARK: - Items

    @Test("An ordinary row goes to the Trash, undoably, on a full swipe")
    func itemFullSwipeTrashes() throws {
        let services = makeServices()
        let note = try services.items.create(ItemDraft(kind: .note, title: "A thought"))

        let trailing = RowSwipeActions.itemTrailing(
            note,
            services: services,
            isTrashScope: false,
            onPermanentDeletion: { _ in Issue.record("Not a permanent-delete context") },
            onChange: {}
        )

        let delete = try #require(trailing.first)
        #expect(delete.isFullSwipeDefault)

        delete.handler()
        #expect(try services.items.item(id: note.id)?.isInTrash == true)

        services.undoManager.undo()
        #expect(try services.items.item(id: note.id)?.isInTrash == false)
    }

    @Test("In the Trash the swipe offers the end, and refuses to be the one to press it")
    func trashScopeNeverDeletesFromAGesture() throws {
        let services = makeServices()
        let note = try services.items.create(ItemDraft(kind: .note, title: "Discarded"))
        try services.items.moveToTrash(note)

        var asked: Item?
        let trailing = RowSwipeActions.itemTrailing(
            note,
            services: services,
            isTrashScope: true,
            onPermanentDeletion: { asked = $0 },
            onChange: {}
        )

        let delete = try #require(trailing.first)
        #expect(delete.id == "item.deletePermanently")
        #expect(delete.role == .destructive)
        // The one operation structural undo cannot reverse, so the one a gesture may reveal and
        // never finish.
        #expect(!delete.isFullSwipeDefault)

        delete.handler()
        #expect(asked?.id == note.id)
        #expect(try services.items.item(id: note.id) != nil, "Still there; the dialogue has not run")
    }

    @Test("In the Trash the other direction puts something back")
    func trashScopeLeadingRestores() throws {
        let services = makeServices()
        let note = try services.items.create(ItemDraft(kind: .note, title: "Kept after all"))
        try services.items.moveToTrash(note)

        let leading = RowSwipeActions.itemLeading(
            note,
            services: services,
            isTrashScope: true,
            onChange: {}
        )

        #expect(leading.map(\.id) == ["item.restore"])
        try #require(leading.first).handler()
        #expect(try services.items.item(id: note.id)?.isInTrash == false)
    }

    @Test("A note has no completion action, because a note does not complete")
    func leadingActionsFollowTheKind() throws {
        let services = makeServices()
        let note = try services.items.create(ItemDraft(kind: .note, title: "Not a task"))
        let task = try services.items.create(ItemDraft(kind: .task, title: "Is a task"))

        let noteActions = RowSwipeActions.itemLeading(
            note, services: services, isTrashScope: false, onChange: {}
        )
        let taskActions = RowSwipeActions.itemLeading(
            task, services: services, isTrashScope: false, onChange: {}
        )

        #expect(!noteActions.contains { $0.id == "item.complete" })
        #expect(taskActions.contains { $0.id == "item.complete" })
    }

    // MARK: - People

    @Test("A person goes to the Trash like anything else, and comes back the same way")
    func personTrash() throws {
        let services = makeServices()
        let person = try services.persons.createPerson(PersonDraft(fullName: "Ada Lovelace"))

        let delete = try #require(
            RowSwipeActions.personTrailing(person, services: services, onChange: {}).first
        )
        #expect(delete.isFullSwipeDefault)

        delete.handler()
        #expect(try services.items.item(id: person.id)?.isInTrash == true)

        services.undoManager.undo()
        #expect(try services.items.item(id: person.id)?.isInTrash == false)
    }

    @Test("Starring somebody from a swipe stars them")
    func personFavourite() throws {
        let services = makeServices()
        let person = try services.persons.createPerson(PersonDraft(fullName: "Grace Hopper"))

        let star = try #require(
            RowSwipeActions.personLeading(person, services: services, onChange: {})
                .first { $0.id == "person.favorite" }
        )
        star.handler()

        #expect(try services.items.item(id: person.id)?.isFavorite == true)
    }

    // MARK: - The coordinator

    @Test("An action asked for twice in one turn of the run loop runs once")
    func duplicateDeletionIsPrevented() {
        // A full swipe landing at the same moment as a click on the button it was expanding is two
        // requests to delete one row, and the second one would be deleting whatever had taken its
        // place in the list.
        let coordinator = SwipeActionCoordinator()
        var runs = 0
        let action = SwipeAction(id: "test", title: "Delete", systemImage: "trash") { runs += 1 }

        coordinator.perform(action, on: AnyHashable("row"))
        coordinator.perform(action, on: AnyHashable("row"))

        #expect(runs == 1)
    }

    @Test("A different row is not held back by another row's action")
    func deduplicationIsPerRow() {
        let coordinator = SwipeActionCoordinator()
        var runs = 0
        let action = SwipeAction(id: "test", title: "Delete", systemImage: "trash") { runs += 1 }

        coordinator.perform(action, on: AnyHashable("first"))
        coordinator.perform(action, on: AnyHashable("second"))

        #expect(runs == 2)
    }

    @Test("Closing says whether there was anything to close")
    func closingReportsWhetherItDidAnything() {
        // What lets Escape fall through to the next rung of the ladder rather than swallowing the
        // key when no row was open.
        let coordinator = SwipeActionCoordinator()
        #expect(coordinator.closeAll() == false)
        #expect(coordinator.openRow == nil)
    }

    @Test("A row that has gone away is forgotten rather than left at an offset")
    func forgettingARow() {
        let coordinator = SwipeActionCoordinator()
        let row = AnyHashable(UUID())
        coordinator.setGeometry(SwipeGesture(trailingCount: 1, rowWidth: 400), for: row)

        coordinator.forget(row)
        #expect(coordinator.offset(for: row) == 0)
        #expect(!coordinator.isOpen(row))
    }
}

/// Which destinations each module's sidebar draws.
///
/// The registry is the only place that answers this, so a module quietly losing its rows — or
/// gaining somebody else's — is a change to one array and would otherwise be invisible.
@MainActor
@Suite("Module sidebar contents")
struct ModuleSidebarContentTests {
    /// The two modules whose navigation is not made of registry rows.
    ///
    /// Tasks draws `TaskSystemView`, which is a type of its own precisely so that "what does Anytime
    /// mean" has one answer; People draws `PeopleScope`, for the same reason. Neither belongs in a
    /// registry of fixed destinations, and forcing them in would be duplicating a vocabulary to
    /// satisfy a test.
    static let modulesWithTheirOwnVocabulary: Set<AppModule> = [.tasks, .people]

    @Test("Every module draws something, and only its own rows")
    func everyModuleDrawsSomething() {
        for module in AppModule.displayOrder {
            let destinations = SidebarRegistry.destinations(in: module)

            if !Self.modulesWithTheirOwnVocabulary.contains(module) {
                #expect(!destinations.isEmpty, "\(module.title) would open on an empty sidebar")
            }

            for destination in destinations {
                #expect(destination.module == module)
                #expect(destination.band == .module)
                #expect(destination.isAvailable)
            }
        }

        // The two exceptions still have somewhere to open on, which is the property that actually
        // matters and the one an empty sidebar would break.
        #expect(AppModule.tasks.defaultSelection == .taskView(.today))
        #expect(AppModule.people.defaultSelection == .people(.all))
    }

    @Test("No destination is drawn by two modules")
    func noDestinationIsShared() {
        var seen: [String: AppModule] = [:]

        for module in AppModule.displayOrder {
            for destination in SidebarRegistry.destinations(in: module) {
                #expect(
                    seen[destination.id] == nil,
                    "\(destination.title) appears in both \(seen[destination.id]?.title ?? "") and \(module.title)"
                )
                seen[destination.id] = module
            }
        }
    }

    @Test("A module's first destination is where entering it lands")
    func frontDoorsAgree() {
        // `⌘1`–`⌘9` step through these, and a shortcut that selected something other than what
        // clicking the module row does would be two answers to one question.
        for module in AppModule.displayOrder {
            guard let first = SidebarRegistry.destinations(in: module).first else { continue }

            // Tasks and People are the deliberate exceptions — their sidebars are made of
            // `TaskSystemView` and `PeopleScope`, not registry rows.
            if Self.modulesWithTheirOwnVocabulary.contains(module) { continue }
            #expect(
                first.selection == module.defaultSelection,
                "\(module.title) opens somewhere other than its first row"
            )
        }
    }

    @Test("Notes gathers the kinds that are notes by every other measure")
    func notesModuleContents() {
        let ids = SidebarRegistry.destinations(in: .notes).map(\.id)
        #expect(ids == ["notes", "ideas", "references", "daily"])
    }

    @Test("The one-list modules say so with one row rather than inventing three")
    func singleDestinationModules() {
        for module in [AppModule.bookmarks, .archive, .trash, .calendar, .time] {
            #expect(SidebarRegistry.destinations(in: module).count == 1)
        }
    }
}
