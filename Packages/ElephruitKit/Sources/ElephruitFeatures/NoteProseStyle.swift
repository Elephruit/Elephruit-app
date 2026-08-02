import AppKit
import ElephruitCore
import ElephruitDesign

// MARK: - The custom attributes

extension NSAttributedString.Key {
    /// The paragraph's kind and its fields, on every character of the paragraph.
    ///
    /// **The attribute is authoritative, never the appearance.** Fonts and colours are derived
    /// from this on the way in and ignored on the way out — the same rule ADR 0006 gives the
    /// stored format, arriving at the editing surface. Reading appearance back would conflate a
    /// heading's weight with a bolded word the moment both exist.
    static let noteParagraph = NSAttributedString.Key("com.elephruit.note.paragraph")

    /// The inline marks on a run, as `NoteInlineMarks.rawValue` in an `NSNumber`.
    static let noteMarks = NSAttributedString.Key("com.elephruit.note.marks")

    /// The link on a run, as a ``NoteLinkAttribute``.
    static let noteLink = NSAttributedString.Key("com.elephruit.note.link")
}

/// A paragraph's kind and fields, boxed for the attributed string.
///
/// A class rather than the `NoteParagraph` struct, because attribute values live in an
/// `NSAttributedString`, which compares them with `isEqual` when it coalesces runs — a boxed
/// struct answers that with identity, and every paragraph would be its own attribute run forever.
/// The text is deliberately absent: the string *is* the text.
final class NoteParagraphAttribute: NSObject, Sendable {
    let kind: NoteParagraphKind
    let indent: Int
    let isTicked: Bool
    let language: String?
    let tone: NoteCalloutTone?

    init(kind: NoteParagraphKind, indent: Int = 0, isTicked: Bool = false, language: String? = nil, tone: NoteCalloutTone? = nil) {
        self.kind = kind
        self.indent = indent
        self.isTicked = isTicked
        self.language = language
        self.tone = tone
    }

    convenience init(_ paragraph: NoteParagraph) {
        self.init(
            kind: paragraph.kind,
            indent: paragraph.indent,
            isTicked: paragraph.isTicked,
            language: paragraph.language,
            tone: paragraph.tone
        )
    }

    /// The same fields on an empty paragraph, ready to receive the text.
    var emptyParagraph: NoteParagraph {
        NoteParagraph(kind: kind, text: NoteRichText(), indent: indent, isTicked: isTicked, language: language, tone: tone)
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NoteParagraphAttribute else { return false }
        return kind == other.kind
            && indent == other.indent
            && isTicked == other.isTicked
            && language == other.language
            && tone == other.tone
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(indent)
        hasher.combine(isTicked)
        hasher.combine(language)
        hasher.combine(tone)
        return hasher.finalize()
    }
}

/// A link, boxed for the attributed string. Same reasoning as ``NoteParagraphAttribute``.
final class NoteLinkAttribute: NSObject, Sendable {
    let link: NoteInlineLink

    init(_ link: NoteInlineLink) {
        self.link = link
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NoteLinkAttribute else { return false }
        return link == other.link
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(link)
        return hasher.finalize()
    }
}

// MARK: - Appearance

/// How a paragraph kind looks, derived fresh from the attributes every time.
///
/// All of it resolves through the design system — `Theme.AppKitColors` and `Theme.Palette` — so
/// the editor is readable in dark mode without owning a single colour decision of its own.
enum NoteProseStyle {
    // MARK: Metrics

    /// One step of list nesting.
    static let indentStep: CGFloat = 24

    /// The column a list marker is drawn in, between the indent and the text.
    static let markerColumn: CGFloat = 26

    /// The inset a quote, code block or callout takes from the leading edge.
    static let blockInset: CGFloat = 14

    /// The padding inside a code block's or callout's tinted rectangle.
    static let blockPadding: CGFloat = 10

    // MARK: Fonts

    /// The base font for a kind, before inline marks are laid over it.
    ///
    /// Text styles rather than point sizes, so the system text-size setting keeps working — the
    /// same rule `Theme.Text` follows on the SwiftUI side.
    static func baseFont(for kind: NoteParagraphKind) -> NSFont {
        switch kind {
        case .heading1:
            weighted(.title1, weight: .bold)
        case .heading2:
            weighted(.title2, weight: .semibold)
        case .heading3:
            weighted(.title3, weight: .semibold)
        case .code:
            monospaced(.body)
        default:
            NSFont.preferredFont(forTextStyle: .body)
        }
    }

