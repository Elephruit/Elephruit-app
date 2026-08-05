import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The reminder editor, inline in the list — the Mac's card, laid out for a thumb.
///
/// ### The same six things, in the same order
/// The Mac's composer is a card in two halves: what you wrote on top — title, notes, the
/// checklist, and chips summarising everything chosen — and a rule of controls underneath,
/// Project on the leading edge and then When, Tags, People, Checklist, Deadline. This is that
/// card. Same six fields, same order, same words, and the same rule that a chosen value is
/// shown twice: once as a chip you can take off, and once on the control that set it.
///
/// ### What changes, and why
/// The Mac drives all of it from the keyboard — eight focus stops, popovers anchored to each
/// control, a date search answering `we` and `8`. A thumb has no Tab key, so each control opens
/// a sheet instead of a popover, and the sheets are lists rather than query fields. The
/// *arrangement* is what makes the two apps recognisable as one app; the input method is what
/// makes each of them usable on its own machine.
struct MobileReminderComposer: View {
    @Environment(\.services) private var services

    @Binding var draft: ReminderComposerDraft

    /// Saves and stays open, for writing several in a row.
    var onQuickCommit: () -> Void
    /// Saves and closes.
    var onCommitAndClose: () -> Void
    /// Closes without saving.
    var onCancel: () -> Void

    @FocusState private var focus: Field?
    @State private var vocabulary = CaptureVocabulary.empty
    @State private var sheet: Sheet?
    /// Whether the checklist's entry row is showing, mirroring the Mac's `.checklist` stop.
    @State private var isAddingStep = false

    private enum Field: Hashable { case title, notes, step }

    /// Which picker is up. One piece of state for all five, because only one can be.
    private enum Sheet: String, Identifiable {
        case when, deadline, tags, people, project
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                titleLine
                notesField
                checklist
                metadataSummary
            }
            .padding(Theme.Spacing.medium)

