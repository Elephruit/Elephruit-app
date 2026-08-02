import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The state of one open project.
///
/// Everything the workspace draws is computed here, on change, and never in a view body — the
/// `FetchAudit` contract. `groups` is the output of ``WorkItemArrangement``, so every view in the
/// workspace is drawing the same arrangement of the same work.
@MainActor
@Observable
public final class ProjectWorkspaceModel {
    public private(set) var project: Item?
    public private(set) var views: [ProjectViewRecord] = []
    public private(set) var stages: [WorkflowStage] = []
    public private(set) var activeView: ProjectViewRecord?
    public private(set) var groups: [WorkItemArrangement.Group] = []
    public private(set) var allFacts: [TaskFacts] = []
    public private(set) var markers: [Item] = []
    public private(set) var health: ProjectHealth = ProjectHealth()

    /// Everything currently in the arrangement, by identifier.
    ///
    /// Consulted rather than `item(_:)` when deciding whether something is still on screen. The
    /// repository's fetch answers for **trashed** items too, so a sheet open over a just-deleted
    /// work item would find it and stay open over a ghost.
    public private(set) var itemsByID: [UUID: Item] = [:]

    // MARK: Selection

    public var selectedItemIDs: Set<UUID> = []
    public var focusedItemID: UUID?

    /// The item shown in the sheet.
    ///
    /// **Deliberately separate from the selection.** A click selects — which is what keeps
    /// multi-select, drag and the bulk bar working — and a double-click, Return, or Open presents.
    /// One identifier serving both means every click throws a sheet over the board.
    public var presentedItemID: UUID?

    /// The bug report opened inside the Bugs queue rather than in the general-purpose sheet.
    ///
    /// This lives beside presentation state so every opening route — row, keyboard, quick add, or
    /// health concern — reaches the same inline surface when the Bugs view is active.
    public var expandedBugID: UUID?

    /// Whether a text field in the workspace currently has focus.
    ///
    /// **The keyboard shortcuts are gated on this**, and that gate is not optional. The handlers are
    /// attached to the workspace, because a shortcut bound to a row only fires while that row has
    /// focus and a board's focus is on its scroll view. Without the gate, typing a space into a
    /// title marked the item complete *and never reached the field* — the giveaway was a bug filed
    /// as "Can'tedit any bug details".
    public var isEditingText = false

    public var renamingItemID: UUID?
    public var searchText = ""

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    // MARK: Loading

    public func load(projectID: UUID, viewID: UUID?) {
        project = try? services.items.item(id: projectID)
        guard let project else { return }

        _ = try? services.projectWorkspace.ensureWorkspace(for: project)
        views = services.projectWorkspace.views(in: project)
        stages = services.projectWorkspace.stages(in: project)
        activeView = viewID.flatMap { id in views.first { $0.id == id } } ?? views.first
        refresh()
    }

