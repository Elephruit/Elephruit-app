import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A note, an idea, a reference, a decision — anything whose body *is* the view.
///
/// One metadata line above, the text, and collapsed disclosures below. Nothing competes with the
/// writing, which is the whole point of the kind.
struct NoteDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let item: Item
    let navigation: NavigationModel
    @Binding var title: String
    @Binding var bodyText: String
    @Binding var pendingInsertion: WikiLinkInsertion?
    let completionContext: WikiLinkCompletionContext?
    let completionSuggestions: [(id: UUID, title: String)]
    let onCompletionContextChange: (WikiLinkCompletionContext?) -> Void
    let onAcceptCompletion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(item: item, title: $title, isEditable: !item.isInTrash) {
                ContextLine(facts: contextFacts)
            }

            Divider()

            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(
                    text: $bodyText,
                    pendingInsertion: $pendingInsertion,
                    isMonospaced: prefersMonospaced,
                    isEditable: !item.isInTrash,
                    onCompletionContextChange: onCompletionContextChange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if completionContext != nil, !completionSuggestions.isEmpty {
                    LinkCompletionList(
                        suggestions: completionSuggestions,
                        onAccept: onAcceptCompletion
                    )
                    .padding(.leading, Theme.Spacing.large)
                    .padding(.top, Theme.Spacing.section)
                }
            }

            if !backlinks.isEmpty {
                Divider()
                BacklinkList(links: backlinks) { navigation.selectItem($0) }
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.medium)
                    .frame(maxHeight: 180)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }

    private var backlinks: [ItemLink] { item.visibleBacklinks() }

    private var contextFacts: [String] {
        var facts: [String] = []
        if let parent = item.parent { facts.append(parent.displayTitle) }
        if !item.tagSlugs.isEmpty { facts.append(item.tagSlugs.map { "#\($0)" }.joined(separator: " ")) }
        facts.append("edited \(item.updatedAt.formatted(.relative(presentation: .named)))")
        return facts
    }
}

