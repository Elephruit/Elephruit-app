import AppKit
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Selection rules for the Reminders tag rail.
///
/// A plain click behaves like a single-choice filter. Command-click extends that selection, which
/// makes the interaction match selection elsewhere on macOS without turning every click into an
/// accumulating filter. Multiple tags are inclusive: a reminder carrying any selected tag stays
/// visible.
struct ReminderTagSelection: Equatable {
    private(set) var slugs: Set<String> = []

    var showsAll: Bool { slugs.isEmpty }

    mutating func select(_ slug: String, extending: Bool) {
        if extending {
            if slugs.remove(slug) == nil {
                slugs.insert(slug)
            }
        } else if slugs == [slug] {
            slugs.removeAll()
        } else {
            slugs = [slug]
        }
    }

    mutating func showAll() {
        slugs.removeAll()
    }

    /// A filter for a tag that no visible reminder carries is a filter nothing can satisfy;
    /// it leaves the selection rather than silently emptying the list.
    mutating func reconcile(availableSlugs: Set<String>) {
        slugs.formIntersection(availableSlugs)
    }

    func includes(tagSlugs: [String]) -> Bool {
        showsAll || !slugs.isDisjoint(with: tagSlugs)
    }
}

/// The two independent filters applied to the Reminders list.
///
/// Completed reminders are hidden by default: the list's job is what still needs doing, and the
/// record of what got done is one deliberate click away rather than interleaved with it.
struct ReminderVisibility: Equatable {
    var showsCompleted = false
    var tags = ReminderTagSelection()

    func includes(isCompleted: Bool, tagSlugs: [String]) -> Bool {
        (showsCompleted || !isCompleted) && tags.includes(tagSlugs: tagSlugs)
    }
}

/// The Reminders module: one compact list over first-class graph items.
struct RemindersWorkspaceView: View {
    @Environment(\.services) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let navigation: NavigationModel

    @State private var isComposing = false
    @State private var editingReminderID: UUID?
    @State private var draft = ReminderComposerDraft()
    @State private var visibility = ReminderVisibility()

    var body: some View {
        VStack(spacing: 0) {
            filterRail
            Divider()
            content
            Divider()
            bottomBar
        }
        .background(Theme.Colors.windowBackground)
        .navigationTitle("Reminders")
        .accessibilityIdentifier("reminders.workspace")
        .onAppear(perform: openLinkedReminderIfNeeded)
        .onChange(of: navigation.selectedItemID) { _, _ in openLinkedReminderIfNeeded() }
        .onChange(of: navigation.reminderComposerRequest) { _, _ in openComposer() }
        .onChange(of: activeTags.map(\.slug)) { _, slugs in
            visibility.tags.reconcile(availableSlugs: Set(slugs))
        }
        // ⌘N still creates a reminder while this surface has focus — through the File menu's
        // focused command, the key's one owner, rather than a second binding on the button.
        .focusedSceneValue(
            \.newItemCommand,
            NewItemCommand(title: "New Reminder") { openComposer() }
        )
    }

    // MARK: - The filter rail

    /// The first content row: what to show, not what this screen is called — the window title
    /// already says "Reminders" once, which is the right number of times.
    ///
    /// The tag rail scrolls when tags outgrow the width; the Completed control never scrolls
    /// away with them, because "where did my finished reminders go" deserves a fixed answer.
    private var filterRail: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    allFilterChip

