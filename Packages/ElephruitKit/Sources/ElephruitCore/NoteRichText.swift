import Foundation

/// The inline marks a run of text can carry.
///
/// A closed set, and that is the point. ADR 0006 chose an explicit run list over `NSKeyedArchiver`
/// precisely so that an attribute this app does not understand *cannot be represented* — sanitising
/// pasted content becomes a property of the format rather than a pass somebody has to remember to
/// write. Foreign RTF arriving with a hard-coded red foreground has nowhere to put it.
///
/// Encoded as a sorted array of names rather than a bitfield, for the reason `ArchiveDocument` is
/// pretty-printed with sorted keys: a stored format that cannot be read in a diff is a stored format
/// nobody can review. `["bold", "code"]` says what it is; `5` does not.
public struct NoteInlineMarks: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = NoteInlineMarks(rawValue: 1 << 0)
    public static let italic = NoteInlineMarks(rawValue: 1 << 1)
    public static let underline = NoteInlineMarks(rawValue: 1 << 2)
    public static let strikethrough = NoteInlineMarks(rawValue: 1 << 3)

    /// Inline code — `like this`, inside a sentence. Not a code block, which is a paragraph kind.
    public static let code = NoteInlineMarks(rawValue: 1 << 4)

    /// Every mark and the name it is stored under, in the order they are written.
    ///
    /// Ordered deliberately: the encoded form has to be stable, or two documents that are the same
    /// document produce different bytes and every round-trip test becomes a test of dictionary
    /// ordering.
    static let allNamed: [(mark: NoteInlineMarks, name: String)] = [
        (.bold, "bold"),
        (.italic, "italic"),
        (.underline, "underline"),
        (.strikethrough, "strikethrough"),
        (.code, "code"),
    ]

    public var names: [String] {
        Self.allNamed.filter { contains($0.mark) }.map(\.name)
    }
}

extension NoteInlineMarks: Codable {
    public init(from decoder: any Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)

        // A name this build has never heard of is dropped rather than carried. That is the
        // allow-list doing its job: a mark that cannot be rendered, exported, searched or reasoned
        // about is not something to keep hold of on the grounds that some other build might. The
        // cost is real and is accepted — a document written by a newer version loses that version's
        // marks when an older one saves it — and it is the trade ADR 0006 makes on purpose.
        var marks = NoteInlineMarks()
        for (mark, name) in Self.allNamed where names.contains(name) {
            marks.insert(mark)
        }
        self = marks
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }
}

/// What a stretch of text points at.
///
/// Three cases, because this app has three kinds of link and they are not interchangeable. A `url`
/// leaves the app. An `item` is a modelled relationship with a stable target — the thing RTFD was
/// measured losing, and the reason it was disqualified. A `wiki` is a link *by title* to something
/// that may not exist yet, which is a first-class state here rather than a broken link: creating a
/// note resolves every wiki link that was waiting on that title.
public enum NoteInlineLink: Sendable, Hashable {
    case url(String)
    case item(UUID)
    case wiki(String)
}

extension NoteInlineLink: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)

        switch kind {
        case "url":
            self = .url(value)
        case "item":
            guard let id = UUID(uuidString: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "An item link must carry a UUID, and this one carries “\(value)”."
                )
            }
            self = .item(id)
        case "wiki":
            self = .wiki(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "“\(kind)” is not a kind of link this version knows about."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .url(let address):
            try container.encode("url", forKey: .kind)
            try container.encode(address, forKey: .value)
        case .item(let id):
            try container.encode("item", forKey: .kind)
            try container.encode(id.uuidString, forKey: .value)
        case .wiki(let title):
            try container.encode("wiki", forKey: .kind)
            try container.encode(title, forKey: .value)
        }
    }
}

/// A stretch of text that is all the same.
public struct NoteTextRun: Codable, Sendable, Hashable {
    public var text: String
    public var marks: NoteInlineMarks
    public var link: NoteInlineLink?

    public init(_ text: String, marks: NoteInlineMarks = [], link: NoteInlineLink? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
    }

