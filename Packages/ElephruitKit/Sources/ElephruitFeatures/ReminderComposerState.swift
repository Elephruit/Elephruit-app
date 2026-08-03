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
    case checklist
    case deadline

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
    var checklist: [ReminderChecklistItem] = []
    var pendingStep = ""

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
