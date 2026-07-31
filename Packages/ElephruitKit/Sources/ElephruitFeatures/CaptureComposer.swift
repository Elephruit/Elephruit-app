import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Everything between the title and the buttons of a Quick Jot, wherever it is being shown.
///
/// ### Why this is one view rather than two
/// Quick Jot has two doors: a floating panel for when Elephruit is not what you are looking at, and
/// a sheet for when it is. They were two views. That meant ⌘⇧J did different things depending on
/// where you pressed it — the panel offered completions and the sheet did not, the panel's field was
/// an `NSTextView` and the sheet's was a `TextEditor`, and a fix to one silently left the other
/// behind. Two doors into one room is a good design; two rooms is a bug that takes a year to notice.
///
/// What differs between the two is genuinely only what surrounds this: a panel is a window and a
/// sheet is not, they save through different objects, and they dismiss differently. All of that is
/// passed in.
struct CaptureComposer: View {
    @Environment(\.services) private var services

    @Binding var text: String

    /// The most recent failure, if the caller keeps one. A sheet that dismisses on success has
    /// nowhere to show a failure and passes `nil`; the panel stays open and shows it.
    var error: AppError?

    var isSaving: Bool = false

    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var caret = 0
    @State private var suggestions: [String] = []
    @State private var selection = 0

    private var draft: CaptureDraft { CaptureParser.parse(text) }

    private var completion: CaptureCompletion? {
        CaptureCompletion.active(in: text, caretAt: caret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            CaptureTextField(
                text: $text,
                caret: $caret,
                onSubmit: onSave,
                onCancel: onCancel,
                onMove: { direction in moveSelection(direction) },
                onAccept: { acceptSuggestion() }
            )
            .frame(minHeight: 78, maxHeight: 130)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator)
            )
            .accessibilityIdentifier(AccessibilityID.QuickCapture.textField)
            .accessibilityLabel("What would you like to capture?")

            if !suggestions.isEmpty {
                suggestionList
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                interpretation
            }

            // Always. See ``CaptureGrammarHints`` for why this does not disappear at the first
            // keystroke the way it used to.
            CaptureGrammarHints(hints: CaptureParser.grammarHints)

            if let error {
                Label(error.summary, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
                    .lineLimit(2)
            }

            Divider()

            footer
        }
        .task(id: completion) { await refreshSuggestions() }
    }

    // MARK: - Interpretation

    /// What the parser made of the text, shown before it is committed.
    ///
    /// The point of showing it is that the grammar becomes learnable by using it: a mistyped
    /// `!tomorow` is visible here rather than silently becoming three words of a title.
    private var interpretation: some View {
        let parsed = draft

        return HStack(spacing: Theme.Spacing.small) {
            Label(parsed.kind.displayName, systemImage: parsed.kind.symbolName)
                .foregroundStyle(Theme.Colors.secondaryText)

            if !parsed.tagSlugs.isEmpty {
                TagChipRow(slugs: parsed.tagSlugs, limit: 3)
            }

            if let project = parsed.projectHint {
                let resolved = resolvedProject(named: project)
                Label(project, systemImage: "square.stack.3d.up")
                    .foregroundStyle(resolved == nil ? Theme.Colors.unresolvedLink : Theme.Colors.secondaryText)
                    .help(
                        resolved == nil
                            ? "No project with this name — the capture will go to the Inbox"
                            : project
                    )
            }

            if let due = parsed.dueInterpretation {
                Label(due.summary, systemImage: "calendar")
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Deliberately a different glyph from the deadline. The two dates mean opposite things
            // and a shared icon would be the interface conflating what the grammar separates.
            if let follow = parsed.followDate {
                Label(follow.summary, systemImage: "arrow.trianglehead.counterclockwise")
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if let priority = parsed.priority, priority != .normal {
                Label(priority.displayName, systemImage: "flag")
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            if parsed.url != nil {
                Image(systemName: "link")
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()
        }
        .font(Theme.Text.metadata)
        .lineLimit(1)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
        .accessibilityLabel(interpretationDescription(parsed))
    }

    private func interpretationDescription(_ parsed: CaptureDraft) -> String {
        var parts = ["Will create a \(parsed.kind.displayName.lowercased())"]
        if !parsed.tagSlugs.isEmpty { parts.append("tagged \(parsed.tagSlugs.joined(separator: ", "))") }
        if let project = parsed.projectHint { parts.append("in \(project)") }
        if let due = parsed.dueInterpretation { parts.append("due \(due.summary)") }
        if let follow = parsed.followDate { parts.append("coming back \(follow.summary)") }
        if let priority = parsed.priority, priority != .normal {
            parts.append("\(priority.displayName.lowercased()) priority")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Completions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text(completion?.trigger.prefix ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.CaptureToken.accent)
                    Text(value)
                        .font(Theme.Text.metadata)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, Theme.Spacing.small)
                .background(
                    index == selection ? Theme.Colors.selection.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection = index; acceptSuggestion() }
            }
        }
        .accessibilityLabel("\(suggestions.count) suggestions. Use the arrow keys, then Tab to accept.")
    }

    private func moveSelection(_ direction: Int) {
        guard !suggestions.isEmpty else { return }
        selection = max(0, min(suggestions.count - 1, selection + direction))
    }

    /// Returns whether a suggestion was taken, so the field knows whether to swallow the key.
    @discardableResult
    private func acceptSuggestion() -> Bool {
        guard let completion, suggestions.indices.contains(selection) else { return false }
        let applied = completion.applying(suggestions[selection], to: text, caretAt: caret)
        text = applied.text
        caret = applied.caret
        suggestions = []
        return true
    }

    private func refreshSuggestions() async {
        guard let completion, let services else {
            suggestions = []
            return
        }

        selection = 0
        let query = completion.query

        switch completion.trigger {
        case .tag:
            let slugs = ((try? services.tags.allTags()) ?? [])
                .map(\.slug)
                .filter { query.isEmpty || $0.hasPrefix(query.lowercased()) }
            suggestions = Array(slugs.prefix(6))

        case .person, .project:
            // The same index-backed lookup that already backs `[[` completion in the editor.
            let titles = await services.search.titleSuggestions(prefix: query, limit: 12)
            let kinds: Set<ItemKind> = completion.trigger == .person
                ? [.person]
                : [.project, .area, .goal]
            let matches = titles
                .compactMap { try? services.items.item(id: $0.id) }
                .filter { kinds.contains($0.kind) }
                .map(\.title)
            suggestions = Array(matches.prefix(6))

        case .dueDate, .followDate:
            let examples = NaturalDateParser.recognisedExamples
                .filter { query.isEmpty || $0.hasPrefix(query.lowercased()) }
            suggestions = Array(examples.prefix(6))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(suggestions.isEmpty ? "Saved to Inbox unless a project is named." : "Tab accepts · ↑↓ chooses")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.cancelButton)

            Button("Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(draft.isEmpty || isSaving)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.saveButton)
        }
    }

    /// Only for the live interpretation line — resolution for the *save* happens in the service.
    private func resolvedProject(named hint: String) -> Item? {
        guard let services else { return nil }
        return try? services.capture.resolveContainer(named: hint)
    }
}

/// The title strip both doors share.
struct CaptureComposerHeader: View {
    var body: some View {
        HStack {
            Label("Quick Jot", systemImage: "square.and.pencil")
                .font(.system(.headline, design: .default, weight: .medium))
            Spacer()
            KeyHint("⌘", "↩")
        }
    }
}
