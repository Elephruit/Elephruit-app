import Foundation

/// One step inside a single action.
///
/// ### Checklist items are not subtasks, and the difference is ownership
/// A subtask is a task: it has a status, dates, a project, tags, a place in Today, and a row of its
/// own in every list a task can appear in. A checklist item has a title and a tick, and it exists
/// only inside its parent — "buy stamps, address it, post it" is one errand with three steps, not
/// three errands.
///
/// Modelling both is not indecision. Making everything a subtask fills Anytime with fragments of
/// single actions; making everything a checklist item means a step can never be scheduled,
/// delegated, or given its own deadline the moment it turns out to need one. So both exist, the
/// cheap one is the default, and ``TaskChecklist/promotable(_:)`` describes the one-way door
/// between them.
///
/// The user is never asked to choose up front: typing steps into a task makes checklist items, and
/// the conversion is offered when one of them starts behaving like real work.
public struct ChecklistItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var isCompleted: Bool

    /// When it was ticked. Kept so a completed task's history is legible later.
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String = "",
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.completedAt = isCompleted ? completedAt : nil
    }
}

/// An ordered list of steps, and the operations on it.
///
/// A value type with no side effects, encoded into one column. Checklist items are never queried
/// individually, never linked to, and never appear in a list of their own — so an entity per step
/// would be a table whose every row is read only through its parent.
public struct TaskChecklist: Sendable, Hashable, Codable {
    public var items: [ChecklistItem]

    public init(items: [ChecklistItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var total: Int { items.count }
    public var completed: Int { items.count(where: \.isCompleted) }

    /// Progress, or `nil` when there is nothing to measure — see ``TaskFacts/checklistProgress``.
    public var progress: Double? {
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    /// Whether every step is ticked. `false` for an empty list: no steps is not the same as all
    /// steps done, and treating it as completion would auto-finish every task that never had one.
    public var isFullyComplete: Bool {
        !items.isEmpty && completed == total
    }

    // MARK: - Editing

    public mutating func append(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(title: trimmed))
    }

    public mutating func setCompleted(_ id: UUID, _ completed: Bool, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isCompleted = completed
        items[index].completedAt = completed ? date : nil
    }

    public mutating func rename(_ id: UUID, to title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = title
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Reorders steps.
    ///
    /// Implemented rather than delegated to `Array.move(fromOffsets:toOffset:)`, which SwiftUI adds
    /// — and this module deliberately has nothing above Foundation, which is what lets the whole
    /// task model be tested without a window.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !moved.isEmpty else { return }

        // The insertion point is expressed against the *original* array, so it has to be adjusted by
        // however many of the moved elements sat before it.
        let landing = destination - source.count { $0 < destination }

        var remaining = items
        for index in source.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }
        remaining.insert(contentsOf: moved, at: min(max(landing, 0), remaining.count))
        items = remaining
    }

    /// Unticks everything, keeping the steps.
    ///
    /// What a repeating task needs when its next occurrence comes round: the steps are the point of
    /// the recurrence, and regenerating them from scratch would lose any the user had edited.
    public mutating func reset() {
        for index in items.indices {
            items[index].isCompleted = false
            items[index].completedAt = nil
        }
    }

    /// The step whose title suggests it is really a task in its own right.
    ///
    /// Deliberately **not** automatic. This is offered in a menu; nothing is promoted without being
    /// asked for, because a step silently becoming a row in Anytime is the app rearranging the
    /// user's work behind their back.
    public static func promotable(_ item: ChecklistItem) -> Bool {
        !item.isCompleted && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Parsing

    /// Reads a pasted or typed block into steps.
    ///
    /// Accepts what people actually paste: bare lines, `- item`, `* item`, `1. item`, and
    /// `- [ ] item` / `- [x] item` with the tick honoured. Anything it cannot recognise stays a
    /// plain step with its text intact — nothing is dropped for failing to match a pattern.
    public static func parse(_ text: String) -> TaskChecklist {
        var checklist = TaskChecklist()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var body = line.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            var isCompleted = false

            for bullet in ["- ", "* ", "• "] where body.hasPrefix(bullet) {
                body = String(body.dropFirst(bullet.count))
                break
            }

            // `1. `, `2) ` and friends.
            if let separator = body.firstIndex(where: { $0 == "." || $0 == ")" }),
               separator > body.startIndex,
               body[body.startIndex..<separator].allSatisfy(\.isNumber),
               body.index(after: separator) < body.endIndex,
               body[body.index(after: separator)] == " " {
                body = String(body[body.index(separator, offsetBy: 2)...])
            }

            for marker in ["[x] ", "[X] ", "[ ] ", "[] "] where body.hasPrefix(marker) {
                isCompleted = marker.lowercased().hasPrefix("[x]")
                body = String(body.dropFirst(marker.count))
                break
            }

            let title = body.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            checklist.items.append(ChecklistItem(title: title, isCompleted: isCompleted))
        }

        return checklist
    }

    // MARK: - Storage

    /// Decodes from the stored column. Unreadable data reads as no checklist rather than throwing —
    /// a task whose steps cannot be read is still a perfectly good task.
    public static func decode(from data: Data?) -> TaskChecklist {
        guard let data else { return TaskChecklist() }
        return (try? JSONDecoder().decode(TaskChecklist.self, from: data)) ?? TaskChecklist()
    }

    /// Encodes for storage. `nil` for an empty checklist, so a task that never had one stores no
    /// blob at all.
    public func encoded() -> Data? {
        guard !items.isEmpty else { return nil }
        return try? JSONEncoder().encode(self)
    }
}
