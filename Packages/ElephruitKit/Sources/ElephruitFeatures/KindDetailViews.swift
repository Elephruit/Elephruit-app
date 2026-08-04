import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A note, an idea, a reference, a decision — anything whose body *is* the view.
///
/// The notes workspace: an outline rail on the left when the document has enough structure to
/// earn one, the page in the middle, and the format and info panels floating from the toolbar.
/// Nothing competes with the writing, which is the whole point of the kind.
struct NoteDetailView: View {
    @Environment(\.services) private var services

    let item: Item
    let navigation: NavigationModel
    @Binding var title: String

    @State private var model = NoteEditorModel()
    @State private var showsFormatPanel = false
    @State private var showsInfoPanel = false

    /// Remembered across notes and launches: hiding the outline is a way of working, not a
    /// per-document choice.
    @AppStorage("notes.outlineVisible") private var outlineVisible = true

    @State private var detailWidth = CGFloat.zero

    var body: some View {
        HStack(spacing: 0) {
            if showsOutline {
                NoteOutlineRail(model: model)
                Divider()
            }

            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(item: item, title: $title, isEditable: !item.isInTrash) {
                    ContextLine(facts: contextFacts)
                }

                Divider()

                NotePageView(item: item, navigation: navigation, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !backlinks.isEmpty {
                    Divider()
                    BacklinkList(links: backlinks) { navigation.selectItem($0) }
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                        .frame(maxHeight: 180)
                }

                Divider()
                AttachmentSection(item: item)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.small)
            }
        }
        .toolbar { noteToolbar }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            detailWidth = width
        }
        // Dropping a file anywhere on a note attaches it, which is what someone dragging a PDF onto
        // a window expects. Copied, never moved.
        .acceptsAttachmentDrops(on: item)
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }

    /// Shown when asked for, worth its width, and affordable: below about 660 points the rail
    /// would be taken out of the editor's measure, which is the wrong thing to spend.
    private var showsOutline: Bool {
        outlineVisible && model.document.hasUsefulOutline() && detailWidth >= 660
    }

    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                outlineVisible.toggle()
            } label: {
                Label("Contents", systemImage: "list.bullet.indent")
            }
            .help(outlineVisible ? "Hide the outline" : "Show the outline")
            .disabled(!model.document.hasUsefulOutline())
        }

        ToolbarItem {
            Button {
                showsFormatPanel.toggle()
                showsInfoPanel = false
            } label: {
                Label("Format", systemImage: "textformat")
            }
            .help("Format — paragraph styles, marks, links")
            .popover(isPresented: $showsFormatPanel, arrowEdge: .bottom) {
                NoteFormatPanel(model: model)
            }
            .disabled(item.isInTrash)
        }

        ToolbarItem {
            Button {
                showsInfoPanel.toggle()
                showsFormatPanel = false
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .help("Info — properties, statistics, actions")
            .popover(isPresented: $showsInfoPanel, arrowEdge: .bottom) {
                NoteInfoPanel(item: item, model: model, onDelete: moveToTrash)
            }
        }
    }

    private func moveToTrash() {
        guard let services else { return }
        let id = item.id
        services.perform { try services.undo.moveToTrash([item]) }
        navigation.selectedItemIDs.remove(id)
        if navigation.selectedItemID == id { navigation.selectItem(nil) }
        services.refreshDerivedState()
        services.noteRemoval(of: id)
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

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    BookmarkPreviewImage(item: item)

                    NotesField(
                        text: $bodyText,
                        title: "Notes",
                        placeholder: "What is this link for?",
                        isEditable: !item.isInTrash
                    )

                    AttachmentSection(item: item)
                }
                .padding(Theme.Spacing.large)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.root)
    }
}

private struct BookmarkPreviewImage: View {
    @Environment(\.services) private var services

    let item: Item

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            }
        }
        .task(id: previewAttachment?.id) {
            guard let services, let attachment = previewAttachment,
                  let url = services.attachments.resolve(attachment) else {
                image = nil
                return
            }
            image = NSImage(contentsOf: url)
        }
    }

    private var previewAttachment: Attachment? {
        (item.attachments ?? []).first { attachment in
            ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"]
                .contains(attachment.typeIdentifier)
        }
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

                    NotesField(
                        text: $bodyText,
                        placeholder: "What is worth remembering about them?",
                        isEditable: !item.isInTrash
                    )
                    .padding(.horizontal, Theme.Spacing.large)

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

                    AttachmentSection(item: item)
                        .padding(.horizontal, Theme.Spacing.large)
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
                    .accessibilityIdentifier(AccessibilityID.Records.recordInteraction)
            }
            .padding(.horizontal, Theme.Spacing.large)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Records.relationshipSummary)
            .sheet(isPresented: $isRecordingInteraction) {
                LogInteractionSheet(
                    person: item,
                    onSave: { draft in
                        record(draft)
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

    private func record(_ draft: PersonInteractionDraft) {
        guard let services else { return }
        services.perform {
            let created = try services.people.recordInteractionBundle(
                with: interactionParticipants(for: draft, services: services),
                summary: draft.cleanedSummary,
                kind: draft.kind,
                at: draft.occurredAt,
                discussion: draft.cleanedDiscussion,
                followUps: draft.followUpItems,
                commitments: draft.commitmentItems
            )
            for item in created { services.noteChange(to: item) }
        }
    }

    private func interactionParticipants(for draft: PersonInteractionDraft, services: AppServices) -> [Item] {
        draft.participantIDs.compactMap { id in
            try? services.persons.person(id: id)
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
            .filter { $0.kind.isWorkItem && $0.status == .open }
            .uniqued()
    }

    private var mentions: [ItemLink] {
        item.visibleBacklinks().filter { $0.source?.kind.isWorkItem != true }
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
        .elevation(.floating)
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
