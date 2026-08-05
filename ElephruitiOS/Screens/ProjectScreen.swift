import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A project: how far along it is, what is left, and what has been written about it.
///
/// The Mac's project workspace is a board, a timeline, a table and a brief in four switchable
/// views. A phone gets the one view the other three are summaries of — the work, grouped by the
/// project's own workflow stages when it has them and by nothing when it does not — because a
/// board with four columns at 400 points is a list with extra steps, and a timeline is a
/// picture you cannot read at this width.
///
/// The stages come from `ProjectWorkspaceService`, so a project whose owner arranged five
/// stages on the Mac sees those five stages here, in that order, under those names.
///
/// ### The order of the page
/// Brief, then status, then the work — the Mac's Home page in the Mac's order, because the three
/// answer different questions and people ask them in that sequence: what is this for, how is it
/// going, what is left. Health comes from `ProjectReportingService`, the same call the Mac's
/// status section makes, so the two never quote different completion figures for one project.
struct ProjectScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let projectID: UUID

    @State private var project: Item?
    @State private var stages: [WorkflowStage] = []
    @State private var headings: [Item] = []
    @State private var work: [Item] = []
    @State private var notes: [Item] = []
    @State private var health = ProjectHealth()
    @State private var loadError: String?

    @State private var isEditingBrief = false
    @State private var briefDraft = ""
    @State private var pendingBrief = PendingSave()

    @State private var isAddingWork = false
    @State private var draftWorkTitle = ""
    @State private var isConfirmingDeletion = false

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            if let project {
                headerSection(project)
                briefSection(project)
                statusSection
                workSections
                notesSection
            } else if loadError == nil {
                EmptyStateView(
                    symbolName: "folder",
                    headline: "Project not found",
                    message: "It may have been deleted or moved to the Trash."
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project?.displayTitle ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let project {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        draftWorkTitle = ""
                        isAddingWork = true
                    } label: {
                        Label("Add work", systemImage: "plus")
                    }
                    .accessibilityIdentifier("project.addWork")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        projectMenu(project)
                    } label: {
                        Label("Project actions", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("project.actions")
                }
            }
        }
        .alert("Add Work", isPresented: $isAddingWork) {
            TextField("What needs doing?", text: $draftWorkTitle)
                .accessibilityIdentifier("project.addWork.title")
            Button("Add") { addWork() }
            Button("Cancel", role: .cancel) { draftWorkTitle = "" }
        }
        .confirmationDialog(
            "Move “\(project?.displayTitle ?? "this project")” to Trash?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { moveProjectToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
        .task(id: reloadKey) { reload() }
        // A brief half-typed when the app goes to the background, or when the screen is popped,
        // is a brief that must already be saved. `PendingSave` debounces; these are the two
        // moments where waiting out the debounce is no longer an option.
        .onDisappear { pendingBrief.flush() }
        .accessibilityIdentifier("project.screen")
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(projectID.uuidString)"
    }

    // MARK: - Header

    private func headerSection(_ project: Item) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: project.effectiveSymbolName)
                        .font(.title2)
                        .foregroundStyle(Theme.Palette.color(named: project.colorName))

                    Text(project.displayTitle)
                        .font(Theme.Text.title)

                    Spacer(minLength: 0)
                }

                // The one number a project is asked for most, said as a bar and as words —
                // the bar for the glance, the words for the answer. `nil` rather than zero for
                // a project with no work in it: an empty project is not 0% finished, and a bar
                // pinned to the far left is a statement about a project that has not made one yet.
                if let fraction = health.completionFraction {
                    ProgressView(value: fraction)
                        .tint(Theme.Colors.completed)
                }

                Text(progressSummary)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)

                if let dueAt = project.dueAt, let clock = services?.dateProvider {
                    Label(
                        "Deadline \(RelativeDay.text(for: dueAt, using: clock))",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(DateUrgency.color(for: dueAt, using: clock))
                }

                if !project.tagSlugs.isEmpty {
                    TagChipRow(slugs: project.tagSlugs, limit: 6)
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
            .accessibilityElement(children: .combine)
        }
    }

    private var progressSummary: String {
        guard health.totalWork > 0 else { return "No work to track yet" }
        return "\(health.completedWork) of \(health.totalWork) done"
    }

    // MARK: - Brief

    /// What finishing looks like, rendered rather than shown as punctuation.
    ///
    /// The same `ProjectBrief` parser the Mac reads with, so a brief written there arrives here
    /// as headings, lists and quotes rather than as hash marks and hyphens. Editing shows the
    /// stored Markdown exactly as typed, because the format the user owns is the format they see
    /// when they reach for it.
    ///
    /// The section is present even when the brief is empty. A project whose brief is missing is
    /// the project that most needs one, and a section that appears only once there is something
    /// in it is a section nobody discovers.
    @ViewBuilder
    private func briefSection(_ project: Item) -> some View {
        Section {
            if isEditingBrief {
                TextEditor(text: $briefDraft)
                    .font(Theme.Text.editorBody)
                    .frame(minHeight: 140)
                    .onChange(of: briefDraft) { _, _ in pendingBrief.schedule { commitBrief() } }
                    .accessibilityLabel("Project brief, as Markdown")
                    .accessibilityIdentifier("project.brief.editor")
            } else {
                let blocks = ProjectBrief.displayBlocks(from: resolvedBrief(project))
                if blocks.isEmpty {
                    Text("What does finishing this look like?")
                        .font(Theme.Text.editorBody)
                        .foregroundStyle(Theme.Colors.placeholderText)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        ForEach(blocks) { block in
                            MobileBriefBlock(block: block)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.tight)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let id = ProjectBrief.itemID(from: url) else { return .systemAction }
                        guard let services, let target = try? services.items.item(id: id) else {
                            return .handled
                        }
                        shell.push(MobileShellModel.route(for: target.kind, id: target.id))
                        return .handled
                    })
                    .textSelection(.enabled)
                }
            }
        } header: {
            HStack {
                Text("Brief")
                Spacer(minLength: 0)
                if project.isInTrash {
                    EmptyView()
                } else if isEditingBrief {
                    Button("Done") { endEditingBrief() }
                        .accessibilityIdentifier("project.brief.done")
                } else {
                    Button("Edit") { beginEditingBrief(project) }
                        .accessibilityIdentifier("project.brief.edit")
                }
            }
        }
    }

    /// The stored Markdown with `[[Wiki Links]]` resolved through the link graph the store
    /// already reconciles on every save. A resolved title becomes a tappable name; an unknown
    /// one degrades to a bare readable name rather than to bracket syntax.
    private func resolvedBrief(_ project: Item) -> String {
        var targets: [String: UUID] = [:]
        for link in (project.outgoingLinks ?? []) where link.kind == .wiki {
            if let target = link.target {
                targets[TextNormalizer.foldedForMatching(target.title)] = target.id
            }
        }
        return ProjectBrief.resolvingWikiLinks(in: project.body) { link in
            targets[link.matchKey].flatMap(ProjectBrief.wikiURL(for:))
        }
    }

    private func beginEditingBrief(_ project: Item) {
        briefDraft = project.body
        isEditingBrief = true
    }

    private func endEditingBrief() {
        pendingBrief.flush()
        isEditingBrief = false
    }

    private func commitBrief() {
        guard let services,
              let current = try? services.items.item(id: projectID),
              !current.isInTrash,
              current.body != briefDraft
        else { return }

        let text = briefDraft
        services.perform {
            try services.items.update(current) { $0.body = text }
            services.noteChange(to: current)
        }
    }

    // MARK: - Status

    /// What is wrong, said in sentences, and only when it is true.
    ///
    /// `ProjectHealth.concerns` already decides which of eleven figures deserve saying out loud;
    /// this draws what it returns and nothing else. A dashboard of counters where eight read zero
    /// is a dashboard people stop looking at — and on a phone it is also most of the screen.
    @ViewBuilder
    private var statusSection: some View {
        if !health.concerns.isEmpty {
            Section("Needs Attention") {
                ForEach(health.concerns) { concern in
                    Label {
                        Text(concern.sentence)
                            .font(Theme.Text.rowTitle)
                    } icon: {
                        Image(systemName: concern.symbolName)
                            .foregroundStyle(
                                concern.isUrgent ? Theme.Colors.overdue : Theme.Colors.secondaryText
                            )
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("project.concerns")
        }

        if let deadline = health.nextDeadline, let clock = services?.dateProvider {
            Section {
                HStack {
                    Text("Next deadline")
                        .font(Theme.Text.rowTitle)
                    Spacer(minLength: 0)
                    DueDateLabel(date: deadline, dateProvider: clock)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Work

    /// The work, under the project's own stage names when it has them.
    ///
    /// Items whose stage was deleted, or which never had one, are not dropped — they collect
    /// under "Unstaged", because a project view that silently omits work is worse than one
    /// that admits it does not know where a piece belongs.
    ///
    /// Stages group only when the work actually uses them. Every template ships columns, so a
    /// project that has never been touched on a board has five stage names and nothing in any of
    /// them — grouping by stage there produces one section called "Unstaged" holding everything,
    /// which is a heading that says nothing. In that case the plan's own headings group instead,
    /// which is how the Mac's Home page reads the same project.
    @ViewBuilder
    private var workSections: some View {
        if work.isEmpty {
            Section("Work") {
                Text("Nothing filed under this project yet.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        } else if usesStages {
            ForEach(stages, id: \.id) { stage in
                let staged = work.filter { $0.workflowStageID == stage.id }
                if !staged.isEmpty {
                    Section(stage.name) {
                        ForEach(staged) { item in
                            workRow(item)
                        }
                    }
                }
            }

            let stageIDs = Set(stages.map(\.id))
            let unstaged = work.filter { item in
                item.workflowStageID.map { !stageIDs.contains($0) } ?? true
            }
            if !unstaged.isEmpty {
                Section("Unstaged") {
                    ForEach(unstaged) { item in
                        workRow(item)
                    }
                }
            }
        } else if !headings.isEmpty {
            let grouped = Set(headings.map(\.id))
            let ungrouped = work.filter { $0.parent.map { !grouped.contains($0.id) } ?? true }
            if !ungrouped.isEmpty {
                Section("Work") {
                    ForEach(ungrouped) { item in
                        workRow(item)
                    }
                }
            }

            ForEach(headings, id: \.id) { heading in
                let inside = work.filter { $0.parent?.id == heading.id }
                // An empty heading is legitimate — a placeholder for work not yet written down —
                // so it says so rather than vanishing.
                Section(heading.displayTitle) {
                    if inside.isEmpty {
                        Text("Nothing here yet")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    } else {
                        ForEach(inside) { item in
                            workRow(item)
                        }
                    }
                }
            }
        } else {
            Section("Work") {
                ForEach(work) { item in
                    workRow(item)
                }
            }
        }
    }

    private var usesStages: Bool {
        !stages.isEmpty && work.contains { $0.workflowStageID != nil }
    }

    private func workRow(_ item: Item) -> some View {
        MobileItemRow(
            item: item,
            // The section already names the project; a row repeating it is the list
            // stuttering — the same rule the row anatomy states.
            showsParent: false,
            onToggleCompletion: item.kind.supportsStatus ? { toggleCompletion(of: item) } : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            shell.push(MobileShellModel.route(for: item.kind, id: item.id))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                moveToTrash(item)
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !notes.isEmpty {
            Section("Notes") {
                ForEach(notes) { note in
                    MobileItemRow(item: note, showsParent: false)
                        .contentShape(Rectangle())
                        .onTapGesture { shell.push(.item(note.id)) }
                }
            }
        }
    }

    // MARK: - Project actions

    @ViewBuilder
    private func projectMenu(_ project: Item) -> some View {
        Button(
            project.isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: project.isFavorite ? "star.slash" : "star"
        ) {
            act { try $0.items.update(project) { $0.isFavorite.toggle() } }
        }
        if project.archivedAt == nil {
            Button("Archive", systemImage: "archivebox") {
                act { try $0.items.setArchived(project, true) }
            }
        } else {
            Button("Put Back", systemImage: "tray.and.arrow.up") {
                act { try $0.items.setArchived(project, false) }
            }
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            isConfirmingDeletion = true
        }
    }

    private var deletionMessage: String {
        guard let project else { return "You can put it back from the Trash." }
        let count = project.descendantWork().count
        guard count > 0 else { return "You can put it back from the Trash." }
        return count == 1
            ? "The one item in it goes too. You can put both back from the Trash."
            : "The \(count) items in it go too. You can put them all back from the Trash."
    }

    private func moveProjectToTrash() {
        guard let services, let project else { return }
        services.perform { try services.undo.moveToTrash([project]) }
        services.noteRemoval(of: projectID)
        services.refreshDerivedState()
        // The screen it was showing no longer exists; going back is the only honest next step.
        shell.goBack()
    }

    /// Adds a reminder to the project.
    ///
    /// A reminder rather than a choice of seven kinds: the overwhelming majority of what lands in
    /// a project is a thing to do, and the kind is one tap to change on the item's own screen.
    /// It goes to the project itself rather than into a stage — putting new work in a column is a
    /// board gesture, and there is no board here to have dragged it from.
    private func addWork() {
        defer { draftWorkTitle = "" }
        guard let services, let title = draftWorkTitle.nilIfBlank else { return }
        services.perform {
            let created = try services.items.create(
                ItemDraft(kind: .reminder, title: title, parentID: projectID)
            )
            services.noteChange(to: created)
        }
        services.refreshDerivedState()
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }
        do {
            guard let found = try services.items.item(id: projectID) else {
                project = nil
                return
            }
            project = found
            stages = services.projectWorkspace.stages(in: found)
            headings = found.orderedHeadings()

            // The plan as the Mac reads it: loose work plus whatever sits under each heading.
            // The old query asked for direct children only, which made every item filed under a
            // heading invisible on the phone — a project organised on the Mac showed its headings
            // as if they were the work and the work not at all.
            let underHeadings = headings.flatMap { heading in
                (heading.children ?? [])
                    .filter { $0.kind.isWorkItem && $0.deletedAt == nil }
                    .sorted { $0.sortOrder < $1.sortOrder }
            }
            work = found.ungroupedTasks() + underHeadings

            notes = (found.children ?? [])
                .filter { $0.kind == .note && $0.deletedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }

            // The same call the Mac's status section makes, so the two cannot quote different
            // completion figures for one project. It walks the project's own work, which is a
            // wider set than the plan above — subtasks count towards done, they just do not earn
            // a row of their own here.
            health = services.projectReports.health(of: found)
            services.registerSuspensionFlush(projectID) { pendingBrief.flush() }
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }

    private func toggleCompletion(of item: Item) {
        guard let services else { return }
        services.perform {
            try services.items.toggleCompletion(item)
            services.noteChange(to: item)
        }
    }

    private func moveToTrash(_ item: Item) {
        guard let services else { return }
        let id = item.id
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
    }

    private func act(_ work: @escaping (AppServices) throws -> Void) {
        guard let services, let project else { return }
        services.perform {
            try work(services)
            services.noteChange(to: project)
        }
        services.refreshDerivedState()
    }
}

/// One rendered block of a brief, at phone measure.
///
/// The Mac's `ProjectBriefBlockView`, same blocks and same rules, with the type scale a phone can
/// carry: a level-one heading here is the Mac's level-two, because a document title inside a
/// grouped list row is a shout.
struct MobileBriefBlock: View {
    let block: ProjectBrief.Block

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? Theme.Spacing.small : 0)
                .accessibilityAddTraits(.isHeader)

        case .paragraph:
            Text(block.text)
                .font(Theme.Text.editorBody)
                .lineSpacing(2)

        case .bulleted(let indent):
            listRow(marker: "•", indent: indent)

        case .ordered(let indent, let ordinal):
            listRow(marker: "\(ordinal).", indent: indent)

        case .quote:
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                Capsule()
                    .fill(Theme.Colors.separator)
                    .frame(width: 3)
                Text(block.text)
                    .font(Theme.Text.editorBody)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .padding(.leading, Theme.Spacing.tight)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title3, design: .default, weight: .semibold)
        case 2: .system(.headline)
        default: .system(.subheadline, design: .default, weight: .semibold)
        }
    }

    private func listRow(marker: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(marker)
                .font(Theme.Text.editorBody)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(minWidth: Theme.Spacing.large, alignment: .trailing)
            Text(block.text)
                .font(Theme.Text.editorBody)
                .lineSpacing(2)
        }
        .padding(.leading, CGFloat(indent) * Theme.Spacing.large)
        .accessibilityElement(children: .combine)
    }
}
