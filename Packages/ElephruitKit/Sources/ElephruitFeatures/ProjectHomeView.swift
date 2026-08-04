import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The project's front page: one canonical place a project opens.
///
/// Every ordinary route into a project — the sidebar, the Projects list, the palette, a link in
/// a note — lands here, on one composed, readable page: the brief as rendered prose, the status
/// the old Overview tab used to hold, the plan grouped by its headings, and the quiet reference
/// material at the bottom. Centred at a document's measure, because a landing page that stretches
/// edge-to-edge across a wide window reads as a dashboard, and a project is a piece of work.
struct ProjectHomeView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel
    let navigation: NavigationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if let project = model.project {
                    ProjectBriefSection(project: project, navigation: navigation)

                    if model.health.totalWork > 0 || model.health.openBugs > 0 {
                        ProjectStatusSection(model: model)
                    }

                    ProjectPlanSection(model: model, navigation: navigation)

                    ProjectReferenceSections(project: project, navigation: navigation)
                }
            }
            // A full section step below the tab divider, supplied by the page itself: with the
            // duplicate project header suppressed, nothing else stands between the tabs and the
            // Brief, and prose that touches a divider reads as clipped.
            .padding(.top, Theme.Spacing.section)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.generous)
            .frame(maxWidth: Theme.Size.projectHomeMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("project.home")
    }
}

// MARK: - Brief

/// The brief, read as prose and edited as Markdown.
///
/// Reading mode renders what the text *means* — headings, lists, quotes, emphasis, and wiki
/// links wearing their names. The stored value stays portable plain Markdown, and editing mode
/// shows exactly that source, because the format the user typed is the format they own.
private struct ProjectBriefSection: View {
    @Environment(\.services) private var services
    let project: Item
    let navigation: NavigationModel

    @State private var isEditing = false
    @State private var draft = ""
    @State private var pendingSave = PendingSave()
    @State private var editorID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Brief")
                Spacer(minLength: 0)
                if project.isInTrash {
                    EmptyView()
                } else if isEditing {
                    Button("Done") { endEditing() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("project.home.brief.done")
                } else {
                    Button("Edit") { beginEditing() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .accessibilityIdentifier("project.home.brief.edit")
                }
            }

            if isEditing {
                TextEditor(text: $draft)
                    .font(Theme.Text.editorBody)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.small)
                    .frame(minHeight: 160, maxHeight: 360)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .fill(Theme.Colors.contentBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Colors.separator)
                    )
                    .onChange(of: draft) { _, _ in pendingSave.schedule { commit() } }
                    .accessibilityLabel("Project brief, as Markdown")
                    .accessibilityIdentifier("project.home.brief.editor")
            } else {
                briefReading
            }
        }
        .task { navigation.registerEditFlush(editorID) { pendingSave.flush() } }
        .onDisappear {
            navigation.unregisterEditFlush(editorID)
            pendingSave.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            pendingSave.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            pendingSave.flush()
        }
        .accessibilityIdentifier("project.home.brief")
    }

    @ViewBuilder
    private var briefReading: some View {
        let blocks = ProjectBrief.displayBlocks(from: resolvedMarkdown)
        if blocks.isEmpty {
            Text("What does finishing this look like?")
                .font(Theme.Text.editorBody)
                .foregroundStyle(Theme.Colors.placeholderText)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(blocks) { block in
                    ProjectBriefBlockView(block: block)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let id = ProjectBrief.itemID(from: url) else { return .systemAction }
                if let services, let target = try? services.items.item(id: id) {
                    navigation.open(target)
                }
                return .handled
            })
            .textSelection(.enabled)
        }
    }

    /// The stored Markdown with `[[Wiki Links]]` resolved through the graph the store already
    /// reconciles on every save. A resolved title links to its item; an unknown one degrades
    /// to a bare readable name.
    private var resolvedMarkdown: String {
        var targets: [String: UUID] = [:]
        for link in project.outgoingLinks where link.kind == .wiki {
            if let target = link.target {
                targets[TextNormalizer.foldedForMatching(target.title)] = target.id
            }
        }
        return ProjectBrief.resolvingWikiLinks(in: project.body) { link in
            targets[link.matchKey].flatMap(ProjectBrief.wikiURL(for:))
        }
    }

    private func beginEditing() {
        draft = project.body
        isEditing = true
    }

    private func endEditing() {
        pendingSave.flush()
        isEditing = false
    }

    private func commit() {
        guard let services,
              let current = try? services.items.item(id: project.id),
              !current.isInTrash,
              current.body != draft
        else { return }

        let text = draft
        services.perform {
            try services.items.update(current) { $0.body = text }
        }
        services.noteChange(to: current)
    }
}

