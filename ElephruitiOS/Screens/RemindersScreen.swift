import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftData
import SwiftUI

/// The Reminders module on a phone: the Mac's five buckets, and one tap to write anything.
///
/// ### Anywhere is the button
/// A floating button is a target you have to find and hit. Here the *surface* is the target:
/// a tap on any empty part of the list opens a composer where the next reminder goes, and it
/// animates in exactly as the Mac's does. The screen's whole job is collecting things you must
/// remember, so a tap that meant nothing else would be a tap wasted — and the one interaction
/// that has no wrong place to happen is the one you never have to aim.
///
/// ### The same five answers as the Mac
/// Overdue, Today, Upcoming, Anytime, Someday — read straight off `ReminderStore.sections`, so
/// the phone and the Mac cannot come to different conclusions about which bucket a reminder is
/// in. Absent sections stay absent rather than appearing empty, which is what keeps a short
/// list short.
struct RemindersScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    /// What the composer is doing, or nothing.
    ///
    /// A single optional rather than an `isComposing` flag beside an `editingID`, which is the
    /// same state spelled twice and can disagree with itself.
    private enum Composing: Equatable {
        case newReminder
        case editing(UUID)
    }

    /// How much reachable empty space follows the last row. Enough that a thumb landing below
    /// the list finds the target rather than the edge of it.
    private static let tapTargetTail: CGFloat = 220

    /// Where a row's separator starts: under the title, not under the completion circle, so
    /// the circles read as one column rather than as the first cell of a table.
    private static let separatorInset: CGFloat = 44

    @State private var composing: Composing?
    /// Which field the editor should arrive on, when the tap that opened it said so.
    @State private var openingField: ComposerField?
    @State private var draft = ReminderComposerDraft()
    @State private var showsCompleted = false
    @State private var actionError: String?

    /// The list, loaded rather than computed in the body.
    ///
    /// `ReminderStore.sections` runs a fetch every time it is read, which makes it a function
    /// wearing a property's clothes: reading it from `body` gave SwiftUI nothing to observe, so
    /// a reminder written by the composer landed in the store and never appeared on screen.
    /// Loading on `changeToken` is what every other screen in this target does, and it is the
    /// only version where the list is a picture of the library rather than of the last render.
    @State private var sections: [ReminderStore.SectionGroup] = []
    @State private var completed: [Item] = []

    var body: some View {
        ZStack {
            // Beneath the scroller, catching every tap the content did not want. This is the
            // "anywhere" in "tap anywhere": the background is not decoration, it is the
            // control.
            // White, not the window's grey. The grey existed to make each reminder's card
            // float above it, and cards on a phone list are chrome the content has to be read
            // through: thirteen rounded rectangles stacked down a 400-point column is thirteen
            // borders competing with thirteen titles. One white sheet, hairlines between the
            // rows, and the only card left is the composer — which is the one thing that
            // genuinely *is* floating above the list.
            Theme.Colors.contentBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: startNewReminder)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("New reminder")
                .accessibilityHint("Opens a composer at the end of the list")
                .accessibilityIdentifier("reminders.background")

            list
        }
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { smartListMenu }
            ToolbarItem(placement: .topBarTrailing) { completedToggle }
        }
        .task(id: services?.changeToken ?? 0) { reload() }
    }

    /// The saved rules over this library, as a menu rather than a permanent rail.
    ///
    /// The Mac can afford a sidebar section listing every smart list beside the reminders
    /// themselves. A phone cannot, and the choice is not between showing them and hiding them
    /// but between showing them *always* and showing them *when asked* — a menu is the second,
    /// and it costs one tap rather than a permanent share of a 400-point-wide screen.
    private var smartListMenu: some View {
        Menu {
            Section("Built in") {
                ForEach(BuiltInSmartList.all) { list in
                    Button(list.title, systemImage: list.symbolName) {
                        shell.push(.builtInSmartList(list.id))
                    }
                }
            }

            if !savedSmartLists.isEmpty {
                Section("Saved") {
                    ForEach(savedSmartLists, id: \.id) { saved in
                        Button(
                            saved.name,
                            systemImage: saved.symbolName ?? "line.3.horizontal.decrease.circle"
                        ) {
                            shell.push(.smartList(saved.id))
                        }
                    }
                }
            }
        } label: {
            Label("Lists", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("reminders.lists")
    }

    /// The user's own saved rules, in the order the Mac's sidebar puts them.
    private var savedSmartLists: [SavedSearch] {
        guard let services else { return [] }
        let descriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil && $0.taskFilterData != nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? services.context.fetch(descriptor)) ?? []
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.warning)
                }

                ForEach(sections) { group in
                    sectionHeader(group.section)
                    ForEach(group.reminders) { reminder in
                        row(reminder)
                    }
                }

                if showsCompleted, !completed.isEmpty {
                    sectionHeader(title: "Completed")
                    ForEach(completed) { reminder in
                        row(reminder)
                    }
                }

                if isEmpty {
                    emptyState
                }

                // The new reminder is written where the next reminder goes: at the end,
                // exactly where the tail row was standing. The Mac opens its composer at the
                // top of the list, which is right for a window you can see all of at once and
                // wrong for a phone — the tap that opened it happened down here, and a form
                // that answers a tap by scrolling somewhere else has moved the conversation.
                if composing == .newReminder {
                    composer(quickCommitKeepsOpen: true)
                } else if composing == nil {
                    newReminderTail

                    // The empty space under a short list, made part of the target.
                    //
                    // It has to live *inside* the scroll content rather than behind it: a
                    // `ScrollView` hit-tests its whole frame, so the gap below the last row
                    // belongs to the scroller and a background layer under it never hears the
                    // tap. This is that gap, on the near side of the glass.
                    Color.clear
                        .frame(height: Self.tapTargetTail)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: startNewReminder)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.section)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ reminder: Item) -> some View {
        if composing == .editing(reminder.id) {
            composer(quickCommitKeepsOpen: false)
        } else {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                Button {
                    toggleCompletion(of: reminder)
                } label: {
                    Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(
                            reminder.isCompleted
                                ? Theme.Colors.completed
                                : Theme.Colors.secondaryText
                        )
                        // A 44-point target around a 20-point glyph: the circle is the control
                        // people hit most on this screen and the one they hit while walking.
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reminder.isCompleted ? "Completed" : "Not completed")
                .accessibilityHint("Double-tap to toggle")

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text(reminder.displayTitle)
                        .font(Theme.Text.rowTitle)
                        .strikethrough(reminder.isCompleted, color: Theme.Colors.tertiaryText)
                        .foregroundStyle(
                            reminder.isCompleted
                                ? Theme.Colors.secondaryText
                                : Theme.Colors.primaryText
                        )
                        .multilineTextAlignment(.leading)

                    if !reminder.body.isEmpty {
                        Text(reminder.body)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(2)
                    }

                    ReminderFactRow(reminder: reminder) { field in
                        startEditing(reminder, opening: field)
                    }
                }
                .padding(.vertical, Theme.Spacing.small)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.tight)
            // A hairline under the row instead of a card around it. On one white sheet the
            // separator is all the structure a list of sentences needs, and it costs a pixel
            // where a rounded card costs a border, a fill and a shadow.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(height: 0.5)
                    .padding(.leading, Self.separatorInset)
            }
            .contentShape(Rectangle())
            // One tap edits. The Mac needs a double-click because a single click there means
            // "select"; nothing on this screen is selectable, so the cheapest gesture goes to
            // the only thing a row can do.
            .onTapGesture { startEditing(reminder) }
            // `.contain` before the identifier — the third place in this target that needed
            // it. An identifier on a container is inherited by every child without one, and an
            // element that has an identifier stops answering to its label, so naming the row
            // had made every reminder's *title* unfindable by the words it says.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reminders.row")
            .contextMenu {
                Button("Edit", systemImage: "pencil") { startEditing(reminder) }
                Button("Delete", systemImage: "trash", role: .destructive) { delete(reminder) }
            }
        }
    }

    /// The end of the list, which is also the start of the next reminder.
    ///
    /// The background alone was "tap anywhere" only while there was anywhere: a screen full of
    /// reminders is exactly the screen with no empty space left, and that is also the screen
    /// where you are most likely to be adding another one. So the affordance travels with the
    /// content instead of depending on a gap — it is always the last thing in the list,
    /// reachable by the same scroll that reads the list, and it is a row rather than a button
    /// floating over one because the next reminder genuinely does go there.
    private var newReminderTail: some View {
        Button(action: startNewReminder) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .frame(width: 32, height: 44)
                Text("New Reminder")
                    .font(Theme.Text.rowTitle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Colors.secondaryText)
            .padding(.horizontal, Theme.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Spacing.small)
        .accessibilityIdentifier("reminders.new")
    }

    private func sectionHeader(_ section: ReminderStore.Section) -> some View {
        sectionHeader(title: section.title)
    }

    private func sectionHeader(title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Text.sectionHeader)
            .kerning(Theme.Text.Tracking.caps)
            .foregroundStyle(Theme.Colors.secondaryText)
            .padding(.top, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbolName: "bell",
            headline: hasHiddenCompleted ? "No open reminders" : "No reminders",
            message: hasHiddenCompleted
                ? "Completed reminders are hidden. Show them from the toolbar."
                : "Tap anywhere to write the first one down.",
            tone: hasHiddenCompleted ? .accomplished : .neutral
        )
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.generous)
        // The empty state is the emptiest part of an empty screen, so it had better be part of
        // the target rather than a hole in it.
        .contentShape(Rectangle())
        .onTapGesture(perform: startNewReminder)
    }

    private var completedToggle: some View {
        Button {
            withCalmAnimation { showsCompleted.toggle() }
        } label: {
            Image(systemName: showsCompleted ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .accessibilityLabel(
            showsCompleted ? "Hide completed reminders" : "Show completed reminders"
        )
        .accessibilityAddTraits(showsCompleted ? .isSelected : [])
        .accessibilityIdentifier("reminders.showCompleted")
    }

    // MARK: - The composer

    private func composer(quickCommitKeepsOpen: Bool) -> some View {
        MobileReminderComposer(
            draft: $draft,
            onQuickCommit: { commit(keepsOpen: quickCommitKeepsOpen) },
            onDismiss: { commit(keepsOpen: false) },
            opening: openingField
        )
        // Identity by target *and* field, so tapping a different chip on the reminder already
        // being edited builds a fresh card that opens on the new field rather than reusing the
        // old one, which would keep showing the popover the first tap asked for.
        .id(composingIdentity)
        // The Mac's transition, to the token: the editor grows into place from the top edge of
        // where it will sit, so it reads as the list making room rather than a card landing on
        // it.
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func startNewReminder() {
        guard composing != .newReminder else { return }
        settleOpenEditor()
        draft.reset()
        openingField = nil
        withCalmAnimation(Theme.Motion.appearance) {
            composing = .newReminder
        }
    }

    /// Opens a reminder's editor, optionally already on one field.
    ///
    /// `opening` is what makes a tap on a deadline chip land *in* the deadline rather than in
    /// the editor beside it. Re-tapping the same chip while that reminder is already open still
    /// opens the field, because the second tap means the same thing the first one did.
    private func startEditing(_ reminder: Item, opening field: ComposerField? = nil) {
        guard composing != .editing(reminder.id) || openingField != field else { return }
        settleOpenEditor()
        draft = ReminderComposerDraft(reminder: reminder)
        openingField = field
        withCalmAnimation(Theme.Motion.appearance) {
            composing = .editing(reminder.id)
        }
    }

    /// Puts away whatever editor is already open, so tapping a second reminder just moves the
    /// editor to it.
    ///
    /// Saving rather than discarding, and without asking. The alternative — refusing the tap
    /// until Done or Cancel is pressed — makes the list stop responding for a reason that is
    /// invisible while it is happening, and there is nothing to confirm: the words are already
    /// typed, and moving to another reminder is not a statement about wanting to lose them.
    /// An untouched editor writes nothing, because a blank title is not a save.
    private func settleOpenEditor() {
        guard composing != nil else { return }
        draft.commitPendingStep()
        saveDraft()
    }

    private func closeComposer() {
        withCalmAnimation(Theme.Motion.appearance) {
            composing = nil
        }
        openingField = nil
        draft.reset()
    }

    /// What makes one presentation of the composer distinct from another.
    private var composingIdentity: String {
        let target: String = switch composing {
        case .newReminder: "new"
        case .editing(let id): id.uuidString
        case nil: "none"
        }
        return "\(target)-\(openingField?.rawValue ?? "")"
    }

    /// Saves what was typed, and either stays open for the next one or closes.
    ///
    /// Committing an empty title is not an error and not a save — it is someone who opened the
    /// composer by tapping the background and then changed their mind, which is the most
    /// likely thing to happen on a screen where the background opens the composer.
    private func commit(keepsOpen: Bool) {
        draft.commitPendingStep()
        let editingID: UUID? = if case .editing(let id) = composing { id } else { nil }
        saveDraft()

        if keepsOpen && editingID == nil {
            draft.reset()
        } else {
            closeComposer()
        }
    }

    /// Writes the draft, creating or updating according to what the composer was opened on.
    ///
    /// An empty title writes nothing and is not an error: it is someone who opened the composer
    /// by tapping the background and changed their mind, which is the likeliest thing to happen
    /// on a screen where the background opens the composer.
    private func saveDraft() {
        guard let services,
              !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        var committed = draft
        // The grammar is read here rather than while typing, so a half-typed `#foll` never
        // becomes a tag and the field keeps showing exactly what was written.
        let extraction = ReminderShortcutParser.extract(
            from: draft.title,
            knowing: (try? services.capture.vocabulary()) ?? .empty
        )
        committed.title = extraction.text
        // Merged, not replaced. What the pickers hold was chosen deliberately; what the parser
        // found was typed into the title. Assigning the parser's result was silently throwing
        // away every tag and person picked from a sheet the moment the reminder was saved.
        committed.tagSlugs = draft.tagSlugs + extraction.tagSlugs.filter {
            !draft.tagSlugs.contains($0)
        }
        committed.personNames = draft.personNames + extraction.personNames.filter {
            !draft.personNames.contains($0)
        }
        committed.projectTitle = draft.projectTitle ?? extraction.projectTitle

        let editingID: UUID? = if case .editing(let id) = composing { id } else { nil }

        actionError = nil
        do {
            if let editingID,
               let reminder = services.reminderStore.reminders.first(where: { $0.id == editingID }) {
                try services.reminderStore.update(reminder, from: committed)
                services.noteChange(to: reminder)
            } else {
                let reminder = try services.reminderStore.create(from: committed)
                services.noteChange(to: reminder)
            }
        } catch {
            actionError = error.summary
        }
    }

    // MARK: - Mutation

    private func toggleCompletion(of reminder: Item) {
        perform { (services) throws(AppError) in
            try services.reminderStore.toggleCompletion(of: reminder)
            services.noteChange(to: reminder)
        }
    }

    private func delete(_ reminder: Item) {
        perform { (services) throws(AppError) in
            try services.reminderStore.delete(reminder)
            services.noteChange(to: reminder)
        }
    }

    private func perform(_ work: (AppServices) throws(AppError) -> Void) {
        guard let services else { return }
        do {
            try work(services)
            actionError = nil
        } catch {
            actionError = error.summary
        }
    }

    // MARK: - What the list shows

    private func reload() {
        sections = services?.reminderStore.sections ?? []
        completed = services?.reminderStore.completed ?? []
    }

    private var isEmpty: Bool {
        sections.isEmpty && !(showsCompleted && !completed.isEmpty) && composing == nil
    }

    private var hasHiddenCompleted: Bool {
        !showsCompleted && !completed.isEmpty
    }
}

/// A reminder's facts, as chips: what it is attached to and when it matters.
///
/// The Mac's `metadataFacts` vocabulary, said in the same words, symbols and colours. A phone
/// shows fewer of them only because it has fewer points across, never different ones.
///
/// Each chip is also the way in to the thing it names. A chip that reads "Jul 21" is already
/// pointing at the deadline; making it open the editor *on some other field* — or worse, open
/// the editor and then wait to be told again which field was meant — spends two taps and an
/// animation getting back to where the first tap was already aimed.
private struct ReminderFactRow: View {
    @Environment(\.services) private var services

    let reminder: Item
    /// Opens this reminder's editor on one field.
    var onEdit: (ComposerField) -> Void

    var body: some View {
        let facts = facts
        if !facts.isEmpty {
            FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                ForEach(facts, id: \.id) { fact in
                    Button {
                        onEdit(fact.field)
                    } label: {
                        HStack(spacing: Theme.Spacing.hairline) {
                            Image(systemName: fact.symbol)
                            Text(fact.text).lineLimit(1)
                        }
                        .font(Theme.Text.chip)
                        .foregroundStyle(fact.tint)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.hairline)
                        .background(
                            Capsule().fill(Theme.Colors.tintedFill(fact.tint))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens this reminder's \(fact.field.rawValue)")
                }
            }
        }
    }

    private struct Fact {
        let id: String
        let symbol: String
        let text: String
        let tint: Color
        /// Which field of the editor this chip is a door to.
        let field: ComposerField
    }

    private var facts: [Fact] {
        guard let clock = services?.dateProvider else { return [] }
        var facts: [Fact] = []

        if reminder.isSomeday {
            facts.append(
                Fact(id: "someday", symbol: "archivebox", text: "Someday",
                     tint: Theme.Colors.secondaryText, field: .when)
            )
        } else if let startAt = reminder.startAt {
            facts.append(
                Fact(
                    id: "scheduled",
                    symbol: "calendar",
                    text: RelativeDay.text(for: startAt, using: clock),
                    tint: Theme.Colors.secondaryText,
                    field: .when
                )
            )
        }

        if let dueAt = reminder.dueAt {
            facts.append(
                Fact(
                    id: "deadline",
                    symbol: "calendar.badge.exclamationmark",
                    text: RelativeDay.text(for: dueAt, using: clock),
                    // A finished reminder's deadline is history; urgency is for the ones still
                    // open — the Mac's rule, kept.
                    tint: reminder.isCompleted
                        ? Theme.Colors.secondaryText
                        : DateUrgency.color(for: dueAt, using: clock),
                    field: .deadline
                )
            )
        }

        if let project = reminder.parent, project.kind == .project {
            facts.append(
                Fact(
                    id: "project",
                    symbol: "folder",
                    text: project.displayTitle,
                    tint: Theme.Palette.color(named: project.colorName),
                    field: .project
                )
            )
        }

        for tag in (reminder.tags ?? []).sorted(by: {
            $0.slug.localizedStandardCompare($1.slug) == .orderedAscending
        }) {
            facts.append(
                Fact(
                    id: "tag-\(tag.slug)",
                    symbol: "number",
                    text: tag.slug,
                    tint: Theme.Palette.color(named: tag.colorName, neutral: Theme.Colors.secondaryText),
                    field: .tags
                )
            )
        }

        let checklist = reminder.checklist
        if !checklist.isEmpty {
            let text = checklist.completed > 0
                ? "\(checklist.completed) of \(checklist.total) steps"
                : (checklist.total == 1 ? "1 step" : "\(checklist.total) steps")
            facts.append(
                Fact(
                    id: "checklist",
                    symbol: "checklist",
                    text: text,
                    tint: checklist.completed == checklist.total
                        ? Theme.Colors.completed
                        : Theme.Colors.secondaryText,
                    field: .checklist
                )
            )
        }

        return facts
    }
}
