import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What a swipe offers, per module.
///
/// ### Why the gesture layer does not decide any of this
/// `SwipeAction` carries a closure and nothing else, because "delete" is four different operations
/// in this app. A task linked to a reminder cannot be deleted without a decision about the reminder;
/// a row already in the Trash is a permanent deletion and nothing can bring it back; everything else
/// is a move to the Trash that `⌘Z` reverses. A shared gesture layer that picked one of those would
/// be picking wrongly for the other three.
///
/// ### What a full swipe is allowed to do
/// Only a move to the Trash, and only where it is undoable. A permanent deletion and a deletion that
/// reaches into somebody's iCloud account both stop at revealing the button, so that the last thing
/// between the data and its destruction is a click rather than the distance a finger travelled.
@MainActor
enum RowSwipeActions {
    // MARK: - Tasks

    /// Swipe right: the three things done to a task far more often than anything else.
    static func taskLeading(
        _ task: Item,
        services: AppServices?,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        var actions: [SwipeAction] = []

        actions.append(
            SwipeAction(
                id: "task.complete",
                title: task.status == .completed ? "Reopen" : "Complete",
                systemImage: task.status == .completed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                tint: Theme.Colors.completed
            ) {
                services.perform {
                    if task.status == .completed {
                        try services.reminderLifecycle.reopen(task)
                    } else {
                        let outcome = try services.reminderLifecycle.complete(task)
                        if outcome.needsReminderPush {
                            Task { await services.reminders.sync(using: services.reminderSync) }
                        }
                    }
                    services.noteChange(to: task)
                }
                onChange()
            }
        )

        let isOnToday = task.isCommittedTo(today: services.dateProvider)
        actions.append(
            SwipeAction(
                id: "task.today",
                title: isOnToday ? "Off Today" : "Today",
                systemImage: isOnToday ? "calendar.badge.minus" : "sun.max",
                tint: Theme.Colors.dueToday
            ) {
                services.perform {
                    if isOnToday {
                        try services.reminderLifecycle.removeFromToday(task)
                    } else {
                        try services.reminderLifecycle.commitToToday(task)
                    }
                    services.noteChange(to: task)
                }
                onChange()
            }
        )

        actions.append(
            SwipeAction(
                id: "task.flag",
                title: task.isFlagged ? "Unflag" : "Flag",
                systemImage: "flag",
                tint: Theme.Colors.favorite
            ) {
                services.perform {
                    try services.reminderLifecycle.setFlagged(!task.isFlagged, on: task)
                    services.noteChange(to: task)
                }
                onChange()
            }
        )

        return actions
    }

    /// Swipe left: the Trash, unless a reminder is in the way.
    ///
    /// A task Elephruit owns goes to the Trash as one undo step. A task linked to Apple Reminders
    /// does not, because deleting somebody's reminder out of an iCloud account — where it may be
    /// shared with other people — is not a recoverable mistake. That one asks first, which is the
    /// same rule its context menu already follows by offering two commands rather than one.
    static func taskTrailing(
        _ task: Item,
        services: AppServices?,
        onLinkedDeletion: @escaping (Item) -> Void,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        guard task.syncState == .local else {
            return [
                SwipeAction(
                    id: "task.delete.linked",
                    title: "Delete…",
                    systemImage: "trash",
                    role: .destructive,
                    isFullSwipeDefault: false
                ) {
                    onLinkedDeletion(task)
                }
            ]
        }

        return [
            SwipeAction(
                id: "task.trash",
                title: "Trash",
                systemImage: "trash",
                armedSystemImage: "trash.fill",
                role: .destructive,
                isFullSwipeDefault: true
            ) {
                let id = task.id
                services.perform { try services.undo.moveToTrash([task]) }
                services.refreshDerivedState()
                services.noteRemoval(of: id)
                onChange()
            }
        ]
    }

    /// Whether a task's trailing swipe may be completed by the gesture alone.
    static func taskAllowsFullSwipe(_ task: Item) -> Bool {
        task.syncState == .local
    }

    // MARK: - Items

