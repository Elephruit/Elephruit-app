import Foundation

// MARK: - Segments

/// One stretch of a note the editor draws with a single view.
///
/// A run of consecutive prose pieces is one segment and one text view; each object piece is its own
/// segment. This is the spec's central decision made into a value: a note of twenty paragraphs, an
/// image, and ten more paragraphs is *three* segments, and everything a text view is good at —
/// selection, the caret, ⌘B across paragraphs — stays inside one of them.
public enum NoteSegment: Hashable, Sendable {
    /// The piece indices of a maximal run of prose. Never empty.
    case prose(Range<Int>)

    /// The piece index of a single object.
    case object(Int)

    /// The piece indices this segment covers.
    public var pieceRange: Range<Int> {
        switch self {
        case .prose(let range): range
        case .object(let index): index..<(index + 1)
        }
    }
}

extension NoteDocument {
    /// The document cut into segments: maximal runs of prose, and objects one by one.
    ///
    /// Pure and recomputed rather than stored, because the pieces are the truth and a cached
    /// segmentation is a second copy of it that can disagree. The editor's view identity is derived
    /// from what a segment contains, not from its position — see the `/` menu trap in
    /// `docs/31-notes-editor-spec.md` for what position-based identity costs.
    public var segments: [NoteSegment] {
        var result: [NoteSegment] = []
        var proseStart: Int?

        for (index, piece) in pieces.enumerated() {
            if piece.isProse {
                if proseStart == nil { proseStart = index }
            } else {
                if let start = proseStart {
                    result.append(.prose(start..<index))
                    proseStart = nil
                }
                result.append(.object(index))
            }
        }

        if let start = proseStart {
            result.append(.prose(start..<pieces.count))
        }

        return result
    }
}

// MARK: - Editing operations

/// Where in a document an insertion lands: inside which piece, and how far into its text.
public struct NotePieceLocation: Hashable, Sendable {
    public var pieceIndex: Int

    /// A Character offset into a prose piece's text. Ignored when the piece is an object.
    public var offset: Int

    public init(pieceIndex: Int, offset: Int = 0) {
        self.pieceIndex = pieceIndex
        self.offset = offset
    }
}

/// The pure editing operations, on the document rather than in the view.
///
/// ### Why these are functions returning documents
/// Because this is where correctness is decided and where tests are cheap. The text view will
/// express most edits as text edits and convert; these are the operations that arrive from
/// *outside* the text — the Format menu, the `/` menu, the outline, a click on a checkbox — and
/// each of them has to hold for any document, including ones the view could not currently show.
///
/// Every operation is total: an index that is out of range is answered with the document unchanged,
/// never a trap. A stale index is a normal event in an editor — the click that toggled a tick was
/// aimed at a document the debounced save has since replaced — and the right response to it is
/// nothing, not a crash.
extension NoteDocument {
    /// Splits a prose piece in two at a Character offset. Both halves keep the kind and its fields.
    ///
    /// The tick does not duplicate: ticking a checklist item and then splitting it should not mint
    /// a second finished task. The first half keeps the tick, the second starts clear.
    public func splittingParagraph(at index: Int, offset: Int) -> NoteDocument {
        guard pieces.indices.contains(index), let paragraph = pieces[index].paragraph else { return self }

        let at = max(0, min(offset, paragraph.text.length))
        var first = paragraph
        first.text = paragraph.text.slice(0..<at)
        var second = paragraph
        second.text = paragraph.text.slice(at..<paragraph.text.length)
        second.isTicked = false

        var updated = self
        updated.pieces.replaceSubrange(index...index, with: [.prose(first), .prose(second)])
        return updated
    }

    /// Joins a prose piece onto the prose piece before it, keeping the earlier one's kind.
    ///
    /// This is Backspace at the start of a paragraph. The earlier paragraph's kind wins because
    /// that is where the merged text now lives; the later one's kind was a property of a paragraph
    /// that no longer exists.
    public func joiningParagraphWithPrevious(at index: Int) -> NoteDocument {
        guard index > 0,
              pieces.indices.contains(index),
              let current = pieces[index].paragraph,
              let previous = pieces[index - 1].paragraph
        else { return self }

        var merged = previous
        merged.text = previous.text.appending(current.text)

        var updated = self
        updated.pieces.replaceSubrange((index - 1)...index, with: [.prose(merged)])
        return updated
    }

    /// Applies a kind to every prose piece in a range of piece indices.
    ///
    /// Objects in the range are left alone rather than refused: the Format menu acts on whatever is
    /// selected, and a selection that happens to cross a divider should still turn its paragraphs
    /// into a quote. `NoteParagraph.normalize` drops the fields the new kind cannot use.
    public func changingKind(to kind: NoteParagraphKind, in range: Range<Int>) -> NoteDocument {
        let bounded = clampedPieceRange(range)
        guard !bounded.isEmpty else { return self }

        var updated = self
        for index in bounded {
            guard let paragraph = updated.pieces[index].paragraph else { continue }
            updated.pieces[index] = .prose(
                NoteParagraph(
                    kind: kind,
                    text: paragraph.text,
                    indent: paragraph.indent,
                    isTicked: paragraph.isTicked,
                    language: paragraph.language,
                    tone: paragraph.tone
                )
            )
        }
        return updated
    }