    /// Whether two runs differ only in their text, and so could be one run.
    func hasSameAttributes(as other: NoteTextRun) -> Bool {
        marks == other.marks && link == other.link
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case marks
        case link
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        // Absent rather than empty in the stored form, because most runs carry neither and writing
        // `"marks": []` on every one of them triples the size of an ordinary paragraph.
        marks = try container.decodeIfPresent(NoteInlineMarks.self, forKey: .marks) ?? []
        link = try container.decodeIfPresent(NoteInlineLink.self, forKey: .link)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if !marks.isEmpty { try container.encode(marks, forKey: .marks) }
        try container.encodeIfPresent(link, forKey: .link)
    }
}

/// One paragraph's worth of text, with its marks.
///
/// ### Why offsets are in Characters and not UTF-16
/// Because everything above this speaks in Characters — a caret position, the place Return splits, a
/// selection — and `NSTextView` speaks UTF-16. The two diverge the moment a note contains an emoji.
/// Choosing one and converting at the single boundary where AppKit is on the other side is the only
/// arrangement where a caret cannot land in the middle of a character; mixing them silently is how
/// it does.
public struct NoteRichText: Codable, Sendable, Hashable {
    public private(set) var runs: [NoteTextRun]

    public init(runs: [NoteTextRun] = []) {
        self.runs = Self.normalizing(runs)
    }

    public init(_ text: String, marks: NoteInlineMarks = [], link: NoteInlineLink? = nil) {
        self.init(runs: text.isEmpty ? [] : [NoteTextRun(text, marks: marks, link: link)])
    }

