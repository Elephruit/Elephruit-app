import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Every tag, with room to search, rename, recolour and delete.
///
/// The sidebar's *All Tags…* button promised this sheet from the day the eight-tag limit went in —
/// and presented nothing: `isTagBrowserVisible` was set and never observed, which left tags as the
/// one kind of object in the app that could be created and never managed. Renaming reslugs
/// descendants and re-indexes tagged items (``TagRepository/rename(_:to:)``); deleting reparents a
/// tag's children rather than destroying them, and the dialog says what actually goes.
struct TagBrowserView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var tags: [Tag] = []
    @State private var searchText = ""
    @State private var renamingID: UUID?
    @State private var draftName = ""
    @State private var pendingDeletion: TagDeletion?
    @FocusState private var renameFocused: Bool

    private struct TagDeletion {
        let id: UUID
        let name: String
        let itemCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tags")
                    .font(Theme.Text.title)
                Spacer()
            }
            .padding(Theme.Spacing.medium)

            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)
                .accessibilityIdentifier("tags.filter")

            Divider()

            if visibleTags.isEmpty {
                EmptyStateView(
                    symbolName: "number",
                    headline: tags.isEmpty ? "No tags yet" : "Nothing matches",
                    message: tags.isEmpty
                        ? "Type # in Quick Jot, or add one from any item's inspector."
                        : "No tag matches what you typed."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleTags, id: \.id) { tag in
                    row(tag)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 420, height: 480)
        .task { reload() }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
        .accessibilityIdentifier("tags.browser")
    }

    private var visibleTags: [Tag] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private func row(_ tag: Tag) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "number")
                .foregroundStyle(
                    tag.colorName == nil
                        ? Theme.Colors.secondaryText
                        : Theme.Palette.color(named: tag.colorName)
                )
                .frame(width: Theme.Size.rowGlyph)

            if renamingID == tag.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(tag) }
                    .onExitCommand { renamingID = nil }
                    .onAppear { renameFocused = true }
            } else {
                Text(tag.name)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("\((tag.items ?? []).count)")
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityLabel("\((tag.items ?? []).count) items")
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Rename") { beginRename(tag) }

            Menu("Color") {
                Button("Default") { setColor(tag, nil) }
                ForEach(Theme.Palette.allCases, id: \.rawValue) { entry in
                    Button {
                        setColor(tag, entry.rawValue)
                    } label: {
                        if tag.colorName == entry.rawValue {
                            Label(entry.rawValue.capitalized, systemImage: "checkmark")
                        } else {
                            Text(entry.rawValue.capitalized)
                        }
                    }
                }
            }

            Divider()

            Button("Delete Tag…", role: .destructive) {
                pendingDeletion = TagDeletion(id: tag.id, name: tag.name, itemCount: (tag.items ?? []).count)
            }
        }
        .accessibilityIdentifier("tags.row.\(tag.slug)")
    }

    // MARK: - Actions

    private func reload() {
        tags = ((try? services?.tags.allTags()) ?? [])
            .sorted { $0.slug.localizedCompare($1.slug) == .orderedAscending }
    }

    private func beginRename(_ tag: Tag) {
        draftName = tag.name
        renamingID = tag.id
    }

    private func commitRename(_ tag: Tag) {
        defer { renamingID = nil }
        guard let services, let name = draftName.nilIfBlank, name != tag.name else { return }
        services.perform { try services.tags.rename(tag, to: name) }
        services.refreshDerivedState()
        reload()
    }

    private func setColor(_ tag: Tag, _ colorName: String?) {
        guard let services else { return }
        services.perform { try services.tags.setColor(tag, colorName: colorName) }
        services.refreshDerivedState()
        reload()
    }

    /// Names what actually happens, which is less than it sounds: the tagging goes, the items stay,
    /// and a child like `work/clients` is orphaned rather than deleted with its parent.
    private var deletionMessage: String {
        guard let pending = pendingDeletion else { return "" }
        switch pending.itemCount {
        case 0: return "Nothing is tagged with it."
        case 1: return "The tag comes off the one item that carries it. The item stays."
        default: return "The tag comes off the \(pending.itemCount) items that carry it. The items stay."
        }
    }

    private func confirmDeletion() {
        defer { pendingDeletion = nil }
        guard let services,
              let pending = pendingDeletion,
              let tag = tags.first(where: { $0.id == pending.id })
        else { return }
        services.perform { try services.tags.delete(tag) }
        services.refreshDerivedState()
        reload()
    }
}
