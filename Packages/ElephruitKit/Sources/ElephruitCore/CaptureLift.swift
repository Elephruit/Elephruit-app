import Foundation

/// Taking a finished instruction out of the sentence it was written in.
///
/// ### What this is for
/// Quick Jot's grammar is *commands*. `due:friday` is not part of anybody's sentence — it is a thing
/// you say to the app, and once it has been heard there is no reason for it to go on sitting in the
/// middle of "Call the framer due:friday about the quote". This turns the heard part into a chip and
/// gives the sentence back.
///
/// ### Why a field that rewrites itself is normally a mistake, and why this is not one
/// Two other quick-entry surfaces in this app argue, at length, that the field must never be
/// rewritten — see ``TaskEntryParser`` and the event composer. They are right about what they are
/// describing, and the distinction is worth stating because otherwise this file reads as somebody
/// ignoring them.
///
/// Where the parse is **advisory** — Tasks and Calendar quick entry — the text *is* the record and
/// the interpretation is a reading of it. Dismissing a chip there deliberately leaves the words
/// behind, because the words are the user's sentence and nobody asked for it to be edited.
///
/// Where the parse is **constitutive** — here — the sigils are instructions and the title is what is
/// left once they have been obeyed. Leaving `#errand` in the title of a note that is now tagged
/// `errand` is not preserving the user's text; it is showing them the same fact twice and making one
/// of the copies their problem.
///
/// The specific harms those files list are real, and each has a guard rather than an argument:
/// nothing is lifted while there is marked text (so composition and dictation are untouched), nothing
/// is lifted with a selection open (so no selection has to be remapped), the caret is remapped
/// explicitly rather than left to land where it may, and the removal is one edit computed from one
/// parse so a paste of six tokens is a single undoable step. What survives of their argument — never
/// rewrite the token the user is *still typing* — is the rule below, in full.
///
/// ### Being late is safe, and that is the design
/// A token is only taken once it has plainly stopped growing, which means at any moment there may be
/// one in the sentence that has not become a chip yet. That is fine. ``QuickJotDraft/merged(with:)``
/// parses whatever is still in the fields and folds it in, so an unlifted token is *un-chipped*,
/// never *lost*. Every remaining gap in the rule below degrades to a missing chip rather than a
/// dropped instruction, which is the difference between a design and a bet.
public enum CaptureLift {
    /// What lifting did.
    public struct Result: Sendable, Hashable {
        /// The text with the settled tokens taken out.
        public var text: String

        /// Where the caret should now be, as a character offset.
        public var caret: Int

        /// The attributes the removed tokens carried, ready for ``QuickJotDraft/apply(_:)``.
        ///
        /// Only ever describes what was actually removed. A token left in the text contributes
        /// nothing here, which is what stops it being counted twice.
        public var lifted: CaptureDraft

        /// Whether anything moved. `false` means the caller must not touch its text view — the
        /// commonest case by far, since most keystrokes settle nothing.
        public var didLift: Bool
    }

    /// The task prefixes ``CaptureParser`` understands, longest first so `- [ ] ` is not read as `- `.
    private static let taskPrefixes = ["- [ ] ", "- [x] ", "[] ", "[ ] ", "- ", "* "]

