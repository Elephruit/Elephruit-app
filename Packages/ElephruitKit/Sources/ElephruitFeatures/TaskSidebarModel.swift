import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// Everything the Tasks band of the sidebar reads, computed away from the view.
///
/// The view reads stored values and performs **no** store access while rendering — the rule
/// `SidebarModel` already establishes, and the one `FetchAudit` exists to prove. It matters more
/// here than elsewhere: a badge on Today is a whole scheduling evaluation over every open task, and
/// doing that inside a `body` would run it on every keystroke in the search field.
@Observable
@MainActor
public final class TaskSidebarModel {
    /// The two counts that are shown. Deliberately a dictionary rather than two properties, so
    /// adding a badge is a change in one place and removing one cannot leave a stale reader.
    public private(set) var badges: [TaskSystemView: Int] = [:]

    /// Areas, with their projects and lists beneath them.
    public private(set) var containers: [TasksSidebarSection.ContainerRow] = []

    /// The user's own smart lists, in sidebar order.
    public private(set) var smartLists: [SavedSearch] = []

    /// How many linked tasks are waiting for the user to decide something.
    ///
    /// Surfaced so the Reminders row can say so quietly rather than the app either nagging or
    /// staying silent about a sync that has stopped working.
    public private(set) var syncNeedsAttention = 0

    @ObservationIgnored private let items: any ItemRepository
    @ObservationIgnored private let views: TaskViewService

    public init(items: any ItemRepository, views: TaskViewService) {
        self.items = items
        self.views = views
    }

    /// Recomputes. Called on change, never during rendering.
    ///
    /// This runs after every save, so what it asks matters: the badges come from one pass over the
    /// open tasks rather than one fetch per badge, and the sync count is a store-side count rather
    /// than a materialisation of every work item ever resolved.
    public func refresh() {
        badges = (try? views.badgeCounts()) ?? [:]
        containers = computeContainers()
        smartLists = views.smartLists()
        syncNeedsAttention = views.syncAttentionCount()
    }

    /// The container tree, flattened with a depth on each row.
    ///
    /// Flattened rather than nested because `List` draws rows, and a two-level tree expressed as
    /// nested `DisclosureGroup`s inside a sidebar section loses keyboard navigation between the
    /// levels. Depth as an inset gives the same reading with none of that lost.
    private func computeContainers() -> [TasksSidebarSection.ContainerRow] {
        var query = ItemQuery()
        query.kinds = [.area, .project, .list]
        query.sort = .manual
        guard let all = try? items.items(matching: query) else { return [] }

        let areas = all.filter { $0.kind == .area }
        let orphans = all.filter { $0.kind != .area && $0.parent == nil }

        var rows: [TasksSidebarSection.ContainerRow] = []

        func row(for item: Item, depth: Int) -> TasksSidebarSection.ContainerRow {
            TasksSidebarSection.ContainerRow(
                id: item.id,
                title: item.displayTitle,
                symbolName: item.effectiveSymbolName,
                colorName: item.colorName,
                depth: depth,
                progress: progress(for: item),
                kind: item.kind
            )
        }

        for area in areas {
            rows.append(row(for: area, depth: 0))
            let children = area.children
                .filter { ($0.kind == .project || $0.kind == .list) && $0.deletedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            rows.append(contentsOf: children.map { row(for: $0, depth: 1) })
        }

        // Top-level projects and lists come last rather than first: they are the ones that have not
        // been filed anywhere, and opening the section on unfiled work would bury the structure the
        // user built.
        rows.append(contentsOf: orphans.map { row(for: $0, depth: 0) })
        return rows
    }

    /// Progress, where it means anything.
    ///
    /// `nil` for an area and for a list, both of which are ongoing by definition. `nil` also for a
    /// project with no tasks: an empty project is not a project 0% done, and drawing it as one is an
    /// accusation about work that has not been broken down yet.
    private func progress(for item: Item) -> Double? {
        guard item.kind == .project else { return nil }
        let counts = item.taskProgress()
        guard counts.total > 0 else { return nil }
        return Double(counts.completed) / Double(counts.total)
    }
}
