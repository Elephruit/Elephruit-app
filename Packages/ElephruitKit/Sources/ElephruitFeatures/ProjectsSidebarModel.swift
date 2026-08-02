import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

/// One row of the Projects tree.
///
/// A value, computed off-render. The `SidebarModel`/`FetchAudit` contract is that nothing touches
/// the store while a list is drawing, and a tree of projects is exactly the shape that tempts you to
/// — every row would otherwise fault in its children to count them.
public struct ProjectSidebarRow: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var symbolName: String
    public var colorName: String?

    /// How deep in the Area ▸ Project tree this sits.
    public var depth: Int

    public var isArea: Bool
    public var isFavorite: Bool
    public var isArchived: Bool

    /// Work past its deadline, anywhere beneath this row.
    public var overdueCount: Int

    /// Unread notifications, anywhere beneath this row.
    public var unreadCount: Int

    public var completedWork: Int
    public var totalWork: Int

    /// Whether this row has anything worth drawing beside the name.
    ///
    /// **Progress is deliberately excluded.** A partial arc beside a project's name is a mark people
    /// notice and cannot read — is that a third done or a third left? — and it was on every row at
    /// once, so it drew the eye everywhere and therefore nowhere. The figure belongs on the project
    /// header, in words. An overdue dot and an unread count are different: they are absent almost
    /// always, so when they appear they mean something.
    public var hasIndicators: Bool {
        overdueCount > 0 || unreadCount > 0
    }

    public init(
        id: UUID,
        title: String,
        symbolName: String,
        colorName: String? = nil,
        depth: Int = 0,
        isArea: Bool = false,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        overdueCount: Int = 0,
        unreadCount: Int = 0,
        completedWork: Int = 0,
        totalWork: Int = 0
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.colorName = colorName
        self.depth = depth
        self.isArea = isArea
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.overdueCount = overdueCount
        self.unreadCount = unreadCount
        self.completedWork = completedWork
        self.totalWork = totalWork
    }
}

/// The Projects tree, recomputed on change and never during a render.
@MainActor
@Observable
public final class ProjectsSidebarModel {
    /// The Area ▸ Project tree, in display order and already flattened.
    public private(set) var rows: [ProjectSidebarRow] = []

    /// Favourites, hoisted into their own band.
    public private(set) var favourites: [ProjectSidebarRow] = []

    /// Archived projects, behind a disclosure.
    public private(set) var archived: [ProjectSidebarRow] = []

    public private(set) var totalUnread: Int = 0

    private let items: any ItemRepository
    private let inbox: InboxService
    private let dateProvider: any DateProvider

    public init(items: any ItemRepository, inbox: InboxService, dateProvider: any DateProvider) {
        self.items = items
        self.inbox = inbox
        self.dateProvider = dateProvider
    }

    public var isEmpty: Bool {
        rows.isEmpty && favourites.isEmpty && archived.isEmpty
    }

    /// Rebuilds the tree. Called from `AppServices.refreshDerivedState()`, never from a view body.
    public func refresh(calendar: Calendar = .current) {
        var query = ItemQuery()
        query.kinds = [.project, .area]
        query.scope = .active

        var activeQuery = query
        activeQuery.scope = .active
        var archivedQuery = query
        archivedQuery.scope = .archived

        let live = (try? items.items(matching: activeQuery)) ?? []
        let put_away = (try? items.items(matching: archivedQuery)) ?? []

        let areas = live.filter { $0.kind == .area }.sorted { $0.sortOrder < $1.sortOrder }
        let projects = live.filter { $0.kind == .project }

        var built: [ProjectSidebarRow] = []
        for area in areas {
            let inside = projects
                .filter { $0.parent?.id == area.id }
                .sorted { $0.sortOrder < $1.sortOrder }
            // An area with no projects is still a row — it is where the next project goes, and a
            // heading that disappears when you empty it is one you cannot drop into.
            built.append(row(for: area, depth: 0, calendar: calendar))
            built.append(contentsOf: inside.map { row(for: $0, depth: 1, calendar: calendar) })
        }

        let loose = projects
            .filter { $0.parent == nil || $0.parent?.kind != .area }
            .sorted { $0.sortOrder < $1.sortOrder }
        built.append(contentsOf: loose.map { row(for: $0, depth: 0, calendar: calendar) })

        rows = built
        favourites = built.filter { $0.isFavorite && !$0.isArea }
        archived = put_away
            .filter { $0.kind == .project }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { row(for: $0, depth: 0, calendar: calendar) }
        totalUnread = built.reduce(0) { $0 + $1.unreadCount }
    }

    private func row(for item: Item, depth: Int, calendar: Calendar) -> ProjectSidebarRow {
        // `descendantWork`, not `descendantTasks`, and this is the whole reason that method exists.
        // An area asking "is anything under me late?" has to descend through the projects inside it —
        // an area that reads as calm while a project within it is three weeks overdue is worse than
        // no indicator at all.
        let work = item.descendantWork()
        let today = calendar.startOfDay(for: dateProvider.now)

        let overdue = work.filter { candidate in
            guard candidate.status == .open || candidate.status == .none else { return false }
            guard let due = candidate.dueAt else { return false }
            return calendar.startOfDay(for: due) < today
        }.count

        return ProjectSidebarRow(
            id: item.id,
            title: item.title,
            symbolName: item.symbolName ?? item.kind.symbolName,
            colorName: item.colorName,
            depth: depth,
            isArea: item.kind == .area,
            isFavorite: item.isFavorite,
            isArchived: item.archivedAt != nil,
            overdueCount: overdue,
            unreadCount: inbox.badgeCount(for: item),
            completedWork: work.filter { $0.status == .completed }.count,
            totalWork: work.count
        )
    }
}
