import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What the caret is in the middle of typing.
///
/// Pure, so the rule for "is the user part-way through a tag" is testable without a window.
public struct CaptureCompletion: Sendable, Hashable {
    public enum Trigger: String, Sendable, Hashable {
        case tag
        case person
        case project
        case dueDate
        case followDate

        /// What was typed to start it.
        public var prefix: String {
            switch self {
            case .tag: "#"
            case .person: "@"
            case .project: ">"
            case .dueDate: "due:"
            case .followDate: "follow:"
            }
        }
    }

    public var trigger: Trigger
    /// What has been typed since the trigger.
    public var query: String
    /// Where the trigger began, as a character offset.
    public var start: Int

    public init(trigger: Trigger, query: String, start: Int) {
        self.trigger = trigger
        self.query = query
        self.start = start
    }
}

extension CaptureCompletion {
    /// Works out what, if anything, the caret is completing.
    ///
    /// Scans back from the caret to the start of the current word. A completion ends at whitespace,
    /// so `#work ` is finished and `#wo` is not — which is the behaviour that stops a suggestion
    /// list appearing over text the user has moved on from.
    public static func active(in text: String, caretAt caret: Int) -> CaptureCompletion? {
        let characters = Array(text)
        guard caret <= characters.count, caret > 0 else { return nil }

        var start = caret
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }
        guard start < caret else { return nil }

        let word = String(characters[start..<caret])

        // Keywords before sigils: `due:` starts with a letter, so a sigil test would never see it.
        for trigger in [Trigger.dueDate, .followDate] where word.lowercased().hasPrefix(trigger.prefix) {
            return CaptureCompletion(
                trigger: trigger,
                query: String(word.dropFirst(trigger.prefix.count)),
                start: start
            )
        }

        for trigger in [Trigger.tag, .person, .project] where word.hasPrefix(trigger.prefix) {
            return CaptureCompletion(
                trigger: trigger,
                query: String(word.dropFirst()),
                start: start
            )
        }

        return nil
    }

    /// Replaces the word being completed with the chosen value, and says where the caret goes.
    ///
    /// A trailing space is added because the next thing typed is always something else — making the
    /// user press space after every accepted suggestion would be a tax on the common case.
    public func applying(_ value: String, to text: String, caretAt caret: Int) -> (text: String, caret: Int) {
        let characters = Array(text)
        let replacement = Array(trigger.prefix + value + " ")
        var updated = characters
        updated.replaceSubrange(start..<min(caret, characters.count), with: replacement)
        return (String(updated), start + replacement.count)
    }
}

/// The contents of the floating capture panel.
///
/// Deliberately the same grammar, the same parser and the same save path as the in-window sheet —
/// this is a different way in, not a different feature.
struct QuickJotView: View {
    @Environment(\.services) private var services

    @Bindable var controller: QuickJotController

    @State private var caret = 0
    @State private var suggestions: [String] = []
    @State private var selection = 0
    @FocusState private var isFieldFocused: Bool

    private var draft: CaptureDraft { CaptureParser.parse(controller.text) }

    private var completion: CaptureCompletion? {
        CaptureCompletion.active(in: controller.text, caretAt: caret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            CaptureTextField(
                text: $controller.text,
                caret: $caret,
                onSubmit: { save() },
                onCancel: { controller.hide() },
                onMove: { direction in moveSelection(direction) },
                onAccept: { acceptSuggestion() }
            )
            .frame(minHeight: 78, maxHeight: 130)
            .accessibilityIdentifier(AccessibilityID.QuickCapture.textField)
            .accessibilityLabel("What would you like to capture?")

            if !suggestions.isEmpty {
                suggestionList
            } else {
                interpretation
            }

            if let error = controller.lastError {
                Label(error.summary, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
                    .lineLimit(2)
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .task(id: completion) { await refreshSuggestions() }
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }

    private var header: some View {
        HStack {
            Label("Quick Jot", systemImage: "square.and.pencil")
                .font(.system(.headline, design: .default, weight: .medium))
            Spacer()
            KeyHint("⌘", "↩")
        }
    }

    @ViewBuilder
    private var interpretation: some View {
        if controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: Theme.Spacing.medium) {
                ForEach(CaptureParser.grammarHints, id: \.sigil) { hint in
                    HStack(spacing: Theme.Spacing.hairline) {
                        Text(hint.sigil)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(Theme.Colors.selection)
                        Text(hint.meaning)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
        } else {
            let parsed = draft
            HStack(spacing: Theme.Spacing.small) {
                Label(parsed.kind.displayName, systemImage: parsed.kind.symbolName)
                if !parsed.tagSlugs.isEmpty { TagChipRow(slugs: parsed.tagSlugs, limit: 3) }
                if let project = parsed.projectHint {
                    Label(project, systemImage: "square.stack.3d.up")
                }
                if let due = parsed.dueInterpretation {
                    Label(due.summary, systemImage: "calendar")
                }
                if let follow = parsed.followDate {
                    Label(follow.summary, systemImage: "arrow.trianglehead.counterclockwise")
                }
                Spacer()
            }
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.secondaryText)
            .lineLimit(1)
            .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text(completion?.trigger.prefix ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Colors.selection)
                    Text(value)
                        .font(Theme.Text.metadata)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, Theme.Spacing.small)
                .background(
                    index == selection
                        ? Theme.Colors.selection.opacity(0.18)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection = index; acceptSuggestion() }
            }
        }
        .accessibilityLabel("\(suggestions.count) suggestions. Use the arrow keys, then Tab to accept.")
    }

    private var footer: some View {
        HStack {
            Text(suggestions.isEmpty ? "Saved to Inbox unless a project is named." : "Tab accepts · ↑↓ chooses")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Spacer()

            Button("Cancel") { controller.hide() }
                .accessibilityIdentifier(AccessibilityID.QuickCapture.cancelButton)

            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(draft.isEmpty)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.saveButton)
        }
    }

    // MARK: - Behaviour

    private func save() {
        controller.save()
    }

    private func moveSelection(_ direction: Int) {
        guard !suggestions.isEmpty else { return }
        selection = max(0, min(suggestions.count - 1, selection + direction))
    }

    /// Returns whether a suggestion was taken, so the field knows whether to swallow the key.
    @discardableResult
    private func acceptSuggestion() -> Bool {
        guard let completion, suggestions.indices.contains(selection) else { return false }
        let applied = completion.applying(suggestions[selection], to: controller.text, caretAt: caret)
        controller.text = applied.text
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
}
