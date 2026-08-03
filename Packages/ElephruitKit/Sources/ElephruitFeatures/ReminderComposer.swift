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
    @State private var popupField: ReminderComposerField?
    @State private var showsChecklist = false
    @StateObject private var focusRouter = ReminderComposerFocusRouter()

    private var activeField: ReminderComposerField { focusRouter.activeField }

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
        .background {
            ReminderComposerKeyboardMonitor(router: focusRouter)
            .frame(width: 0, height: 0)
        }
        .onAppear {
            focusRouter.onTab = { reverse in
                move(from: focusRouter.activeField, reverse: reverse)
            }
            availableTags = (try? services?.tags.allTags().map(\.slug).sorted()) ?? []
            Task { @MainActor in
                await Task.yield()
                activate(.title)
            }
        }
        .onDisappear {
            focusRouter.onTab = nil
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
                        activate(.notes)
                        return
                    }
                    onQuickCommit()
                    Task { @MainActor in
                        await Task.yield()
                        activate(.title)
                    }
                },
                onCommandReturn: onCommitAndClose,
                onEscape: onCancel,
                field: .title,
                focusRouter: focusRouter,
                onFocus: { activate(.title) }
            )
            .frame(height: 26)
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
            onEscape: onCancel,
            field: .notes,
            focusRouter: focusRouter,
            onFocus: { activate(.notes) }
        )
        .frame(minHeight: 42, maxHeight: 88)
        .padding(.leading, 21)
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
                            activate(.checklist)
                        },
                        onCommandReturn: onCommitAndClose,
                        onEscape: onCancel,
                        field: .checklist,
                        focusRouter: focusRouter,
                        onFocus: { activate(.checklist) }
                    )
                    .frame(height: 24)
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
        .popover(isPresented: popupPresented, arrowEdge: .bottom) {
            metadataPopup
        }
    }

    private var whenControl: some View {
        HStack(spacing: 0) {
            if activeField == .when {
                ReminderPlainTextEditor(
                    text: $whenQuery,
                    placeholder: "When",
                    role: .body,
                    onTab: { reverse in
                        commitWhenQuery()
                        move(from: .when, reverse: reverse)
                    },
                    onReturn: {
                        commitWhenQuery()
                        activate(.tags)
                    },
                    onCommandReturn: onCommitAndClose,
                    onEscape: { popupField = nil; activate(.notes) },
                    field: .when,
                    focusRouter: focusRouter,
                    onFocus: { activate(.when) }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
            } else {
                actionButton(
                    title: draft.isSomeday ? "Someday" : draft.startAt.map(shortDate) ?? "When",
                    symbol: "calendar",
                    isActive: draft.startAt != nil || draft.isSomeday
                ) {
                    activate(.when)
                }
            }
        }
    }

    private var tagsControl: some View {
        HStack(spacing: 0) {
            if activeField == .tags {
                ReminderPlainTextEditor(
                    text: $tagQuery,
                    placeholder: "Tags",
                    role: .body,
                    onTab: { reverse in
                        move(from: .tags, reverse: reverse)
                    },
                    onReturn: toggleFirstMatchingTag,
                    onCommandReturn: onCommitAndClose,
                    onEscape: { popupField = nil; activate(.when) },
                    field: .tags,
                    focusRouter: focusRouter,
                    onFocus: { activate(.tags) }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
            } else {
                actionButton(
                    title: draft.tagSlugs.isEmpty ? "Tags" : draft.tagSlugs.joined(separator: ", "),
                    symbol: "tag",
                    isActive: !draft.tagSlugs.isEmpty
                ) {
                    activate(.tags)
                }
            }
        }
    }

    private var checklistControl: some View {
        actionButton(
            title: draft.checklist.isEmpty ? "Checklist" : "\(draft.checklist.count) items",
            symbol: "checklist",
            isActive: !draft.checklist.isEmpty
        ) {
            showsChecklist = true
            activate(.checklist)
        }
    }

    private var deadlineControl: some View {
        HStack(spacing: 0) {
            if activeField == .deadline {
                ReminderPlainTextEditor(
                    text: $deadlineQuery,
                    placeholder: "Deadline",
                    role: .body,
                    onTab: { reverse in
                        commitDeadlineQuery()
                        move(from: .deadline, reverse: reverse)
                    },
                    onReturn: {
                        commitDeadlineQuery()
                        activate(.title)
                    },
                    onCommandReturn: onCommitAndClose,
                    onEscape: { popupField = nil; activate(.checklist) },
                    field: .deadline,
                    focusRouter: focusRouter,
                    onFocus: { activate(.deadline) }
                )
                .frame(width: 116, height: 24)
                .padding(.horizontal, Theme.Spacing.small)
                .background(Theme.Colors.subtleFill, in: Capsule())
            } else {
                actionButton(
                    title: draft.dueAt.map(shortDate) ?? "Deadline",
                    symbol: "flag",
                    isActive: draft.dueAt != nil
                ) {
                    activate(.deadline)
                }
            }
        }
    }

    private var popupPresented: Binding<Bool> {
        Binding(
            get: { popupField != nil },
            set: { if !$0 { popupField = nil } }
        )
    }

    @ViewBuilder
    private var metadataPopup: some View {
        switch popupField {
        case .when:
            reminderDatePopover(
                selected: draft.startAt,
                allowsSomeday: true,
                onPick: { date in
                    draft.startAt = date
                    draft.isSomeday = false
                    activate(.tags)
                }
            )
        case .tags:
            reminderTagPopover
        case .deadline:
            reminderDatePopover(
                selected: draft.dueAt,
                allowsSomeday: false,
                onPick: { date in
                    draft.dueAt = date
                    popupField = nil
                    activate(.title)
                }
            )
        case .title, .notes, .checklist, nil:
            EmptyView()
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
                    activate(.tags)
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
        activate(next)
    }

    /// Moves through the product's focus path and switches the single metadata popover.
    ///
    /// The action row is a permanent anchor, so popup presentation never waits on a conditional
    /// view and calendar-to-tags traversal does not perform a dismiss/present race.
    private func activate(_ field: ReminderComposerField) {
        if activeField == field {
            focusRouter.focus(field)
            presentPopupAfterLayout(for: field)
            return
        }
        focusRouter.activate(field)
        if field == .checklist { showsChecklist = true }

        if field != .when, field != .tags, field != .deadline {
            popupField = nil
        }

        presentPopupAfterLayout(for: field)
    }

    private func presentPopupAfterLayout(for field: ReminderComposerField) {
        guard field == .when || field == .tags || field == .deadline else { return }
        if popupField == field { return }
        popupField = field
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
    let field: ReminderComposerField
    let focusRouter: ReminderComposerFocusRouter
    var onFocus: () -> Void = {}

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
        editor.focusField = field
        editor.focusRouter = focusRouter
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
        focusRouter.register(editor, for: field)
        return scroll
    }

    func updateNSView(_ scroll: ReminderEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ReminderEditorTextView else { return }
        focusRouter.register(editor, for: field)
        editor.placeholder = placeholder
        context.coordinator.reconciliationGeneration += 1
        let generation = context.coordinator.reconciliationGeneration
        guard editor.string != text else { return }

        // A keystroke can queue several SwiftUI updates. Reconcile external resets only after that
        // queue settles; applying an older snapshot immediately would erase the just-flushed text
        // as focus moves to the next field.
        DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
            guard let editor,
                  let coordinator,
                  coordinator.reconciliationGeneration == generation,
                  !editor.hasMarkedText(),
                  editor.window?.firstResponder !== editor
            else { return }
            let latestText = coordinator.parent.text
            guard editor.string != latestText else { return }
            editor.string = latestText
            coordinator.lastEditorText = latestText
            editor.setSelectedRange(NSRange(location: (latestText as NSString).length, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReminderPlainTextEditor
        var lastEditorText: String
        var reconciliationGeneration = 0

        init(_ parent: ReminderPlainTextEditor) {
            self.parent = parent
            self.lastEditorText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            flushText(editor)
        }

        func flushText(_ editor: NSTextView) {
            lastEditorText = editor.string
            parent.text = editor.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }

        /// AppKit interprets Tab and Return as text commands before a field editor necessarily
        /// receives a raw key event. Handling the commands here makes the path work for hardware
        /// keyboards, accessibility-generated events, and the system key-view loop alike.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(true)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onCommandReturn()
                    return true
                }
                switch parent.role {
                case .notes:
                    return false
                case .title, .body:
                    parent.onReturn()
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

final class ReminderEditorScrollView: NSScrollView {}

final class ReminderEditorTextView: NSTextView {
    weak var coordinator: ReminderPlainTextEditor.Coordinator?
    weak var focusRouter: ReminderComposerFocusRouter?
    var focusField: ReminderComposerField = .title
    var placeholder = "" { didSet { needsDisplay = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        focusRouter?.register(self, for: focusField)
    }

    /// The text system may dispatch these actions directly, without a raw key event or delegate
    /// command. Overriding the responder actions closes that final route around the focus machine.
    override func insertTab(_ sender: Any?) {
        MainActor.assumeIsolated { coordinator?.parent.onTab(false) }
    }

    override func insertBacktab(_ sender: Any?) {
        MainActor.assumeIsolated { coordinator?.parent.onTab(true) }
    }

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

// MARK: - Authoritative focus routing

/// Owns the composer responder chain for its entire lifetime.
///
/// SwiftUI state describes the visuals, but it never decides which editor is first responder.
/// That decision stays here, beside the concrete AppKit text views, so a Tab cannot race a view
/// update or be redirected by a popover window.
@MainActor
final class ReminderComposerFocusRouter: ObservableObject {
    @Published private(set) var activeField: ReminderComposerField = .title
    var onTab: ((Bool) -> Void)?

    private var editors: [ReminderComposerField: WeakReminderEditor] = [:]
    private var focusGeneration = 0

    func register(_ editor: NSTextView, for field: ReminderComposerField) {
        editors[field] = WeakReminderEditor(editor)
        if activeField == field { focus(field) }
    }

    func activate(_ field: ReminderComposerField) {
        flushActiveEditor()
        activeField = field
        focus(field)
    }

    func focus(_ field: ReminderComposerField) {
        focusGeneration += 1
        let generation = focusGeneration
        _ = focusNow(field)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.focusGeneration == generation,
                  self.activeField == field
            else { return }
            _ = self.focusNow(field)
        }
    }

    @discardableResult
    private func focusNow(_ field: ReminderComposerField) -> Bool {
        guard activeField == field,
              let editor = editors[field]?.value,
              let window = editor.window
        else { return false }
        if window.firstResponder !== editor, !window.makeFirstResponder(editor) { return false }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        return true
    }

    func handleTab(reverse: Bool) {
        flushActiveEditor()
        onTab?(reverse)
    }

    private func flushActiveEditor() {
        guard let editor = editors[activeField]?.value as? ReminderEditorTextView,
              !editor.hasMarkedText()
        else { return }
        editor.coordinator?.flushText(editor)
    }
}

private final class WeakReminderEditor {
    weak var value: NSTextView?

    init(_ value: NSTextView) {
        self.value = value
    }
}

// MARK: - Window-level keyboard routing

/// Captures Tab before AppKit decides whether it means text insertion, field-editor traversal, or
/// an accessibility key-view action. It exists only while one composer exists and only consumes
/// events belonging to that composer's window.
struct ReminderComposerKeyboardMonitor: NSViewRepresentable {
    let router: ReminderComposerFocusRouter

    func makeCoordinator() -> Coordinator { Coordinator(router: router) }

    func makeNSView(context: Context) -> ReminderComposerKeyboardMonitorView {
        let view = ReminderComposerKeyboardMonitorView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: ReminderComposerKeyboardMonitorView, context: Context) {}

    static func dismantleNSView(
        _ view: ReminderComposerKeyboardMonitorView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var router: ReminderComposerFocusRouter?
        private var monitor: Any?

        init(router: ReminderComposerFocusRouter) {
            self.router = router
        }

        func install(for view: ReminderComposerKeyboardMonitorView) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self,
                      let view,
                      let composerWindow = view.window,
                      NSApp.isActive,
                      event.window === composerWindow || NSApp.mainWindow === composerWindow,
                      event.keyCode == 48,
                      !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.option)
                else { return event }
                self.router?.handleTab(reverse: event.modifierFlags.contains(.shift))
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

    }
}

final class ReminderComposerKeyboardMonitorView: NSView {}
