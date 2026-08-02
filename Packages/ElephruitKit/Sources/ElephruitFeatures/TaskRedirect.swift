import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// What happens when a task is selected somewhere that cannot draw one.
///
/// ### Why following a link to a task is a navigation now
/// A task has no pane of its own: it opens by making its row taller in the list it lives in. So a
/// backlink, a person's page, a search result or a deep link cannot *show* a task where the click
/// happened — it has to take you to where the task is and open it there. Which is also what somebody
/// following a link to a task wants: not the task in isolation, but the task among the work it
/// belongs to.
///
/// ### Why it redirects rather than offering a button
/// Because the click already was the request. A pane reading "this task is over there" with a button
/// underneath is a second click for a decision nobody is making, and the thing it would say is
/// something the app can simply do. The empty state behind it is what a failed lookup looks like —
/// a trashed task, a store that has moved on — rather than a step in the normal path.
struct TaskRedirect: View {
    @Environment(\.services) private var services

    let task: Item
    let navigation: NavigationModel

    var body: some View {
        EmptyStateView(
            symbolName: "arrow.forward",
            headline: "Opening in Tasks",
            message: "“\(task.displayTitle)” opens in the list it belongs to."
        )
        .task(id: task.id) { redirect() }
        .accessibilityIdentifier("task.redirect")
    }

    private func redirect() {
        navigation.openTask(task.id, in: destination)
    }

    /// The list this task actually appears in.
    ///
    /// A container if it has one — walking up past headings and parent tasks, which are structure
    /// inside a list rather than lists in their own right — and otherwise whichever system view its
    /// dates and marks put it in. See ``ElephruitCore/TaskHome``.
    private var destination: SidebarSelection {
        var cursor = task.parent
        while let candidate = cursor {
            // A project opens as its own workspace rather than as a row in a list, so sending
            // somebody to `.item` would land them on the generic detail for the project instead of
            // the board their work is actually on.
            if candidate.kind == .project {
                return .project(id: candidate.id, viewID: nil)
            }
            if candidate.kind == .list || candidate.kind == .area {
                return .item(id: candidate.id)
            }
            cursor = candidate.parent
        }

        let clock = services?.dateProvider ?? SystemDateProvider()
        let view = TaskHome.systemView(
            for: task.taskFacts(),
            now: clock.now,
            calendar: clock.calendar
        )
        // All Tasks stopped being a sidebar row and became a smart list; the selection has to follow,
        // or the last-resort destination is one nothing draws.
        return view == .all ? .builtInSmartList(id: "all-tasks") : .taskView(view)
    }
}
