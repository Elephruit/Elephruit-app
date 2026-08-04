import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The capture inbox: a queue to empty, not a list to live in.
///
/// Every row offers the four triage moves — open it, make it a task or a note, file it,
/// trash it — as swipes and a context menu, so most items never need their own screen.
struct InboxScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var items: [Item] = []

    var body: some View {
        List {
            ForEach(items) { item in
                MobileItemRow(item: item, onToggleCompletion: item.kind.supportsStatus ? {
                    act(on: item) { try $0.items.toggleCompletion(item) }
                } : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { shell.push(.item(item.id)) }
                    .swipeActions(edge: .leading) {
                        Button {
                            convert(item)
                        } label: {
                            item.kind == .task
                                ? Label("To Note", systemImage: "note.text")
                                : Label("To Task", systemImage: "checkmark.circle")
                        }
                        .tint(Theme.Colors.selection)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            moveToTrash(item)
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        .tint(Theme.Colors.destructive)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.forward.square") {
                            shell.push(.item(item.id))
                        }
                        Button(
                            item.kind == .task ? "Convert to Note" : "Convert to Task",
                            systemImage: item.kind == .task ? "note.text" : "checkmark.circle"
                        ) {
                            convert(item)
                        }
                        fileUnderMenu(item)
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            moveToTrash(item)
                        }
                    }
            }

            if items.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: "tray",
                        headline: "Inbox zero",
                        message: "Everything captured has been filed. That is the whole game.",
                        tone: .accomplished
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: services?.changeToken) { reload() }
    }

    /// The projects and areas something can be filed into, read once per menu open —
    /// the vocabulary is small and already what the capture parser uses.
    @ViewBuilder
    private func fileUnderMenu(_ item: Item) -> some View {
        if let services,
            let containers = try? services.items.items(
                matching: {
                    var query = ItemQuery()
                    query.kinds = [.project, .area, .list]
                    query.sort = .titleAscending
                    return query
                }()
            ), !containers.isEmpty {
            Menu {
                ForEach(containers) { container in
                    Button(container.displayTitle) {
                        act(on: item) { try $0.items.fileItem(item, under: container) }
                    }
                }
            } label: {
                Label("File Under", systemImage: "folder")
            }
        }
    }

    private func convert(_ item: Item) {
        act(on: item) {
            _ = try $0.items.setKind(item, to: item.kind == .task ? .note : .task)
        }
    }

    private func reload() {
        guard let services else { return }
        items = (try? services.items.items(matching: ItemQuery.inbox())) ?? []
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
