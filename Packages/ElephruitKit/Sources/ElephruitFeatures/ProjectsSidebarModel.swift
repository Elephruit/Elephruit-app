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
        unreadCount: Int = 0
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

    /// Rebuilds the tree.
    ///
    /// Called from `AppServices.refreshDerivedState()`, which runs after **every mutation anywhere
    /// in the app** — so this method's cost is paid on every keystroke that saves.
    ///
    /// ### Why it fetches rather than walks
    ///
    /// The obvious shape asked each row for its own numbers: `descendantWork()` for the counts,
    /// `badgeCount` for the unread total, per project *and* per area. That recursively faults the
    /// `children` relationship of every container in the store, and the badge faulted a `notifications`
    /// relationship on every item. Measured at 144ms for the badges and a further 122ms for the walks,
    /// on ten projects of two hundred items — a quarter of a second of blocked main thread per
    /// keystroke, on a library that is not large.
    ///
    /// So it asks only for what it draws. Two narrow fetches — overdue work, unread notifications —
    /// and each result walks *up* to credit its ancestors, which is a to-one hop or two rather than a
    /// recursive descent. The cost is now proportional to the number of things worth showing a mark
    /// for, which is almost always nearly none.
    ///
    /// The completed/total figures went with it. Nothing in the tree draws them: they existed for the
    /// deletion confirmation's "and the 43 items in it", which is now counted at the moment somebody
    /// opens that dialog rather than on every save for every project forever.
    public func refresh(calendar: Calendar = .current) {
        var containerQuery = ItemQuery()
        containerQuery.kinds = [.project, .area]

        var activeQuery = containerQuery
        activeQuery.scope = .active
        var archivedQuery = containerQuery
        archivedQuery.scope = .archived

        let live = (try? items.items(matching: activeQuery)) ?? []
        let archivedItems = (try? items.items(matching: archivedQuery)) ?? []

        let overdue = overdueCountsByContainer(calendar: calendar)
        let unread = inbox.unreadCountsByContainer()

        let areas = live.filter { $0.kind == .area }.sorted { $0.sortOrder < $1.sortOrder }
        let projects = live.filter { $0.kind == .project }

        func makeRow(_ item: Item, depth: Int) -> ProjectSidebarRow {
            row(
                for: item,
                depth: depth,
                overdue: overdue[item.id] ?? 0,
                unread: unread[item.id] ?? 0
            )
        }

        var built: [ProjectSidebarRow] = []
        for area in areas {
            let inside = projects
                .filter { $0.parent?.id == area.id }
                .sorted { $0.sortOrder < $1.sortOrder }
            // An area with no projects is still a row: it is where the next project goes, and a
            // heading that vanishes when you empty it is one you cannot drop into.
            built.append(makeRow(area, depth: 0))
            built.append(contentsOf: inside.map { makeRow($0, depth: 1) })
        }

        let loose = projects
            .filter { $0.parent == nil || $0.parent?.kind != .area }
            .sorted { $0.sortOrder < $1.sortOrder }
        built.append(contentsOf: loose.map { makeRow($0, depth: 0) })

        rows = built
        favourites = built.filter { $0.isFavorite && !$0.isArea }
        archived = archivedItems
            .filter { $0.kind == .project }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { makeRow($0, depth: 0) }
        totalUnread = built.filter { !$0.isArea }.reduce(0) { $0 + $1.unreadCount }
    }

    /// Overdue work per container, from one bounded fetch.
    ///
    /// `dueBefore` is a store-side bound against the `dueSortKey` column, so the rows that come back
    /// are the overdue ones rather than everything-then-filtered. Every ancestor is credited as it
    /// goes, which is what lets an area answer for the projects inside it — an area that read as calm
    /// while a project within it was three weeks late would be worse than no indicator at all.
    private func overdueCountsByContainer(calendar: Calendar) -> [UUID: Int] {
        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = [.open, .none]
        query.dueBefore = calendar.startOfDay(for: dateProvider.now)
        query.scope = .active

        guard let late = try? items.items(matching: query) else { return [:] }

        var counts: [UUID: Int] = [:]
        for item in late {
            var container = item.parent
            var seen: Set<UUID> = []
            while let next = container, seen.insert(next.id).inserted {
                counts[next.id, default: 0] += 1
                container = next.parent
            }
        }
        return counts
    }

    private func row(for item: Item, depth: Int, overdue: Int, unread: Int) -> ProjectSidebarRow {
        ProjectSidebarRow(
            id: item.id,
            title: item.title,
            symbolName: item.symbolName ?? item.kind.symbolName,
            colorName: item.colorName,
            depth: depth,
            isArea: item.kind == .area,
            isFavorite: item.isFavorite,
            isArchived: item.archivedAt != nil,
            overdueCount: overdue,
            unreadCount: unread
        )
    }
}
