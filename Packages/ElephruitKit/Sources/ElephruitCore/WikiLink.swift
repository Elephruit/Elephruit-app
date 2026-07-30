import Foundation

/// A `[[Wiki Link]]` found in a body of text.
///
/// Wiki links are *owned by the text*. On every save the body is re-scanned and the
/// item's `.wiki` links are reconciled to match, so the text and the graph can never
/// disagree. Links the user makes deliberately through the inspector use a different
/// ``LinkKind`` and are never touched by this process.
public struct WikiLink: Sendable, Hashable {
    /// The target's title, as written between the brackets.
    public let targetTitle: String

    /// Alternate text to display, from `[[Target|display text]]`.
    public let displayText: String?

    /// Where the whole `[[…]]` construct sits in the source string.
    public let range: Range<String.Index>

    /// The matching form of ``targetTitle``, used to resolve against existing items.
    public var matchKey: String {
        TextNormalizer.foldedForMatching(targetTitle)
    }

    /// What to render for this link.
    public var label: String {
        displayText ?? targetTitle
    }

    public init(targetTitle: String, displayText: String?, range: Range<String.Index>) {
        self.targetTitle = targetTitle
        self.displayText = displayText
        self.range = range
    }
}

/// Finds and rewrites `[[Wiki Links]]` in plain text.
///
/// A deliberately small hand-written scanner rather than a regular expression or a
/// Markdown parser: the syntax is two characters, the text can be megabytes, and this
/// runs on every keystroke's debounce. It also means the editor and the exporter agree
/// exactly on what a link is.
public enum WikiLinkParser {
    private static let opening = "[["
    private static let closing = "]]"

    /// Every wiki link in `text`, in the order they appear.
    ///
    /// Unterminated openings are ignored, so a user midway through typing `[[Some ti`
    /// produces no link and no error.
    public static func links(in text: String) -> [WikiLink] {
        guard text.contains(opening) else { return [] }

        var results: [WikiLink] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let openRange = text.range(of: opening, range: searchStart..<text.endIndex) {
            guard let closeRange = text.range(of: closing, range: openRange.upperBound..<text.endIndex) else {
                break  // Unterminated; nothing further can close either.
            }

            let inner = text[openRange.upperBound..<closeRange.lowerBound]

            // A nested opening means the outer one was never a link.
            if inner.contains("[") {
                searchStart = openRange.upperBound
                continue
            }

            if let link = makeLink(from: inner, fullRange: openRange.lowerBound..<closeRange.upperBound) {
                results.append(link)
            }

            searchStart = closeRange.upperBound
        }

        return results
    }

    private static func makeLink(from inner: Substring, fullRange: Range<String.Index>) -> WikiLink? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)

        let target = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !target.isEmpty else { return nil }

        let display = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : nil

        return WikiLink(
            targetTitle: target,
            displayText: (display?.isEmpty ?? true) ? nil : display,
            range: fullRange
        )
    }

    /// The partial link the caret sits inside, if any — the state that drives inline
    /// completion.
    ///
    /// Returns the text typed so far after `[[`, together with the range that an
    /// accepted completion should replace. Returns `nil` if the caret is not inside an
    /// unterminated `[[`.
    public static func activeCompletion(
        in text: String,
        caretAt caret: String.Index
    ) -> (query: String, replacementRange: Range<String.Index>)? {
        guard caret <= text.endIndex else { return nil }

        // Walk back from the caret looking for an unclosed `[[` on the same line.
        var cursor = caret
        var scanned = 0
        let maximumTitleLength = 200

        while cursor > text.startIndex, scanned < maximumTitleLength {
            let previous = text.index(before: cursor)
            let character = text[previous]

            // A newline or a closing bracket ends the candidate.
            if character.isNewline || character == "]" { return nil }

            if character == "[", previous > text.startIndex, text[text.index(before: previous)] == "[" {
                let openStart = text.index(before: previous)
                let query = String(text[cursor..<caret])
                return (query, openStart..<caret)
            }

            cursor = previous
            scanned += 1
        }

        return nil
    }

    /// The `[[…]]` form of a title, for insertion by the completion UI.
    ///
    /// Titles containing `]` or `|` cannot be represented, so they are sanitised rather
    /// than producing a link that will not parse back.
    public static func linkSyntax(forTitle title: String) -> String {
        let sanitised = title
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return opening + sanitised + closing
    }
}
