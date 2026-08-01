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
        .onChange(of: completion) { refreshSuggestions() }
        // Keyed on the change token rather than run once, because the panel outlives any single
        // capture: a project created after it was first opened must still be nameable in it.
        .task(id: services?.changeToken) {
            refreshLibraryFacts()
            // After the names, not before. The suggestion list is drawn from them, and an empty
            // vocabulary on the first pass is a panel that offers nothing until you type twice.
            refreshSuggestions()
        }
        .onAppear { focus = .title }
    }

    // MARK: - The card

    /// ### Why nothing sits to the left of the title
    /// The note/task control started here, as a checkbox in front of the first character. That is
    /// the conventional place for one, and it was wrong here for a reason the convention does not
    /// have to answer: where every captured item is a to-do, the box is decoration. Ours is a
    /// *choice*, and an unlabelled glyph that silently changes what you are creating is the wrong
    /// way to offer one. See ``CaptureKindToggle``.
    ///
    /// It also pushed the caret inward. An empty field showed a symbol, a gap, and then an insertion
    /// point floating in the middle of the card with the placeholder starting underneath it — so the
    /// first thing the panel did was make you work out where you were about to type. The title now
    /// begins at the card's edge, and the choice is in the footer with the other choices, wearing a
    /// word.
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
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
            .frame(height: 26)
            .focused($focus, equals: .title)
            .accessibilityIdentifier(AccessibilityID.QuickCapture.textField)
            .accessibilityLabel("What would you like to capture?")

            CaptureNotesField(text: $composition.notesText, onCancel: onCancel)
                .focused($focus, equals: .notes)

            if !suggestions.isEmpty {
                suggestionList
            }

            if !composition.draft.isEmpty {
                CaptureChipRow(draft: $composition.draft, tagColors: tagColors)
            }

            CaptureGrammarHints(hints: CaptureParser.grammarHints)

            if let error {
                Label(error.summary, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
                    .lineLimit(2)
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

    /// What the caret is part-way through naming.
    ///
    /// Every lookup goes through ``CaptureSuggestionSource``, which is also what the icon menus use,
    /// so the list under the field and the list in the popover cannot come to disagree about which
    /// people there are.
    private func refreshSuggestions() {
        guard let completion else {
            suggestions = []
            return
        }

        selection = 0
        let query = completion.query

        switch completion.trigger {
        case .tag:
            suggestions = source.tagSlugs(matching: query, limit: 6)

        case .person:
            suggestions = source.people(matching: query, limit: 6)

        case .project:
            suggestions = source.containers(matching: query, limit: 6)

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
            CaptureKindToggle(draft: $composition.draft)

            CaptureDestinationButton(
                draft: $composition.draft,
                source: source,
                onBeforeChoosing: settleWhatWasTyped
            )

            Spacer()

            CaptureActionRow(
                draft: $composition.draft,
                source: source,
                onBeforeChoosing: settleWhatWasTyped
            )

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

    private var source: CaptureSuggestionSource {
        CaptureSuggestionSource(services: services)
    }

    /// Turns anything typed but unsettled into a chip, before a click adds one of its own.
    ///
    /// Without this, `due:friday` left sitting in the sentence would be lifted later and would
    /// overwrite a date picked from the menu afterwards — because a lift is treated as the more
    /// recent act, and by the clock it would be. Settling first puts the two in the order they
    /// actually happened.
    private func settleWhatWasTyped() {
        composition.flush(knowing: vocabulary)
        suggestions = []
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
