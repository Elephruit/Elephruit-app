import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation

public struct ContainerSidebarEntry: Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var symbolName: String
    public var colorName: String?
    public var depth: Int
    public var progress: Double?
    public var kind: ItemKind

    public init(
        id: UUID,
        title: String,
        symbolName: String,
        colorName: String? = nil,
        depth: Int = 0,
        progress: Double? = nil,
        kind: ItemKind = .project
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.colorName = colorName
        self.depth = depth
        self.progress = progress
        self.kind = kind
    }
}

/// The area, project, and list tree shared by the primary sidebar.
///
/// Values are recomputed after writes so rendering never performs store access.
@Observable
@MainActor
public final class ContainerSidebarModel {
    public private(set) var containers: [ContainerSidebarEntry] = []

    @ObservationIgnored private let items: any ItemRepository

    public init(items: any ItemRepository) {
        self.items = items
    }

    public func refresh() {
        containers = computeContainers()
    }

    private func computeContainers() -> [ContainerSidebarEntry] {
        var query = ItemQuery()
        query.kinds = [.area, .project, .list]
        query.sort = .manual
        guard let all = try? items.items(matching: query) else { return [] }

        let areas = all.filter { $0.kind == .area }
        let orphans = all.filter { $0.kind != .area && $0.parent == nil }
        var rows: [ContainerSidebarEntry] = []

        func row(for item: Item, depth: Int) -> ContainerSidebarEntry {
            ContainerSidebarEntry(
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
            let children = (area.children ?? [])
                .filter { ($0.kind == .project || $0.kind == .list) && $0.deletedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            rows.append(contentsOf: children.map { row(for: $0, depth: 1) })
        }

        rows.append(contentsOf: orphans.map { row(for: $0, depth: 0) })
        return rows
    }

    private func progress(for item: Item) -> Double? {
        guard item.kind == .project else { return nil }
        let counts = item.taskProgress()
        guard counts.total > 0 else { return nil }
        return Double(counts.completed) / Double(counts.total)
    }
}
