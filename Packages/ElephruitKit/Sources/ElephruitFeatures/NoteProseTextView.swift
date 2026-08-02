import AppKit
import ElephruitCore
import ElephruitDesign

/// What the editor knows about the current selection, for the inspector and the Format menu.
public struct NoteSelectionState: Equatable, Sendable {
    /// The kinds the selection touches. One entry when the selection sits inside one paragraph.
    public var kinds: Set<NoteParagraphKind> = []

    /// The marks in force — at the caret, or common to the whole selection.
    public var marks: NoteInlineMarks = []

    /// Whether Tab would mean anything here.
    public var canIndent = false

    /// The callout tone at the caret, when the caret is in a callout.
    public var calloutTone: NoteCalloutTone?

    /// The code language at the caret, when the caret is in a code block.
    public var codeLanguage: String?

    /// Whether anything is actually selected, as opposed to a bare caret.
    public var hasSelection = false

    public init() {}
}

/// What the `/` menu needs from the text view, and what it answers back.
enum NoteSlashMenuCommand {
    case moveUp
    case moveDown
    case commit
    case cancel
}

/// The view-to-page conversation that `NSTextViewDelegate` does not cover.
@MainActor
protocol NoteProseTextViewCoordinator: AnyObject {
    /// The text or its attributes changed and the pieces should be read back.
    func proseDidChange(_ view: NoteProseTextView)

    /// A Markdown shortcut or `/` command asked for an object at a character position.
    func prose(_ view: NoteProseTextView, requestsObject object: NoteObject, atCharacterIndex index: Int)

    /// The `/` menu state changed: a query while it is open, `nil` when it closed.
    func prose(_ view: NoteProseTextView, slashQueryChanged query: String?, caretNear rect: NSRect)

    /// A key the `/` menu owns while it is open. Returns whether the menu consumed it.
    func prose(_ view: NoteProseTextView, slashCommand: NoteSlashMenuCommand) -> Bool

    /// The caret tried to leave the segment — arrow up on the first line, down on the last.
    func prose(_ view: NoteProseTextView, caretLeavesTowards edge: NoteProseTextView.Edge)

    /// The selection moved; the inspector wants the new state.
    func proseSelectionDidChange(_ view: NoteProseTextView, state: NoteSelectionState)
}

/// The editing surface for one run of prose.
///
/// One `NSTextView` for the whole run — never one per paragraph. Selection across paragraphs,
/// ⌘B, arrow keys, dictation and Find all come from AppKit for free because they are the things
/// a text view *is*; the paragraph kind travels as an attribute and the appearance is derived
/// from it, never the other way around. See `docs/31-notes-editor-spec.md` for what the
/// one-view-per-block design cost the first time.
final class NoteProseTextView: NSTextView {
    enum Edge {
        case up
        case down
    }

    weak var noteCoordinator: (any NoteProseTextViewCoordinator)?

    /// Where an active `/` began, or `nil` when no menu is open.
    private var slashLocation: Int?

