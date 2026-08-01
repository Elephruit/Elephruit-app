import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Everything between the edges of a Quick Jot card, wherever it is being shown.
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
///
/// ### The shape of the card
/// A title, some notes, the chips for whatever has been decided, and a footer saying where it is
/// going. In that order, because that is the order somebody thinks in: what it is, then what else
/// there is to say about it, then which shelf it goes on.
///
/// The grammar hints stay visible throughout. They are the only thing in the card that teaches the
/// keyboard path, and a hint that disappears at the first keystroke is a hint nobody has read yet.
struct CaptureComposer: View {
    @Environment(\.services) private var services

    @Binding var composition: QuickJotComposition

    /// The most recent failure, if the caller keeps one. A sheet that dismisses on success has
    /// nowhere to show a failure and passes `nil`; the panel stays open and shows it.
    var error: AppError?

    var isSaving: Bool = false

    var onSave: () -> Void
    var onCancel: () -> Void

    /// Which field has the keyboard. `nil` means neither, which is what a click on a chip leaves
    /// behind and what the icon menus take.
    private enum Field: Hashable { case title, notes }

    @State private var caret = 0
    @State private var suggestions: [String] = []
    @State private var selection = 0
    @FocusState private var focus: Field?

    /// The project and person names the grammar may spell out without quotes.
    ///
    /// Held rather than fetched per keystroke: it changes when the library changes, not when the
    /// user types, and it is consulted for every word of every token.
    @State private var vocabulary: CaptureVocabulary = .empty

    /// Tag colours, so a chip here is the same colour as the same tag in a list.
    @State private var tagColors: [String: String] = [:]

    private var completion: CaptureCompletion? {
        CaptureCompletion.active(in: composition.titleText, caretAt: caret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Divider()
            footer
        }
        .task(id: completion) { await refreshSuggestions() }
        // Keyed on the change token rather than run once, because the panel outlives any single
        // capture: a project created after it was first opened must still be nameable in it.
        .task(id: services?.changeToken) { refreshLibraryFacts() }
        .onAppear { focus = .title }
    }

    // MARK: - The card

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                CaptureKindToggle(draft: $composition.draft)

                CaptureTitleField(
                    composition: $composition,
                    caret: $caret,
                    vocabulary: vocabulary,
                    placeholder: composition.draft.kind == .task ? "New To-Do" : "New Note",
                    onSubmit: onSave,
                    onCancel: onCancel,
                    onMoveToNotes: { focus = .notes },
                    onMove: { direction in moveSelection(direction) },
                    onAccept: { acceptSuggestion() },
                    onRemoveLastChip: { removeLastChip() }
                )
                .frame(height: 24)
                .focused($focus, equals: .title)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.textField)
                .accessibilityLabel("What would you like to capture?")
            }

            CaptureNotesField(text: $composition.notesText, onCancel: onCancel)
                .focused($focus, equals: .notes)
                .padding(.leading, 24)

            if !suggestions.isEmpty {
                suggestionList.padding(.leading, 24)
            }

            if !composition.draft.isEmpty {
                CaptureChipRow(draft: $composition.draft, tagColors: tagColors)
                    .padding(.leading, 24)
            }

            CaptureGrammarHints(hints: CaptureParser.grammarHints)
                .padding(.leading, 24)

            if let error {
                Label(error.summary, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(Theme.Spacing.large)
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
        let applied = completion.applying(suggestions[selection], to: composition.titleText, caretAt: caret)
        composition.titleText = applied.text
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

    // MARK: - Chips

    /// Backspace against the left edge of an empty title takes back the last thing decided.
    ///
    /// The words are deliberately **not** put back. Somebody pressing Backspace where there is
    /// nothing to delete is reaching for the last thing they did, not asking for `due:friday` to
    /// reappear in the middle of a sentence they have since finished writing.
    private func removeLastChip() -> Bool {
        var draft = composition.draft

        if let priority = draft.priority, priority.symbolName != nil {
            draft.setPriority(nil)
        } else if draft.dueDate != nil {
            draft.setDue(nil)
        } else if draft.followDate != nil {
            draft.setFollow(nil)
        } else if let last = draft.personHints.last {
            draft.removePerson(last)
        } else if let last = draft.tagSlugs.last {
            draft.removeTag(last)
        } else {
            return false
        }

        composition.draft = draft
        return true
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            destination

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.cancelButton)

            Button("Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(composition.isEmpty || isSaving)
                .accessibilityIdentifier(AccessibilityID.QuickCapture.saveButton)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Colors.subtleFill)
    }

    /// Where this will land — the Inbox, or a project named with `>`.
    ///
    /// A label for now; the picker arrives with the rest of the point-and-click row.
    private var destination: some View {
        let hint = composition.draft.projectHint
        let resolved = hint.flatMap { try? services?.capture.resolveContainer(named: $0) } ?? nil

        return Label(
            resolved?.title ?? hint ?? "Inbox",
            systemImage: resolved == nil && hint != nil ? "questionmark.square.dashed" : (hint == nil ? "tray" : "square.stack.3d.up")
        )
        .font(Theme.Text.metadata)
        .foregroundStyle(resolved == nil && hint != nil ? Theme.Colors.unresolvedLink : Theme.Colors.secondaryText)
        .lineLimit(1)
        .help(
            resolved == nil && hint != nil
                ? "No project with this name — the capture will go to the Inbox"
                : "Where this will be filed"
        )
        .accessibilityIdentifier(AccessibilityID.QuickCapture.destinationButton)
    }

    // MARK: - What the library knows

    private func refreshLibraryFacts() {
        guard let services else { return }
        vocabulary = (try? services.capture.vocabulary()) ?? .empty
        tagColors = Dictionary(
            ((try? services.tags.allTags()) ?? []).compactMap { tag in
                tag.colorName.map { (tag.slug, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
