import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// A complete reminder, composed in place without touching the store until it is ready.
///
/// The title, notes, date phrases, tag filter and checklist line are AppKit text views because this
/// card promises an exact Tab path. SwiftUI's key-view order cannot express that path once two of
/// the stops live in popovers, and an `NSTextView` would otherwise insert a tab into Notes instead
/// of moving on.
struct ReminderComposer: View {
    @Environment(\.services) private var services

    @Binding var draft: ReminderComposerDraft
    var onQuickCommit: () -> Void
    var onCommitAndClose: () -> Void
    var onCancel: () -> Void

    @State private var whenQuery = ""
    @State private var deadlineQuery = ""
    @State private var tagQuery = ""
    @State private var availableTags: [String] = []
    @State private var isWhenOpen = false
    @State private var isTagsOpen = false
    @State private var isDeadlineOpen = false
    @State private var showsChecklist = false
    @FocusState private var focus: ReminderComposerField?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            titleLine
            notes
            checklist
            actionRow
        }
        .padding(Theme.Spacing.medium)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.contentBackground)
                .shadow(color: Theme.Colors.shadow.opacity(0.14), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Colors.separator, lineWidth: 1)
        }
        .onAppear {
            availableTags = (try? services?.tags.allTags().map(\.slug).sorted()) ?? []
            Task { @MainActor in
                await Task.yield()
                focus = .title
            }
        }
        .onChange(of: focus) { old, new in
            fieldChanged(from: old, to: new)
        }
        .accessibilityIdentifier("tasks.reminderComposer")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText)

            ReminderPlainTextEditor(
                text: $draft.title,
                placeholder: "New Reminder",
                role: .title,
                onTab: moveFromTitle,
                onReturn: {
                    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        focus = .notes
                        return
                    }
                    onQuickCommit()
                    Task { @MainActor in
                        await Task.yield()
                        focus = .title
                    }
                },
                onCommandReturn: onCommitAndClose,
                onEscape: onCancel
            )
            .frame(height: 26)
            .focused($focus, equals: .title)
            .accessibilityIdentifier("tasks.reminderComposer.title")
        }
    }

    private var notes: some View {
        ReminderPlainTextEditor(
            text: $draft.notes,
            placeholder: "Notes",
            role: .notes,
            onTab: { reverse in move(from: .notes, reverse: reverse) },
            onReturn: {},
            onCommandReturn: onCommitAndClose,
            onEscape: onCancel
        )
        .frame(minHeight: 42, maxHeight: 88)
        .padding(.leading, 21)
        .focused($focus, equals: .notes)
        .accessibilityIdentifier("tasks.reminderComposer.notes")
    }

    @ViewBuilder
    private var checklist: some View {
        if showsChecklist || !draft.checklist.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                ForEach(draft.checklist) { step in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(step.title)
                            .font(Theme.Text.rowSubtitle)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Theme.Size.rowHeight)
                }

                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "circle")
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    ReminderPlainTextEditor(
                        text: $draft.pendingStep,
                        placeholder: "Add a checklist item",
                        role: .body,
                        onTab: { reverse in
                            if !reverse { draft.commitPendingStep() }
                            move(from: .checklist, reverse: reverse)
                        },
                        onReturn: {
                            draft.commitPendingStep()
                            focus = .checklist
                        },
                        onCommandReturn: onCommitAndClose,
                        onEscape: onCancel
                    )
                    .frame(height: 24)
                    .focused($focus, equals: .checklist)
                    .accessibilityIdentifier("tasks.reminderComposer.checklistField")
                }
                .frame(minHeight: Theme.Size.rowHeight)
            }
            .padding(.leading, 21)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Spacer(minLength: 0)
            whenControl
            tagsControl
            checklistControl
            deadlineControl
        }
        .padding(.top, Theme.Spacing.tight)
    }

    private var whenControl: some View {
        Group {
            if focus == .when {
                ReminderPlainTextEditor(
                    text: $whenQuery,
                    placeholder: "When",
                    role: .body,
                    onTab: { reverse in
                        commitWhenQuery()
                        isWhenOpen = false
                        move(from: .when, reverse: reverse)
                    },
                    onReturn: {
                        commitWhenQuery()
                        isWhenOpen = false
                        focus = .tags
                    },
                    onCommandReturn: onCommitAndClose,
                    onEscape: { isWhenOpen = false; focus = .notes }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
                .focused($focus, equals: .when)
            } else {
                actionButton(
                    title: draft.isSomeday ? "Someday" : draft.startAt.map(shortDate) ?? "When",
                    symbol: "calendar",
                    isActive: draft.startAt != nil || draft.isSomeday
                ) {
                    focus = .when
                }
            }
        }
        .popover(isPresented: $isWhenOpen, arrowEdge: .bottom) {
            reminderDatePopover(
                selected: draft.startAt,
                allowsSomeday: true,
                onPick: { date in
                    draft.startAt = date
                    draft.isSomeday = false
                    isWhenOpen = false
                    focus = .tags
                }
            )
        }
    }

    private var tagsControl: some View {
        Group {
            if focus == .tags {
                ReminderPlainTextEditor(
                    text: $tagQuery,
                    placeholder: "Tags",
                    role: .body,
                    onTab: { reverse in
                        isTagsOpen = false
                        move(from: .tags, reverse: reverse)
                    },
                    onReturn: toggleFirstMatchingTag,
                    onCommandReturn: onCommitAndClose,
                    onEscape: { isTagsOpen = false; focus = .when }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
                .focused($focus, equals: .tags)
            } else {
                actionButton(
                    title: draft.tagSlugs.isEmpty ? "Tags" : draft.tagSlugs.joined(separator: ", "),
                    symbol: "tag",
                    isActive: !draft.tagSlugs.isEmpty
                ) {
                    focus = .tags
                }
            }
        }
        .popover(isPresented: $isTagsOpen, arrowEdge: .bottom) {
            reminderTagPopover
        }
    }

    private var checklistControl: some View {
        actionButton(
            title: draft.checklist.isEmpty ? "Checklist" : "\(draft.checklist.count) items",
            symbol: "checklist",
            isActive: !draft.checklist.isEmpty
        ) {
            showsChecklist = true
            focus = .checklist
        }
    }

    private var deadlineControl: some View {
        Group {
            if focus == .deadline {
                ReminderPlainTextEditor(
                    text: $deadlineQuery,
                    placeholder: "Deadline",
                    role: .body,
                    onTab: { reverse in
                        commitDeadlineQuery()
                        isDeadlineOpen = false
                        move(from: .deadline, reverse: reverse)
                    },
                    onReturn: {
                        commitDeadlineQuery()
                        isDeadlineOpen = false
                        focus = .title
                    },
                    onCommandReturn: onCommitAndClose,
                    onEscape: { isDeadlineOpen = false; focus = .checklist }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
                .focused($focus, equals: .deadline)
            } else {
                actionButton(
                    title: draft.dueAt.map(shortDate) ?? "Deadline",
                    symbol: "flag",
                    isActive: draft.dueAt != nil
                ) {
                    focus = .deadline
                }
            }
        }
        .popover(isPresented: $isDeadlineOpen, arrowEdge: .bottom) {
            reminderDatePopover(
                selected: draft.dueAt,
                allowsSomeday: false,
                onPick: { date in
                    draft.dueAt = date
                    isDeadlineOpen = false
                    focus = .title
                }
            )
        }
    }

    private func actionButton(
        title: String,
        symbol: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: activeSymbol(symbol, isActive: isActive))
                .font(Theme.Text.metadata)
                .lineLimit(1)
                .foregroundStyle(isActive ? Theme.Colors.selection : Theme.Colors.tertiaryText)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func activeSymbol(_ symbol: String, isActive: Bool) -> String {
        guard isActive else { return symbol }
        return switch symbol {
        case "checklist": "checklist.checked"
        case "calendar": "calendar.badge.checkmark"
        default: symbol + ".fill"
        }
    }

    private var reminderTagPopover: some View {
        VStack(alignment: .leading, spacing: 1) {
            if matchingTags.isEmpty {
                Button {
                    addTag(tagQuery)
                } label: {
                    Label("Create \(TextNormalizer.slug(tagQuery))", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(TextNormalizer.slug(tagQuery).isEmpty)
            } else {
                ForEach(matchingTags, id: \.self) { slug in
                    Button {
                        toggleTag(slug)
                    } label: {
                        Label(slug, systemImage: draft.tagSlugs.contains(slug) ? "checkmark" : "tag")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Spacing.small)
        .frame(width: 220)
    }

    private func reminderDatePopover(
        selected: Date?,
        allowsSomeday: Bool,
        onPick: @escaping (Date?) -> Void
    ) -> some View {
        let clock = services?.dateProvider ?? SystemDateProvider()
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button("Today", systemImage: "star") { onPick(clock.startOfToday) }
                .buttonStyle(.plain)
            Button("Tomorrow", systemImage: "sunrise") { onPick(clock.startOfDay(daysFromToday: 1)) }
                .buttonStyle(.plain)

            Divider()

            TaskMonthPicker(
                calendar: clock.calendar,
                today: clock.now,
                selected: selected,
                onPick: { onPick($0) }
            )

            if allowsSomeday {
                Divider()
                Button("Someday", systemImage: "archivebox") {
                    draft.startAt = nil
                    draft.isSomeday = true
                    isWhenOpen = false
                    focus = .tags
                }
                .buttonStyle(.plain)
            }

            if selected != nil {
                Divider()
                Button("Clear", systemImage: "xmark.circle") { onPick(nil) }
                    .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 250)
    }

    private var matchingTags: [String] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(availableTags.prefix(12)) }
        return Array(availableTags.lazy.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(12))
    }

    private func moveFromTitle(reverse: Bool) {
        move(from: .title, reverse: reverse)
    }

    private func move(from field: ReminderComposerField, reverse: Bool) {
        let next = field.advanced(reverse: reverse)
        if next == .checklist { showsChecklist = true }
        focus = next
    }

    private func fieldChanged(from old: ReminderComposerField?, to new: ReminderComposerField?) {
        if new == .when { isWhenOpen = true }
        if new == .tags { isTagsOpen = true }
        if new == .checklist { showsChecklist = true }
        if new == .deadline { isDeadlineOpen = true }

        // A click outside the card commits a real draft. Clicking inside a popover also clears the
        // field focus, so an open picker guards that deliberate handoff.
        if old != nil, new == nil, !isWhenOpen, !isTagsOpen, !isDeadlineOpen {
            if draft.isEmpty { onCancel() } else { onCommitAndClose() }
        }
    }

    private func commitWhenQuery() {
        guard let suggestion = services.flatMap({ TaskDateSuggestion.resolving(whenQuery, using: $0.dateProvider) })
        else { return }
        draft.startAt = suggestion.date
        draft.isSomeday = false
        whenQuery = ""
    }

    private func commitDeadlineQuery() {
        guard let suggestion = services.flatMap({ TaskDateSuggestion.resolving(deadlineQuery, using: $0.dateProvider) })
        else { return }
        draft.dueAt = suggestion.date
        deadlineQuery = ""
    }

    private func toggleFirstMatchingTag() {
        if let first = matchingTags.first {
            toggleTag(first)
        } else {
            addTag(tagQuery)
        }
        tagQuery = ""
    }

    private func addTag(_ name: String) {
        let slug = TextNormalizer.slug(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !slug.isEmpty else { return }
        if !availableTags.contains(slug) { availableTags.append(slug); availableTags.sort() }
        if !draft.tagSlugs.contains(slug) { draft.tagSlugs.append(slug); draft.tagSlugs.sort() }
    }

    private func toggleTag(_ slug: String) {
        if draft.tagSlugs.contains(slug) {
            draft.tagSlugs.removeAll { $0 == slug }
        } else {
            draft.tagSlugs.append(slug)
            draft.tagSlugs.sort()
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - The keyboard editor

struct ReminderPlainTextEditor: NSViewRepresentable {
    enum Role { case title, notes, body }

    @Binding var text: String
    let placeholder: String
    let role: Role
    let onTab: (Bool) -> Void
    let onReturn: () -> Void
    let onCommandReturn: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ReminderEditorScrollView {
        let scroll = ReminderEditorScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = role == .notes
        scroll.autohidesScrollers = true

        let editor = ReminderEditorTextView()
        editor.delegate = context.coordinator
        editor.coordinator = context.coordinator
        editor.string = text
        editor.placeholder = placeholder
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isFieldEditor = role != .notes
        editor.isVerticallyResizable = role == .notes
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: role == .title ? 2 : 0)
        editor.font = switch role {
        case .title: .preferredFont(forTextStyle: .title3)
        case .notes, .body: .preferredFont(forTextStyle: .subheadline)
        }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: ReminderEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ReminderEditorTextView else { return }
        editor.placeholder = placeholder
        guard editor.string != text, text != context.coordinator.lastEditorText, !editor.hasMarkedText()
        else { return }
        editor.string = text
        context.coordinator.lastEditorText = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReminderPlainTextEditor
        var lastEditorText: String

        init(_ parent: ReminderPlainTextEditor) {
            self.parent = parent
            self.lastEditorText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            lastEditorText = editor.string
            parent.text = editor.string
        }
    }
}

final class ReminderEditorScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let editor = documentView as? NSTextView, let window else { return false }
        return window.makeFirstResponder(editor)
    }
}

final class ReminderEditorTextView: NSTextView {
    weak var coordinator: ReminderPlainTextEditor.Coordinator?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        guard let parent = coordinator?.parent else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 48: // Tab
            MainActor.assumeIsolated {
                parent.onTab(event.modifierFlags.contains(.shift))
            }
        case 36, 76: // Return and keypad Enter
            if event.modifierFlags.contains(.command) {
                MainActor.assumeIsolated { parent.onCommandReturn() }
            } else if parent.role == .notes {
                super.keyDown(with: event)
            } else {
                MainActor.assumeIsolated { parent.onReturn() }
            }
        case 53: // Escape
            MainActor.assumeIsolated { parent.onEscape() }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font ?? NSFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        ).draw(at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y))
    }
}
