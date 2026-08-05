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
/// The controls are glyphs, not glyphs-and-words, for the Mac's reason: the chips above
/// already say what each field holds, so a label on the button spends the row saying it twice.
///
/// ### What changes, and why
/// The Mac drives all of it from the keyboard — eight focus stops, a date search answering `we`
/// and `8`. A thumb has no Tab key, so the popovers hold lists rather than query fields. They
/// are still popovers, anchored to the control that opened them: a full-screen sheet for
/// choosing one tag covers the sentence you are in the middle of writing, which is the one
/// thing you need to see while deciding how to file it.
/// One of the composer's six fields, nameable from outside it.
///
/// At file scope rather than nested in the composer because the *list* needs to say which one
/// it means: tapping a reminder's deadline is a request to change that deadline, and the
/// request has to survive the trip from the row to the editor that opens.
enum ComposerField: String, Identifiable, Hashable {
    case project, when, tags, people, checklist, deadline
    var id: String { rawValue }
}

struct MobileReminderComposer: View {
    @Environment(\.services) private var services

    @Binding var draft: ReminderComposerDraft

    /// Saves and stays open, for writing several in a row.
    var onQuickCommit: () -> Void
    /// Saves and closes. The only way out, because there is no other kind.
    var onDismiss: () -> Void

    /// The field to open on, for arrivals that already know which one they mean — a tap on a
    /// reminder's deadline chip is a request to change the deadline, not to look at the editor.
    var opening: ComposerField?

    @FocusState private var focus: Field?
    @State private var vocabulary = CaptureVocabulary.empty
    @State private var activePopover: ComposerField?
    /// The field whose search sheet is up. Separate from `activePopover` because they are two
    /// presentations and the popover has to be gone before the sheet can arrive.
    @State private var searchingField: ComposerField?
    /// Whether the checklist's entry row is showing, mirroring the Mac's `.checklist` stop.
    @State private var isAddingStep = false

    private enum Field: Hashable { case title, notes, step }

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
        .task {
            vocabulary = (try? services?.capture.vocabulary()) ?? .empty

            guard let opening else {
                focus = .title
                return
            }
            // One turn of the run loop before presenting: the card is arriving, and a popover
            // anchored to a control that has not been laid out yet has nothing to point at.
            await Task.yield()
            open(opening)
        }
        .sheet(item: $searchingField) { field in
            searchSheet(for: field)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.composer")
    }

    // MARK: - What you wrote

