import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A flat list of items — one kind, one tag, or the archive.
struct ItemListScreen: View {
    enum Source: Hashable {
        case kind(ItemKind)
        case tag(String)
        case archive
    }

    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let source: Source

    @State private var items: [Item] = []

    var body: some View {
        List {
            ForEach(items) { item in
                MobileItemRow(item: item, onToggleCompletion: toggleAction(for: item))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        shell.push(MobileShellModel.route(for: item.kind, id: item.id))
                    }
                    .swipeActions(edge: .trailing) {
                        if case .archive = source {
                            Button {
                                act(on: item) { try $0.items.setArchived(item, false) }
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }
                            .tint(Theme.Colors.selection)
                        }
                        Button {
                            moveToTrash(item)
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        .tint(Theme.Colors.destructive)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.forward.square") {
                            shell.push(MobileShellModel.route(for: item.kind, id: item.id))
                        }
                        if item.archivedAt == nil {
                            Button("Archive", systemImage: "archivebox") {
                                act(on: item) { try $0.items.setArchived(item, true) }
                            }
                        } else {
                            Button("Unarchive", systemImage: "tray.and.arrow.up") {
                                act(on: item) { try $0.items.setArchived(item, false) }
                            }
                        }
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            moveToTrash(item)
                        }
                    }
            }

            if items.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .kind(let kind) = source, creatableKinds.contains(kind) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createItem(of: kind)
                    } label: {
                        Label("New \(kind.displayName)", systemImage: "plus")
                    }
                }
            }
        }
        .task(id: services?.changeToken) { reload() }
    }

    private let creatableKinds: Set<ItemKind> = [.note, .bookmark, .area, .list, .idea, .reference]

    private var title: String {
        switch source {
        case .kind(let kind): kind.pluralDisplayName
        case .tag(let slug): "#\(slug)"
        case .archive: "Archive"
        }
    }

    private var emptyState: some View {
        switch source {
        case .kind(let kind):
            EmptyStateView(
                symbolName: kind.symbolName,
                headline: "No \(kind.pluralDisplayName.lowercased()) yet",
                message: creatableKinds.contains(kind)
                    ? "Make the first one with the + above, or capture one from anywhere."
                    : nil
            )
        case .tag(let slug):
            EmptyStateView(
                symbolName: "number",
                headline: "Nothing tagged #\(slug)",
                message: "Type #\(slug) while capturing to file things here."
            )
        case .archive:
            EmptyStateView(
                symbolName: "archivebox",
                headline: "Nothing archived",
                message: "Archiving keeps something out of the way without deleting it."
            )
        }
    }

    private func toggleAction(for item: Item) -> (() -> Void)? {
        guard item.kind.supportsStatus else { return nil }
        return {
            withCalmAnimation(Theme.Motion.standard) {
                act(on: item) { try $0.items.toggleCompletion(item) }
            }
        }
    }

    private func createItem(of kind: ItemKind) {
        guard let services else { return }
        services.perform {
            let created = try services.items.create(ItemDraft(kind: kind))
            services.noteChange(to: created)
            shell.push(.item(created.id))
        }
    }

    private func reload() {
        guard let services else { return }
        let query: ItemQuery
        switch source {
        case .kind(let kind): query = ItemQuery.kind(kind)
        case .tag(let slug): query = ItemQuery.tag(slug: slug)
        case .archive: query = ItemQuery.archive()
        }
        items = (try? services.items.items(matching: query)) ?? []
    }

    private func act(on item: Item, _ work: (AppServices) throws -> Void) {
        guard let services else { return }
        services.perform {
            try work(services)
            services.noteChange(to: item)
        }
        reload()
    }

    private func moveToTrash(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
        reload()
    }
}