    /// Built on the legacy layout stack deliberately: the list markers, quote bars and block
    /// tints are drawn from `NSLayoutManager` geometry, and TextKit 2 would silently fall back
    /// the first time `layoutManager` is touched anyway. Explicit is diagnosable.
    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)

        isRichText = true
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // The page supplies the sheet; the text draws straight onto it.
        drawsBackground = false

        // The attributes are ours to manage. Panels that write fonts and colours directly would
        // bypass the paragraph attribute, which is the one authority.
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        importsGraphics = false
        allowsImageEditing = false

        usesFindBar = true
        isIncrementalSearchingEnabled = true

        smartInsertDeleteEnabled = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = true
        isAutomaticDashSubstitutionEnabled = true
        isAutomaticTextReplacementEnabled = true
        isAutomaticSpellingCorrectionEnabled = false

        textContainerInset = NSSize(width: 0, height: 0)
        typingAttributes = NoteProseStyle.attributes(for: NoteParagraphAttribute(kind: .paragraph))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: - Paragraph geography

    /// The full range of the paragraph containing a character index, including its trailing
    /// newline when it has one.
    private func paragraphRange(at index: Int) -> NSRange {
        let text = string as NSString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        return text.paragraphRange(for: NSRange(location: min(index, text.length), length: 0))
    }

    /// The paragraph's text range, without its trailing newline.
    private func paragraphContentRange(at index: Int) -> NSRange {
        var range = paragraphRange(at: index)
        let text = string as NSString
        if range.length > 0, text.character(at: range.location + range.length - 1) == 0x0A {
            range.length -= 1
        }
        return range
    }

    /// The authoritative attribute for the paragraph at an index.
    ///
    /// Read from the paragraph's first character when it has one, and from the typing attributes
    /// when it does not — an empty paragraph the caret is parked in has its kind there and
    /// nowhere else.
    func paragraphAttribute(at index: Int) -> NoteParagraphAttribute {
        let range = paragraphRange(at: index)
        if range.length > 0, let attribute = textStorage?.attribute(
            .noteParagraph, at: range.location, effectiveRange: nil
        ) as? NoteParagraphAttribute {
            return attribute
        }
        if let typed = typingAttributes[.noteParagraph] as? NoteParagraphAttribute {
            return typed
        }
        return NoteParagraphAttribute(kind: .paragraph)
    }

    /// The attribute the conversion should assume for an empty final paragraph.
    var trailingEmptyParagraphAttribute: NoteParagraphAttribute? {
        typingAttributes[.noteParagraph] as? NoteParagraphAttribute
    }

    /// The content ranges of every paragraph the selection touches.
    private func selectedParagraphContentRanges() -> [NSRange] {
        let text = string as NSString
        let selection = selectedRange()
        let coverage = text.length > 0 ? text.paragraphRange(for: selection) : NSRange(location: 0, length: 0)

        var ranges: [NSRange] = []
        var index = coverage.location

        repeat {
            ranges.append(paragraphContentRange(at: index))
            let full = paragraphRange(at: index)
            if full.length == 0 { break }
            index = full.location + full.length
        } while index < coverage.location + coverage.length

        return ranges
    }

    // MARK: - Rewriting attributes

    /// Applies a new paragraph attribute across one paragraph, through the undo machinery.
    private func rewriteParagraph(at index: Int, to attribute: NoteParagraphAttribute) {
        let full = paragraphRange(at: index)

        if full.length > 0 {
            guard shouldChangeText(in: full, replacementString: nil) else { return }
            textStorage?.beginEditing()
            textStorage?.addAttribute(.noteParagraph, value: attribute, range: full)
            textStorage?.endEditing()
            didChangeText()
        }

        if paragraphRange(at: selectedRange().location) == full || full.length == 0 {
            typingAttributes = NoteProseStyle.attributes(
                for: attribute,
                marks: currentTypingMarks(),
                link: nil
            )
            // An attribute change with no characters — an empty paragraph taking a new kind —
            // never passes through `didChangeText`, so report it directly.
            if full.length == 0 {
                noteCoordinator?.proseDidChange(self)
            }
        }
    }

    private func currentTypingMarks() -> NoteInlineMarks {
        if let number = typingAttributes[.noteMarks] as? NSNumber {
            return NoteInlineMarks(rawValue: number.intValue)
        }
        return []
    }

    // MARK: - Public formatting surface

    /// Applies a paragraph kind to every paragraph the selection touches.
    func applyParagraphKind(_ kind: NoteParagraphKind) {
        for content in selectedParagraphContentRanges() {
            let existing = paragraphAttribute(at: content.location)
            let attribute = NoteParagraphAttribute(
                kind: kind,
                indent: kind.acceptsIndent ? existing.indent : 0,
                isTicked: kind == .checklist ? existing.isTicked : false,
                language: kind == .code ? existing.language : nil,
                tone: kind == .callout ? (existing.tone ?? .note) : nil
            )
            rewriteParagraph(at: content.location, to: attribute)
        }
        reconcileAppearance()
        reportSelectionState()
    }

    /// Steps the selection's list items in or out.
    func applyIndent(by delta: Int) {
        var changed = false
        for content in selectedParagraphContentRanges() {
            let existing = paragraphAttribute(at: content.location)
            guard existing.kind.acceptsIndent else { continue }
            let indent = max(0, min(existing.indent + delta, NoteParagraph.maximumIndent))
            guard indent != existing.indent else { continue }
            changed = true
            rewriteParagraph(at: content.location, to: NoteParagraphAttribute(
                kind: existing.kind,
                indent: indent,
                isTicked: existing.isTicked,
                language: existing.language,
                tone: existing.tone
            ))
        }
        if changed {
            reconcileAppearance()
            reportSelectionState()
        }
    }

    /// Sets the tone of the callout at the caret.
    func applyCalloutTone(_ tone: NoteCalloutTone) {
        let attribute = paragraphAttribute(at: selectedRange().location)
        guard attribute.kind == .callout else { return }
        rewriteParagraph(at: selectedRange().location, to: NoteParagraphAttribute(
            kind: .callout,
            indent: 0,
            isTicked: false,
            language: nil,
            tone: tone
        ))
        reconcileAppearance()
        reportSelectionState()
    }

    /// Sets the language of the code block at the caret.
    func applyCodeLanguage(_ language: String?) {
        let attribute = paragraphAttribute(at: selectedRange().location)
        guard attribute.kind == .code else { return }
        rewriteParagraph(at: selectedRange().location, to: NoteParagraphAttribute(
            kind: .code,
            indent: 0,
            isTicked: false,
            language: (language?.isEmpty ?? true) ? nil : language,
            tone: nil
        ))
        reportSelectionState()
    }

    /// Adds a mark across the selection, or removes it if every character already has it —
    /// the whole range decides, exactly as `NoteRichText.togglingMark` does and for the same
    /// reason: the second press must always undo the first.
    func toggleMark(_ mark: NoteInlineMarks) {
        let selection = selectedRange()

        guard selection.length > 0 else {
            var marks = currentTypingMarks()
            if marks.contains(mark) { marks.remove(mark) } else { marks.insert(mark) }
            let attribute = paragraphAttribute(at: selection.location)
            typingAttributes = NoteProseStyle.attributes(for: attribute, marks: marks, link: nil)
            reportSelectionState()
            return
        }

        guard let storage = textStorage else { return }

        var everywhere = true
        storage.enumerateAttribute(.noteMarks, in: selection, options: []) { value, _, stop in
            let marks = NoteInlineMarks(rawValue: (value as? NSNumber)?.intValue ?? 0)
            if !marks.contains(mark) {
                everywhere = false
                stop.pointee = true
            }
        }

        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.noteMarks, in: selection, options: []) { value, range, _ in
            var marks = NoteInlineMarks(rawValue: (value as? NSNumber)?.intValue ?? 0)
            if everywhere { marks.remove(mark) } else { marks.insert(mark) }
            if marks.isEmpty {
                storage.removeAttribute(.noteMarks, range: range)
            } else {
                storage.addAttribute(.noteMarks, value: NSNumber(value: marks.rawValue), range: range)
            }
        }
        storage.endEditing()
        didChangeText()
        reconcileAppearance()
        reportSelectionState()
    }

    /// Puts a link on the selection, or removes every link from it when given `nil`.
    func applyLink(_ link: NoteInlineLink?) {
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage else { return }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }

        storage.beginEditing()
        if let link {
            storage.addAttribute(.noteLink, value: NoteLinkAttribute(link), range: selection)
        } else {
            storage.removeAttribute(.noteLink, range: selection)
        }
        storage.endEditing()
        didChangeText()
        reconcileAppearance()
        reportSelectionState()
    }

    // MARK: - Appearance reconciliation

    /// Re-derives every derived attribute from the authoritative ones.
    ///
    /// After a join, a paste, or an undo, characters carry the paragraph attribute of a paragraph
    /// they no longer belong to. The rule is single: the attribute at a paragraph's head speaks
    /// for the whole paragraph, and font, colour, style, underline and strikethrough are all
    /// consequences. Idempotent, and appearance-only — it never touches what conversion reads,
    /// so it needs no undo registration.
    func reconcileAppearance() {
        guard let storage = textStorage, storage.length > 0 else { return }

        let text = string as NSString
        storage.beginEditing()

        var index = 0
        while index < text.length {
            let full = text.paragraphRange(for: NSRange(location: index, length: 0))
            let attribute = (storage.attribute(.noteParagraph, at: full.location, effectiveRange: nil)
                as? NoteParagraphAttribute) ?? NoteParagraphAttribute(kind: .paragraph)

            storage.addAttribute(.noteParagraph, value: attribute, range: full)

            storage.enumerateAttributes(in: full, options: []) { attributes, range, _ in
                let marks = NoteInlineMarks(rawValue: (attributes[.noteMarks] as? NSNumber)?.intValue ?? 0)
                let link = (attributes[.noteLink] as? NoteLinkAttribute)?.link
                let derived = NoteProseStyle.attributes(for: attribute, marks: marks, link: link)

                storage.addAttributes(derived, range: range)
                if derived[.underlineStyle] == nil {
                    storage.removeAttribute(.underlineStyle, range: range)
                }
                if derived[.strikethroughStyle] == nil {
                    storage.removeAttribute(.strikethroughStyle, range: range)
                }
                if derived[.backgroundColor] == nil {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
                if derived[.link] == nil {
                    storage.removeAttribute(.link, range: range)
                }
            }

            index = full.location + max(full.length, 1)
        }

        storage.endEditing()
    }

    // MARK: - Keys

    override func insertNewline(_ sender: Any?) {
        if slashLocation != nil, noteCoordinator?.prose(self, slashCommand: .commit) == true {
            return
        }

        let selection = selectedRange()
        let attribute = paragraphAttribute(at: selection.location)
        let content = paragraphContentRange(at: selection.location)

        // Return inside a code block is a new line of code, not a new block…
        if attribute.kind == .code, selection.length == 0 {
            let text = string as NSString
            let atEnd = selection.location == content.location + content.length
            let lastDisplayLineEmpty = content.length > 0
                && text.character(at: content.location + content.length - 1) == 0x2028

            // …except on an empty last line, which is how you leave the block.
            if atEnd, lastDisplayLineEmpty {
                let breakRange = NSRange(location: content.location + content.length - 1, length: 1)
                if shouldChangeText(in: breakRange, replacementString: "") {
                    textStorage?.replaceCharacters(in: breakRange, with: "")
                    didChangeText()
                }
                super.insertNewline(sender)
                setTypingKind(.paragraph)
                return
            }

            insertText(NoteProseConversion.displayLineBreak, replacementRange: selection)
            return
        }

        // Return on an empty list item steps out rather than continuing a list nobody is writing.
        if attribute.kind.isListItem, selection.length == 0, content.length == 0 {
            if attribute.indent > 0 {
                applyIndent(by: -1)
            } else {
                applyParagraphKind(.paragraph)
            }
            return
        }

        let atEnd = selection.length == 0 && selection.location == content.location + content.length

        super.insertNewline(sender)

        if atEnd {
            // A fresh paragraph continues the list, or falls back to prose — the kind's decision.
            setTypingKind(
                attribute.kind.continuationKind,
                indent: attribute.kind.continuationKind.isListItem ? attribute.indent : 0,
                language: nil,
                tone: nil
            )
        } else if attribute.isTicked {
            // Splitting a ticked item does not mint a second finished task.
            let caret = selectedRange().location
            rewriteParagraph(at: caret, to: NoteParagraphAttribute(
                kind: attribute.kind,
                indent: attribute.indent,
                isTicked: false,
                language: attribute.language,
                tone: attribute.tone
            ))
            reconcileAppearance()
        }
    }

    private func setTypingKind(
        _ kind: NoteParagraphKind,
        indent: Int = 0,
        language: String? = nil,
        tone: NoteCalloutTone? = nil
    ) {
        let attribute = NoteParagraphAttribute(kind: kind, indent: indent, isTicked: false, language: language, tone: tone)
        typingAttributes = NoteProseStyle.attributes(for: attribute)
        // The paragraph may already have characters after the caret (a split); make them agree.
        let content = paragraphContentRange(at: selectedRange().location)
        if content.length > 0 {
            rewriteParagraph(at: content.location, to: attribute)
            reconcileAppearance()
        }
        noteCoordinator?.proseDidChange(self)
        reportSelectionState()
    }

    override func insertTab(_ sender: Any?) {
        let attribute = paragraphAttribute(at: selectedRange().location)
        if attribute.kind.acceptsIndent {
            applyIndent(by: 1)
        }
        // On anything else Tab does nothing, rather than inserting a character the key was not
        // pressed for.
    }

    override func insertBacktab(_ sender: Any?) {
        let attribute = paragraphAttribute(at: selectedRange().location)
        if attribute.kind.acceptsIndent {
            applyIndent(by: -1)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        let content = paragraphContentRange(at: selection.location)

        // Backspace at the head of a styled paragraph takes the style before it takes a
        // character: an indent step first, then the kind, then the ordinary join.
        if selection.length == 0, selection.location == content.location {
            let attribute = paragraphAttribute(at: selection.location)

            if attribute.kind.acceptsIndent, attribute.indent > 0 {
                applyIndent(by: -1)
                return
            }
            if attribute.kind != .paragraph {
                applyParagraphKind(.paragraph)
                return
            }
        }

        super.deleteBackward(sender)
    }

    override func moveUp(_ sender: Any?) {
        if slashLocation != nil, noteCoordinator?.prose(self, slashCommand: .moveUp) == true {
            return
        }
        if caretIsOnFirstLine() {
            noteCoordinator?.prose(self, caretLeavesTowards: .up)
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if slashLocation != nil, noteCoordinator?.prose(self, slashCommand: .moveDown) == true {
            return
        }
        if caretIsOnLastLine() {
            noteCoordinator?.prose(self, caretLeavesTowards: .down)
            return
        }
        super.moveDown(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if slashLocation != nil {
            _ = noteCoordinator?.prose(self, slashCommand: .cancel)
            cancelSlash()
            return
        }
        super.cancelOperation(sender)
    }

    private func caretIsOnFirstLine() -> Bool {
        guard let layoutManager, selectedRange().length == 0 else { return false }
        guard (string as NSString).length > 0 else { return true }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(selectedRange().location, (string as NSString).length - 1))
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return lineRange.location == 0
    }

    private func caretIsOnLastLine() -> Bool {
        guard let layoutManager, selectedRange().length == 0 else { return false }
        let length = (string as NSString).length
        guard length > 0 else { return true }
        if selectedRange().location >= length { return true }
        let glyph = layoutManager.glyphIndexForCharacter(at: selectedRange().location)
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return lineRange.location + lineRange.length >= layoutManager.numberOfGlyphs
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command {
            switch key {
            case "b": toggleMark(.bold); return true
            case "i": toggleMark(.italic); return true
            case "u": toggleMark(.underline); return true
            case "e": toggleMark(.code); return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "x" {
            toggleMark(.strikethrough)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Sanitised input

    /// Paste arrives as plain text taking the surrounding attributes — ADR 0006's consequence
    /// made physical: foreign RTF with a hard-coded red foreground has nowhere to put it.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Normalise foreign paragraph separators before they enter the storage, where `\r` would
        // be a paragraph boundary the conversion does not speak.
        if let raw = string as? String {
            let cleaned = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            super.insertText(cleaned, replacementRange: replacementRange)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    // MARK: - The / menu and Markdown shortcuts, watched from the change stream

    /// Called by the coordinator from `textDidChange`, after reconciliation.
    func observeEditForTriggers() {
        guard selectedRange().length == 0 else {
            cancelSlash()
            return
        }

        let caret = selectedRange().location
        let text = string as NSString

        if let start = slashLocation {
            // The menu is open: the query is whatever sits between the `/` and the caret.
            guard caret > start, start < text.length, text.character(at: start) == 0x2F else {
                cancelSlash()
                return
            }
            let query = text.substring(with: NSRange(location: start + 1, length: caret - start - 1))
            guard !query.contains("\n"), !query.contains(" "), query.count <= 24 else {
                cancelSlash()
                return
            }
            noteCoordinator?.prose(self, slashQueryChanged: query, caretNear: caretRect())
            return
        }

        guard caret > 0 else { return }
        let previous = text.character(at: caret - 1)

        // A fresh "/" at the start of a paragraph or after whitespace opens the menu.
        if previous == 0x2F {
            let content = paragraphContentRange(at: caret)
            let isAtParagraphStart = caret - 1 == content.location
            let afterSpace = caret >= 2 && text.character(at: caret - 2) == 0x20
            if isAtParagraphStart || afterSpace {
                slashLocation = caret - 1
                noteCoordinator?.prose(self, slashQueryChanged: "", caretNear: caretRect())
                return
            }
        }

        checkMarkdownShortcut(caretAt: caret, in: text)
    }

    private func checkMarkdownShortcut(caretAt caret: Int, in text: NSString) {
        let content = paragraphContentRange(at: caret)
        let attribute = paragraphAttribute(at: caret)

        // Shortcuts only convert ordinary prose. "- " inside a code block is code.
        guard attribute.kind == .paragraph else { return }

        let leadingLength = caret - content.location
        guard leadingLength > 0, leadingLength <= 8 else { return }

        let leading = text.substring(with: NSRange(location: content.location, length: leadingLength))
        guard let match = NoteMarkdownShortcut.match(leading) else { return }

        let consumed = NSRange(location: content.location, length: leadingLength)

        switch match.shortcut {
        case .paragraph(let kind, let ticked):
            guard shouldChangeText(in: consumed, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: consumed, with: "")
            didChangeText()
            rewriteParagraph(at: content.location, to: NoteParagraphAttribute(
                kind: kind,
                indent: 0,
                isTicked: ticked,
                language: nil,
                tone: kind == .callout ? .note : nil
            ))
            reconcileAppearance()
            reportSelectionState()

        case .divider:
            guard shouldChangeText(in: consumed, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: consumed, with: "")
            didChangeText()
            noteCoordinator?.prose(self, requestsObject: .divider, atCharacterIndex: content.location)
        }
    }

    /// The range an accepted `/` command replaces: the slash and everything typed after it.
    var slashReplacementRange: NSRange? {
        guard let start = slashLocation else { return nil }
        let caret = selectedRange().location
        guard caret >= start else { return nil }
        return NSRange(location: start, length: caret - start)
    }

    func cancelSlash() {
        guard slashLocation != nil else { return }
        slashLocation = nil
        noteCoordinator?.prose(self, slashQueryChanged: nil, caretNear: .zero)
    }

    /// Removes the typed `/query` after a command is chosen.
    func consumeSlashText() {
        guard let range = slashReplacementRange else { return }
        slashLocation = nil
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
    }

    private func caretRect() -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let caret = selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if caret.location == (string as NSString).length, rect.isEmpty {
            rect = layoutManager.extraLineFragmentRect
        }
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        if rect.size.height == 0 {
            rect.size.height = NSFont.preferredFont(forTextStyle: .body).pointSize + 6
        }
        if rect.size.width == 0 {
            rect.size.width = 2
        }
        return rect
    }

    // MARK: - Checkboxes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let index = checklistMarkerIndex(at: point) {
            let attribute = paragraphAttribute(at: index)
            rewriteParagraph(at: index, to: NoteParagraphAttribute(
                kind: .checklist,
                indent: attribute.indent,
                isTicked: !attribute.isTicked,
                language: nil,
                tone: nil
            ))
            reconcileAppearance()
            return
        }

        super.mouseDown(with: event)
    }

    /// The paragraph whose checklist marker sits under a point, if any.
    private func checklistMarkerIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < (string as NSString).length else { return nil }

        let attribute = paragraphAttribute(at: character)
        guard attribute.kind == .checklist else { return nil }

        // Only the marker column of the *first* line toggles; the text is for the caret.
        let content = paragraphContentRange(at: character)
        var lineRange = NSRange()
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: content.location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: &lineRange)

        let leading = CGFloat(attribute.indent) * NoteProseStyle.indentStep
        let markerZone = NSRect(
            x: leading,
            y: lineRect.minY,
            width: NoteProseStyle.markerColumn,
            height: lineRect.height
        )
        return markerZone.contains(containerPoint) ? content.location : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Checklist markers read as controls, so the pointer should say so.
        enumerateParagraphs { attribute, content in
            guard attribute.kind == .checklist, let layoutManager, let textContainer else { return }
            let anchor = min(content.location, max(0, (string as NSString).length - 1))
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            var lineRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            _ = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) ?? textContainer

            let leading = CGFloat(attribute.indent) * NoteProseStyle.indentStep
            let zone = NSRect(
                x: leading + textContainerInset.width,
                y: lineRect.minY + textContainerInset.height,
                width: NoteProseStyle.markerColumn,
                height: lineRect.height
            )
            addCursorRect(zone, cursor: .pointingHand)
        }
    }

    // MARK: - Selection state

    func reportSelectionState() {
        var state = NoteSelectionState()
        let selection = selectedRange()
        state.hasSelection = selection.length > 0

        for content in selectedParagraphContentRanges() {
            let attribute = paragraphAttribute(at: content.location)
            state.kinds.insert(attribute.kind)
            if attribute.kind.acceptsIndent { state.canIndent = true }
            if attribute.kind == .callout { state.calloutTone = attribute.tone }
            if attribute.kind == .code { state.codeLanguage = attribute.language }
        }

        if selection.length == 0 {
            state.marks = currentTypingMarks()
        } else if let storage = textStorage {
            var common: NoteInlineMarks = [.bold, .italic, .underline, .strikethrough, .code]
            storage.enumerateAttribute(.noteMarks, in: selection, options: []) { value, _, _ in
                common = common.intersection(NoteInlineMarks(rawValue: (value as? NSNumber)?.intValue ?? 0))
            }
            state.marks = common
        }

        noteCoordinator?.proseSelectionDidChange(self, state: state)

        // Code wants straight quotes and no substitutions; prose wants the opposite. The switch
        // is per-view, so it follows the caret.
        let kindHere = paragraphAttribute(at: selection.location).kind
        isAutomaticQuoteSubstitutionEnabled = kindHere.isProse
        isAutomaticDashSubstitutionEnabled = kindHere.isProse
        isAutomaticTextReplacementEnabled = kindHere.isProse
        isContinuousSpellCheckingEnabled = kindHere.isProse
    }

    // MARK: - Decorations

    // Decorations are painted before `super.draw` puts the glyphs down, so they sit behind the
    // text the way a background does. (`drawViewBackgroundInRect:` would be the canonical hook,
    // but this SDK's Swift interface does not surface it to subclasses in explicit-module builds.)
    override func draw(_ dirtyRect: NSRect) {
        drawParagraphDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func enumerateParagraphs(_ body: (NoteParagraphAttribute, NSRange) -> Void) {
        let text = string as NSString
        var index = 0
        while index < text.length {
            let full = text.paragraphRange(for: NSRange(location: index, length: 0))
            var content = full
            if content.length > 0, text.character(at: content.location + content.length - 1) == 0x0A {
                content.length -= 1
            }
            let attribute = (textStorage?.attribute(.noteParagraph, at: full.location, effectiveRange: nil)
                as? NoteParagraphAttribute) ?? NoteParagraphAttribute(kind: .paragraph)
            body(attribute, content)
            index = full.location + max(full.length, 1)
        }
    }

    private func drawParagraphDecorations(in rect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        let inset = textContainerInset

        enumerateParagraphs { attribute, content in
            let paragraphGlyphs = layoutManager.glyphRange(
                forCharacterRange: content.length > 0 ? content : NSRange(location: content.location, length: 0),
                actualCharacterRange: nil
            )

            var bounds: NSRect
            if content.length > 0 {
                bounds = layoutManager.boundingRect(forGlyphRange: paragraphGlyphs, in: textContainer)
            } else if content.location < (string as NSString).length {
                var lineRange = NSRange()
                bounds = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.glyphIndexForCharacter(at: content.location),
                    effectiveRange: &lineRange
                )
            } else {
                return
            }

            bounds.origin.x += inset.width
            bounds.origin.y += inset.height
            guard bounds.intersects(rect.insetBy(dx: -50, dy: -50)) else { return }

            switch attribute.kind {
            case .quote:
                let bar = NSRect(x: inset.width + 2, y: bounds.minY + 1, width: 3, height: bounds.height - 2)
                Theme.AppKitColors.separator.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

            case .code:
                let block = NSRect(
                    x: inset.width + 2,
                    y: bounds.minY - 4,
                    width: frame.width - inset.width * 2 - 4,
                    height: bounds.height + 8
                )
                Theme.AppKitColors.subtleFill.setFill()
                NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6).fill()

            case .callout:
                let tone = attribute.tone ?? .note
                let block = NSRect(
                    x: inset.width + 2,
                    y: bounds.minY - 4,
                    width: frame.width - inset.width * 2 - 4,
                    height: bounds.height + 8
                )
                NoteProseStyle.calloutTint(for: tone).setFill()
                NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6).fill()

            case .bulleted, .numbered, .checklist:
                drawListMarker(for: attribute, content: content, layoutManager: layoutManager, inset: inset)

            default:
                break
            }
        }
    }

    private func drawListMarker(
        for attribute: NoteParagraphAttribute,
        content: NSRange,
        layoutManager: NSLayoutManager,
        inset: NSSize
    ) {
        let text = string as NSString
        guard content.location < text.length else { return }

        var lineRange = NSRange()
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: content.location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: &lineRange)

        let leading = CGFloat(attribute.indent) * NoteProseStyle.indentStep + inset.width
        let column = NSRect(
            x: leading,
            y: lineRect.minY + inset.height,
            width: NoteProseStyle.markerColumn - 8,
            height: lineRect.height
        )

        let bodyFont = NSFont.preferredFont(forTextStyle: .body)

        switch attribute.kind {
        case .bulleted:
            let size: CGFloat = 5
            let dot = NSRect(
                x: column.midX - size / 2,
                y: column.midY - size / 2,
                width: size,
                height: size
            )
            Theme.AppKitColors.secondaryText.setFill()
            NSBezierPath(ovalIn: dot).fill()

        case .numbered:
            let number = listNumber(forParagraphAt: content.location, attribute: attribute)
            let label = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular),
                .foregroundColor: Theme.AppKitColors.secondaryText,
            ])
            let size = label.size()
            label.draw(at: NSPoint(
                x: column.maxX - size.width,
                y: column.midY - size.height / 2
            ))

        case .checklist:
            let symbolName = attribute.isTicked ? "checkmark.square.fill" : "square"
            let configuration = NSImage.SymbolConfiguration(pointSize: bodyFont.pointSize - 1, weight: .regular)
            guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { break }

            let tint = attribute.isTicked ? Theme.AppKitColors.link : Theme.AppKitColors.secondaryText
            let tinted = image.tinted(with: tint)
            let size = tinted.size
            tinted.draw(in: NSRect(
                x: column.midX - size.width / 2,
                y: column.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))

        default:
            break
        }
    }

    /// The number a numbered item shows: counted, never stored, so deleting the first item
    /// renumbers the rest. Items nested deeper are stepped over; anything that is not a numbered
    /// item ends the run — the same rule the Markdown projection applies.
    private func listNumber(forParagraphAt location: Int, attribute: NoteParagraphAttribute) -> Int {
        let text = string as NSString
        var number = 1
        var index = location

        while index > 0 {
            let previous = text.paragraphRange(for: NSRange(location: index - 1, length: 0))
            guard let earlier = textStorage?.attribute(.noteParagraph, at: previous.location, effectiveRange: nil)
                as? NoteParagraphAttribute,
                earlier.kind == .numbered
            else { break }

            if earlier.indent == attribute.indent {
                number += 1
            } else if earlier.indent < attribute.indent {
                break
            }
            index = previous.location
        }

        return number
    }
}

extension NSImage {
    /// The image recoloured, for symbol markers drawn outside a view hierarchy.
    fileprivate func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)
            return true
        }
        result.isTemplate = false
        return result
    }
}
