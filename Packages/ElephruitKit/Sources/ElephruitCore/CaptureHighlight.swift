import Foundation

/// One stretch of capture text that means something, expressed in the offsets a text view uses.
///
/// ### Why this is not just `CaptureDraft.tokens`
/// The parser records character offsets — grapheme clusters, the unit Swift's `String` counts in.
/// `NSTextView`, `NSAttributedString`, and every `NSRange` in AppKit count UTF-16 code units. The two
/// agree right up until somebody types an emoji or a flag, at which point every highlight after it
/// is drawn over the wrong letters. Converting once, here, where it can be tested against a string
/// containing a family emoji, is the difference between a rule and a hope.
///
/// It also collapses the parser's two lists — what it understood and what looked like syntax and was
/// not understood — into one ordered sequence, because a view drawing them has to interleave them
/// and neither list is sorted with respect to the other.
public struct CaptureHighlight: Sendable, Hashable {
    /// Whether the app made sense of this.
    ///
    /// Kept separate from ``kind`` because the *treatment* differs by this and not by that: anything
    /// understood becomes a solid token the user can delete in one press, and anything that only
    /// looked like syntax gets a quiet mark and stays ordinary editable text. Drawing an unrecognised
    /// `#` as a token would be the interface claiming something it has not done.
    public enum Standing: Sendable, Hashable {
        case understood
        case notUnderstood
    }

    public var standing: Standing

    /// What the parser called it. `.unrecognised` when ``standing`` is ``Standing/notUnderstood``.
    public var kind: CaptureToken.Kind

    /// The value without its sigil — what to say out loud.
    public var text: String

    /// UTF-16 offsets into the text this was built from, ready for `NSRange(location:length:)`.
    public var utf16Range: Range<Int>

    public init(standing: Standing, kind: CaptureToken.Kind, text: String, utf16Range: Range<Int>) {
        self.standing = standing
        self.kind = kind
        self.text = text
        self.utf16Range = utf16Range
    }

    /// What VoiceOver should hear in place of the punctuation.
    ///
    /// A screen reader given `#landscape` says "number sign landscape", which describes the
    /// keystrokes rather than the meaning. The token is a tag; that is the fact worth announcing.
    public var spokenDescription: String {
        switch (standing, kind) {
        case (.notUnderstood, _): "\(text), not recognized"
        case (_, .tag): "Tag \(text)"
        case (_, .kind): "Type \(text)"
        case (_, .person): "Person \(text)"
        case (_, .project): "Project \(text)"
        case (_, .dueDate): "Deadline \(text)"
        case (_, .followDate): "Come back to it \(text)"
        case (_, .priority): "Priority \(text)"
        case (_, .unrecognised): "\(text), not recognized"
        }
    }
}

extension CaptureHighlight {
    /// Every meaningful stretch of `text`, in the order it appears.
    ///
    /// Runs the same parser the interpretation row and the save path run, so a token that is drawn
    /// as understood is understood — there is no second, cosmetic notion of what counts as a tag
    /// that could drift away from the real one.
    ///
    /// Only the first line carries tokens, because only the first line is parsed for grammar: a `#`
    /// in the third paragraph of a jotted note is a hash, not a tag, and highlighting it would
    /// promise a tag that never gets written.
    ///
    /// The vocabulary is passed straight through for the same reason it exists: a field that drew
    /// `>Q3 Launch` as one token while the save path filed it under "Q3" would be lying about what
    /// it had understood.
    public static func spans(
        in text: String,
        knowing vocabulary: CaptureVocabulary = .empty
    ) -> [CaptureHighlight] {
        let draft = CaptureParser.parse(text, knowing: vocabulary)

        let understood = draft.tokens.map {
            (standing: Standing.understood, token: $0)
        }
        let notUnderstood = draft.unresolvedTokens.map {
            (standing: Standing.notUnderstood, token: $0)
        }

        return (understood + notUnderstood)
            .compactMap { entry -> CaptureHighlight? in
                guard let range = utf16Range(of: entry.token.range, in: text) else { return nil }
                return CaptureHighlight(
                    standing: entry.standing,
                    kind: entry.token.kind,
                    text: entry.token.text,
                    utf16Range: range
                )
            }
            .sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
    }

    /// Converts a range of characters into a range of UTF-16 code units.
    ///
    /// Returns `nil` rather than clamping when the range does not fit, because a highlight that has
    /// slipped is worse than a highlight that is missing: the first quietly draws over the wrong
    /// word, and only the second is visible as a bug.
    static func utf16Range(of characters: Range<Int>, in text: String) -> Range<Int>? {
        let count = text.count
        guard characters.lowerBound >= 0,
              characters.upperBound <= count,
              characters.lowerBound < characters.upperBound
        else { return nil }

        let lower = text.index(text.startIndex, offsetBy: characters.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: characters.upperBound)
        return lower.utf16Offset(in: text)..<upper.utf16Offset(in: text)
    }
}

extension Array where Element == CaptureHighlight {
    /// The token containing or ending at `location`, if there is one.
    ///
    /// "Ending at" is included on purpose: it is what makes one press of Delete remove a whole tag.
    /// A caret sitting immediately after `#landscape` is, to the person looking at it, *on* the tag —
    /// the tag is the last thing they typed — so that is where the rule has to hold.
    ///
    /// The opening edge is excluded for the mirrored reason. A caret immediately *before* a token has
    /// not entered it yet, and deleting backwards from there must take whatever precedes the token
    /// rather than reaching forwards over it.
    public func token(enclosing location: Int) -> CaptureHighlight? {
        first {
            $0.standing == .understood
                && location > $0.utf16Range.lowerBound
                && location <= $0.utf16Range.upperBound
        }
    }

    /// The token a forward delete at `location` should remove whole.
    ///
    /// The mirror of ``token(enclosing:)``: forward delete works on what is *in front of* the caret,
    /// so here the opening edge counts and the closing edge does not.
    public func token(startingFrom location: Int) -> CaptureHighlight? {
        first {
            $0.standing == .understood
                && location >= $0.utf16Range.lowerBound
                && location < $0.utf16Range.upperBound
        }
    }

    /// The token any part of `range` touches, if exactly one does.
    ///
    /// An empty range is a caret, and a caret touching either edge counts — this is what a
    /// double-click reports before AppKit has grown the selection to a word, and growing it to the
    /// whole token instead is the point.
    public func token(intersecting range: Range<Int>) -> CaptureHighlight? {
        let hits = filter { span in
            guard span.standing == .understood else { return false }

            if range.isEmpty {
                return range.lowerBound >= span.utf16Range.lowerBound
                    && range.lowerBound <= span.utf16Range.upperBound
            }

            return span.utf16Range.lowerBound < range.upperBound
                && range.lowerBound < span.utf16Range.upperBound
        }
        return hits.count == 1 ? hits.first : nil
    }
}
