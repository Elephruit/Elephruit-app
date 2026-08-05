import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Which groups one person is in, as a list of toggles.
///
/// ### Why writes happen per toggle rather than on a Done button
/// Adding somebody to a group is one row in a join table, and it is its own complete thought — there
/// is no half-finished state to protect and nothing to validate across the set. Batching them behind
/// a Save would mean holding a pending diff, reconciling it against a library that can change
/// underneath, and deciding what Cancel means after six taps. Writing immediately makes the toggle
/// the truth, and the toggle is already the thing the user is looking at.
///
/// ### Why smart groups are not here
/// Their membership is the result of running a query, so there is nothing a toggle could write. They
/// are shown on the person's page — being in one is still true of them — but the only honest way to
/// change it is to change the person until the query matches. A disabled row would read as broken;
/// a row that appeared to work and did not would be worse. The sheet says where they went instead.
struct GroupMembershipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    let person: Item
    /// Called after any write, so the page behind can re-read.
    let onChange: () -> Void

    @State private var groups: [PersonGroup] = []
    @State private var memberOf: Set<UUID> = []
    @State private var smartGroups: [PersonGroup] = []
    @State private var loadError: String?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warning)
                }

                if groups.isEmpty, loadError == nil {
                    Section {
                        Button("New Group", systemImage: "plus.circle") { isCreating = true }
                    } footer: {
                        Text("Groups are yours to invent — family, work, the book club. "
                            + "Each one gets a colour that shows up beside this person's name in the list.")
                    }
                } else {
                    Section("Groups") {
                        ForEach(groups) { group in
                            Toggle(isOn: binding(for: group)) {
                                HStack(spacing: Theme.Spacing.medium) {
                                    GroupTile(
                                        symbolName: group.symbolName,
                                        colorName: group.colorName,
                                        size: .small
                                    )
                                    Text(group.name)
                                }
                            }
                            .accessibilityIdentifier("group.toggle.\(group.name)")
                        }
                    }

                    Section {
                        Button("New Group", systemImage: "plus.circle") { isCreating = true }
                    }
                }

                // Shown, and said to be automatic. Being in one is a fact about this person; it is
                // simply not one this sheet can change.
                if !smartGroups.isEmpty {
                    Section {
                        ForEach(smartGroups) { group in
                            HStack(spacing: Theme.Spacing.medium) {
                                GroupTile(
                                    symbolName: group.symbolName,
                                    colorName: group.colorName,
                                    size: .small
                                )
                                Text(group.name)
                                Spacer(minLength: 0)
                                Text("Automatic")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                        }
                    } header: {
                        Text("Matched")
                    } footer: {
                        Text("These groups collect whoever matches a search, so membership follows "
                            + "the record rather than being set here.")
                    }
                }
            }
            .navigationTitle(person.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isCreating) {
                NewGroupWithMemberSheet(person: person) {
                    reload()
                    onChange()
                }
            }
            .task(id: services?.changeToken ?? 0) { reload() }
        }
    }

    /// A toggle that writes as it is flipped. The `set` half is the whole feature.
    private func binding(for group: PersonGroup) -> Binding<Bool> {
        Binding(
            get: { memberOf.contains(group.id) },
            set: { isMember in
                guard let services else { return }
                let succeeded = services.perform {
                    if isMember {
                        try services.personGroups.add(person, to: group.id)
                    } else {
                        try services.personGroups.remove(person, from: group.id)
                    }
                }
                // Only on success: a toggle that moved while the write failed is a lie the user has
                // no way to notice.
                guard succeeded else { return }

                if isMember { memberOf.insert(group.id) } else { memberOf.remove(group.id) }
                onChange()
            }
        )
    }

    private func reload() {
        guard let services else { return }
        do {
            groups = try services.personGroups.fixedGroups()
            memberOf = try services.personGroups.fixedGroupIDs(containing: person.id)
            smartGroups = try services.personGroups.smartGroups()
                .filter { $0.memberIDs.contains(person.id) }
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }
}

/// Making a group with this person already in it.
///
/// The path that matters when there are no groups yet: somebody opens a person, wants a circle for
/// them, and should not have to make one somewhere else and come back. Name and colour only — the
/// symbol keeps its default, because this is the shortcut and the Groups screen is where a group is
/// dressed properly.
private struct NewGroupWithMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    let person: Item
    let onCreate: () -> Void

    @State private var name = ""
    @State private var colorName: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("group.name")
                }

                Section("Color") {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: Theme.Size.iconTileMedium),
                                spacing: Theme.Spacing.medium
                            )
                        ],
                        spacing: Theme.Spacing.medium
                    ) {
                        ForEach(PersonGroupService.groupColorNames, id: \.self) { candidate in
                            Button {
                                colorName = candidate
                            } label: {
                                Circle()
                                    .fill(Theme.Palette.color(named: candidate))
                                    .frame(
                                        width: Theme.Size.iconTileMedium,
                                        height: Theme.Size.iconTileMedium
                                    )
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Theme.Colors.primaryText, lineWidth: 2)
                                            .padding(-Theme.Spacing.hairline)
                                            .opacity(colorName == candidate ? 1 : 0)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Theme.Palette(rawValue: candidate)?.displayName ?? candidate)
                            .accessibilityAddTraits(colorName == candidate ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, Theme.Spacing.tight)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("group.save")
                }
            }
            .task {
                colorName = try? services?.personGroups.assignableColorName()
                isNameFocused = true
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let services else { return }

        let succeeded = services.perform {
            let group = try services.personGroups.createFixedGroup(named: trimmed, colorName: colorName)
            // Made and joined in one transaction: a group created from a person's page that did not
            // contain them would be the one outcome nobody asked for.
            try services.personGroups.add(person, to: group.id)
        }
        guard succeeded else { return }

        onCreate()
        dismiss()
    }
}