                    ForEach(activeTags, id: \.id) { tag in
                        tagFilterChip(tag)
                    }
                }
                .padding(.leading, Theme.Spacing.large)
                .padding(.trailing, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.medium)
            }
            .scrollIndicators(.hidden)

            Divider()
                .frame(height: 22)

            completedToggle
                .padding(.horizontal, Theme.Spacing.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.tagFilter")
    }

    private var allFilterChip: some View {
        Button {
            visibility.tags.showAll()
        } label: {
            Text("All")
                .lineLimit(1)
                .font(Theme.Text.rowSubtitle.weight(.medium))
                .foregroundStyle(
                    visibility.tags.showsAll ? Theme.Colors.onAccent : Theme.Colors.secondaryText
                )
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(
                            visibility.tags.showsAll
                                ? AnyShapeStyle(Theme.Colors.selection)
                                : AnyShapeStyle(Theme.Colors.subtleFill)
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Show every reminder, whatever its tags")
        .accessibilityLabel("Clear tag filters")
        .accessibilityAddTraits(visibility.tags.showsAll ? .isSelected : [])
        .accessibilityIdentifier("reminders.tagFilter.all")
    }

    private func tagFilterChip(_ tag: Tag) -> some View {
        let isSelected = visibility.tags.slugs.contains(tag.slug)
        return Button {
            selectTag(tag.slug)
        } label: {
            TagChip(slug: tag.slug, colorName: tag.colorName, isSelected: isSelected, size: .prominent)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("reminders.tagFilter.\(tag.slug)")
        .contextMenu { colorMenu(for: tag) }
        .help(
            "Filter by #\(tag.slug). Command-click to select more than one tag. "
                + "Right-click to change its color."
        )
    }

    /// Reads state with all five voices the spec of a good toggle asks for: the words, the icon,
    /// the fill, the tooltip, and what a screen reader is told.
    private var completedToggle: some View {
        Button {
            visibility.showsCompleted.toggle()
        } label: {
            Label(
                "Completed",
                systemImage: visibility.showsCompleted ? "checkmark.circle.fill" : "checkmark.circle"
            )
            .lineLimit(1)
            .font(Theme.Text.rowSubtitle.weight(.medium))
            .foregroundStyle(
                visibility.showsCompleted ? Theme.Colors.onAccent : Theme.Colors.secondaryText
            )
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(
                        visibility.showsCompleted
                            ? AnyShapeStyle(Theme.Colors.selection)
                            : AnyShapeStyle(Theme.Colors.subtleFill)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(visibility.showsCompleted ? "Hide completed reminders" : "Show completed reminders")
        .accessibilityLabel(
            visibility.showsCompleted ? "Hide completed reminders" : "Show completed reminders"
        )
        .accessibilityAddTraits(visibility.showsCompleted ? .isSelected : [])
        .accessibilityIdentifier("reminders.showCompleted")
    }

    private func selectTag(_ slug: String) {
        let extendsSelection = NSApplication.shared.currentEvent?
            .modifierFlags.contains(.command) == true
        visibility.tags.select(slug, extending: extendsSelection)
    }

    /// Every colour a tag can wear, each shown as itself.
    ///
    /// A menu of colour *names* asks the reader to imagine thirteen colours; a swatch beside
    /// each name asks nothing.
    @ViewBuilder
    private func colorMenu(for tag: Tag) -> some View {
        Menu("Color") {
            colorChoice(named: nil, label: "Default", swatch: Theme.Colors.secondaryText, for: tag)

            ForEach(Theme.Palette.allCases, id: \.rawValue) { entry in
                colorChoice(named: entry.rawValue, label: entry.displayName, swatch: entry.color, for: tag)
            }
        }
    }

    private func colorChoice(named name: String?, label: String, swatch: Color, for tag: Tag) -> some View {
        Toggle(isOn: Binding(
            get: { tag.colorName == name },
            set: { _ in setColor(name, for: tag) }
        )) {
            Label {
                Text(label)
            } icon: {
                Image(nsImage: Self.swatchImage(for: swatch))
            }
        }
    }

    /// A small rounded square of the colour itself. An `NSImage`, because a menu row renders its
    /// icon as an image and quietly drops any other view.
    private static func swatchImage(for color: Color) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: Theme.Radius.small,
                yRadius: Theme.Radius.small
            )
            NSColor(color).setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func setColor(_ colorName: String?, for tag: Tag) {
        guard let services else { return }
        services.perform { try services.tags.setColor(tag, colorName: colorName) }
        services.refreshDerivedState()
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if visibleReminders.isEmpty && !isComposing {
            EmptyStateView(
                symbolName: "bell",
                headline: emptyStateHeadline,
                message: emptyStateMessage,
                actionTitle: "New Reminder",
                action: openComposer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    if isComposing && editingReminderID == nil {
                        ReminderComposer(
                            draft: $draft,
                            onQuickCommit: { commit(keepsOpen: true) },
                            onCommitAndClose: { commit(keepsOpen: false) },
                            onCancel: closeComposer
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }

                    ForEach(visibleReminders) { reminder in
                        if editingReminderID == reminder.id {
                            ReminderComposer(
                                draft: $draft,
                                onQuickCommit: { commit(keepsOpen: false) },
                                onCommitAndClose: { commit(keepsOpen: false) },
                                onCancel: closeComposer
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        } else {
                            reminderRow(reminder)
                        }
                    }
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: openComposer) {
                Label("New Reminder", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(isComposing)

            Spacer()

            Text("Return saves · ⌘Return closes · Esc cancels")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: 44)
        .background(.bar)
    }

    private func reminderRow(_ reminder: Item) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Button {
                services?.perform {
                    guard let services else { return }
                    try services.reminderStore.toggleCompletion(of: reminder)
                    services.noteChange(to: reminder)
                }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        reminder.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(reminder.title)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(
                        reminder.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.primaryText
                    )

                if !reminder.body.isEmpty {
                    Text(reminder.body)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                }

                metadata(for: reminder)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openComposer(editing: reminder) }
        .accessibilityAction(named: "Edit Reminder") { openComposer(editing: reminder) }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                openComposer(editing: reminder)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                services?.perform {
                    guard let services else { return }
                    try services.reminderStore.delete(reminder)
                    services.noteChange(to: reminder)
                }
            }
        }
    }

    // MARK: - Metadata

    /// One fact under a reminder's title: what kind of fact, said with a symbol *and* a word,
    /// tinted with what the fact means.
    private struct MetadataFact: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let tint: Color
    }

    /// Facts as chips, flowing and wrapping, never one pale sentence.
    ///
    /// `FlowLayout` wraps at narrow widths, so a reminder wearing a project, a deadline, two
    /// people and a tag stays readable in a compact window instead of compressing into ellipses
    /// or demanding a horizontal scroller.
    @ViewBuilder
    private func metadata(for reminder: Item) -> some View {
        let facts = metadataFacts(for: reminder)
        let tags = (reminder.tags ?? []).sorted {
            $0.slug.localizedStandardCompare($1.slug) == .orderedAscending
        }
        let checklist = checklistFact(for: reminder)
        if !facts.isEmpty || !tags.isEmpty || checklist != nil {
            FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                ForEach(facts) { fact in
                    metadataChip(fact)
                }
                ForEach(tags, id: \.id) { tag in
                    TagChip(slug: tag.slug, colorName: tag.colorName, size: .prominent)
                }
                if let checklist {
                    metadataChip(checklist)
                }
            }
        }
    }

    private func metadataChip(_ fact: MetadataFact) -> some View {
        HStack(spacing: Theme.Spacing.hairline) {
            Image(systemName: fact.symbol)
            Text(fact.text)
                .lineLimit(1)
        }
        .font(Theme.Text.rowSubtitle)
        .foregroundStyle(fact.tint)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Colors.tintedFill(fact.tint))
        )
        .accessibilityElement(children: .combine)
    }

    private func metadataFacts(for reminder: Item) -> [MetadataFact] {
        guard let clock = services?.dateProvider else { return [] }
        var facts: [MetadataFact] = []

        if reminder.isSomeday {
            facts.append(MetadataFact(
                id: "someday",
                symbol: "archivebox",
                text: "Someday",
                tint: Theme.Colors.secondaryText
            ))
        } else if let startAt = reminder.startAt {
            facts.append(MetadataFact(
                id: "scheduled",
                symbol: "calendar",
                text: "Scheduled \(RelativeDay.text(for: startAt, using: clock))",
                tint: Theme.Colors.secondaryText
            ))
        }

        if let dueAt = reminder.dueAt {
            facts.append(MetadataFact(
                id: "deadline",
                symbol: "calendar.badge.exclamationmark",
                text: "Deadline \(RelativeDay.text(for: dueAt, using: clock))",
                // A finished reminder's deadline is history; urgency is for the ones still open.
                tint: reminder.isCompleted
                    ? Theme.Colors.secondaryText
                    : DateUrgency.color(for: dueAt, using: clock)
            ))
        }

        if reminder.parent?.kind == .project, let project = reminder.parent {
            facts.append(MetadataFact(
                id: "project",
                symbol: "folder",
                text: project.displayTitle,
                // `color(named:)` falls back to the accent, which is the app's link colour:
                // an unpainted project still reads as somewhere you can go.
                tint: Theme.Palette.color(named: project.colorName)
            ))
        }

        let people = (reminder.outgoingLinks ?? []).compactMap { link -> Item? in
            guard link.kind == .mentions,
                  let target = link.target,
                  target.kind == .person || target.kind == .organization
            else { return nil }
            return target
        }
        for person in people.sorted(by: { $0.displayTitle < $1.displayTitle }) {
            facts.append(MetadataFact(
                id: "person-\(person.id.uuidString)",
                symbol: "person",
                text: person.displayTitle,
                tint: Theme.Palette.color(named: person.colorName, neutral: Theme.Colors.link)
            ))
        }

        return facts
    }

    /// "2 of 3 steps" once any step is done; the bare count until then; the completed green
    /// only when the list has nothing left to give.
    private func checklistFact(for reminder: Item) -> MetadataFact? {
        let checklist = reminder.checklist
        guard !checklist.isEmpty else { return nil }

        let text: String
        if checklist.completed > 0 {
            text = "\(checklist.completed) of \(checklist.total) steps"
        } else {
            text = checklist.total == 1 ? "1 step" : "\(checklist.total) steps"
        }

        let isDone = checklist.completed == checklist.total
        return MetadataFact(
            id: "checklist",
            symbol: "checklist",
            text: text,
            tint: isDone ? Theme.Colors.completed : Theme.Colors.secondaryText
        )
    }

    // MARK: - Visibility

    private var allReminders: [Item] {
        services?.reminderStore.reminders ?? []
    }

    /// What the list shows: the visibility filters, with one exception — the reminder being
    /// edited stays visible even when a filter change would hide it, because a form that
    /// vanishes mid-edit takes the user's typing with it.
    private var visibleReminders: [Item] {
        allReminders.filter {
            $0.id == editingReminderID
                || visibility.includes(isCompleted: $0.isCompleted, tagSlugs: $0.tagSlugs)
        }
    }

    /// Tags carried by reminders eligible for display, rather than every historical tag in the
    /// library. A tag used only by completed reminders appears only while completed reminders
    /// do — a filter should never offer what it cannot show.
    private var activeTags: [Tag] {
        var tagsByID: [UUID: Tag] = [:]
        let eligible = allReminders.filter { visibility.showsCompleted || !$0.isCompleted }
        for tag in eligible.flatMap({ $0.tags ?? [] }) {
            tagsByID[tag.id] = tag
        }
        return tagsByID.values.sorted {
            $0.slug.localizedStandardCompare($1.slug) == .orderedAscending
        }
    }

    private var emptyStateHeadline: String {
        if hasHiddenCompletedReminders { return "No open reminders" }
        if !visibility.tags.showsAll { return "No matching reminders" }
        return "No reminders"
    }

    private var emptyStateMessage: String {
        if hasHiddenCompletedReminders {
            return "Completed reminders are hidden. Use Completed above to show them."
        }
        if !visibility.tags.showsAll {
            return "Nothing carries the selected tags."
        }
        return "Keep everything you need to remember in one place."
    }

    private var hasHiddenCompletedReminders: Bool {
        !visibility.showsCompleted && allReminders.contains(where: \.isCompleted)
    }

    // MARK: - Opening and editing

    /// A reminder opened from elsewhere — ⌘K, a link, a redirect — must actually appear:
    /// tag filters clear, and a completed one brings the completed section out with it.
    private func openLinkedReminderIfNeeded() {
        guard !isComposing,
              let id = navigation.selectedItemID,
              let reminder = allReminders.first(where: { $0.id == id })
        else { return }
        visibility.tags.showAll()
        if reminder.isCompleted {
            visibility.showsCompleted = true
        }
        openComposer(editing: reminder)
    }

    private func openComposer() {
        guard !isComposing else { return }
        editingReminderID = nil
        draft.reset()
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
    }

    private func openComposer(editing reminder: Item) {
        guard !isComposing else { return }
        draft = ReminderComposerDraft(reminder: reminder)
        editingReminderID = reminder.id
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = true
        }
    }

    private func closeComposer() {
        withAnimation(Theme.Motion.respectingReduceMotion(Theme.Motion.appearance, reduceMotion: reduceMotion)) {
            isComposing = false
        }
        editingReminderID = nil
        draft.reset()
    }

    private func commit(keepsOpen: Bool) {
        draft.commitPendingStep()
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let services
        else {
            if !keepsOpen { closeComposer() }
            return
        }

        let committed = draft
        let reminderID = editingReminderID
        services.perform {
            if let reminderID,
               let reminder = services.reminderStore.reminders.first(where: { $0.id == reminderID }) {
                try services.reminderStore.update(reminder, from: committed)
                services.noteChange(to: reminder)
            } else {
                let reminder = try services.reminderStore.create(from: committed)
                services.noteChange(to: reminder)
            }
        }

        if keepsOpen && reminderID == nil {
            draft.reset()
        } else {
            closeComposer()
        }
    }
}