    /// Removes every settled token from `text`.
    ///
    /// - Parameters:
    ///   - caret: The insertion point, as a character offset.
    ///   - selectionLength: How much is selected. Anything but zero means nothing is lifted —
    ///     remapping a selection across a set of removals is where this would get quietly wrong, and
    ///     a user with a selection open is about to replace it anyway.
    ///   - vocabulary: The project and person names the grammar may spell out without quotes. Must be
    ///     the same one the field and the save path are using, or they will disagree about where a
    ///     name ends.
    ///   - hasMarkedText: Whether an input method is part-way through composing. Nothing is lifted
    ///     while it is.
    ///   - flushing: Take everything understood, whether or not it has settled. What Save and losing
    ///     focus do, because there is no next keystroke for a token to grow into.
    public static func lift(
        _ text: String,
        caretAt caret: Int,
        selectionLength: Int = 0,
        knowing vocabulary: CaptureVocabulary = .empty,
        hasMarkedText: Bool = false,
        flushing: Bool = false
    ) -> Result {
        let unchanged = Result(text: text, caret: caret, lifted: CaptureDraft(), didLift: false)
        guard !hasMarkedText, selectionLength == 0 else { return unchanged }

        let characters = Array(text)
        let parsed = CaptureParser.parse(text, knowing: vocabulary)

        var lifted = CaptureDraft()
        var spans: [Range<Int>] = []

        // The task prefix first, and separately, because it is the one instruction with no token
        // behind it — the parser consumes it before tokenizing and reports only its effect.
        if let prefix = taskPrefixes.first(where: { text.hasPrefix($0) }) {
            lifted.kind = .task
            spans.append(0..<prefix.count)
        }

        for token in parsed.tokens where isSettled(token, in: characters, flushing: flushing) {
            guard record(token, from: parsed, into: &lifted) else { continue }
            spans.append(expanded(token.range, in: characters))
        }

        guard !spans.isEmpty else { return unchanged }

        let ordered = merging(spans)
        return Result(
            text: removing(ordered, from: characters),
            caret: remapping(caret, across: ordered),
            lifted: lifted,
            didLift: true
        )
    }

    // MARK: - When a token has stopped being typed

    /// Whether a token has settled, and so may be taken out of the text.
    ///
    /// Two rules, and which one applies depends on whether the token could still grow:
    ///
    /// - A token that **cannot grow** — a tag, a priority, anything quoted — is settled as soon as
    ///   there is whitespace after it. Typing the space is the user finishing it.
    /// - A token that **can grow** needs a *completed* word after it: a run of non-whitespace that is
    ///   itself followed by whitespace. Until then the next thing typed might still join on.
    ///
    /// The second rule is what makes `>Q3 ` behave, and it is worth tracing, because the obvious rule
    /// gets it wrong. `>Q3` is followed by a space, so "settled means followed by whitespace" would
    /// lift a project called `Q3` at the exact moment somebody is half-way through typing `Q3 Launch`.
    /// Requiring a completed word after it means the lift waits until there is a word that plainly is
    /// not part of the name — and because the parser re-reads the whole line each time, by then the
    /// token has already grown to `Q3 Launch` on its own. The rule does not need to know anything
    /// about names; it only needs to know when to stop waiting.
    ///
    /// The same clause does the same job for greedy dates: `due:friday 3` waits, because `3` might
    /// become `3pm`.
    private static func isSettled(
        _ token: CaptureToken,
        in characters: [Character],
        flushing: Bool
    ) -> Bool {
        // Never. Its text is still in the title and it means nothing yet; drawing it as a chip would
        // promise something the save path will not deliver.
        guard token.kind != .unrecognised else { return false }

        if flushing { return true }

        let end = token.range.upperBound
        guard end < characters.count, characters[end].isWhitespace else { return false }

        guard canGrow(token) else { return true }

        // The grammar is the first line's, so nothing on the next line can join this token.
        guard !characters[end].isNewline else { return true }

        return hasCompletedWord(after: end, in: characters)
    }

    /// Whether the next word typed might still become part of this token.
    ///
    /// Quoting settles anything: it is the user stating where the value ends, which is the whole
    /// reason ``CaptureToken/isQuoted`` is recorded.
    private static func canGrow(_ token: CaptureToken) -> Bool {
        guard !token.isQuoted else { return false }

        switch token.kind {
        case .tag, .priority, .unrecognised, .kind:
            // One non-whitespace run and one word from a closed set. Neither has any lookahead.
            // A kind word is the most closed of the lot — five words, exactly matched.
            return false
        case .project, .person:
            return true
        case .dueDate, .followDate:
            return true
        }
    }