/// One rendered block of the brief.
private struct ProjectBriefBlockView: View {
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
        case 1: Theme.Text.title
        case 2: .system(.title3, design: .default, weight: .semibold)
        default: .system(.headline)
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

// MARK: - Status

/// What the Overview tab used to say, said once, on the page a project opens to.
struct ProjectStatusSection: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionHeader("Status")

            HStack(spacing: Theme.Spacing.medium) {
                StatTile(
                    value: "\(model.health.openWork)",
                    label: "Open",
                    symbolName: "circle",
                    tint: Theme.Colors.secondaryText
                )
                StatTile(
                    value: "\(model.health.completedWork)",
                    label: "Done",
                    symbolName: "checkmark.circle.fill",
                    tint: Theme.Colors.completed
                )
                StatTile(
                    value: "\(model.health.openBugs)",
                    label: model.health.openBugs == 1 ? "Open bug" : "Open bugs",
                    symbolName: "ant",
                    tint: model.health.criticalBugs > 0 ? Theme.Colors.overdue : Theme.Colors.secondaryText
                )
                StatTile(
                    value: "\(model.health.overdueWork)",
                    label: "Overdue",
                    symbolName: "exclamationmark.triangle",
                    tint: model.health.overdueWork > 0 ? Theme.Colors.overdue : Theme.Colors.secondaryText
                )
            }

            if let fraction = model.health.completionFraction {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack {
                        Text("\(model.health.completedWork) of \(model.health.totalWork) done")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Spacer(minLength: 0)
                        if let deadline = model.health.nextDeadline {
                            HStack(spacing: Theme.Spacing.tight) {
                                Text("Next deadline")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                DueDateLabel(date: deadline, dateProvider: dateProvider)
                            }
                        }
                    }

                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.Colors.completed)
                        .accessibilityLabel("\(Int(fraction * 100)) per cent complete")
                }
            }

            if !model.health.concerns.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionHeader("Needs attention")
                    ForEach(model.health.concerns) { concern in
                        ProjectConcernRow(concern: concern, model: model)
                    }
                }
            }

            if !stageBreakdown.isEmpty {
                stageSection
            }
        }
        .accessibilityIdentifier("project.home.status")
    }

    // MARK: Stages

    private struct StageCount: Identifiable {
        let id: String
        let name: String
        let color: Color
        let count: Int
    }

    /// Open work by board column, in column order. Empty when the project has no stages in use —
    /// a breakdown of one bar saying "everything is somewhere" earns no pixels.
    private var stageBreakdown: [StageCount] {
        let facts = model.allFacts.filter { !$0.status.isResolved }
        guard facts.contains(where: { $0.workflowStageID != nil }) else { return [] }

        let byStage = Dictionary(grouping: facts, by: \.workflowStageID)
        var result: [StageCount] = model.stages.compactMap { stage in
            guard let items = byStage[stage.id], !items.isEmpty else { return nil }
            return StageCount(
                id: stage.id.uuidString,
                name: stage.name,
                color: Theme.Palette.color(named: stage.colorName, neutral: Theme.Colors.secondaryText),
                count: items.count
            )
        }
        if let unstaged = byStage[nil], !unstaged.isEmpty {
            result.append(StageCount(
                id: "unstaged",
                name: "No column",
                color: Theme.Colors.tertiaryText,
                count: unstaged.count
            ))
        }
        return result
    }

    private var stageSection: some View {
        let breakdown = stageBreakdown
        let widest = breakdown.map(\.count).max() ?? 1

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Open work by column")

            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.tight) {
                ForEach(breakdown) { stage in
                    GridRow {
                        Text(stage.name)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .gridColumnAlignment(.leading)

                        BreakdownBar(fraction: Double(stage.count) / Double(widest), color: stage.color)

                        Text("\(stage.count)")
                            .font(Theme.Text.rowSubtitle)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(stage.name), \(stage.count) open")
                }
            }
        }
    }

    private var dateProvider: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }
}

// MARK: - Plan

