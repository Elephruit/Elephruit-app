import ElephruitCore
import Foundation

/// The keyboard stops in the reminder composer, in their deliberate traversal order.
///
/// Kept as a small state machine rather than relying on AppKit's incidental key-view order: some
/// stops live in popovers and the checklist rows are created on demand, so the view hierarchy is
/// not the product's focus order.
enum ReminderComposerField: Int, CaseIterable, Sendable, Hashable {
    case title
    case notes
    case when
    case tags
    case people
    case checklist
    case deadline
    case project

    func advanced(reverse: Bool = false) -> Self {
        let fields = Self.allCases
        guard let index = fields.firstIndex(of: self) else { return .title }
        let offset = reverse ? -1 : 1
        return fields[(index + offset + fields.count) % fields.count]
    }
}

/// Everything typed into a new reminder before it becomes a stored item.
///
/// A value type is the performance boundary: keystrokes only mutate this value. Store validation,
/// tag creation, search indexing and list reconciliation happen once, when the draft is committed.
struct ReminderComposerDraft: Sendable, Hashable {
    var title = ""
    var notes = ""
    var startAt: Date?
    var dueAt: Date?
    var isSomeday = false
    var tagSlugs: [String] = []
    var personNames: [String] = []
    var projectTitle: String?
    var checklist: [ReminderChecklistItem] = []
    var pendingStep = ""

    init() {}

    init(reminder: LightweightReminder) {
        title = reminder.title
        notes = reminder.notes
        startAt = reminder.startAt
        dueAt = reminder.dueAt
        isSomeday = reminder.isSomeday
        tagSlugs = reminder.tagSlugs
        personNames = reminder.personNames
        projectTitle = reminder.projectTitle
        checklist = reminder.checklist
    }

    var hasChecklistContent: Bool {
        !pendingStep.isEmpty || !checklist.isEmpty
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func commitPendingStep() {
        let title = pendingStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { checklist.append(ReminderChecklistItem(title: title)) }
        pendingStep = ""
    }

    mutating func reset() {
        self = ReminderComposerDraft()
    }
}

/// The three Quick Jot-style instructions a lightweight reminder understands.
///
/// Parsing is shared with Quick Jot so multi-word people and projects have exactly the same
/// boundaries. Only reminder metadata is extracted: this never changes item kind or sends the
/// reminder through capture, filing, or task services.
struct ReminderShortcutExtraction: Sendable, Hashable {
    var text: String
    var tagSlugs: [String]
    var personNames: [String]
    var projectTitle: String?
}

enum ReminderShortcutParser {
    static func extract(
        from text: String,
        knowing vocabulary: CaptureVocabulary
    ) -> ReminderShortcutExtraction {
        var tagSlugs: [String] = []
        var personNames: [String] = []
        var projectTitle: String?
        var cleanedLines: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let parsed = CaptureParser.parse(line, knowing: vocabulary)
            let shortcuts = parsed.tokens.filter { token in
                switch token.kind {
                case .tag, .kind, .person, .project: true
                case .dueDate, .followDate, .priority, .unrecognised: false
                }
            }

            for token in shortcuts {
                switch token.kind {
                case .tag, .kind:
                    let slug = TextNormalizer.slug(token.text)
                    if !slug.isEmpty, !tagSlugs.contains(slug) { tagSlugs.append(slug) }
                case .person:
                    let folded = TextNormalizer.foldedForMatching(token.text)
                    if !personNames.contains(where: {
                        TextNormalizer.foldedForMatching($0) == folded
                    }) {
                        personNames.append(token.text)
                    }
                case .project:
                    projectTitle = token.text
                case .dueDate, .followDate, .priority, .unrecognised:
                    break
                }
            }

            cleanedLines.append(removing(shortcuts.map(\.range), from: line))
        }

        return ReminderShortcutExtraction(
            text: cleanedLines.joined(separator: "\n"),
            tagSlugs: tagSlugs,
            personNames: personNames,
            projectTitle: projectTitle
        )
    }

    private static func removing(_ ranges: [Range<Int>], from text: String) -> String {
        guard !ranges.isEmpty else { return text }
        let characters = Array(text)
        var removed: Set<Int> = []

        for range in ranges {
            let expanded: Range<Int>
            if range.upperBound < characters.count,
               characters[range.upperBound].isWhitespace {
                expanded = range.lowerBound..<(range.upperBound + 1)
            } else if range.lowerBound > 0,
                      characters[range.lowerBound - 1].isWhitespace {
                expanded = (range.lowerBound - 1)..<range.upperBound
            } else {
                expanded = range
            }
            removed.formUnion(expanded)
        }

        return String(characters.enumerated().compactMap { index, character in
            removed.contains(index) ? nil : character
        })
        .trimmingCharacters(in: .whitespaces)
    }
}