    /// Swipe right, for a note, a bookmark, a project — anything the generic list draws.
    static func itemLeading(
        _ item: Item,
        services: AppServices?,
        isTrashScope: Bool,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        guard !isTrashScope else {
            return [
                SwipeAction(
                    id: "item.restore",
                    title: "Put Back",
                    systemImage: "arrow.uturn.backward",
                    tint: Theme.Colors.completed
                ) {
                    services.perform { try services.undo.restore(ids: [item.id]) }
                    services.noteChange(to: item)
                    onChange()
                }
            ]
        }

        var actions: [SwipeAction] = []

        if item.kind.supportsStatus {
            actions.append(
                SwipeAction(
                    id: "item.complete",
                    title: item.isCompleted ? "Reopen" : "Complete",
                    systemImage: item.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    tint: Theme.Colors.completed
                ) {
                    services.perform { try services.items.toggleCompletion(item) }
                    services.noteChange(to: item)
                    onChange()
                }
            )
        }

        actions.append(
            SwipeAction(
                id: "item.archive",
                title: item.isArchived ? "Unarchive" : "Archive",
                systemImage: "archivebox",
                tint: Theme.Colors.selection
            ) {
                services.perform { try services.items.setArchived(item, !item.isArchived) }
                services.noteChange(to: item)
                onChange()
            }
        )

        actions.append(
            SwipeAction(
                id: "item.pin",
                title: item.isPinned ? "Unpin" : "Pin",
                systemImage: "pin",
                tint: Theme.Colors.favorite
            ) {
                services.perform { try services.items.update(item) { $0.isPinned.toggle() } }
                services.noteChange(to: item)
                services.refreshDerivedState()
                onChange()
            }
        )

        return actions
    }

    /// Swipe left: the Trash, or — in the Trash — the end.
    ///
    /// The Trash is the one view in this app that genuinely *is* a permanent-delete context, so it
    /// is the one view where a swipe offers a permanent deletion at all. It still stops at the
    /// button: a gesture cannot finish it, and clicking it asks first, because nothing brings this
    /// one back.
    static func itemTrailing(
        _ item: Item,
        services: AppServices?,
        isTrashScope: Bool,
        onPermanentDeletion: @escaping (Item) -> Void,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        guard !isTrashScope else {
            return [
                SwipeAction(
                    id: "item.deletePermanently",
                    title: "Delete…",
                    systemImage: "xmark.bin",
                    role: .destructive,
                    isFullSwipeDefault: false
                ) {
                    onPermanentDeletion(item)
                }
            ]
        }

        return [
            SwipeAction(
                id: "item.trash",
                title: "Trash",
                systemImage: "trash",
                armedSystemImage: "trash.fill",
                role: .destructive,
                isFullSwipeDefault: true
            ) {
                let id = item.id
                services.perform { try services.undo.moveToTrash([item]) }
                services.refreshDerivedState()
                services.noteRemoval(of: id)
                onChange()
            }
        ]
    }

    // MARK: - People

    static func personLeading(
        _ person: Item,
        services: AppServices?,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        return [
            SwipeAction(
                id: "person.favorite",
                title: person.isFavorite ? "Unstar" : "Star",
                systemImage: "star",
                tint: Theme.Colors.favorite
            ) {
                services.perform { try services.items.update(person) { $0.isFavorite.toggle() } }
                services.noteChange(to: person)
                onChange()
            },
            SwipeAction(
                id: "person.pin",
                title: person.isPinned ? "Unpin" : "Pin",
                systemImage: "pin",
                tint: Theme.Colors.selection
            ) {
                services.perform { try services.items.update(person) { $0.isPinned.toggle() } }
                services.noteChange(to: person)
                services.refreshDerivedState()
                onChange()
            },
        ]
    }

    static func personTrailing(
        _ person: Item,
        services: AppServices?,
        onChange: @escaping () -> Void
    ) -> [SwipeAction] {
        guard let services else { return [] }

        return [
            SwipeAction(
                id: "person.trash",
                title: "Trash",
                systemImage: "trash",
                armedSystemImage: "trash.fill",
                role: .destructive,
                isFullSwipeDefault: true
            ) {
                let id = person.id
                services.perform { try services.undo.moveToTrash([person]) }
                services.refreshDerivedState()
                services.noteRemoval(of: id)
                onChange()
            }
        ]
    }
}

/// The generic list's swipe set, as a modifier.
///
/// A modifier rather than a call at each of the two places `ItemListView` draws rows, because the
/// two are the same list with and without a calendar band above it and the actions must not be able
/// to drift apart between them.
struct ItemSwipeActions: ViewModifier {
    @Environment(\.services) private var services

    let item: Item
    let navigation: NavigationModel
    let onPermanentDeletion: (Item) -> Void
    let onChange: () -> Void

    func body(content: Content) -> some View {
        let isTrash = navigation.selection.showsTrashedItems

        content.rowSwipeActions(
            id: item.id,
            leading: RowSwipeActions.itemLeading(
                item,
                services: services,
                isTrashScope: isTrash,
                onChange: onChange
            ),
            trailing: RowSwipeActions.itemTrailing(
                item,
                services: services,
                isTrashScope: isTrash,
                onPermanentDeletion: onPermanentDeletion,
                onChange: onChange
            ),
            // The Trash is a permanent-delete context, and that is precisely why the gesture stops
            // short there: a swipe may reveal the button and never press it.
            allowsFullSwipe: !isTrash
        )
    }
}