    public init(from decoder: any Decoder) throws {
        // Normalised on the way in as well as on the way out, so a document written by hand, by an
        // importer, or by an older build cannot put the editor into a state its own operations would
        // never produce.
        try self.init(runs: decoder.singleValueContainer().decode([NoteTextRun].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(runs)
    }

    // MARK: Reading

    /// The text with no marks on it.
    ///
    /// **Strips `U+FFFC`.** An attachment appears in `NSAttributedString.string` as the
    /// object-replacement character, and ADR 0006 measured it arriving here. Left in, every note
    /// with an image gains a junk character in the search index and in its Markdown export.
    public var plainText: String {
        runs.map(\.text).joined().replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// The length in Characters, which is what every offset in this type means.
    public var length: Int {
        runs.reduce(0) { $0 + $1.text.count }
    }

    public var isEmpty: Bool { runs.isEmpty }

    /// The marks in force at an offset, for the formatting bar's state.
    ///
    /// Reads the run *before* the offset rather than after it, which is what a caret between two
    /// runs means to somebody about to type: typing at the end of a bold word continues the bold
    /// word. At the very start there is nothing before, so it reads forwards.
    public func marks(at offset: Int) -> NoteInlineMarks {
        guard !runs.isEmpty else { return [] }

        var consumed = 0
        var previous: NoteTextRun?

        for run in runs {
            let end = consumed + run.text.count
            if offset > consumed, offset <= end { return run.marks }
            if offset <= consumed { return previous?.marks ?? run.marks }
            previous = run
            consumed = end
        }

        return runs.last?.marks ?? []
    }

    /// The link at an offset, if the caret is inside one.
    public func link(at offset: Int) -> NoteInlineLink? {
        var consumed = 0
        for run in runs {
            let end = consumed + run.text.count
            if offset >= consumed, offset < end { return run.link }
            consumed = end
        }
        return nil
    }

    // MARK: Slicing and splicing

    /// The text between two offsets, keeping every mark on it.
    public func slice(_ range: Range<Int>) -> NoteRichText {
        let bounded = clamped(range)
        guard !bounded.isEmpty else { return NoteRichText() }

        var result: [NoteTextRun] = []
        var consumed = 0

        for run in runs {
            let count = run.text.count
            let runRange = consumed..<(consumed + count)
            consumed += count

            // Compared before being made into a range, never after. A run that sits entirely
            // outside the slice gives a *lower* bound above its upper one, and `Range` traps on
            // that rather than reporting an empty range — so `a..<b` cannot be written until `a < b`
            // is known. Every slice of a multi-run text hits this on its first non-overlapping run.
            let lower = max(runRange.lowerBound, bounded.lowerBound)
            let upper = min(runRange.upperBound, bounded.upperBound)
            guard lower < upper else { continue }

            let local = (lower - runRange.lowerBound)..<(upper - runRange.lowerBound)
            result.append(NoteTextRun(Self.substring(of: run.text, local), marks: run.marks, link: run.link))
        }

        return NoteRichText(runs: result)
    }

    /// This text with another inserted at an offset.
    ///
    /// The inserted text keeps its own marks rather than adopting the surrounding ones. That is what
    /// a paste means; typing goes through the editor's typing attributes instead, which is a
    /// different question and is answered where the caret is.
    public func inserting(_ other: NoteRichText, at offset: Int) -> NoteRichText {
        let at = max(0, min(offset, length))
        return NoteRichText(runs: slice(0..<at).runs + other.runs + slice(at..<length).runs)
    }

    /// This text with a range taken out of it.
    public func removing(_ range: Range<Int>) -> NoteRichText {
        let bounded = clamped(range)
        guard !bounded.isEmpty else { return self }
        return NoteRichText(runs: slice(0..<bounded.lowerBound).runs + slice(bounded.upperBound..<length).runs)
    }

    public func appending(_ other: NoteRichText) -> NoteRichText {
        NoteRichText(runs: runs + other.runs)
    }

    // MARK: Marks

    /// Adds a mark across a range, or removes it if every character in the range already has it.
    ///
    /// ### Why the whole range decides
    /// Because the alternative — flipping each run independently — makes ⌘B on a mixed selection do
    /// something nobody asked for: half the words bold, the other half not, and pressing it again
    /// swaps which half. Reading the selection as a whole means ⌘B always has one of two meanings,
    /// and the second press always undoes the first.
    public func togglingMark(_ mark: NoteInlineMarks, in range: Range<Int>) -> NoteRichText {
        let bounded = clamped(range)
        guard !bounded.isEmpty else { return self }

        let selected = slice(bounded)
        let alreadyEverywhere = selected.runs.allSatisfy { $0.marks.contains(mark) }

        let changed = selected.runs.map { run -> NoteTextRun in
            var updated = run
            if alreadyEverywhere {
                updated.marks.remove(mark)
            } else {
                updated.marks.insert(mark)
            }
            return updated
        }

        return NoteRichText(
            runs: slice(0..<bounded.lowerBound).runs + changed + slice(bounded.upperBound..<length).runs
        )
    }

    /// Puts a link on a range, or takes every link off it when given `nil`.
    public func settingLink(_ link: NoteInlineLink?, in range: Range<Int>) -> NoteRichText {
        let bounded = clamped(range)
        guard !bounded.isEmpty else { return self }

        let changed = slice(bounded).runs.map { run -> NoteTextRun in
            var updated = run
            updated.link = link
            return updated
        }

        return NoteRichText(
            runs: slice(0..<bounded.lowerBound).runs + changed + slice(bounded.upperBound..<length).runs
        )
    }

    // MARK: Normalising

    /// Merges neighbouring runs that agree, and drops empty ones.
    ///
    /// ### Why this is not cosmetic
    /// Because without it, `Hashable` is wrong in the way that matters most: bolding a word and then
    /// unbolding it would leave a document that renders identically to the original and does not
    /// compare equal to it — so the editor would think there was something to save, undo would have
    /// a step in it that changes nothing visible, and every round-trip test would be asserting on
    /// how the text happened to be cut up rather than on what it says.
    private static func normalizing(_ runs: [NoteTextRun]) -> [NoteTextRun] {
        var result: [NoteTextRun] = []

        for run in runs where !run.text.isEmpty {
            if var last = result.last, last.hasSameAttributes(as: run) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }

        return result
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, length))
        let upper = max(lower, min(range.upperBound, length))
        return lower..<upper
    }

    private static func substring(of text: String, _ range: Range<Int>) -> String {
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: range.upperBound)
        return String(text[start..<end])
    }
}
