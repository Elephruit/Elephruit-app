import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// The mutations behind the work-item sheet.
///
/// A model rather than closures scattered through the view, so that "editing a bug creates its
/// record on the first write and not before" is a fact a test can assert rather than behaviour
/// somebody has to reproduce in a sheet. This is what makes the original report — a bug selected
/// from a project view could not be edited — impossible to reintroduce silently: the whole editing
/// surface routes through here, and here is tested.
///
/// Every method commits immediately. The sheet has no Save button, and a field that waits for one
/// is a field whose edit a force-quit loses.
@MainActor
@Observable
public final class WorkItemEditorModel {
    private let services: AppServices
    public let itemID: UUID

    /// Called after every committed change, so the workspace redraws the row the sheet is editing.
    public var onChange: () -> Void = {}

    public init(services: AppServices, itemID: UUID) {
        self.services = services
        self.itemID = itemID
    }

    // MARK: - Reading

    public var item: Item? {
        try? services.items.item(id: itemID)
    }

    /// The report as it stands, whether or not a record exists yet.
    ///
    /// Reading never creates the record — opening a sheet is not an edit. The defaults mirror what
    /// `Item.taskFacts()` already substitutes for a record-less bug, so the sheet and the row agree
    /// about a freshly filed bug's severity.
    public var bugFacts: BugFacts {
        item?.bugRecord?.facts ?? BugFacts()
    }

    public var isVerified: Bool {
        guard let item else { return false }
        return services.bugs.isVerified(item)
    }

    /// Everyone an item could be assigned to.
    public var assignableCandidates: [Item] {
        (try? services.persons.allPeople(includingPlaceholders: false)) ?? []
    }

    // MARK: - The item's own fields

    public func setTitle(_ title: String) {
        guard let item, let name = title.nilIfBlank, name != item.title else { return }
        commit { try services.workItems.setTitle(name, on: item) }
    }

    public func setBody(_ body: String) {
        guard let item, body != item.body else { return }
        commit { try services.items.update(item) { $0.body = body } }
    }

    /// Open, Completed or Cancelled, through the task lifecycle rather than a raw field write, so a
    /// recurring item still rolls forward and completion invariants hold in one place.
    public func setStatus(_ status: ItemStatus) {
        guard let item, item.status != status else { return }
        commit {
            switch status {
            case .completed: _ = try services.tasks.complete(item)
            case .cancelled: try services.tasks.cancel(item)
            case .open, .none: try services.tasks.reopen(item)
            }
        }
    }

    public func setPriority(_ priority: Priority) {
        guard let item, item.priority != priority else { return }
        commit { try services.workItems.setPriority(priority, on: item) }
    }

    public func setEstimate(minutes: Int?) {
        guard let item, item.estimateMinutes != minutes else { return }
        commit { try services.workItems.setEstimate(minutes, on: item) }
    }

    public func setDueDate(_ date: Date?) {
        guard let item else { return }
        commit { try services.workItems.setDueDate(date, on: item) }
    }

    public func setStage(_ stage: WorkflowStage?) {
        guard let item, item.workflowStageID != stage?.id else { return }
        commit { _ = try services.projectWorkspace.move(item, to: stage) }
    }

    public func setAssignee(_ person: Item?) {
        guard let item, item.assignee()?.id != person?.id else { return }
        commit { try services.workItems.assign(item, to: person) }
    }

    public func setMilestone(_ milestone: Item?) {
        guard let item, item.linkedTarget(kind: .targetsMilestone)?.id != milestone?.id else { return }
        commit { try services.workItems.setMilestone(milestone, on: item) }
    }

    public func setRelease(_ release: Item?) {
        guard let item, item.linkedTarget(kind: .relatesToRelease)?.id != release?.id else { return }
        commit { try services.workItems.setRelease(release, on: item) }
    }

    // MARK: - The bug's report

    /// Edits the report, creating the record on this first write if the bug never had one.
    ///
    /// This is the intended lazy-creation path: a bug filed in eight seconds with only a title has
    /// no `BugRecord`, and the record appears the moment somebody has something to record. Routing
    /// through ``BugService/update(_:_:)`` also reindexes the owning item, so new reproduction
    /// steps are findable.
    public func updateBug(_ mutate: (inout BugFacts) -> Void) {
        guard let item, item.kind == .bug else { return }
        commit { try services.bugs.update(item, mutate) }
    }

    public func setSeverity(_ severity: BugSeverity) {
        updateBug { $0.severity = severity }
    }

    public func setVerified(_ verified: Bool) {
        guard let item, item.kind == .bug else { return }
        commit {
            if verified {
                try services.bugs.markVerified(item)
            } else {
                try services.bugs.clearVerification(item)
            }
        }
    }

    // MARK: - Committing

    private func commit(_ work: () throws -> Void) {
        guard services.perform(work) else { return }
        if let item { services.noteChange(to: item) }
        onChange()
    }
}