    /// The font a run actually gets: the kind's base, with the marks' traits laid on.
    static func font(for kind: NoteParagraphKind, marks: NoteInlineMarks) -> NSFont {
        var font = baseFont(for: kind)

        if marks.contains(.code), kind != .code {
            font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .regular)
        }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if marks.contains(.bold) { traits.insert(.bold) }
        if marks.contains(.italic) { traits.insert(.italic) }

        if !traits.isEmpty {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        return font
    }

    private static func weighted(_ style: NSFont.TextStyle, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return NSFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    private static func monospaced(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular)
    }

    // MARK: Colour

    /// The text colour for a run: the kind's colour, dimmed for a ticked checklist item.
    static func textColor(for attribute: NoteParagraphAttribute, link: NoteInlineLink?) -> NSColor {
        if let link {
            if case .wiki = link { return Theme.AppKitColors.link }
            return Theme.AppKitColors.link
        }

        switch attribute.kind {
        case .quote:
            return Theme.AppKitColors.secondaryText
        case .checklist where attribute.isTicked:
            return Theme.AppKitColors.secondaryText
        default:
            return Theme.AppKitColors.primaryText
        }
    }

    /// The tint behind a callout of a given tone, resolved through the palette by name.
    static func calloutTint(for tone: NoteCalloutTone) -> NSColor {
        Theme.Palette
            .nsColor(named: tone.paletteName, neutral: .quaternarySystemFill)
            .withAlphaComponent(0.13)
    }

    // MARK: Paragraph style

    /// The `NSParagraphStyle` a kind draws with — indents for markers and blocks, spacing between
    /// paragraphs. Derived, never stored: the ``NoteParagraphAttribute`` is the truth.
    static func paragraphStyle(for attribute: NoteParagraphAttribute) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 8
        style.lineBreakMode = .byWordWrapping

        switch attribute.kind {
        case .heading1:
            style.paragraphSpacingBefore = 18
            style.paragraphSpacing = 8
        case .heading2:
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 6
        case .heading3:
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 4
        case .bulleted, .numbered, .checklist:
            let leading = CGFloat(attribute.indent) * indentStep + markerColumn
            style.firstLineHeadIndent = leading
            style.headIndent = leading
            style.paragraphSpacing = 4
        case .quote:
            style.firstLineHeadIndent = blockInset
            style.headIndent = blockInset
        case .code:
            style.firstLineHeadIndent = blockInset
            style.headIndent = blockInset
            style.tailIndent = -blockInset
            style.lineSpacing = 1
            style.paragraphSpacing = 12
            style.paragraphSpacingBefore = 6
        case .callout:
            style.firstLineHeadIndent = blockInset
            style.headIndent = blockInset
            style.tailIndent = -blockInset
            style.paragraphSpacing = 12
            style.paragraphSpacingBefore = 6
        case .paragraph:
            break
        }

        return style
    }

    // MARK: The full dictionary

    /// Everything one run of text carries: the authoritative attributes, and the appearance
    /// derived from them.
    static func attributes(
        for attribute: NoteParagraphAttribute,
        marks: NoteInlineMarks = [],
        link: NoteInlineLink? = nil
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .noteParagraph: attribute,
            .font: font(for: attribute.kind, marks: marks),
            .foregroundColor: textColor(for: attribute, link: link),
            .paragraphStyle: paragraphStyle(for: attribute),
        ]

        if !marks.isEmpty {
            result[.noteMarks] = NSNumber(value: marks.rawValue)
        }
        if marks.contains(.underline) {
            result[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
        }
        if marks.contains(.strikethrough) || (attribute.kind == .checklist && attribute.isTicked) {
            result[.strikethroughStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
        }
        if marks.contains(.code), attribute.kind != .code {
            result[.backgroundColor] = Theme.AppKitColors.subtleFill
        }

        if let link {
            result[.noteLink] = NoteLinkAttribute(link)
            result[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
            if let destination = Self.destination(for: link) {
                result[.link] = destination
            }
        }

        return result
    }

    /// The clickable form of a link, for `NSTextView`'s own link machinery.
    ///
    /// App-internal links travel on private schemes the click handler unpicks; they never leave
    /// the process. A malformed URL simply is not clickable — the ``noteLink`` attribute still
    /// round-trips, so nothing is lost but the pointer cursor.
    static func destination(for link: NoteInlineLink) -> URL? {
        switch link {
        case .url(let address):
            return URL(string: address)
        case .item(let id):
            return URL(string: "elephruit-item://\(id.uuidString)")
        case .wiki(let title):
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
            return URL(string: "elephruit-wiki://\(encoded)")
        }
    }
}
