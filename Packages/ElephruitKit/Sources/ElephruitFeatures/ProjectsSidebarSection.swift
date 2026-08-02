import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The Projects tree, at the top level of the sidebar.
///
/// Its own band rather than a module you enter. See ``AppModule/displayOrder`` for why: a module
/// swaps the sidebar for its own navigation, and doing that to projects put the user's structure one
/// level further away than the Trash, then took away the list they switch projects with.
struct ProjectsSidebarSection: View {
    @Environment(\.services) private var services
    let navigation: NavigationModel
    let rowHeight: CGFloat

    @State private var showsArchived = false
    @State private var renamingID: UUID?
    @State private var pendingCreation: PendingProjectCreation?
    @State private var draftName = ""
    @State private var pendingDeletion: ProjectSidebarRow?
    @FocusState private var focusedField: EditingField?

    private var model: ProjectsSidebarModel? { services?.projectSidebar }

    var body: some View {
        Section {
            if let model {
                if !model.favourites.isEmpty {
                    ForEach(model.favourites) { row in
                        projectRow(row, indentOverride: 0, badge: "star.fill")
                    }
                }

                if model.rows.isEmpty && model.favourites.isEmpty {
                    emptyRow
                } else {
                    ForEach(model.rows) { row in
                        projectRow(row)
                    }
                }

                if pendingCreation != nil {
                    newProjectField
                }

                if !model.archived.isEmpty {
                    archivedDisclosure(model.archived)
                }
            }
        } header: {
            header
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text("Projects")
            Spacer(minLength: 0)
            Menu {
                ForEach(ProjectTemplate.all) { template in
                    Button {
                        beginCreation(from: template)
                    } label: {
                        Label(template.name, systemImage: template.symbolName)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New project")
            .accessibilityLabel("New project")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func projectRow(
        _ row: ProjectSidebarRow,
        indentOverride: Int? = nil,
        badge: String? = nil
    ) -> some View {
        if renamingID == row.id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .rename(row.id))
                .onSubmit { commitRename(row) }
                .onExitCommand { cancelEditing() }
                .padding(.leading, indent(indentOverride ?? row.depth))
        } else {
            ProjectSidebarRowView(
                row: row,
                indent: indent(indentOverride ?? row.depth),
                accessorySymbol: badge,
                rowHeight: rowHeight
            )
            .tag(selection(for: row))
            .contextMenu { menu(for: row) }
        }
    }

    private var emptyRow: some View {
        // Says what a project is *for* rather than that there are none, which the absence of rows
        // already says. An empty state that only reports emptiness is a row spent on nothing.
        Text("Work with an outcome and an end.")
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.vertical, Theme.Spacing.tight)
    }

    private var newProjectField: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: ItemKind.project.symbolName)
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(Theme.Colors.secondaryText)

            TextField("Project name", text: $draftName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .newProject)
                .onSubmit { commitCreation() }
                .onExitCommand { cancelEditing() }
                .accessibilityLabel("New project name")
        }
        .padding(.leading, pendingCreation?.indent ?? 0)
    }

    @ViewBuilder
    private func archivedDisclosure(_ rows: [ProjectSidebarRow]) -> some View {
        DisclosureGroup(isExpanded: $showsArchived) {
            ForEach(rows) { row in
                ProjectSidebarRowView(
                    row: row,
                    indent: indent(1),
                    accessorySymbol: nil,
                    rowHeight: rowHeight
                )
                .tag(selection(for: row))
                .contextMenu { archivedMenu(for: row) }
            }
        } label: {
            Label("Archived", systemImage: "archivebox")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(depth) * Theme.Spacing.large
    }

    private func selection(for row: ProjectSidebarRow) -> SidebarSelection {
        row.isArea ? .item(id: row.id) : .project(id: row.id, viewID: nil)
    }

    // MARK: Menu

    @ViewBuilder
    private func menu(for row: ProjectSidebarRow) -> some View {
        Button("Open") { navigation.select(selection(for: row)) }
        Button("Rename") { beginRename(row) }
        Button(row.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            toggleFavourite(row)
        }
        Divider()
        if row.isArea {
            Button("New Project in \(row.title)") { beginCreation(from: .blank, in: row) }
        }
        Button("Move Up") { move(row, by: -1) }
        Button("Move Down") { move(row, by: 1) }
        Divider()
        Button("Archive") { archive(row) }
        Button("Move to Trash", role: .destructive) { pendingDeletion = row }
    }

    @ViewBuilder
    private func archivedMenu(for row: ProjectSidebarRow) -> some View {
        Button("Put Back") { unarchive(row) }
        Button("Move to Trash", role: .destructive) { pendingDeletion = row }
    }

    // MARK: Deletion

    private var deletionTitle: String {
        guard let pendingDeletion else { return "Move to Trash" }
        return "Move “\(pendingDeletion.title)” to Trash?"
    }

    /// Names the work that goes with it.
    ///
    /// "This cannot be undone" is boilerplate nobody reads; "and the 43 items in it" is the sentence
    /// that makes somebody stop and check they meant this project.
    ///
    /// Counted **here**, when the dialog opens, rather than carried on every row. It was a field on
    /// `ProjectSidebarRow`, which meant walking every project in the library on every save to keep a
    /// number that is read at most once, by one project, in the moment somebody asks to delete it.
    private var deletionMessage: String {
        guard let pendingDeletion,
              let services,
              let project = try? services.items.item(id: pendingDeletion.id)
        else {
            return "You can put it back from the Trash."
        }
        let count = project.descendantWork().count
        guard count > 0 else { return "You can put it back from the Trash." }
        return count == 1
            ? "The one item in it goes too. You can put both back from the Trash."
            : "The \(count) items in it go too. You can put them all back from the Trash."
    }

    // MARK: Actions

    private func beginCreation(from template: ProjectTemplate, in area: ProjectSidebarRow? = nil) {
        renamingID = nil
        draftName = ""
        pendingCreation = PendingProjectCreation(template: template, area: area)
        focus(.newProject)
    }

    private func commitCreation() {
        guard let services, let pendingCreation, let name = draftName.nilIfBlank else { return }
        let area = pendingCreation.area.flatMap { try? services.items.item(id: $0.id) }
        guard let project = try? services.projectTemplates.createProject(
            named: name,
            from: pendingCreation.template,
            in: area
        ) else { return }

        self.pendingCreation = nil
        draftName = ""
        focusedField = nil
        services.refreshDerivedState()
        navigation.select(.project(id: project.id, viewID: nil))
    }

    private func beginRename(_ row: ProjectSidebarRow) {
        pendingCreation = nil
        draftName = row.title
        renamingID = row.id
        focus(.rename(row.id))
    }

    private func commitRename(_ row: ProjectSidebarRow) {
        defer { renamingID = nil }
        guard let services,
              let item = try? services.items.item(id: row.id),
              let name = draftName.nilIfBlank
        else { return }
        try? services.items.update(item) { $0.title = name }
        services.refreshDerivedState()
    }

    private func cancelEditing() {
        renamingID = nil
        pendingCreation = nil
        draftName = ""
        focusedField = nil
    }

    private func focus(_ field: EditingField) {
        Task { @MainActor in
            await Task.yield()
            focusedField = field
        }
    }

    private func toggleFavourite(_ row: ProjectSidebarRow) {
        guard let services, let item = try? services.items.item(id: row.id) else { return }
        try? services.items.update(item) { $0.isFavorite.toggle() }
        services.refreshDerivedState()
    }

    private func move(_ row: ProjectSidebarRow, by offset: Int) {
        guard let services,
              let model,
              let item = try? services.items.item(id: row.id)
        else { return }

        let peers = model.rows.filter { $0.depth == row.depth && $0.isArea == row.isArea }
        guard let index = peers.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard peers.indices.contains(target) else { return }

        let neighbour = try? services.items.item(id: peers[target].id)
        try? services.items.move(
            item,
            after: offset > 0 ? neighbour : nil,
            before: offset < 0 ? neighbour : nil
        )
        services.refreshDerivedState()
    }

    private func archive(_ row: ProjectSidebarRow) {
        guard let services, let item = try? services.items.item(id: row.id) else { return }
        try? services.items.setArchived(item, true)
        services.refreshDerivedState()
    }

    private func unarchive(_ row: ProjectSidebarRow) {
        guard let services, let item = try? services.items.item(id: row.id) else { return }
        try? services.items.setArchived(item, false)
        services.refreshDerivedState()
    }

    private func confirmDeletion() {
        defer { pendingDeletion = nil }
        guard let services,
              let row = pendingDeletion,
              let item = try? services.items.item(id: row.id)
        else { return }
        // Through the undo coordinator: confirming a dialog does not waive ⌘Z. The confirmation
        // is there because a project takes its descendants with it; the undo is there because the
        // dialog can still be answered on autopilot.
        services.perform { try services.undo.moveToTrash([item]) }
        services.refreshDerivedState()
        if navigation.selection.projectID == row.id { navigation.select(.today) }
    }
}

private enum EditingField: Hashable {
    case rename(UUID)
    case newProject
}

private struct PendingProjectCreation {
    let template: ProjectTemplate
    let area: ProjectSidebarRow?

    var indent: CGFloat {
        guard let area else { return 0 }
        return CGFloat(area.depth + 1) * Theme.Spacing.large
    }
}

/// One row in the Projects tree.
struct ProjectSidebarRowView: View {
    let row: ProjectSidebarRow
    let indent: CGFloat
    let accessorySymbol: String?
    let rowHeight: CGFloat

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: row.symbolName)
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(glyphColor)

            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Indicators are earned, not decorated. Absent almost always, so present means something.
            // There is deliberately no progress ring here — see `ProjectSidebarRow.hasIndicators`.
            if row.overdueCount > 0 {
                Circle()
                    .fill(Theme.Colors.overdue)
                    .frame(width: 6, height: 6)
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
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, indent)
        .frame(height: rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.project.\(row.id.uuidString)")
    }

    private var glyphColor: Color {
        Theme.Palette.color(named: row.colorName, neutral: Theme.Colors.secondaryText)
    }
}
