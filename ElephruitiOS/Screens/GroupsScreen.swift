import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The groups of people: what they are, what colour, and how many are in them.
///
/// ### Why the colour is taught here
/// The People list draws membership as coloured dots, which are unreadable on their own — a blue dot
/// beside a name says *some group* until you have seen that Family is the blue one. This screen is
/// where that is learned, so it leads with the colour at tile size rather than treating it as
/// decoration on a text row. One tap in from the list's own filter menu, which is as far as the
/// legend for a mark can afford to be from the mark.
///
/// ### Fixed and smart, said plainly
/// A fixed group has members somebody chose; a smart group has whoever matches a query today. They
/// are the same idea to a reader and very different objects to edit — you cannot add somebody to a
/// query — so the difference is on the row rather than in a mode, and the membership editor simply
/// does not offer the ones it cannot write to.
struct GroupsScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var groups: [PersonGroup] = []
    @State private var loadError: String?
    @State private var isCreating = false
    @State private var renaming: PersonGroup?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            ForEach(groups) { group in
                Button {
                    shell.push(.records(.group(id: group.id)))
                } label: {
                    row(group)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        delete(group)
                    }
                    Button("Rename", systemImage: "pencil") {
                        renaming = group
                    }
                    .tint(Theme.Colors.selection)
                }
            }

            if groups.isEmpty, loadError == nil {
                EmptyStateView(
                    symbolName: "person.2.circle",
                    headline: "No groups yet",
                    message: "Put people into circles — family, work, the book club. "
                        + "Somebody can be in as many as you like, and each group gets a color "
                        + "that shows up beside their name."
                )
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Group", systemImage: "plus") { isCreating = true }
                    .accessibilityIdentifier("groups.new")
            }
        }
        .sheet(isPresented: $isCreating) {
            GroupEditorSheet(existing: nil) { name, colorName, symbolName in
                create(name: name, colorName: colorName, symbolName: symbolName)
            }
        }
        .sheet(item: $renaming) { group in
            GroupEditorSheet(existing: group) { name, colorName, symbolName in
                update(group, name: name, colorName: colorName, symbolName: symbolName)
            }
        }
        .task(id: services?.changeToken ?? 0) { reload() }
    }

    private func row(_ group: PersonGroup) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            GroupTile(symbolName: group.symbolName, colorName: group.colorName)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(group.name)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                Text(subtitle(group))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Theme.Size.iconTileLarge)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(subtitle(group))")
    }

    /// The count, and — for a smart group — the fact that nobody chose it.
    ///
    /// Said in words rather than with a badge, because "12 people" and "12 people who match a
    /// search" are different promises and only one of them can be edited by hand.
    private func subtitle(_ group: PersonGroup) -> String {
        let count = "\(group.memberCount) \(group.memberCount == 1 ? "person" : "people")"
        guard case .smart(let query) = group.definition else { return count }
        return "\(count) matching “\(query)”"
    }

    // MARK: - Writing

    private func reload() {
        guard let services else { return }
        do {
            groups = try services.personGroups.allGroups()
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }

    private func create(name: String, colorName: String?, symbolName: String) {
        guard let services else { return }
        services.perform {
            // Discarded explicitly: `perform` takes a `() throws -> Void`, and a single-expression
            // closure would otherwise infer the returned group as the closure's result type.
            _ = try services.personGroups.createFixedGroup(
                named: name, symbolName: symbolName, colorName: colorName
            )
        }
        reload()
    }

    private func update(_ group: PersonGroup, name: String, colorName: String?, symbolName: String) {
        guard let services else { return }
        services.perform {
            if name != group.name { try services.personGroups.rename(groupID: group.id, to: name) }
            if colorName != group.colorName {
                try services.personGroups.setColor(colorName, forGroup: group.id)
            }
            if symbolName != group.symbolName {
                try services.personGroups.setSymbol(symbolName, forGroup: group.id)
            }
        }
        reload()
    }

    /// Deleting the group, and nobody in it.
    ///
    /// A group is an `ItemCollection`, so this is the collection's own soft delete — the people keep
    /// existing, because they were never the group's to own. Worth stating: "delete Family" reads
    /// alarmingly next to a list of names.
    private func delete(_ group: PersonGroup) {
        guard let services else { return }
        services.perform { try services.personGroups.deleteGroup(id: group.id) }
        reload()
    }
}

/// Making a group, or changing one: a name, a colour, and a symbol.
///
/// The colour is offered as the swatches themselves rather than as a named list, because the thing
/// being chosen is a colour and its name is the least useful thing about it. A new group arrives
/// with the next unused colour already selected, so the common path is to type a name and leave.
private struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    let existing: PersonGroup?
    let onSave: (String, String?, String) -> Void

    @State private var name: String = ""
    @State private var colorName: String?
    @State private var symbolName: String = "person.2"
    @FocusState private var isNameFocused: Bool

    /// The symbols a group can wear. Few and concrete: a long grid of every SF Symbol is a search
    /// problem, and the point of the tile is to be recognised at a glance rather than to be exact.
    private static let symbols = [
        "person.2", "figure.2.and.child.holdinghands", "house", "briefcase", "square.grid.2x2",
        "heart", "star", "book", "bicycle", "music.mic", "airplane", "gamecontroller",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("group.name")
                } header: {
                    Text("Name")
                }

                Section("Color") {
                    swatches
                }

                Section("Symbol") {
                    symbolGrid
                }
            }
            .navigationTitle(existing == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("group.save")
                }
            }
            .task {
                if let existing {
                    name = existing.name
                    colorName = existing.colorName
                    symbolName = existing.symbolName
                } else {
                    // The colour a group would have been given anyway, chosen up front so it can be
                    // seen and overridden rather than discovered after saving.
                    colorName = try? services?.personGroups.assignableColorName()
                    isNameFocused = true
                }
            }
        }
    }

    private var swatches: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Size.iconTileMedium), spacing: Theme.Spacing.medium)],
            spacing: Theme.Spacing.medium
        ) {
            ForEach(PersonGroupService.groupColorNames, id: \.self) { name in
                Button {
                    colorName = name
                } label: {
                    Circle()
                        .fill(Theme.Palette.color(named: name))
                        .frame(width: Theme.Size.iconTileMedium, height: Theme.Size.iconTileMedium)
                        .overlay {
                            // A ring on the chosen one rather than a tick inside it: a tick has to
                            // be legible against twelve different fills, and a ring never has to be.
                            Circle()
                                .strokeBorder(Theme.Colors.primaryText, lineWidth: 2)
                                .padding(-Theme.Spacing.hairline)
                                .opacity(colorName == name ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Theme.Palette(rawValue: name)?.displayName ?? name)
                .accessibilityAddTraits(colorName == name ? [.isSelected] : [])
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    private var symbolGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Size.iconTileLarge), spacing: Theme.Spacing.medium)],
            spacing: Theme.Spacing.medium
        ) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button {
                    symbolName = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(
                            symbolName == symbol
                                ? Theme.Palette.color(named: colorName)
                                : Theme.Colors.secondaryText
                        )
                        .frame(width: Theme.Size.iconTileLarge, height: Theme.Size.iconTileLarge)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(Theme.Colors.subtleFill)
                                .opacity(symbolName == symbol ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(symbolName == symbol ? [.isSelected] : [])
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, colorName, symbolName)
        dismiss()
    }
}
