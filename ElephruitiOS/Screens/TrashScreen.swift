import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The Trash: everything recoverable, each row saying when it was deleted, with Put Back
/// one swipe away and permanent deletion always a separate, explicit act.
struct TrashScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var items: [Item] = []
    @State private var confirmingEmpty = false
    @State private var confirmingDelete: Item?

    var body: some View {
        List {
            ForEach(items) { item in
                MobileItemRow(item: item)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            restore(item)
                        } label: {
                            Label("Put Back", systemImage: "arrow.uturn.backward")
                        }
                        .tint(Theme.Colors.selection)
                    }
                    .swipeActions(edge: .trailing) {
                        // Deliberately not a full swipe: this one cannot be undone.
                        Button {
                            confirmingDelete = item
                        } label: {
                            Label("Delete", systemImage: "trash.slash")
                        }
                        .tint(Theme.Colors.destructive)
                    }
                    .contextMenu {
                        Button("Put Back", systemImage: "arrow.uturn.backward") {
                            restore(item)
                        }
                        Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                            confirmingDelete = item
                        }
                    }
            }

            if items.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: "trash",
                        headline: "The Trash is empty",
                        message: "Deleted things wait here until you empty it. Nothing disappears on its own."
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) {
                        confirmingEmpty = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Permanently delete everything in the Trash?",
            isPresented: $confirmingEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete ^[\(items.count) item](inflect: true)", role: .destructive) {
                emptyTrash()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Permanently delete “\(confirmingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let item = confirmingDelete { deletePermanently(item) }
                confirmingDelete = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        .task(id: services?.changeToken) { reload() }
    }

    private func reload() {
        guard let services else { return }
        items = (try? services.items.items(matching: ItemQuery.trash())) ?? []
    }

    private func restore(_ item: Item) {
        guard let services else { return }
        services.perform {
            try services.items.restore(item)
            services.noteChange(to: item)
        }
        reload()
    }

    private func deletePermanently(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform {
            try services.items.deletePermanently(item)
            services.noteRemoval(of: id)
        }
        reload()
    }

    private func emptyTrash() {
        guard let services else { return }
        let ids = items.map(\.id)
        services.perform {
            try services.items.emptyTrash()
            for id in ids { services.noteRemoval(of: id) }
        }
        reload()
    }
}
