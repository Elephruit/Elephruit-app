import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One item, whatever it is: title, body, and the fields its kind supports.
///
/// ### How edits survive
/// Keystrokes land in local state and are written through `PendingSave` half a second
/// after typing pauses — and flushed on disappear, on scene backgrounding (via the
/// suspension registry), and before any navigation this screen initiates. The contract
/// is the Mac's: zero data loss on force-quit mid-edit.
struct ItemScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell
    @Environment(\.dismiss) private var dismiss

    let itemID: UUID

    @State private var item: Item?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var hasLoaded = false
    @State private var pending = PendingSave()
    @State private var isEditingTags = false

    var body: some View {
        Group {
            if let item {
                editor(item)
            } else if hasLoaded {
                EmptyStateView(
                    symbolName: "questionmark.circle",
                    headline: "This item is gone",
                    message: "It may have been deleted on this device."
                )
            } else {
                Color.clear
            }
        }
        .task(id: itemID) { load() }
        .onDisappear {
            pending.flush()
            services?.unregisterSuspensionFlush(itemID)
        }
    }

    // MARK: - Editor

    private func editor(_ item: Item) -> some View {
        List {
            Section {
                TextField(item.kind.displayName, text: $title, axis: .vertical)
                    .font(Theme.Text.title)
                    .lineLimit(1...4)
                    .onChange(of: title) { _, _ in scheduleSave() }
                    .accessibilityLabel("Title")
                    .accessibilityIdentifier("item.title")
            }

            if item.kind.supportsStatus {
                taskSection(item)
            }

            if item.kind == .bug {
                bugSection(item)
            }

            bodySection(item)
            checklistSection(item)
            tagsSection(item)
            childrenSection(item)
            backlinksSection(item)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(item) }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $isEditingTags) {
            TagEditorSheet(item: item) { load() }
        }
    }

    // MARK: - Task fields

    @ViewBuilder
    private func taskSection(_ item: Item) -> some View {
        Section {
            Button {
                act { services in
                    if item.status == .completed {
                        try services.reminderLifecycle.reopen(item)
                    } else {
                        _ = try services.reminderLifecycle.complete(item)
                    }
                }
            } label: {
                Label(
                    item.status == .completed ? "Completed" : "Mark Complete",
                    systemImage: item.status == .completed ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(
                    item.status == .completed ? Theme.Colors.completed : Theme.Colors.primaryText
                )
            }

            whenRow(item)
            deadlineRow(item)

            Toggle(isOn: Binding(
                get: { item.isFlagged },
                set: { flagged in act { try $0.reminderLifecycle.setFlagged(flagged, on: item) } }
            )) {
                Label("Flagged", systemImage: "flag")
            }

            Picker(selection: Binding(
                get: { item.priority },
                set: { priority in act { try $0.reminderLifecycle.setPriority(priority, on: item) } }
            )) {
                Text("Low").tag(Priority.low)
                Text("Normal").tag(Priority.normal)
                Text("High").tag(Priority.high)
            } label: {
                Label("Priority", systemImage: "exclamationmark.circle")
            }
        }
    }

    private func whenRow(_ item: Item) -> some View {
        Menu {
            Button("Today") { act { try $0.reminderLifecycle.apply(.today, to: item) } }
            Button("This Evening") { act { try $0.reminderLifecycle.apply(.thisEvening, to: item) } }
            Button("Someday") { act { try $0.reminderLifecycle.apply(.someday, to: item) } }
            if item.startAt != nil || item.todayCommittedOn != nil || item.isSomeday {
                Button("Clear", role: .destructive) { act { try $0.reminderLifecycle.apply(.clear, to: item) } }
            }
        } label: {
            LabeledContent {
                Text(whenSummary(item))
                    .foregroundStyle(Theme.Colors.secondaryText)
            } label: {
                Label("When", systemImage: "star")
                    .foregroundStyle(Theme.Colors.primaryText)
            }
        }
    }

    private func whenSummary(_ item: Item) -> String {
        guard let services else { return "" }
        if item.isCommittedTo(today: services.dateProvider) {
            return item.isLaterToday ? "This evening" : "Today"
        }
        if item.isSomeday { return "Someday" }
        if let start = item.startAt {
            return RelativeDay.text(for: start, using: services.dateProvider)
        }
        return "Anytime"
    }

    @ViewBuilder
    private func deadlineRow(_ item: Item) -> some View {
        if item.dueAt != nil {
            HStack {
                DatePicker(
                    selection: Binding(
                        get: { item.dueAt ?? services?.dateProvider.startOfTomorrow ?? Date() },
                        set: { date in act { try $0.reminderLifecycle.setDeadline(date, on: item) } }
                    ),
                    displayedComponents: .date
                ) {
                    Label("Deadline", systemImage: "flag.checkered")
                        .foregroundStyle(Theme.Colors.primaryText)
                }

                Button {
                    act { try $0.reminderLifecycle.setDeadline(nil, on: item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove deadline")
            }
        } else {
            Button {
                act { services in
                    try services.reminderLifecycle.setDeadline(services.dateProvider.startOfTomorrow, on: item)
                }
            } label: {
                Label("Add Deadline", systemImage: "flag.checkered")
            }
        }
    }

    // MARK: - Bug fields

    /// A bug is editable wherever it appears — the rule the Mac audit demanded. This is
    /// the canonical editor; every list that shows a bug pushes here, so there is no
    /// presentation where a bug's title or facts are read-only.
    @ViewBuilder
    private func bugSection(_ item: Item) -> some View {
        if let services, let record = try? services.bugs.record(for: item) {
            Section("Bug") {
                Picker(selection: Binding(
                    get: { record.severity },
                    set: { severity in act { try $0.bugs.setSeverity(severity, on: item) } }
                )) {
                    ForEach([BugSeverity.critical, .major, .minor, .cosmetic], id: \.self) { severity in
                        Text(severity.displayName).tag(severity)
                    }
                } label: {
                    Label("Severity", systemImage: "exclamationmark.octagon")
                }

                if services.bugs.isVerified(item) {
                    Label("Verified fixed", systemImage: "checkmark.seal")
                        .foregroundStyle(Theme.Colors.completed)
                } else if item.status == .completed {
                    Button {
                        act { try $0.bugs.markVerified(item) }
                    } label: {
                        Label("Mark Verified", systemImage: "checkmark.seal")
                    }
                }

                bugFactField("Steps to reproduce", text: record.facts.stepsToReproduce, item: item) {
                    facts, value in facts.stepsToReproduce = value
                }
                bugFactField("Expected", text: record.facts.expectedBehavior, item: item) {
                    facts, value in facts.expectedBehavior = value
                }
                bugFactField("Actual", text: record.facts.actualBehavior, item: item) {
                    facts, value in facts.actualBehavior = value
                }
            }
        }
    }

    private func bugFactField(
        _ label: String,
        text: String?,
        item: Item,
        write: @escaping (inout BugFacts, String?) -> Void
    ) -> some View {
        BugFactRow(label: label, initial: text ?? "") { newValue in
            act { services in
                try services.bugs.update(item) { facts in
                    write(&facts, newValue.isEmpty ? nil : newValue)
                }
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func bodySection(_ item: Item) -> some View {
        if item.kind.supportedFields.contains(.body) {
            Section("Notes") {
                TextEditor(text: $bodyText)
                    .font(Theme.Text.editorBody)
                    .frame(minHeight: 120)
                    .onChange(of: bodyText) { _, _ in scheduleSave() }
                    .accessibilityLabel("Notes")
                    .accessibilityIdentifier("item.body")

                // Wiki links in the text, resolved into taps. The editor stays plain
                // text; the links live underneath it, always current.
                let links = WikiLinkParser.links(in: bodyText)
                if !links.isEmpty {
                    ForEach(links, id: \.targetTitle) { link in
                        wikiLinkRow(link)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func wikiLinkRow(_ link: WikiLink) -> some View {
        if let services {
            let target = try? services.items.items(matching: {
                var query = ItemQuery()
                query.text = link.targetTitle
                query.limit = 8
                return query
            }()).first { TextNormalizer.foldedForMatching($0.title) == link.matchKey }

            Button {
                if let target {
                    shell.push(MobileShellModel.route(for: target.kind, id: target.id))
                } else {
                    createLinkTarget(link.targetTitle)
                }
            } label: {
                Label {
                    HStack {
                        Text(link.displayText ?? link.targetTitle)
                        if target == nil {
                            Text("· create")
                                .foregroundStyle(Theme.Colors.unresolvedLink)
                        }
                    }
                } icon: {
                    Image(systemName: target == nil ? "link.badge.plus" : "link")
                        .foregroundStyle(
                            target == nil ? Theme.Colors.unresolvedLink : Theme.Colors.link
                        )
                }
                .font(Theme.Text.rowSubtitle)
            }
        }
    }

    private func createLinkTarget(_ titleText: String) {
        guard let services else { return }
        pending.flush()
        services.perform {
            let created = try services.items.create(ItemDraft(kind: .note, title: titleText))
            services.noteChange(to: created)
            shell.push(.item(created.id))
        }
    }

    // MARK: - Checklist

    @ViewBuilder
    private func checklistSection(_ item: Item) -> some View {
        if item.kind.supportedFields.contains(.checklist) {
            let checklist = item.checklist
            if !checklist.isEmpty {
                Section("Checklist") {
                    ForEach(checklist.items) { step in
                        Button {
                            act { try $0.reminderLifecycle.setChecklistItem(step.id, completed: !step.isCompleted, on: item) }
                        } label: {
                            Label {
                                Text(step.title)
                                    .strikethrough(step.isCompleted, color: Theme.Colors.tertiaryText)
                                    .foregroundStyle(
                                        step.isCompleted
                                            ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                                    )
                            } icon: {
                                Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        step.isCompleted
                                            ? Theme.Colors.completed : Theme.Colors.secondaryText
                                    )
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                act { try $0.reminderLifecycle.removeChecklistItem(step.id, from: item) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    ChecklistEntryRow { titleText in
                        act { try $0.reminderLifecycle.addChecklistItem(titleText, to: item) }
                    }
                }
            } else if item.kind.supportsStatus {
                Section {
                    ChecklistEntryRow { titleText in
                        act { try $0.reminderLifecycle.addChecklistItem(titleText, to: item) }
                    }
                } header: {
                    Text("Checklist")
                }
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagsSection(_ item: Item) -> some View {
        if item.kind.supportedFields.contains(.tags) {
            Section {
                Button {
                    isEditingTags = true
                } label: {
                    if item.tagSlugs.isEmpty {
                        Label("Add Tags", systemImage: "number")
                            .foregroundStyle(Theme.Colors.secondaryText)
                    } else {
                        TagChipRow(slugs: item.tagSlugs, limit: 6)
                    }
                }
            }
        }
    }

    // MARK: - Children

    @ViewBuilder
    private func childrenSection(_ item: Item) -> some View {
        let children = (try? services?.items.items(matching: ItemQuery.children(of: item.id))) ?? []
        if !children.isEmpty {
            Section(item.kind == .task ? "Subtasks" : "Contents") {
                ForEach(children) { child in
                    MobileItemRow(item: child, onToggleCompletion: child.kind.supportsStatus ? {
                        act { try $0.items.toggleCompletion(child) }
                    } : nil)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            pending.flush()
                            shell.push(MobileShellModel.route(for: child.kind, id: child.id))
                        }
                }
            }
        }
    }

    // MARK: - Backlinks

    @ViewBuilder
    private func backlinksSection(_ item: Item) -> some View {
        let backlinks = item.visibleBacklinks()
        if !backlinks.isEmpty {
            Section("Linked from") {
                ForEach(backlinks, id: \.id) { link in
                    if let source = link.source {
                        Button {
                            pending.flush()
                            shell.push(MobileShellModel.route(for: source.kind, id: source.id))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                    Text(source.displayTitle)
                                        .foregroundStyle(Theme.Colors.primaryText)
                                    Text(link.label)
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                            } icon: {
                                Image(systemName: source.effectiveSymbolName)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ item: Item) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Start Timer", systemImage: "play.circle") {
                    services?.timer.switchTo(item: item)
                }
                if item.archivedAt == nil {
                    Button("Archive", systemImage: "archivebox") {
                        act { try $0.items.setArchived(item, true) }
                    }
                } else {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") {
                        act { try $0.items.setArchived(item, false) }
                    }
                }
                if item.kind == .task || item.kind == .note {
                    Button(
                        item.kind == .task ? "Convert to Note" : "Convert to Task",
                        systemImage: item.kind == .task ? "note.text" : "checkmark.circle"
                    ) {
                        act { _ = try $0.items.setKind(item, to: item.kind == .task ? .note : .task) }
                    }
                }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    moveToTrash(item)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("item.more")
        }
    }

    // MARK: - Loading & saving

    private func load() {
        guard let services else { return }
        defer { hasLoaded = true }
        guard let loaded = try? services.items.item(id: itemID) else {
            item = nil
            return
        }
        item = loaded
        title = loaded.title
        bodyText = loaded.body
        services.registerSuspensionFlush(itemID) { pending.flush() }
    }

    private func scheduleSave() {
        pending.schedule { saveText() }
    }

    /// Writes the text as it stands. The body goes through the note document when one
    /// exists, so a note written richly on the Mac and edited plainly here stays one
    /// document rather than two diverging copies.
    private func saveText() {
        guard let services, let item else { return }
        let newTitle = title
        let newBody = bodyText
        guard newTitle != item.title || newBody != item.body else { return }

        services.perform {
            try services.items.update(item) { live in
                live.title = newTitle
                if live.body != newBody {
                    if live.noteDocumentData != nil {
                        live.setNoteDocument(NoteBodyImport.document(from: newBody))
                    } else {
                        live.body = newBody
                    }
                }
            }
            services.noteChange(to: item)
        }
    }

    private func act(_ work: @escaping (AppServices) throws -> Void) {
        guard let services, let item else { return }
        pending.flush()
        services.perform {
            try work(services)
            services.noteChange(to: item)
        }
        load()
    }

    private func moveToTrash(_ item: Item) {
        guard let services else { return }
        pending.cancel()
        let id = item.id
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
        dismiss()
    }
}

// MARK: - Small editors

/// One bug fact as a growing text field that writes on focus loss.
private struct BugFactRow: View {
    let label: String
    let initial: String
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
            TextField(label, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($isFocused)
        }
        .onAppear { text = initial }
        .onChange(of: isFocused) { was, isNow in
            if was, !isNow, text != initial { commit(text) }
        }
    }
}

/// The add-a-step row at the foot of a checklist.
private struct ChecklistEntryRow: View {
    let add: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundStyle(Theme.Colors.secondaryText)
            TextField("Add a step", text: $text)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    add(trimmed)
                    text = ""
                }
        }
    }
}

/// Tag editing: existing tags as toggles, plus a field for a new one.
private struct TagEditorSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let item: Item
    var onChange: () -> Void

    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New tag — e.g. work/clients", text: $newTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addNewTag)
                }

                if let services {
                    let all = ((try? services.tags.allTags()) ?? []).map(\.slug)
                    if !all.isEmpty {
                        Section("Your tags") {
                            ForEach(all, id: \.self) { slug in
                                Button {
                                    toggle(slug)
                                } label: {
                                    HStack {
                                        TagChip(slug: slug)
                                        Spacer()
                                        if item.tagSlugs.contains(slug) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Theme.Colors.selection)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addNewTag() {
        let slug = TextNormalizer.slug(newTag)
        guard !slug.isEmpty else { return }
        var slugs = item.tagSlugs
        guard !slugs.contains(slug) else { return }
        slugs.append(slug)
        write(slugs)
        newTag = ""
    }

    private func toggle(_ slug: String) {
        var slugs = item.tagSlugs
        if let index = slugs.firstIndex(of: slug) {
            slugs.remove(at: index)
        } else {
            slugs.append(slug)
        }
        write(slugs)
    }

    private func write(_ slugs: [String]) {
        guard let services else { return }
        services.perform {
            try services.items.setTags(item, slugs: slugs)
            services.noteChange(to: item)
        }
        onChange()
    }
}