            Divider()
            actionRow
        }
        .background(
            Theme.Colors.contentBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Colors.separator)
        )
        .elevation(.floating)
        .toolbar { keyboardBar }
        .task {
            vocabulary = (try? services?.capture.vocabulary()) ?? .empty
            focus = .title
        }
        .sheet(item: $sheet) { which in
            picker(for: which)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.composer")
    }

    // MARK: - What you wrote

    /// The title, and the one control that is not a field: the way out.
    ///
    /// Top-trailing because that is where a card's dismiss lives on this platform, and because
    /// the alternative — making the only exit a button below the fold, under the keyboard — is
    /// how a composer opened by a stray tap becomes a trap.
    private var titleLine: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            TextField("New reminder", text: $draft.title, axis: .vertical)
                .font(Theme.Text.rowTitle)
                .lineLimit(1...4)
                .focused($focus, equals: .title)
                .submitLabel(.done)
                // Return saves and leaves the editor open, which is the Mac's quick commit and
                // the reason eight reminders are eight sentences rather than eight round trips.
                .onSubmit(onQuickCommit)
                .accessibilityIdentifier("reminders.composer.title")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(Theme.Text.metadata.weight(.semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard this reminder")
            .accessibilityIdentifier("reminders.composer.dismiss")
        }
    }

    private var notesField: some View {
        TextField("Notes", text: $draft.notes, axis: .vertical)
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.secondaryText)
            .lineLimit(1...6)
            .focused($focus, equals: .notes)
            .accessibilityIdentifier("reminders.composer.notes")
    }

    /// The steps, and the row that adds one — shown when there are steps or when Checklist was
    /// tapped, exactly as the Mac shows it when it holds content or holds focus.
    @ViewBuilder
    private var checklist: some View {
        if draft.hasChecklistContent || isAddingStep {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                ForEach(draft.checklist) { step in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(step.title)
                            .font(Theme.Text.rowSubtitle)
                        Spacer(minLength: 0)
                        Button {
                            draft.checklist.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove the step \(step.title)")
                    }
                    .frame(minHeight: 32)
                }

                if isAddingStep {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "circle")
                            .foregroundStyle(Theme.Colors.selection)
                        TextField("Add a step", text: $draft.pendingStep)
                            .font(Theme.Text.rowSubtitle)
                            .focused($focus, equals: .step)
                            .submitLabel(.next)
                            // Return commits the step and stays, so a five-step checklist is
                            // five lines of typing — the Mac's behaviour on its own keyboard.
                            .onSubmit {
                                draft.commitPendingStep()
                                focus = .step
                            }
                            .accessibilityIdentifier("reminders.composer.checklistField")
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .frame(minHeight: 32)
                    .background(
                        Theme.Colors.selectionFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    )
                }
            }
        }
    }

    /// Everything chosen, as chips that can be taken off.
    ///
    /// The Mac's `metadataSummary`, field for field: tags, then people, then the dates. Shown
    /// above the controls rather than only on them because a control can hold one label and a
    /// reminder can carry four tags.
    @ViewBuilder
    private var metadataSummary: some View {
        let hasDates = draft.startAt != nil || draft.dueAt != nil || draft.isSomeday
        if !draft.tagSlugs.isEmpty || !draft.personNames.isEmpty || hasDates
            || draft.projectTitle != nil {
            FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                if let project = draft.projectTitle {
                    removableChip(project, symbol: "square.stack.3d.up", tint: Theme.Colors.link) {
                        draft.projectTitle = nil
                    }
                }

                ForEach(draft.tagSlugs, id: \.self) { slug in
                    removableChip(
                        TextNormalizer.slugComponents(slug).last ?? slug,
                        symbol: "number",
                        tint: Theme.Colors.secondaryText
                    ) {
                        draft.tagSlugs.removeAll { $0 == slug }
                    }
                }

                ForEach(draft.personNames, id: \.self) { name in
                    removableChip(name, symbol: "person", tint: Theme.Colors.link) {
                        draft.personNames.removeAll { $0 == name }
                    }
                }

                if let start = draft.startAt {
                    removableChip(
                        "When: \(shortDate(start))",
                        symbol: "calendar",
                        tint: Theme.Colors.selection
                    ) {
                        draft.startAt = nil
                        draft.isSomeday = false
                    }
                } else if draft.isSomeday {
                    removableChip(
                        "Someday",
                        symbol: "archivebox",
                        tint: Theme.Colors.secondaryText
                    ) {
                        draft.isSomeday = false
                    }
                }

                if let deadline = draft.dueAt {
                    removableChip(
                        "Deadline: \(shortDate(deadline))",
                        symbol: "flag",
                        // The deadline chip carries urgency, the same as the row's does: a
                        // deadline is the only date here that can make anything late.
                        tint: services.map { DateUrgency.color(for: deadline, using: $0.dateProvider) }
                            ?? Theme.Colors.secondaryText
                    ) {
                        draft.dueAt = nil
                    }
                }
            }
            .accessibilityIdentifier("reminders.composer.summary")
        }
    }

    private func removableChip(
        _ label: String,
        symbol: String,
        tint: Color,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Spacing.hairline) {
            Image(systemName: symbol)
            Text(label).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(tint.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .font(Theme.Text.chip)
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(Capsule().fill(Theme.Colors.tintedFill(tint)))
    }

    // MARK: - The controls

    /// The Mac's action row: Project on the leading edge, then the five that qualify it.
    ///
    /// Horizontally scrollable because six controls do not fit across a phone. The order is the
    /// Mac's rather than a fitted subset — a control moved for space is a control somebody has
    /// to find twice.
    /// The six controls, in the Mac's order.
    ///
    /// Done is deliberately not among them. It began inside this scroller, which put the button
    /// that finishes the job off the right-hand edge of the screen; moving it beside the
    /// scroller only moved the problem, because this row sits *below* the title field and the
    /// keyboard covers it the entire time you are typing. A commit action you cannot reach
    /// while writing is not a commit action, so it lives on the keyboard's own bar — see
    /// `keyboardBar`, which is where iOS puts exactly this.
    private var actionRow: some View {
        controlScroller
            .background(Theme.Colors.subtleFill)
    }

    private var controlScroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                control(
                    title: draft.projectTitle ?? "Project",
                    symbol: "square.stack.3d.up",
                    isActive: draft.projectTitle != nil,
                    identifier: "project"
                ) { sheet = .project }

                control(
                    title: draft.isSomeday ? "Someday" : draft.startAt.map(shortDate) ?? "When",
                    symbol: "calendar",
                    isActive: draft.startAt != nil || draft.isSomeday,
                    identifier: "when"
                ) { sheet = .when }

                control(
                    title: draft.tagSlugs.isEmpty ? "Tags" : "\(draft.tagSlugs.count) tags",
                    symbol: "tag",
                    isActive: !draft.tagSlugs.isEmpty,
                    identifier: "tags"
                ) { sheet = .tags }

                control(
                    title: draft.personNames.isEmpty ? "People" : "\(draft.personNames.count) people",
                    symbol: "person",
                    isActive: !draft.personNames.isEmpty,
                    identifier: "people"
                ) { sheet = .people }

                control(
                    title: draft.checklist.isEmpty ? "Checklist" : "\(draft.checklist.count) items",
                    symbol: "checklist",
                    isActive: !draft.checklist.isEmpty,
                    identifier: "checklist"
                ) {
                    withCalmAnimation { isAddingStep = true }
                    focus = .step
                }

                control(
                    title: draft.dueAt.map(shortDate) ?? "Deadline",
                    symbol: "flag",
                    isActive: draft.dueAt != nil,
                    identifier: "deadline"
                ) { sheet = .deadline }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
        .scrollIndicators(.hidden)
    }

    /// Done, on the bar above the keyboard — the only place on this screen that is guaranteed
    /// to be visible while the keyboard is up, which is the whole time a reminder is being
    /// written.
    @ToolbarContentBuilder
    private var keyboardBar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done", action: onCommitAndClose)
                .font(Theme.Text.rowTitle.weight(.semibold))
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("reminders.composer.done")
        }
    }

    private func control(
        title: String,
        symbol: String,
        isActive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.hairline) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
            }
            .font(Theme.Text.chip)
            .foregroundStyle(isActive ? Theme.Colors.selection : Theme.Colors.secondaryText)
            .padding(.horizontal, Theme.Spacing.small)
            // 32 rather than 44: these sit inside a card that is itself inside a list, and a
            // 44-point rule here would make the composer taller than the rows it edits. The
            // targets are still comfortably above the visual size of their labels.
            .frame(minHeight: 32)
            .background(
                Capsule().fill(
                    isActive ? Theme.Colors.selectionFill : Theme.Colors.contentBackground
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("reminders.composer.\(identifier)")
    }

    // MARK: - The pickers

    @ViewBuilder
    private func picker(for which: Sheet) -> some View {
        switch which {
        case .when:
            MobileDayPickerSheet(
                title: "When",
                selection: $draft.startAt,
                isSomeday: $draft.isSomeday
            )
        case .deadline:
            MobileDayPickerSheet(title: "Deadline", selection: $draft.dueAt, isSomeday: nil)
        case .tags:
            MobileTagPickerSheet(selected: $draft.tagSlugs)
        case .people:
            MobilePeoplePickerSheet(selected: $draft.personNames)
        case .project:
            MobileProjectPickerSheet(selected: $draft.projectTitle)
        }
    }

    private func shortDate(_ date: Date) -> String {
        guard let clock = services?.dateProvider else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return RelativeDay.text(for: date, using: clock)
    }
}