/// A task: its notes, and its subtasks inline.
///
/// Distinct from a note because the subtasks belong *in* the view rather than behind a disclosure —
/// they are the work, not context about it.
struct TaskDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let item: Item
    let navigation: NavigationModel
    @Binding var title: String
    @Binding var bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(item: item, title: $title, isEditable: !item.isInTrash) {
                ContextLine(facts: contextFacts)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    MarkdownTextEditor(
                        text: $bodyText,
                        isMonospaced: prefersMonospaced,
                        isEditable: !item.isInTrash
                    )
                    .frame(minHeight: 120)

                    subtasks

                    if !item.visibleBacklinks().isEmpty {
                        Divider()
                        DetailDisclosure(
                            title: "Linked from",
                            count: item.visibleBacklinks().count,
                            systemImage: "link"
                        ) {
                            BacklinkList(links: item.visibleBacklinks()) { navigation.selectItem($0) }
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                    }
                }
                .padding(.bottom, Theme.Spacing.large)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }

    private var subtaskList: [Item] {
        item.children.filter { $0.kind == .task && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            if !subtaskList.isEmpty {
                SectionHeader("Subtasks", count: subtaskList.count)
                    .padding(.bottom, Theme.Spacing.tight)

                ForEach(subtaskList, id: \.id) { subtask in
                    DetailTaskRow(
                        task: subtask,
                        dateProvider: services?.dateProvider ?? SystemDateProvider(),
                        onToggle: { toggle(subtask) },
                        onOpen: { navigation.selectItem(subtask.id) }
                    )
                }
            }

            Button {
                addSubtask()
            } label: {
                Label("New Subtask", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(Theme.Text.rowSubtitle)
            .padding(.top, Theme.Spacing.tight)
        }
        .padding(.horizontal, Theme.Spacing.large)
    }

    private var contextFacts: [String] {
        var facts: [String] = []
        if let parent = item.parent { facts.append(parent.displayTitle) }
        if let dueAt = item.dueAt {
            let provider = services?.dateProvider ?? SystemDateProvider()
            facts.append(provider.isOverdue(dueAt) ? "overdue" : "due \(dueAt.formatted(.relative(presentation: .named)))")
        }
        if item.priority != .normal { facts.append(item.priority.displayName.lowercased()) }
        if let recurrence = item.recurrence { facts.append(recurrence.summary.lowercased()) }
        if !item.tagSlugs.isEmpty { facts.append(item.tagSlugs.map { "#\($0)" }.joined(separator: " ")) }
        return facts
    }

    private func toggle(_ task: Item) {
        guard let services else { return }
        services.perform { try services.items.toggleCompletion(task) }
        services.noteChange(to: task)
    }

    private func addSubtask() {
        guard let services else { return }
        services.perform {
            let subtask = try services.items.create(ItemDraft(kind: .task, parentID: item.id))
            navigation.selectItem(subtask.id)
        }
    }
}

/// A bookmark: the link first, then whatever you wrote about it.
struct BookmarkDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let item: Item
    @Binding var title: String
    @Binding var bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(item: item, title: $title, isEditable: !item.isInTrash) {
                if let url = item.source.url {
                    // A `Link` hands the URL to the OS. The app itself makes no network request —
                    // it has no network entitlement.
                    Link(url.absoluteString, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No link")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Divider()

            MarkdownTextEditor(
                text: $bodyText,
                isMonospaced: prefersMonospaced,
                isEditable: !item.isInTrash
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }
}

/// A person, in the smallest form worth shipping.
///
/// The full workspace — interactions, relationships, follow-up nudges — is Phase E. What is here is
/// the shape that phase fills in: what you wrote about them, what is open with them, and what
/// mentions them. Deliberately not a CRM: no pipeline, no last-contacted nag.
struct PersonDetailView: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let item: Item
    let navigation: NavigationModel
    @Binding var title: String
    @Binding var bodyText: String

    @State private var isRecordingInteraction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(item: item, title: $title, isEditable: !item.isInTrash) {
                ContextLine(facts: contextFacts)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    relationshipSummary

                    MarkdownTextEditor(
                        text: $bodyText,
                        isMonospaced: prefersMonospaced,
                        isEditable: !item.isInTrash
                    )
                    .frame(minHeight: 120)

                    if !openWithThem.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            SectionHeader("Open with \(firstName)", count: openWithThem.count)
                                .padding(.bottom, Theme.Spacing.tight)

                            ForEach(openWithThem, id: \.id) { task in
                                DetailTaskRow(
                                    task: task,
                                    dateProvider: services?.dateProvider ?? SystemDateProvider(),
                                    onToggle: { toggle(task) },
                                    onOpen: { navigation.selectItem(task.id) }
                                )
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                    }

                    if !mentions.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            SectionHeader("Mentioned in", count: mentions.count)
                            BacklinkList(links: mentions) { navigation.selectItem($0) }
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                    }
                }
                .padding(.bottom, Theme.Spacing.large)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }

    /// When you last spoke, what is next, and what is open — the answer to "where are we with this
    /// person", above everything else on the page.
    ///
    /// Computed from links rather than stored, so it cannot go stale: editing a note about someone
    /// *is* the act that updates it.
    @ViewBuilder
    private var relationshipSummary: some View {
        if let context = personContext {
            HStack(spacing: Theme.Spacing.small) {
                Text(context.summary(using: services?.dateProvider ?? SystemDateProvider()))
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer(minLength: Theme.Spacing.small)

                Button("Record a conversation") { isRecordingInteraction = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.People.recordInteraction)
            }
            .padding(.horizontal, Theme.Spacing.large)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.People.relationshipSummary)
            .sheet(isPresented: $isRecordingInteraction) {
                RecordInteractionSheet(
                    personName: item.displayTitle,
                    onSave: { summary, notes, date in
                        record(summary: summary, notes: notes, at: date)
                        isRecordingInteraction = false
                    },
                    onCancel: { isRecordingInteraction = false }
                )
            }
        }
    }

    private var personContext: PersonContext? {
        services?.people.context(for: item)
    }

    private func record(summary: String, notes: String, at date: Date) {
        guard let services else { return }
        services.perform {
            let interaction = try services.people.recordInteraction(
                with: item,
                summary: summary,
                at: date,
                notes: notes
            )
            services.noteChange(to: interaction)
        }
    }

    private var firstName: String {
        item.personProfile?.givenName.isEmpty == false
            ? (item.personProfile?.givenName ?? item.displayTitle)
            : item.displayTitle.split(separator: " ").first.map(String.init) ?? item.displayTitle
    }

    private var contextFacts: [String] {
        var facts: [String] = []
        if let role = item.personProfile?.roleTitle, !role.isEmpty { facts.append(role) }
        if let email = item.personProfile?.emails.first?.value { facts.append(email) }
        if !item.tagSlugs.isEmpty { facts.append(item.tagSlugs.map { "#\($0)" }.joined(separator: " ")) }
        return facts
    }

    /// Open tasks that mention this person.
    private var openWithThem: [Item] {
        item.visibleBacklinks()
            .compactMap(\.source)
            .filter { $0.kind == .task && $0.status == .open }
            .uniqued()
    }

    private var mentions: [ItemLink] {
        item.visibleBacklinks().filter { $0.source?.kind != .task }
    }

    private func toggle(_ task: Item) {
        guard let services else { return }
        services.perform { try services.items.toggleCompletion(task) }
        services.noteChange(to: task)
    }
}

// MARK: - Shared pieces

/// The `[[` completion list.
struct LinkCompletionList: View {
    let suggestions: [(id: UUID, title: String)]
    let onAccept: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions.prefix(6), id: \.id) { suggestion in
                Button {
                    onAccept(suggestion.title)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "link")
                            .font(Theme.Text.metadata)
                        Text(suggestion.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.tight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(Theme.Spacing.tight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Colors.separator)
        )
        .shadow(radius: 8, y: 2)
        .accessibilityLabel("Link suggestions")
    }
}

/// Items pointing at this one.
struct BacklinkList: View {
    let links: [ItemLink]
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(links, id: \.id) { link in
                if let source = link.source {
                    Button {
                        onOpen(source.id)
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: source.effectiveSymbolName)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: Theme.Size.rowGlyph)
                            Text(source.displayTitle)
                                .lineLimit(1)
                            Text(link.kind.displayName)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.backlinksSection)
    }
}