    /// Recomputes everything from the store. Cheap enough to call on any change token bump.
    public func refresh() {
        guard let project else { return }
        views = services.projectWorkspace.views(in: project)
        stages = services.projectWorkspace.stages(in: project)
        if let activeView, !views.contains(where: { $0.id == activeView.id }) {
            self.activeView = views.first
        }

        let work = project.descendantWork()
        itemsByID = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0) })
        allFacts = work.map { $0.taskFacts() }
        markers = project.planningMarkers()
        // Handing over the facts just computed, rather than letting reporting walk the project
        // again. This is one pass over the project per refresh, not three.
        health = services.projectReports.health(of: project, facts: allFacts)
        rearrange()
    }

    /// Switches to another of the project's views.
    public func selectView(_ id: UUID) {
        guard let match = views.first(where: { $0.id == id }), match.id != activeView?.id else {
            return
        }
        activeView = match
        expandedBugID = nil
        // A search belongs to the moment, not to the view. Carrying it across a tab change would
        // make the next view look mysteriously empty.
        searchText = ""
        rearrange()
    }

    /// Re-runs the arrangement without re-reading the store.
    public func rearrange() {
        guard let activeView else {
            groups = []
            return
        }

        var configuration = activeView.configuration
        // A search is transient and belongs to nobody. Folding it in as a rule here — rather than
        // writing it into the view — is what keeps it out of the saved configuration.
        if let text = searchText.nilIfBlank {
            configuration.filter.rules.append(.text(text))
        }

        groups = WorkItemArrangement.arrange(
            allFacts,
            configuration: configuration,
            vocabulary: vocabulary
        )

        // A sheet open over something that has just been deleted has to close. Asked of `itemsByID`
        // rather than of the repository, which would still find a trashed item and leave the sheet
        // sitting over a ghost.
        if let presentedItemID, itemsByID[presentedItemID] == nil {
            self.presentedItemID = nil
        }
        if let expandedBugID, itemsByID[expandedBugID] == nil {
            self.expandedBugID = nil
        }
        selectedItemIDs.formIntersection(itemsByID.keys)
    }

    public var vocabulary: WorkItemArrangement.Vocabulary {
        let names = collectNames()
        return WorkItemArrangement.Vocabulary(stages: stages.map(\.facts)) { names[$0] }
    }

    /// Titles for everything a group header might need to name.
    private func collectNames() -> [UUID: String] {
        var names: [UUID: String] = [:]
        for item in itemsByID.values {
            if let person = item.assignee() { names[person.id] = person.title }
            if let milestone = item.linkedTarget(kind: .targetsMilestone) {
                names[milestone.id] = milestone.title
            }
            if let release = item.linkedTarget(kind: .relatesToRelease) {
                names[release.id] = release.title
            }
            if let section = item.parent, section.kind == .heading {
                names[section.id] = section.title
            }
        }
        for marker in markers { names[marker.id] = marker.title }
        return names
    }

    // MARK: Derived

    public var visibleOrder: [UUID] {
        groups.flatMap { $0.items.map(\.id) }
    }

    public var visibleCount: Int {
        Set(visibleOrder).count
    }

    public var isFiltered: Bool {
        (activeView?.configuration.isFiltered ?? false) || searchText.nilIfBlank != nil
    }

    /// Nothing in the project at all, as opposed to nothing matching.
    ///
    /// The two need different empty states: one offers to add work, the other offers to clear the
    /// filter, and offering the wrong one is how an empty state becomes a dead end.
    public var isEmpty: Bool {
        allFacts.isEmpty
    }

    public var hasNoMatches: Bool {
        !allFacts.isEmpty && visibleCount == 0
    }

    public func item(_ id: UUID) -> Item? {
        itemsByID[id]
    }

    public var presentedItem: Item? {
        presentedItemID.flatMap { itemsByID[$0] }
    }

    // MARK: Selection

    public func select(_ id: UUID, extending: Bool = false) {
        if extending {
            if selectedItemIDs.contains(id) {
                selectedItemIDs.remove(id)
            } else {
                selectedItemIDs.insert(id)
            }
        } else {
            selectedItemIDs = [id]
        }
        focusedItemID = id
    }

    public func selectRange(to id: UUID) {
        let order = visibleOrder
        guard let anchor = focusedItemID,
              let start = order.firstIndex(of: anchor),
              let end = order.firstIndex(of: id)
        else {
            select(id)
            return
        }
        let range = start <= end ? start...end : end...start
        selectedItemIDs.formUnion(order[range])
        focusedItemID = id
    }

    public func selectAll() {
        selectedItemIDs = Set(visibleOrder)
    }

    public func clearSelection() {
        selectedItemIDs = []
        focusedItemID = nil
    }

    public func moveFocus(by offset: Int) {
        let order = visibleOrder
        guard !order.isEmpty else { return }
        guard let current = focusedItemID, let index = order.firstIndex(of: current) else {
            select(order[0])
            return
        }
        let target = max(0, min(order.count - 1, index + offset))
        select(order[target])
    }

    public var selectedItems: [Item] {
        selectedItemIDs.compactMap { itemsByID[$0] }
    }

    // MARK: Deleting

    /// Sends work to the Trash as one undo step, and moves the selection off the ghosts.
    ///
    /// The selection lands on the nearest surviving row below the deleted ones, or above when
    /// nothing is left below — never on nothing while survivors remain, because a deletion that
    /// empties the selection strands the keyboard back at the top of the list. The sheet, if it
    /// was open over one of the deleted items, is closed by ``rearrange()``.
    public func moveToTrash(_ ids: Set<UUID>) {
        let doomed = ids.compactMap { itemsByID[$0] }
        guard !doomed.isEmpty else { return }

        let order = visibleOrder
        let survivor =
            order.drop(while: { !ids.contains($0) }).first(where: { !ids.contains($0) })
            ?? order.reversed().drop(while: { !ids.contains($0) }).first(where: { !ids.contains($0) })

        guard services.perform({ try services.undo.moveToTrash(doomed) }) else { return }
        for id in ids { services.noteRemoval(of: id) }
        refresh()

        if let survivor {
            select(survivor)
        } else {
            clearSelection()
        }
    }

    public func moveSelectionToTrash() {
        moveToTrash(selectedItemIDs)
    }

    // MARK: Presenting

    /// Opens one completed bug whose fix still needs checking.
    ///
    /// The project health summary deliberately stores counts rather than item identifiers. Resolve
    /// the destination from the same facts the summary counted so its verification concern is a
    /// route to the work, not a status message with no next step.
    @discardableResult
    public func presentFixAwaitingVerification() -> Bool {
        guard let fix = allFacts.first(where: {
            $0.kind == .bug && $0.status == .completed && !$0.isVerified
        }) else { return false }

        select(fix.id)
        present(fix.id)
        return true
    }

    public func present(_ id: UUID) {
        if activeView?.kind == .bugs, itemsByID[id]?.kind == .bug {
            presentedItemID = nil
            expandedBugID = id
        } else {
            expandedBugID = nil
            presentedItemID = id
        }
    }

    public func dismissPresentedItem() {
        presentedItemID = nil
    }

    public func beginRenaming(_ id: UUID) {
        renamingItemID = id
    }

    public func endRenaming() {
        renamingItemID = nil
    }

    /// Whether row-level click gestures may act for this item.
    ///
    /// `false` while its title is being edited in place: the field owns those clicks, and a row
    /// that keeps its tap gesture live under an active `TextField` is how a double-click meant to
    /// select a word in the title threw a sheet over the editor instead.
    public func rowGesturesAreActive(for id: UUID) -> Bool {
        renamingItemID != id
    }

    /// Runs `body` only when nothing is being typed into.
    ///
    /// Every keyboard handler in the workspace goes through this. See ``isEditingText``.
    public func guarded(_ body: () -> Void) -> Bool {
        guard !isEditingText else { return false }
        body()
        return true
    }
}
