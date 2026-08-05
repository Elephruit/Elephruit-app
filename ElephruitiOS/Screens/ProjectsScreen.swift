import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Every project, arranged the way the owner arranged them.
///
/// The Mac keeps this tree pinned to the top of its sidebar; the phone gives it a screen, for the
/// reasons `MobileDestination.groups` sets out. What does not change is the *content*: favourites
/// hoisted into their own band, the Area ▸ Project tree in the owner's order, archived projects
/// behind a disclosure, and an overdue dot or an unread count on the rows that have earned one.
///
/// ### One model, not a second reading of the store
/// The rows come from `ProjectsSidebarModel`, which is the same object the Mac's sidebar draws and
/// which `AppServices.refreshDerivedState()` already rebuilds after every mutation anywhere in the
/// app. Re-querying here would mean a second definition of what counts as overdue, a second
/// ordering, and a second answer to "which projects are archived" — three chances for the two
/// shells to disagree about one library, bought for nothing.
///
/// There is deliberately no progress ring on a row. See `ProjectSidebarRow.hasIndicators`: a
/// partial arc beside every name is a mark people notice and cannot read. The figure belongs on
/// the project's own screen, in words, and that is where `ProjectScreen` puts it.
struct ProjectsScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var showsArchived = false
    @State private var creation: Creation?
    @State private var draftName = ""
    @State private var renaming: ProjectSidebarRow?
    @State private var pendingDeletion: ProjectSidebarRow?

    /// A project being named, and the area it will land in.
    ///
    /// The Mac types the name into a row that appears in the tree. A phone cannot: the keyboard
    /// takes half the screen and the row it is editing would be behind it. An alert with one field
    /// is the platform's answer to "name this before it exists", and it keeps the template choice
    /// and the name in one uninterrupted motion.
    private struct Creation: Identifiable {
        let template: ProjectTemplate
        let area: ProjectSidebarRow?
        var id: String { template.id + (area?.id.uuidString ?? "") }
    }

    var body: some View {
        List {
            if let model {
                if !model.favourites.isEmpty {
                    Section("Favorites") {
                        ForEach(model.favourites) { row in
                            // Flattened to the margin: a favourite is hoisted out of the tree, so
                            // carrying its old indent here would indent it under nothing.
                            projectRow(row, indent: 0, accessory: "star.fill")
                        }
                    }
                }

                if model.isEmpty {
                    Section { emptyState }.listRowBackground(Color.clear)
                } else if !model.rows.isEmpty {
                    Section {
                        ForEach(model.rows) { row in
                            projectRow(row)
                        }
                    } header: {
                        // Unheaded when it is the only band: a lone header naming the screen the
                        // title bar just named is a line spent on nothing.
                        if !model.favourites.isEmpty {
                            Text("All Projects")
                        }
                    }
                }

                if !model.archived.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showsArchived) {
                            ForEach(model.archived) { row in
                                archivedRow(row)
                            }
                        } label: {
                            Label("Archived", systemImage: "archivebox")
                                .font(Theme.Text.rowSubtitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                        .accessibilityIdentifier("projects.archived")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ProjectTemplate.all) { template in
                        Button {
                            begin(Creation(template: template, area: nil))
                        } label: {
                            Label(template.name, systemImage: template.symbolName)
                        }
                    }
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .accessibilityIdentifier("projects.new")
            }
        }
        .alert("New Project", isPresented: creationBinding, presenting: creation) { pending in
            TextField("Project name", text: $draftName)
                .accessibilityIdentifier("projects.new.name")
            Button("Create") { commitCreation(pending) }
            Button("Cancel", role: .cancel) { draftName = "" }
        } message: { pending in
            Text(creationMessage(pending))
        }
        .alert("Rename", isPresented: renameBinding, presenting: renaming) { row in
            TextField("Name", text: $draftName)
                .accessibilityIdentifier("projects.rename.name")
            Button("Save") { commitRename(row) }
            Button("Cancel", role: .cancel) { draftName = "" }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { _ in
            Button("Move to Trash", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(deletionMessage(row))
        }
        .accessibilityIdentifier("projects.screen")
    }

    private var model: ProjectsSidebarModel? { services?.projectSidebar }

    // MARK: - Rows

    private func projectRow(
        _ row: ProjectSidebarRow,
        indent: Int? = nil,
        accessory: String? = nil
    ) -> some View {
        MobileProjectRow(row: row, indent: indent ?? row.depth, accessorySymbol: accessory)
            .contentShape(Rectangle())
            .onTapGesture { open(row) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDeletion = row
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                Button {
                    setArchived(row, true)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(Theme.Colors.secondaryText)
            }
            .swipeActions(edge: .leading) {
                Button {
                    toggleFavourite(row)
                } label: {
                    Label(
                        row.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: row.isFavorite ? "star.slash" : "star"
                    )
                }
                .tint(Theme.Colors.warning)
            }
            .contextMenu { menu(for: row) }
    }

    private func archivedRow(_ row: ProjectSidebarRow) -> some View {
        MobileProjectRow(row: row, indent: 0, accessorySymbol: nil)
            .contentShape(Rectangle())
            .onTapGesture { open(row) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDeletion = row
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                Button {
                    setArchived(row, false)
                } label: {
                    Label("Put Back", systemImage: "tray.and.arrow.up")
                }
                .tint(Theme.Colors.selection)
            }
            .contextMenu {
                Button("Put Back", systemImage: "tray.and.arrow.up") { setArchived(row, false) }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    pendingDeletion = row
                }
            }
    }

    @ViewBuilder
    private func menu(for row: ProjectSidebarRow) -> some View {
        Button("Open", systemImage: "arrow.up.forward.square") { open(row) }
        Button("Rename", systemImage: "pencil") { beginRename(row) }
        Button(
            row.isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: row.isFavorite ? "star.slash" : "star"
        ) {
            toggleFavourite(row)
        }
        Divider()
        if row.isArea {
            // The Mac's "New Project in <Area>", which is the only way to aim a new project at a
            // container without dragging it there afterwards.
            Menu {
                ForEach(ProjectTemplate.all) { template in
                    Button {
                        begin(Creation(template: template, area: row))
                    } label: {
                        Label(template.name, systemImage: template.symbolName)
                    }
                }
            } label: {
                Label("New Project in \(row.title)", systemImage: "plus")
            }
        }
        Button("Move Up", systemImage: "arrow.up") { move(row, by: -1) }
        Button("Move Down", systemImage: "arrow.down") { move(row, by: 1) }
        Divider()
        Button("Archive", systemImage: "archivebox") { setArchived(row, true) }
        Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingDeletion = row }
    }

    /// Says what a project is *for* rather than that there are none, which the absence of rows
    /// already says — the Mac's empty row, given the room a phone can spare.
    private var emptyState: some View {
        EmptyStateView(
            symbolName: "square.stack.3d.up",
            headline: "Work with an outcome and an end",
            message: "Anything that finishes belongs here. Start one with the + above."
        )
    }

    // MARK: - Navigation

    /// An area opens as an item and a project as a workspace, exactly as the Mac's
    /// `selection(for:)` decides it — one rule, two shells.
    private func open(_ row: ProjectSidebarRow) {
        shell.push(row.isArea ? .item(row.id) : .project(row.id))
    }

    // MARK: - Creating

    private var creationBinding: Binding<Bool> {
        Binding(get: { creation != nil }, set: { if !$0 { creation = nil } })
    }

    private func begin(_ pending: Creation) {
        draftName = ""
        creation = pending
    }

    private func creationMessage(_ pending: Creation) -> String {
        guard let area = pending.area else { return pending.template.summary }
        return "\(pending.template.summary), in \(area.title)."
    }

    private func commitCreation(_ pending: Creation) {
        defer { draftName = "" }
        guard let services, let name = draftName.nilIfBlank else { return }
        let area = pending.area.flatMap { try? services.items.item(id: $0.id) }
        guard let project = try? services.projectTemplates.createProject(
            named: name,
            from: pending.template,
            in: area
        ) else { return }

        services.refreshDerivedState()
        // Straight into what was just made: a create that leaves you looking at a list is a
        // create you have to go and find.
        shell.push(.project(project.id))
    }

    // MARK: - Renaming

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func beginRename(_ row: ProjectSidebarRow) {
        draftName = row.title
        renaming = row
    }

    private func commitRename(_ row: ProjectSidebarRow) {
        defer { draftName = "" }
        guard let services,
              let item = try? services.items.item(id: row.id),
              let name = draftName.nilIfBlank
        else { return }
        services.perform {
            try services.items.update(item) { $0.title = name }
            services.noteChange(to: item)
        }
    }

    // MARK: - Deleting

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "Move to Trash" }
        return "Move “\(pendingDeletion.title)” to Trash?"
    }

    /// Names the work that goes with it, and counts it only now — the Mac's rule, and for the
    /// same reason: a number read once, by one project, is not worth carrying on every row.
    private func deletionMessage(_ row: ProjectSidebarRow) -> String {
        guard let services, let project = try? services.items.item(id: row.id) else {
            return "You can put it back from the Trash."
        }
        let count = project.descendantWork().count
        guard count > 0 else { return "You can put it back from the Trash." }
        return count == 1
            ? "The one item in it goes too. You can put both back from the Trash."
            : "The \(count) items in it go too. You can put them all back from the Trash."
    }

    private func confirmDeletion() {
        defer { pendingDeletion = nil }
        guard let services,
              let row = pendingDeletion,
              let item = try? services.items.item(id: row.id)
        else { return }
        // Through the undo coordinator: confirming a dialog does not waive undo. The confirmation
        // is there because a project takes its descendants with it; the undo is there because the
        // dialog can still be answered on autopilot.
        services.perform { try services.undo.moveToTrash([item]) }
        services.noteRemoval(of: row.id)
        services.refreshDerivedState()
    }

    // MARK: - Other actions

    private func toggleFavourite(_ row: ProjectSidebarRow) {
        guard let services, let item = try? services.items.item(id: row.id) else { return }
        services.perform {
            try services.items.update(item) { $0.isFavorite.toggle() }
            services.noteChange(to: item)
        }
    }

    private func setArchived(_ row: ProjectSidebarRow, _ archived: Bool) {
        guard let services, let item = try? services.items.item(id: row.id) else { return }
        services.perform {
            try services.items.setArchived(item, archived)
            services.noteChange(to: item)
        }
    }

    /// Moves a row among its own peers — projects among projects at the same depth, areas among
    /// areas. Reordering across those bands would mean reparenting, which is a different verb and
    /// deserves a different gesture.
    private func move(_ row: ProjectSidebarRow, by offset: Int) {
        guard let services, let model, let item = try? services.items.item(id: row.id) else {
            return
        }
        let peers = model.rows.filter { $0.depth == row.depth && $0.isArea == row.isArea }
        guard let index = peers.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard peers.indices.contains(target) else { return }

        let neighbour = try? services.items.item(id: peers[target].id)
        services.perform {
            try services.items.move(
                item,
                after: offset > 0 ? neighbour : nil,
                before: offset < 0 ? neighbour : nil
            )
            services.noteChange(to: item)
        }
    }
}

/// One row of the projects tree on the phone.
///
/// The Mac's `ProjectSidebarRowView`, at touch scale: the same glyph, the same indent per level,
/// the same two earned indicators, and no progress ring.
struct MobileProjectRow: View {
    let row: ProjectSidebarRow
    let indent: Int
    let accessorySymbol: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: row.symbolName)
                .font(.body)
                .foregroundStyle(glyphColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            Text(row.title)
                .font(row.isArea ? Theme.Text.rowTitle.weight(.medium) : Theme.Text.rowTitle)
                .foregroundStyle(Theme.Colors.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if row.overdueCount > 0 {
                Circle()
                    .fill(Theme.Colors.overdue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("\(row.overdueCount) overdue")
            }

            if row.unreadCount > 0 {
                Text("\(row.unreadCount)")
                    .font(Theme.Text.rowSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityLabel("\(row.unreadCount) unread")
            }

            if let accessorySymbol {
                Image(systemName: accessorySymbol)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(indent) * Theme.Spacing.large)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.row.\(row.id.uuidString)")
    }

    private var glyphColor: Color {
        Theme.Palette.color(named: row.colorName, neutral: Theme.Colors.secondaryText)
    }
}
