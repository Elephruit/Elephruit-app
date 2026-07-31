import ElephruitCore
import ElephruitModel
import Foundation

/// A structural change that can be reversed.
///
/// ### Why not SwiftData's own undo manager
/// `ModelContext.undoManager` reverses *context changes*, which sounds like what is wanted and is
/// not. It undoes at the granularity of whatever the framework happened to record, it cannot be
/// named ("Undo Move to Trash" rather than "Undo"), and — as `ItemRestorePoint` already documents —
/// SwiftData's rollback does not reliably restore values on live objects.
///
/// So structural undo is explicit. Each action records what it needs to reverse itself, keyed by
/// identifier rather than by object, so nothing holds a `PersistentModel` past its context.
public enum StructuralChange: Sendable {
    case movedToTrash(ids: [UUID])
    case restoredFromTrash(ids: [UUID])
    case archived(ids: [UUID], archived: Bool)
    case retagged(previous: [UUID: [String]])
    case statusChanged(previous: [UUID: (status: ItemStatus, completedAt: Date?)])
    case reparented(previous: [UUID: UUID?])

    /// What the menu item says. "Undo" alone tells the user nothing about what is about to happen.
    public var actionName: String {
        switch self {
        case .movedToTrash(let ids):
            ids.count == 1 ? "Move to Trash" : "Move \(ids.count) Items to Trash"
        case .restoredFromTrash(let ids):
            ids.count == 1 ? "Put Back" : "Put Back \(ids.count) Items"
        case .archived(let ids, let archived):
            archived
                ? (ids.count == 1 ? "Archive" : "Archive \(ids.count) Items")
                : (ids.count == 1 ? "Unarchive" : "Unarchive \(ids.count) Items")
        case .retagged(let previous):
            previous.count == 1 ? "Change Tags" : "Change Tags on \(previous.count) Items"
        case .statusChanged(let previous):
            previous.count == 1 ? "Change Status" : "Change Status on \(previous.count) Items"
        case .reparented(let previous):
            previous.count == 1 ? "Move" : "Move \(previous.count) Items"
        }
    }
}

/// Applies and reverses structural changes.
///
/// Sits between the repository and `UndoManager`: the repository knows how to mutate, `UndoManager`
/// knows how to sequence, and this knows what the inverse of each mutation is.
///
/// Every operation is keyed by `UUID`. An undo that held object references would break the moment
/// the context that owned them went away, which is exactly when an undo is most likely to be used.
@MainActor
public final class StructuralUndoCoordinator {
    private let items: any ItemRepository
    private let undoManager: UndoManager

    public init(items: any ItemRepository, undoManager: UndoManager) {
        self.items = items
        self.undoManager = undoManager
    }

    // MARK: - Grouping

    /// Combines several *different* operations into one undo step.
    ///
    /// Not needed for a batch of the same operation — every method here takes an array and registers
    /// a single inverse for it, so retagging twenty items is already one `⌘Z`. This is for the case
    /// where one user action performs, say, a move and a retag together.
    ///
    /// Never call this from inside an undo: nesting a group within `UndoManager`'s own aborts.
    public func batch<Result>(_ body: () throws -> Result) rethrows -> Result {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try body()
    }

    // MARK: - Operations

    public func moveToTrash(_ targets: [Item]) throws(AppError) {
        let ids = targets.map(\.id)
        guard !ids.isEmpty else { return }

        try grouped {
            for item in targets {
                try items.moveToTrash(item)
            }
            register(.movedToTrash(ids: ids)) { coordinator in
                try coordinator.restore(ids: ids, registeringUndo: true)
            }
        }
    }

    public func restore(ids: [UUID], registeringUndo: Bool = true) throws(AppError) {
        guard !ids.isEmpty else { return }

        try grouped {
            for id in ids {
                guard let item = try items.item(id: id) else { continue }
                try items.restore(item)
            }
            guard registeringUndo else { return }
            register(.restoredFromTrash(ids: ids)) { coordinator in
                guard let targets = try coordinator.resolve(ids) else { return }
                try coordinator.moveToTrash(targets)
            }
        }
    }

    public func setArchived(_ targets: [Item], _ archived: Bool) throws(AppError) {
        let ids = targets.map(\.id)
        guard !ids.isEmpty else { return }

        try grouped {
            for item in targets {
                try items.setArchived(item, archived)
            }
            register(.archived(ids: ids, archived: archived)) { coordinator in
                guard let targets = try coordinator.resolve(ids) else { return }
                try coordinator.setArchived(targets, !archived)
            }
        }
    }

