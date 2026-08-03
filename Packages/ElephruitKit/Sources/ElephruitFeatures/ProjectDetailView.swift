import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A project as a workspace rather than a note with a different glyph.
///
/// This is the view the old single detail surface could not be. A project shows its brief, its tasks
/// grouped by heading, the notes filed with it, the people it touches, and — from Phase C — the time
/// spent on it. All of it in one scroll, none of it in a tab.
///
/// Also used for areas and goals, which differ in what they contain rather than in shape.
public struct ProjectDetailView: View {
    @Environment(\.services) private var services

    private let project: Item
    private let navigation: NavigationModel
    @Binding private var title: String
    @Binding private var brief: String

    /// A tag chosen from the chips along the top, filtering the task list in place.
    @State private var activeTagFilter: String?
    @State private var pendingHeadingAction: HeadingActionConfirmation?
    @State private var newHeadingTitle = ""
    @State private var isAddingHeading = false

    public init(
        project: Item,
        navigation: NavigationModel,
        title: Binding<String>,
        brief: Binding<String>
    ) {
        self.project = project
        self.navigation = navigation
        self._title = title
        self._brief = brief
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                briefEditor

                if !availableTags.isEmpty {
                    tagFilterRow
                }

                taskList

                if project.shouldSuggestCompletion {
                    CompletionSuggestion(
                        onComplete: { perform { try $0.completeProject(project) } },
                        onDismiss: { perform { try $0.dismissCompletionSuggestion(for: project) } }
                    )
                    .padding(.horizontal, Theme.Spacing.large)
                }

                footerSections
            }
            .padding(.bottom, Theme.Spacing.generous)
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
        .confirmationDialog(
            pendingHeadingAction?.title ?? "",
            isPresented: headingConfirmationBinding,
            presenting: pendingHeadingAction
        ) { pending in
            // The non-destructive option is offered first, and is not the destructive role.
            if pending.taskCount > 0 {
                Button("Move \(pending.taskCount) Tasks Out First") {
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

    // MARK: - Header

    private var header: some View {
        DetailHeader(item: project, title: $title, isEditable: !project.isInTrash) {
            ContextLine(facts: contextFacts)
        }
    }

    /// Only what is true. A project with no due date and no estimate shows neither.
    private var contextFacts: [String] {
        var facts: [String] = []

        if let parent = project.parent {
            facts.append(parent.displayTitle)
        }

        if let dueAt = project.dueAt {
            let provider = services?.dateProvider ?? SystemDateProvider()
            facts.append(provider.isOverdue(dueAt)
                ? "overdue \(dueAt.formatted(.relative(presentation: .named)))"
                : "due \(dueAt.formatted(.relative(presentation: .named)))")
        }

        let progress = project.taskProgress()
        if progress.total > 0 {
            facts.append("\(progress.completed) of \(progress.total)")
        }

        if let estimate = project.estimatedMinutesDescription {
            facts.append(estimate)
        }

        return facts
    }

    private var briefEditor: some View {
        NotesField(
            text: $brief,
            title: "Brief",
            systemImage: "text.alignleft",
            // A project's prose answers a different question from a task's, and a placeholder that
            // says "Add notes…" for both would be the component's default leaking through as though
            // it were a decision.
            placeholder: "What does finishing this look like?",
            isEditable: !project.isInTrash
        )
        .padding(.horizontal, Theme.Spacing.medium)
    }

    // MARK: - Tag filter

    private var availableTags: [String] {
        Array(Set(project.descendantTasks().flatMap(\.tagSlugs))).sorted()
    }

    /// Filters the task list in place, the way the Things screenshot does.
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
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityIdentifier("project.tagFilter")
    }

    // MARK: - Tasks

    private var taskList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            let ungrouped = filtered(project.ungroupedTasks())
            if !ungrouped.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(ungrouped, id: \.id) { task in
                        taskRow(task)
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
            }

            ForEach(project.orderedHeadings(), id: \.id) { heading in
                headingSection(heading)
            }

            addRow
        }
    }

    private func headingSection(_ heading: Item) -> some View {
        let tasks = filtered(heading.children.filter { $0.kind.isWorkItem }
            .sorted { $0.sortOrder < $1.sortOrder })

        return VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack {
                Text(heading.displayTitle)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(Theme.Colors.selection)

                Spacer()

                Menu {
                    Button("Move Tasks Out") { perform { try $0.moveTasksOut(of: heading) } }
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
                // An empty heading is legitimate — a placeholder for work not yet written down — so
                // it says so rather than vanishing.
                Text(activeTagFilter == nil ? "Nothing here yet" : "Nothing matching this tag")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.vertical, Theme.Spacing.tight)
            } else {
                ForEach(tasks, id: \.id) { task in
                    taskRow(task)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityIdentifier("project.heading.\(heading.id.uuidString)")
    }

    private func taskRow(_ task: Item) -> some View {
        DetailTaskRow(
            task: task,
            dateProvider: services?.dateProvider ?? SystemDateProvider(),
            onToggle: { perform { try $0.toggleCompletion(task) } },
            onOpen: { navigation.selectItem(task.id) }
        )
    }

    private func filtered(_ tasks: [Item]) -> [Item] {
        guard let activeTagFilter else { return tasks }
        return tasks.filter { $0.tagSlugs.contains(activeTagFilter) }
    }

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button {
                perform { repository in
                    let task = try repository.create(ItemDraft(kind: .reminder, parentID: project.id))
                    navigation.selectItem(task.id)
                }
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.borderless)

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
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.small)
    }

    private func commitNewHeading() {
        let name = newHeadingTitle.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        perform { repository in
            _ = try repository.create(ItemDraft(kind: .heading, title: name, parentID: project.id))
        }
        newHeadingTitle = ""
        isAddingHeading = false
    }

    // MARK: - Footer

    /// Everything *about* the project rather than part of it, collapsed with a count.
    private var footerSections: some View {
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
        .padding(.horizontal, Theme.Spacing.large)
    }

    /// Notes deliberately filed with this project.
    ///
    /// Filed by link, not by containment: a note may be filed under several projects at once, and
    /// nothing here is owned by this one. Archiving or completing the project leaves every one of
    /// them untouched.
    private var projectNotes: [Item] {
        project.filedItems().filter { !$0.kind.isWorkItem && $0.kind != .heading }
    }

    /// Notes that merely mention this project.
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
                        navigation.selectItem(item.id)
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

    // MARK: - Actions

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
            // Through the undo coordinator: the dialog names the tasks that go with the heading,
            // and ⌘Z is what forgives answering it too fast.
            guard let services else { return }
            services.perform { try services.undo.moveToTrash([pending.heading]) }
            services.noteChange(to: project)
        }
    }

    private var headingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingHeadingAction != nil },
            set: { if !$0 { pendingHeadingAction = nil } }
        )
    }

    private func perform(_ work: (any ItemRepository) throws -> Void) {
        guard let services else { return }
        services.perform { try work(services.items) }
        services.noteChange(to: project)
    }
}

extension Array where Element == Item {
    /// Removes duplicates while keeping the first occurrence's order.
    func uniqued() -> [Item] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension Item {
    /// A human estimate, if one is set. `nil` when there is nothing to say.
    var estimatedMinutesDescription: String? {
        nil  // Estimates arrive with time tracking in Phase C.
    }
}