    private static func hasCompletedWord(after index: Int, in characters: [Character]) -> Bool {
        var index = index
        while index < characters.count, characters[index].isWhitespace, !characters[index].isNewline {
            index += 1
        }
        guard index < characters.count, !characters[index].isNewline else { return false }

        let start = index
        while index < characters.count, !characters[index].isWhitespace {
            index += 1
        }
        guard index > start else { return false }

        // Followed by whitespace, so the word itself is finished rather than being typed.
        return index < characters.count
    }

    // MARK: - What a token was carrying

    /// Copies a token's meaning out of the parse.
    ///
    /// Read from `parsed` rather than from ``CaptureToken/text``, because a date token's text is a
    /// human summary — "Friday at 15:00" — and what is needed is the expression that produced it.
    /// There is at most one deadline and one start date in a parse, so there is nothing to match up.
    ///
    /// Returns whether anything was taken, so a token that turns out to carry nothing is left in the
    /// text rather than silently deleted.
    private static func record(
        _ token: CaptureToken,
        from parsed: CaptureDraft,
        into lifted: inout CaptureDraft
    ) -> Bool {
        switch token.kind {
        case .tag:
            lifted.tagSlugs.append(token.text)
        case .kind:
            // The kind is already on the parsed draft; the token exists so the text can be lifted
            // out of the title rather than left in it as a stray "#bug".
            lifted.kind = parsed.kind
        case .person:
            lifted.personHints.append(token.text)
        case .project:
            lifted.projectHint = token.text
        case .dueDate:
            guard parsed.dueDate != nil else { return false }
            lifted.dueDate = parsed.dueDate
            lifted.dueTime = parsed.dueTime
        case .followDate:
            guard let followDate = parsed.followDate else { return false }
            lifted.followDate = followDate
        case .priority:
            guard let priority = Priority(rawValue: token.text) else { return false }
            lifted.priority = priority
        case .unrecognised:
            return false
        }
        return true
    }

    // MARK: - Editing the text

    /// Widens a token's range to swallow one adjacent space.
    ///
    /// Without it, taking `#urgent` out of `Call #urgent Sarah` leaves `Call  Sarah` with two spaces
    /// in it — a visible scar where the instruction used to be, which is the opposite of the point.
    /// The space after is preferred, so a token at the end of the line takes the one before it
    /// instead and does not leave a trailing space either.
    private static func expanded(_ range: Range<Int>, in characters: [Character]) -> Range<Int> {
        if range.upperBound < characters.count,
           characters[range.upperBound].isWhitespace,
           !characters[range.upperBound].isNewline {
            return range.lowerBound..<(range.upperBound + 1)
        }

        if range.lowerBound > 0,
           characters[range.lowerBound - 1].isWhitespace,
           !characters[range.lowerBound - 1].isNewline {
            return (range.lowerBound - 1)..<range.upperBound
        }

        return range
    }

    /// Sorts and coalesces, so overlapping spans cannot remove the same character twice.
    ///
    /// They can overlap: `#a #b` widens both tokens rightwards, and a task prefix sits flush against
    /// whatever follows it.
    private static func merging(_ spans: [Range<Int>]) -> [Range<Int>] {
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []

        for span in sorted {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    /// Removes right to left, so each span's offsets are still the ones the parser reported.
    private static func removing(_ spans: [Range<Int>], from characters: [Character]) -> String {
        var characters = characters
        for span in spans.reversed() {
            let clamped = min(span.lowerBound, characters.count)..<min(span.upperBound, characters.count)
            guard !clamped.isEmpty else { continue }
            characters.removeSubrange(clamped)
        }
        return String(characters)
    }

    /// Where the insertion point ends up.
    ///
    /// Everything removed before it shifts it left. A caret *inside* something removed has nowhere of
    /// its own to go, so it lands where the token used to start — which is where the eye is, and the
    /// only choice that does not look like the cursor jumped.
    private static func remapping(_ caret: Int, across spans: [Range<Int>]) -> Int {
        var shift = 0

        for span in spans {
            if caret >= span.upperBound {
                shift += span.count
            } else if caret > span.lowerBound {
                return max(0, span.lowerBound - shift)
            } else {
                break
            }
        }

        return max(0, caret - shift)
    }
}