    public func setTags(_ targets: [Item], slugs: [String]) throws(AppError) {
        guard !targets.isEmpty else { return }

        // Captured before the change, so the inverse restores exactly what each item had — not a
        // shared "previous" that would flatten twenty different tag sets into one.
        let previous = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.tagSlugs) })

        try grouped {
            for item in targets {
                try items.setTags(item, slugs: slugs)
            }
            register(.retagged(previous: previous)) { coordinator in
                try coordinator.restoreTags(previous)
            }
        }
    }

    public func restoreTags(_ previous: [UUID: [String]]) throws(AppError) {
        try grouped {
            var inverse: [UUID: [String]] = [:]
            for (id, slugs) in previous {
                guard let item = try items.item(id: id) else { continue }
                inverse[id] = item.tagSlugs
                try items.setTags(item, slugs: slugs)
            }
            register(.retagged(previous: inverse)) { coordinator in
                try coordinator.restoreTags(inverse)
            }
        }
    }

    public func toggleCompletion(_ targets: [Item]) throws(AppError) {
        guard !targets.isEmpty else { return }

        let previous = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, (status: $0.status, completedAt: $0.completedAt)) }
        )

        try grouped {
            for item in targets where item.kind.supportsStatus {
                try items.toggleCompletion(item)
            }
            register(.statusChanged(previous: previous)) { coordinator in
                try coordinator.restoreStatus(previous)
            }
        }
    }

    public func restoreStatus(_ previous: [UUID: (status: ItemStatus, completedAt: Date?)]) throws(AppError) {
        try grouped {
            var inverse: [UUID: (status: ItemStatus, completedAt: Date?)] = [:]
            for (id, state) in previous {
                guard let item = try items.item(id: id) else { continue }
                inverse[id] = (item.status, item.completedAt)
                try items.update(item) { subject in
                    subject.status = state.status
                    subject.completedAt = state.completedAt
                }
            }
            register(.statusChanged(previous: inverse)) { coordinator in
                try coordinator.restoreStatus(inverse)
            }
        }
    }

    public func setParent(_ targets: [Item], to parent: Item?) throws(AppError) {
        guard !targets.isEmpty else { return }

        let previous = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.parent?.id) })

        try grouped {
            for item in targets {
                try items.setParent(item, to: parent)
            }
            register(.reparented(previous: previous)) { coordinator in
                try coordinator.restoreParents(previous)
            }
        }
    }

    public func restoreParents(_ previous: [UUID: UUID?]) throws(AppError) {
        try grouped {
            var inverse: [UUID: UUID?] = [:]
            for (id, parentID) in previous {
                guard let item = try items.item(id: id) else { continue }
                inverse[id] = item.parent?.id

                let parent = try parentID.flatMap { try items.item(id: $0) }
                try items.setParent(item, to: parent)
            }
            register(.reparented(previous: inverse)) { coordinator in
                try coordinator.restoreParents(inverse)
            }
        }
    }

    // MARK: - Registration

    /// Registers the inverse with `UndoManager`, named so the menu reads properly.
    ///
    /// The closure takes the coordinator rather than capturing `self`, so an undo stack outliving a
    /// window cannot keep it alive.
    private func register(
        _ change: StructuralChange,
        inverse: @escaping @MainActor (StructuralUndoCoordinator) throws -> Void
    ) {
        undoManager.setActionName(change.actionName)
        undoManager.registerUndo(withTarget: self) { coordinator in
            MainActor.assumeIsolated {
                do {
                    try inverse(coordinator)
                } catch {
                    Diagnostics.persistence.error(
                        "Undo failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func resolve(_ ids: [UUID]) throws(AppError) -> [Item]? {
        var resolved: [Item] = []
        for id in ids {
            guard let item = try items.item(id: id) else { continue }
            resolved.append(item)
        }
        return resolved.isEmpty ? nil : resolved
    }

    /// Runs an operation's mutations *and* its undo registration inside one group.
    ///
    /// Both must be inside it. `UndoManager` with `groupsByEvent` off raises
    /// `NSInternalInconsistencyException` — "must begin a group before registering undo" — if
    /// `registerUndo` is called with no group open, which is what happens if the group closes around
    /// the mutations alone. Nesting inside the group `UndoManager` opens during an undo is fine;
    /// nested groups are supported and are how redo registration works.
    ///
    /// Untyped `throws` for the same reason `AppServices.perform` uses it: a closure literal with
    /// several throwing calls does not reliably infer a typed-throws signature.
    private func grouped(_ body: () throws -> Void) throws(AppError) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }

        do {
            try body()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