/// The project's tasks as a plan to read, not a dashboard to operate.
private struct ProjectPlanSection: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel
    let navigation: NavigationModel

    @State private var activeTagFilter: String?
    @State private var pendingHeadingAction: HeadingActionConfirmation?
    @State private var newHeadingTitle = ""
    @State private var isAddingHeading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionHeader("Plan")

            if !availableTags.isEmpty {
                tagFilterRow
            }

            planList

            addRow
        }
        .accessibilityIdentifier("project.home.plan")
        .confirmationDialog(
            pendingHeadingAction?.title ?? "",
            isPresented: headingConfirmationBinding,
            presenting: pendingHeadingAction
        ) { pending in
            if pending.taskCount > 0 {
                Button("Move \(pending.taskCount) Work Items Out First") {
                    perform { try $0.moveTasksOut(of: pending.heading) }
                }
            }
            Button(pending.confirmTitle, role: .destructive) {
                apply(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    // MARK: Filtering

    private var project: Item? { model.project }

    private var availableTags: [String] {
        guard let project else { return [] }
        return Array(Set(project.descendantTasks().flatMap(\.tagSlugs))).sorted()
    }

    private var tagFilterRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("All") { activeTagFilter = nil }
                .buttonStyle(.plain)
                .foregroundStyle(activeTagFilter == nil ? Theme.Colors.primaryText : Theme.Colors.secondaryText)
                .fontWeight(activeTagFilter == nil ? .medium : .regular)

            ForEach(availableTags, id: \.self) { slug in
                Button {
                    activeTagFilter = activeTagFilter == slug ? nil : slug
                } label: {
                    TagChip(slug: slug, isSelected: activeTagFilter == slug)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .font(Theme.Text.rowSubtitle)
        .accessibilityIdentifier("project.tagFilter")
    }

    /// The tag filter and the toolbar's project search, composed. Both narrow the same plan.
    private func filtered(_ tasks: [Item]) -> [Item] {
        var result = tasks
        if let activeTagFilter {
            result = result.filter { $0.tagSlugs.contains(activeTagFilter) }
        }
        if let query = model.searchText.nilIfBlank {
            result = result.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
        }
        return result
    }

    // MARK: The plan

    @ViewBuilder
    private var planList: some View {
        if let project {
            let ungrouped = filtered(project.ungroupedTasks())
            if !ungrouped.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(ungrouped, id: \.id) { task in
                        taskRow(task)
                    }
                }
            }

            ForEach(project.orderedHeadings(), id: \.id) { heading in
                headingSection(heading)
            }
        }
    }

    private func headingSection(_ heading: Item) -> some View {
        let tasks = filtered(
            heading.children.filter { $0.kind.isWorkItem }.sorted { $0.sortOrder < $1.sortOrder }
        )

        return VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack {
                Text(heading.displayTitle)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(Theme.Colors.selection)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Menu {
                    Button("Move Work Items Out") { perform { try $0.moveTasksOut(of: heading) } }
                        .disabled(heading.children.isEmpty)
                    Divider()
                    Button("Archive…") { confirm(.archive, for: heading) }
                    Button("Move to Trash…", role: .destructive) { confirm(.trash, for: heading) }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(heading.displayTitle)")
            }
            .padding(.top, Theme.Spacing.small)

            Divider()

            if tasks.isEmpty {
                // An empty heading is legitimate — a placeholder for work not yet written down —
                // so it says so rather than vanishing.
                Text(isFiltering ? "Nothing matching here" : "Nothing here yet")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.vertical, Theme.Spacing.tight)
            } else {
                ForEach(tasks, id: \.id) { task in
                    taskRow(task)
                }
            }
        }
        .accessibilityIdentifier("project.heading.\(heading.id.uuidString)")
    }

    private var isFiltering: Bool {
        activeTagFilter != nil || model.searchText.nilIfBlank != nil
    }

    private func taskRow(_ task: Item) -> some View {
        DetailTaskRow(
            task: task,
            dateProvider: services?.dateProvider ?? SystemDateProvider(),
            onToggle: { perform { try $0.toggleCompletion(task) } },
            // Through the workspace's presenter, so a bug opens on its own triage surface and
            // everything else opens the work-item editor in place.
            onOpen: { model.present(task.id) }
        )
    }

    // MARK: Creating

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.Colors.tertiaryText)
                .accessibilityHidden(true)

            QuickAddRow(placeholder: "New task", model: model, onCommit: addTask)
                .frame(maxWidth: 280)

            if isAddingHeading {
                TextField("Heading name", text: $newHeadingTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { commitNewHeading() }
                Button("Add") { commitNewHeading() }
                    .disabled(newHeadingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    isAddingHeading = false
                    newHeadingTitle = ""
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    isAddingHeading = true
                } label: {
                    Label("New Heading", systemImage: "text.append")
                }
                .buttonStyle(.borderless)
            }

            Spacer()
        }
        .font(Theme.Text.rowSubtitle)
        .padding(.top, Theme.Spacing.small)
    }

    private func addTask(_ title: String) {
        guard let project else { return }
        perform { repository in
            _ = try repository.create(ItemDraft(kind: .reminder, title: title, parentID: project.id))
        }
    }

    private func commitNewHeading() {
        let name = newHeadingTitle.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let project else { return }

        perform { repository in
            _ = try repository.create(ItemDraft(kind: .heading, title: name, parentID: project.id))
        }
        newHeadingTitle = ""
        isAddingHeading = false
    }

    // MARK: Heading actions

    private func confirm(_ action: HeadingActionConfirmation.Action, for heading: Item) {
        pendingHeadingAction = HeadingActionConfirmation(
            heading: heading,
            action: action,
            taskCount: heading.descendantTasks().count
        )
    }

    private func apply(_ pending: HeadingActionConfirmation) {
        switch pending.action {
        case .archive:
            perform { try $0.setArchived(pending.heading, true) }
        case .trash:
            guard let services, let project else { return }
            services.perform { try services.undo.moveToTrash([pending.heading]) }
            services.noteChange(to: project)
            model.refresh()
        }
    }

    private var headingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingHeadingAction != nil },
            set: { if !$0 { pendingHeadingAction = nil } }
        )
    }

    private func perform(_ work: (any ItemRepository) throws -> Void) {
        guard let services, let project else { return }
        services.perform { try work(services.items) }
        services.noteChange(to: project)
        model.refresh()
    }
}