    /// Steps the indent of every list item in a range, in or out.
    ///
    /// Only list items move — on anything else Tab means nothing, and that is decided by the kind
    /// (`acceptsIndent`) rather than re-decided here. The paragraph clamps its own indent.
    public func indenting(by delta: Int, in range: Range<Int>) -> NoteDocument {
        let bounded = clampedPieceRange(range)
        guard !bounded.isEmpty, delta != 0 else { return self }

        var updated = self
        for index in bounded {
            guard let paragraph = updated.pieces[index].paragraph, paragraph.kind.acceptsIndent else { continue }
            var moved = paragraph
            moved.indent = paragraph.indent + delta
            updated.pieces[index] = .prose(NoteParagraph(
                kind: moved.kind,
                text: moved.text,
                indent: moved.indent,
                isTicked: moved.isTicked,
                language: moved.language,
                tone: moved.tone
            ))
        }
        return updated
    }

    /// Moves one piece to sit at another index, as the outline's drag and the Move Up/Down commands
    /// need.
    ///
    /// The destination is the index in the document *as it stands*, and the operation accounts for
    /// the removal itself — callers say "move piece 2 to where piece 5 is" without doing arithmetic
    /// about which side of the gap the target lands on.
    public func movingPiece(from source: Int, to destination: Int) -> NoteDocument {
        guard pieces.indices.contains(source),
              destination >= 0, destination < pieces.count,
              source != destination
        else { return self }

        var updated = self
        let piece = updated.pieces.remove(at: source)
        updated.pieces.insert(piece, at: destination)
        return updated
    }

    /// Inserts an object at a location, splitting the prose piece there if the offset falls inside
    /// its text.
    ///
    /// This is the only operation that moves a segment boundary, and the test suite says so by
    /// name. At the start or end of a paragraph nothing splits — the object slides in beside it —
    /// so typing `/divider` on an empty last line does not leave an empty paragraph stranded on
    /// the far side.
    public func insertingObject(_ object: NoteObject, at location: NotePieceLocation) -> NoteDocument {
        var updated = self

        // Past the end means append, which is what inserting into an empty tail feels like.
        guard pieces.indices.contains(location.pieceIndex) else {
            updated.pieces.append(.object(object))
            return updated
        }

        guard let paragraph = pieces[location.pieceIndex].paragraph else {
            // Inserting at an object means beside it, after.
            updated.pieces.insert(.object(object), at: location.pieceIndex + 1)
            return updated
        }

        let offset = max(0, min(location.offset, paragraph.text.length))

        if offset == 0 {
            updated.pieces.insert(.object(object), at: location.pieceIndex)
        } else if offset == paragraph.text.length {
            updated.pieces.insert(.object(object), at: location.pieceIndex + 1)
        } else {
            updated = updated.splittingParagraph(at: location.pieceIndex, offset: offset)
            updated.pieces.insert(.object(object), at: location.pieceIndex + 1)
        }

        return updated
    }

    /// Removes one piece.
    ///
    /// Never leaves the document with no pieces: an editor with no paragraphs has nowhere to put
    /// the caret, which is the same reason ``NoteDocument/empty`` is not genuinely empty.
    public func removingPiece(at index: Int) -> NoteDocument {
        guard pieces.indices.contains(index) else { return self }

        var updated = self
        updated.pieces.remove(at: index)
        if updated.pieces.isEmpty {
            updated.pieces = [.prose(NoteParagraph())]
        }
        return updated
    }

    /// Replaces a run of pieces with new ones — how a prose segment's edits arrive back from the
    /// text view.
    ///
    /// An empty replacement collapses the run entirely; as with ``removingPiece(at:)``, a document
    /// cannot be edited down to nothing.
    public func replacingPieces(in range: Range<Int>, with replacement: [NotePiece]) -> NoteDocument {
        let bounded = clampedPieceRange(range)

        var updated = self
        updated.pieces.replaceSubrange(bounded, with: replacement)
        if updated.pieces.isEmpty {
            updated.pieces = [.prose(NoteParagraph())]
        }
        return updated
    }

    /// Flips one checklist item's tick.
    public func togglingTick(at index: Int) -> NoteDocument {
        guard pieces.indices.contains(index),
              let paragraph = pieces[index].paragraph,
              paragraph.kind == .checklist
        else { return self }

        var updated = self
        var ticked = paragraph
        ticked.isTicked.toggle()
        updated.pieces[index] = .prose(ticked)
        return updated
    }

    /// Sets a callout's tone. Does nothing to any other kind.
    public func settingCalloutTone(_ tone: NoteCalloutTone, at index: Int) -> NoteDocument {
        guard pieces.indices.contains(index),
              let paragraph = pieces[index].paragraph,
              paragraph.kind == .callout
        else { return self }

        var updated = self
        var toned = paragraph
        toned.tone = tone
        updated.pieces[index] = .prose(toned)
        return updated
    }

    /// Sets a code block's language. Does nothing to any other kind.
    public func settingCodeLanguage(_ language: String?, at index: Int) -> NoteDocument {
        guard pieces.indices.contains(index),
              let paragraph = pieces[index].paragraph,
              paragraph.kind == .code
        else { return self }

        var updated = self
        var retagged = paragraph
        retagged.language = language?.isEmpty == true ? nil : language
        updated.pieces[index] = .prose(retagged)
        return updated
    }

    private func clampedPieceRange(_ range: Range<Int>) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, pieces.count))
        let upper = max(lower, min(range.upperBound, pieces.count))
        return lower..<upper
    }
}
