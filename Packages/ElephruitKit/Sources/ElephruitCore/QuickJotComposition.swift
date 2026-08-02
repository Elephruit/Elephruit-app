import Foundation

/// Everything a half-written Quick Jot consists of: a title, some notes, and the decisions taken so
/// far.
///
/// A value type, and in `ElephruitCore` rather than beside the panel, for the same reason the parser
/// is: the interesting behaviour here is *when a token stops being text and becomes a chip*, and that
/// should be answerable without a window. The panel and the sheet both hold one of these; so does
/// every test of the behaviour.
public struct QuickJotComposition: Sendable, Hashable {
    /// The single line the grammar is read from. Never contains a newline — the field that owns it
    /// is a field editor, and a pasted newline is split off into ``notesText``.
    public var titleText: String

    /// Everything below the title. Grammar chosen from completions is lifted into ``draft`` as it is
    /// entered. Unselected tokens are also recognised on save, so keyboard-only entry in Notes has
    /// the same result as entry in the title field.
    public var notesText: String

    /// What has been decided — by clicking, or by typing something that then settled.
    public var draft: QuickJotDraft

    public init(
        titleText: String = "",
        notesText: String = "",
        draft: QuickJotDraft = QuickJotDraft()
    ) {
        self.titleText = titleText
        self.notesText = notesText
        self.draft = draft
    }

    /// Whether there is anything here at all — what the Save button asks.
    ///
    /// Chips alone do not count. A deadline with no sentence attached is not a thing anybody meant to
    /// create, and saving it would put an untitled row in the Inbox for somebody to puzzle over.
    public var isEmpty: Bool {
        titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The two fields as the one string the parser expects: first line the title, the rest the body.
    private var combinedText: String {
        notesText.isEmpty ? titleText : titleText + "\n" + notesText
    }

    // MARK: - Moving text into decisions

    /// Takes any settled token out of the title, as a keystroke lands.
    ///
    /// Returns where the caret should now be, or `nil` if nothing moved — which is the answer for
    /// almost every keystroke, and the signal the field uses to leave itself alone.
    public mutating func liftWhileTyping(
        caretAt caret: Int,
        selectionLength: Int = 0,
        knowing vocabulary: CaptureVocabulary,
        hasMarkedText: Bool = false
    ) -> Int? {
        let result = CaptureLift.lift(
            titleText,
            caretAt: caret,
            selectionLength: selectionLength,
            knowing: vocabulary,
            hasMarkedText: hasMarkedText
        )
        guard result.didLift else { return nil }

        titleText = result.text
        draft.apply(result.lifted)
        return result.caret
    }

    /// Takes *everything* understood out of the title, settled or not.
    ///
    /// Run when the title field loses focus, when one of the icon menus is about to open, and on
    /// Save. All three are moments when there is no next keystroke for a token to grow into, so
    /// waiting has stopped being caution and become a way to lose a chip.
    ///
    /// The menu case is the one that earns it. Type `due:friday`, leave it sitting in the sentence,
    /// then pick Today from the calendar: without a flush first, the stale text would be lifted later
    /// and would overwrite the click, because a lift is treated as the more recent act. Flushing
    /// before the menu opens puts the two in the order they actually happened.
    @discardableResult
    public mutating func flush(knowing vocabulary: CaptureVocabulary) -> Bool {
        var didLift = false

        let titleResult = CaptureLift.lift(
            titleText,
            caretAt: titleText.count,
            knowing: vocabulary,
            flushing: true
        )
        if titleResult.didLift {
            titleText = titleResult.text
            draft.apply(titleResult.lifted)
            didLift = true
        }

        // Notes use the same grammar line by line. Strip only what the parser understood, keeping
        // all prose and line breaks, and move those decisions into the durable draft before save.
        var cleanedLines: [String] = []
        for line in notesText.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let result = CaptureLift.lift(
                text,
                caretAt: text.count,
                knowing: vocabulary,
                flushing: true
            )
            cleanedLines.append(result.text)
            if result.didLift {
                draft.apply(result.lifted)
                didLift = true
            }
        }
        if didLift {
            notesText = cleanedLines.joined(separator: "\n")
        }

        return didLift
    }

    /// The decisions the footer should show right now, including grammar that deliberately remains
    /// visible in either editor until the next settling point.
    public func previewDraft(knowing vocabulary: CaptureVocabulary) -> QuickJotDraft {
        var preview = draft
        preview.apply(CaptureParser.parse(titleText, knowing: vocabulary))
        for line in notesText.split(separator: "\n", omittingEmptySubsequences: false) {
            preview.apply(CaptureParser.parse(String(line), knowing: vocabulary))
        }
        return preview
    }

    // MARK: - Becoming something that can be saved

    /// What would be created, right now.
    ///
    /// Drawn from the decisions *and* a fresh parse of whatever is still in the fields, so a token
    /// that never settled is still honoured. Callers save after a ``flush(knowing:)``, which leaves
    /// the residual holding only what could never be lifted — an unclosed quote, a sigil the parser
    /// did not recognise, a bare URL.
    public func captured(knowing vocabulary: CaptureVocabulary) -> CaptureDraft {
        var decisions = draft

        // `CaptureParser` treats only its first line as grammar. Feed each notes line through that
        // same grammar to collect decisions, while preserving the notes verbatim as the item's body.
        // This lets `#`, `@`, `!` and `>` work in either editor without turning ordinary note prose
        // into a rewritten, whitespace-normalised document.
        for line in notesText.split(separator: "\n", omittingEmptySubsequences: false) {
            decisions.apply(CaptureParser.parse(String(line), knowing: vocabulary))
        }

        var captured = decisions.merged(
            with: CaptureParser.parse(titleText, knowing: vocabulary)
        )
        captured.originalText = combinedText
        captured.body = notesText.trimmingCharacters(in: .whitespacesAndNewlines)

        if captured.title.isEmpty, !captured.body.isEmpty {
            captured.title = TextNormalizer.inferredTitle(fromBody: captured.body)
        }
        return captured
    }
}