    /// The title, and the one control that is not a field: the way out.
    ///
    /// Top-trailing, where a card's dismiss lives on this platform. It *saves* — there is no
    /// discard on this screen and no Done either, because both were asking a question the
    /// editor already knows the answer to. Everything that closes the editor keeps what is in
    /// it: this ×, Return, tapping another reminder, tapping the background. A reminder is a
    /// sentence you were part-way through writing, and no way of leaving it is a request to
    /// throw it away.
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

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Theme.Text.metadata.weight(.semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close this reminder")
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
    /// Six fields and no seventh button. Done used to sit at the end of this row and was a
    /// mistake twice over — off the right edge of the screen when the row scrolled, and behind
    /// the keyboard once it did not — but the deeper problem was that it existed at all. Every
    /// other way of leaving this editor already saves, so a button whose only job was to save
    /// was a second answer to a question with one answer.
    private var actionRow: some View {
        controlScroller
            .background(Theme.Colors.subtleFill)
    }

    /// Project keeps its name; the other five are glyphs.
    ///
    /// The Mac's rule, and the reason it works: what a control *holds* is already said by the
    /// chips above it, so repeating the value on the button spends a third of the row saying
    /// something twice. Project is the exception there and here, because it is the one field
    /// that says where the reminder lives rather than something about it — and with all six
    /// down to icons, the row stops needing to scroll at all.
    private var controlScroller: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button { activePopover = .project } label: {
                HStack(spacing: Theme.Spacing.hairline) {
                    Image(systemName: "square.stack.3d.up")
                    if let project = draft.projectTitle {
                        Text(project).lineLimit(1)
                    }
                }
                .font(Theme.Text.chip)
                .foregroundStyle(
                    draft.projectTitle == nil ? Theme.Colors.secondaryText : Theme.Colors.link
                )
                .frame(minHeight: 32)
                .frame(maxWidth: 160, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(draft.projectTitle.map { "Project: \($0)" } ?? "Choose a project")
            .accessibilityIdentifier("reminders.composer.project")
            .popover(isPresented: showing(.project), arrowEdge: .top) {
                MobileProjectPicker(
                    selected: $draft.projectTitle,
                    onRequestSearch: { requestSearch(.project) }
                )
            }

            Spacer(minLength: 0)

            control(symbol: "calendar", isActive: draft.startAt != nil || draft.isSomeday,
                    label: "When", identifier: "when") { activePopover = .when }
                .popover(isPresented: showing(.when), arrowEdge: .top) {
                    MobileDayPicker(
                        title: "When",
                        selection: $draft.startAt,
                        isSomeday: $draft.isSomeday
                    )
                }

            control(symbol: "tag", isActive: !draft.tagSlugs.isEmpty,
                    label: "Tags", identifier: "tags") { activePopover = .tags }
                .popover(isPresented: showing(.tags), arrowEdge: .top) {
                    MobileTagPicker(
                        selected: $draft.tagSlugs,
                        onRequestSearch: { requestSearch(.tags) }
                    )
                }

            control(symbol: "person", isActive: !draft.personNames.isEmpty,
                    label: "People", identifier: "people") { activePopover = .people }
                .popover(isPresented: showing(.people), arrowEdge: .top) {
                    MobilePeoplePicker(
                        selected: $draft.personNames,
                        onRequestSearch: { requestSearch(.people) }
                    )
                }

            control(symbol: "checklist", isActive: !draft.checklist.isEmpty,
                    label: "Checklist", identifier: "checklist") { open(.checklist) }

            control(symbol: "flag", isActive: draft.dueAt != nil,
                    label: "Deadline", identifier: "deadline") { activePopover = .deadline }
                .popover(isPresented: showing(.deadline), arrowEdge: .top) {
                    MobileDayPicker(title: "Deadline", selection: $draft.dueAt, isSomeday: nil)
                }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    /// Trades the popover for the sheet that can hold a keyboard.
    ///
    /// Sequenced rather than swapped: dismissing a popover and presenting a sheet in the same
    /// turn asks UIKit to run two presentation transitions at once, and it answers by dropping
    /// one of them. The popover goes first, and the sheet follows once it is gone.
    private func requestSearch(_ field: ComposerField) {
        activePopover = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            searchingField = field
        }
    }

    @ViewBuilder
    private func searchSheet(for field: ComposerField) -> some View {
        switch field {
        case .tags:
            MobileTagPicker(selected: $draft.tagSlugs, style: .search)
        case .people:
            MobilePeoplePicker(selected: $draft.personNames, style: .search)
        case .project:
            MobileProjectPicker(selected: $draft.projectTitle, style: .search)
        case .when, .deadline, .checklist:
            // Nothing here is typed into, so nothing here escalates.
            EmptyView()
        }
    }

    /// Opens one field. Five of them are popovers; the checklist is a row inside the card, so
    /// "open" means something different for it and this is the one place that knows so.
    private func open(_ field: ComposerField) {
        if field == .checklist {
            withCalmAnimation { isAddingStep = true }
            focus = .step
        } else {
            activePopover = field
        }
    }

    /// Whether one picker is showing, as a binding a popover can also close.
    private func showing(_ which: ComposerField) -> Binding<Bool> {
        Binding(
            get: { activePopover == which },
            set: { isShowing in
                if isShowing {
                    activePopover = which
                } else if activePopover == which {
                    activePopover = nil
                }
            }
        )
    }

    /// One glyph, tinted when the field holds something.
    ///
    /// The word it stands for moves to the accessibility label rather than disappearing: a
    /// screen reader has no icon to look at, and "tag" is not a thing a glyph can say out loud.
    private func control(
        symbol: String,
        isActive: Bool,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(isActive ? Theme.Colors.selection : Theme.Colors.secondaryText)
                // Square rather than a capsule around a word: with the label gone, a pill would
                // be a lozenge of background around a 14-point glyph.
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(isActive ? Theme.Colors.selectionFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("reminders.composer.\(identifier)")
    }

    private func shortDate(_ date: Date) -> String {
        guard let clock = services?.dateProvider else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return RelativeDay.text(for: date, using: clock)
    }
}