// MARK: - Reference

/// Everything *about* the project rather than part of it, collapsed with a count.
private struct ProjectReferenceSections: View {
    let project: Item
    let navigation: NavigationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Divider()

            DetailDisclosure(title: "Project notes", count: projectNotes.count, systemImage: "note.text") {
                linkedItemList(projectNotes, emptyMessage: "Notes filed with this project appear here.")
            }

            DetailDisclosure(title: "Related notes", count: relatedNotes.count, systemImage: "link") {
                linkedItemList(relatedNotes, emptyMessage: "Notes that mention this project appear here.")
            }

            DetailDisclosure(title: "People", count: relatedPeople.count, systemImage: "person") {
                linkedItemList(relatedPeople, emptyMessage: "People mentioned in this project appear here.")
            }
        }
        .accessibilityIdentifier("project.home.reference")
    }

    private var projectNotes: [Item] {
        project.filedItems().filter { !$0.kind.isWorkItem && $0.kind != .heading }
    }

    private var relatedNotes: [Item] {
        project.mentioningItems().filter { $0.kind != .person && !$0.kind.isWorkItem }
    }

    private var relatedPeople: [Item] {
        (project.visibleBacklinks().compactMap(\.source)
            + project.outgoingLinks.compactMap(\.target))
            .filter { $0.kind == .person && $0.deletedAt == nil }
            .uniqued()
    }

    @ViewBuilder
    private func linkedItemList(_ items: [Item], emptyMessage: String) -> some View {
        if items.isEmpty {
            Text(emptyMessage)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(items, id: \.id) { item in
                    Button {
                        // Through the canonical opener: a note lands on its editor, a person on
                        // their page — not on a selection this module has no pane to show.
                        navigation.open(item)
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: item.effectiveSymbolName)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: Theme.Size.rowGlyph)
                            Text(item.displayTitle)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Shared health components

/// A health concern, with a direct route to the work when the concern has one.
///
/// Verification is intentionally a separate claim from completion. Completed bugs are hidden from
/// the default Bugs list, so telling somebody a fix needs checking without opening that bug leaves
/// the only clearing action effectively undiscoverable.
struct ProjectConcernRow: View {
    let concern: ProjectHealth.Concern
    let model: ProjectWorkspaceModel

    var body: some View {
        if concern.id == "verify" {
            Button {
                model.presentFixAwaitingVerification()
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    concernLabel
                    Image(systemName: "chevron.right")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a fix to check it")
            .accessibilityHint("Opens a completed bug so its fix can be marked verified")
            .accessibilityIdentifier("project.concern.verify")
        } else {
            concernLabel
        }
    }

    private var concernLabel: some View {
        Label(concern.sentence, systemImage: concern.symbolName)
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(
                concern.isUrgent ? Theme.Colors.overdue : Theme.Colors.secondaryText
            )
    }
}

/// One number with its name under it.
struct StatTile: View {
    let value: String
    let label: String
    let symbolName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: symbolName)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .fill(Theme.Colors.subtleFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A quiet horizontal bar, scaled against the widest in its set.
struct BreakdownBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color.opacity(0.7))
                .frame(width: max(4, proxy.size.width * fraction), height: 6)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