// MARK: - Day

/// One day, chosen.
///
/// A day rather than an instant: every scheduling decision this app makes is about which day
/// something belongs to, and a picker offering 3:47 PM would offer precision the model does not
/// keep. The quick rows come first because they answer the question most of the time.
struct MobileDayPickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var selection: Date?
    /// Bound only for When: Someday is a *kind* of when, and a deadline cannot be someday.
    var isSomeday: Binding<Bool>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickRow("Today", daysFromToday: 0)
                    quickRow("Tomorrow", daysFromToday: 1)
                    quickRow("Next week", daysFromToday: 7)

                    if let isSomeday {
                        Button {
                            isSomeday.wrappedValue = true
                            selection = nil
                            dismiss()
                        } label: {
                            Label("Someday", systemImage: "archivebox")
                        }
                        .accessibilityIdentifier("reminders.picker.someday")
                    }
                }

                Section {
                    DatePicker(
                        title,
                        selection: Binding(
                            get: { selection ?? services?.dateProvider.startOfToday ?? Date() },
                            set: {
                                selection = $0
                                isSomeday?.wrappedValue = false
                            }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                }

                if selection != nil || isSomeday?.wrappedValue == true {
                    Section {
                        Button("Clear", role: .destructive) {
                            selection = nil
                            isSomeday?.wrappedValue = false
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quickRow(_ label: String, daysFromToday: Int) -> some View {
        Button(label) {
            selection = services?.dateProvider.startOfDay(daysFromToday: daysFromToday)
            isSomeday?.wrappedValue = false
            dismiss()
        }
    }
}

// MARK: - Tags

/// The library's tags, plus room to coin one.
struct MobileTagPickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @Binding var selected: [String]

    @State private var query = ""
    @State private var tags: [Tag] = []

    var body: some View {
        NavigationStack {
            List {
                // A tag that does not exist yet is the common case for a new reminder, so
                // coining one is a row rather than a separate mode.
                if !normalizedQuery.isEmpty, !tags.contains(where: { $0.slug == normalizedQuery }) {
                    Button {
                        toggle(normalizedQuery)
                    } label: {
                        Label("Add #\(normalizedQuery)", systemImage: "plus.circle")
                    }
                }

                ForEach(matching, id: \.id) { tag in
                    Button {
                        toggle(tag.slug)
                    } label: {
                        HStack {
                            TagChip(slug: tag.slug, colorName: tag.colorName)
                            Spacer(minLength: 0)
                            if selected.contains(tag.slug) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Colors.selection)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Find or add a tag")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { tags = (try? services?.tags.allTags()) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private var normalizedQuery: String {
        TextNormalizer.slug(query)
    }

    private var matching: [Tag] {
        guard !normalizedQuery.isEmpty else { return tags }
        return tags.filter { $0.slug.contains(normalizedQuery) }
    }

    private func toggle(_ slug: String) {
        if let index = selected.firstIndex(of: slug) {
            selected.remove(at: index)
        } else {
            selected.append(slug)
        }
    }
}

// MARK: - People

/// Who this reminder is about. The same records the Records module lists.
struct MobilePeoplePickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @Binding var selected: [String]

    @State private var query = ""
    @State private var records: [Item] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(matching) { record in
                    Button {
                        toggle(record.displayTitle)
                    } label: {
                        HStack {
                            Label(record.displayTitle, systemImage: record.effectiveSymbolName)
                                .foregroundStyle(Theme.Colors.primaryText)
                            Spacer(minLength: 0)
                            if selected.contains(record.displayTitle) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Colors.selection)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Find a person")
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { records = (try? services?.records.allRecords()) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private var matching: [Item] {
        let wanted = TextNormalizer.foldedForMatching(query)
        guard !wanted.isEmpty else { return records }
        return records.filter {
            TextNormalizer.foldedForMatching($0.displayTitle).contains(wanted)
        }
    }

    private func toggle(_ name: String) {
        if let index = selected.firstIndex(of: name) {
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
    }
}

// MARK: - Project

/// Which project this belongs to. One, or none — the model allows a single parent.
struct MobileProjectPickerSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @Binding var selected: String?

    @State private var query = ""
    @State private var projects: [Item] = []

    var body: some View {
        NavigationStack {
            List {
                if selected != nil {
                    Button("None", role: .destructive) {
                        selected = nil
                        dismiss()
                    }
                }

                ForEach(matching) { project in
                    Button {
                        selected = project.displayTitle
                        dismiss()
                    } label: {
                        HStack {
                            Label(project.displayTitle, systemImage: "square.stack.3d.up")
                                .foregroundStyle(Theme.Colors.primaryText)
                            Spacer(minLength: 0)
                            if selected == project.displayTitle {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Colors.selection)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Find a project")
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                projects = (try? services?.items.items(matching: ItemQuery.kind(.project))) ?? []
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var matching: [Item] {
        let wanted = TextNormalizer.foldedForMatching(query)
        guard !wanted.isEmpty else { return projects }
        return projects.filter {
            TextNormalizer.foldedForMatching($0.displayTitle).contains(wanted)
        }
    }
}
