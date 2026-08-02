import ElephruitCore
import Foundation

/// Enforces the invariants from `docs/04-domain-model.md`.
///
/// This is the answer to the wide-row objection against a single ``Item`` entity: the
/// schema permits a note to carry a due date, and this type makes sure none ever does.
/// Every repository save path runs ``ItemValidator/validate(_:)``, and every invariant
/// here has a test.
///
/// Stateless and free of side effects, so it is cheap to call on every save.
public enum ItemValidator {
    /// Checks every invariant. Throws on the first failure, naming the field so the UI
    /// can move focus to it.
    public static func validate(_ item: Item) throws(AppError) {
        try validateKindFields(item)
        try validateStatus(item)
        try validateDateOrder(item)
        try validateContainment(item)
    }

    /// Whether the item is valid, when a Boolean is more useful than a throw.
    public static func isValid(_ item: Item) -> Bool {
        do {
            try validate(item)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Kind and fields

    /// Invariant 3 and the `supportedFields` contract: an item may only carry values in
    /// fields its kind declares.
    private static func validateKindFields(_ item: Item) throws(AppError) {
        let kind = item.kind
        let fields = kind.supportedFields

        if item.dueAt != nil, !fields.contains(.dueDate) {
            throw fieldFailure("dueAt", kind)
        }
        if item.startAt != nil, !fields.contains(.startDate) {
            throw fieldFailure("startAt", kind)
        }
        if item.deferUntil != nil, !fields.contains(.deferDate) {
            throw fieldFailure("deferUntil", kind)
        }
        if item.recurrenceData != nil, !fields.contains(.recurrence) {
            throw fieldFailure("recurrence", kind)
        }
        if item.priority != .normal, !fields.contains(.priority) {
            throw fieldFailure("priority", kind)
        }
        if item.dayKey != nil, !fields.contains(.dayKey) {
            throw fieldFailure("dayKey", kind)
        }
        if item.personProfile != nil, !fields.contains(.personProfile) {
            throw fieldFailure("personProfile", kind)
        }
        if item.eventReference != nil, !fields.contains(.eventReference) {
            throw fieldFailure("eventReference", kind)
        }

        // The project-workspace columns. Each is checked against its owning kind rather than
        // against an `ItemFields` flag, because each belongs to exactly one kind — a flag would be
        // a bit that only ever has one holder, which reads as generality that is not there.
        if item.bugRecord != nil, kind != .bug {
            throw fieldFailure("bugRecord", kind)
        }
        if item.projectKey != nil, kind != .project {
            throw fieldFailure("projectKey", kind)
        }
        if item.releaseVersion != nil, kind != .release {
            throw fieldFailure("releaseVersion", kind)
        }
        if item.workflowStageID != nil, !kind.isWorkItem {
            throw fieldFailure("workflowStageID", kind)
        }
        if item.goalTargetValue != nil || item.goalCurrentValue != nil || item.goalUnit != nil,
           kind != .goal {
            throw fieldFailure("goalValue", kind)
        }
        if !item.children.isEmpty, !fields.contains(.children) {
            throw fieldFailure("children", kind)
        }
        if !item.body.isEmpty, !fields.contains(.body) {
            throw fieldFailure("body", kind)
        }
        if !item.tags.isEmpty, !fields.contains(.tags) {
            throw fieldFailure("tags", kind)
        }
        if item.reminderAt != nil, !fields.contains(.reminder) {
            throw fieldFailure("reminderAt", kind)
        }
        if item.checklistData != nil, !fields.contains(.checklist) {
            throw fieldFailure("checklist", kind)
        }
        if item.externalIdentifier != nil, !fields.contains(.externalLink) {
            throw fieldFailure("externalIdentifier", kind)
        }
        if !fields.contains(.planning) {
            // Checked together because they are one capability. A note that somehow acquired a
            // Someday mark and a note that acquired a flag are the same bug, and naming the first
            // field found is enough to locate it.
            let hasPlanningValue = item.todayCommittedOn != nil
                || item.isLaterToday
                || item.isSomeday
                || item.isFlagged
                || item.waitingSince != nil
                || item.followUpAt != nil
            if hasPlanningValue { throw fieldFailure("planning", kind) }
        }
    }

    private static func fieldFailure(_ field: String, _ kind: ItemKind) -> AppError {
        .validation(ValidationFailure(reason: .fieldNotSupportedByKind(field: field, kind: kind), field: field))
    }

    // MARK: - Status

    /// Invariants 2 and 3: `completed ⇔ completedAt != nil`, and only status-bearing
    /// kinds may have a status at all.
    private static func validateStatus(_ item: Item) throws(AppError) {
        let kind = item.kind

        guard kind.supportsStatus else {
            guard item.status == .none, item.completedAt == nil else {
                throw .validation(
                    ValidationFailure(reason: .statusNotSupportedByKind(kind: kind), field: "status")
                )
            }
            return
        }

        let isCompleted = item.status == .completed
        let hasCompletionDate = item.completedAt != nil

        guard isCompleted == hasCompletionDate else {
            throw .validation(ValidationFailure(reason: .statusDateMismatch, field: "completedAt"))
        }

        // Cancellation carries the same rule as completion: the state and its date are one fact, and
        // a task that reads as abandoned with no date for it cannot be placed in the log.
        guard (item.status == .cancelled) == (item.cancelledAt != nil) else {
            throw .validation(ValidationFailure(reason: .statusDateMismatch, field: "cancelledAt"))
        }
    }

    // MARK: - Dates

    /// A start that follows its due date is almost always a slip of the keyboard, and
    /// silently accepting it produces views that make no sense.
    private static func validateDateOrder(_ item: Item) throws(AppError) {
        if let startAt = item.startAt, let dueAt = item.dueAt, startAt > dueAt {
            throw .validation(
                ValidationFailure(reason: .invalidDateRange(startField: "startAt", endField: "dueAt"), field: "dueAt")
            )
        }
    }

    // MARK: - Containment

    /// Invariant 4: the parent must be able to contain this kind, and no cycles.
    private static func validateContainment(_ item: Item) throws(AppError) {
        guard let parent = item.parent else { return }

        guard parent.id != item.id else {
            throw .validation(ValidationFailure(reason: .containmentCycle, field: "parent"))
        }

        guard parent.kind.canContain(item.kind) else {
            throw .validation(
                ValidationFailure(
                    reason: .invalidContainment(parentKind: parent.kind, childKind: item.kind),
                    field: "parent"
                )
            )
        }

        // Walking up must reach a root without meeting this item again.
        var seen: Set<UUID> = [item.id]
        var cursor: Item? = parent
        var depth = 0

        while let current = cursor, depth < 64 {
            guard seen.insert(current.id).inserted else {
                throw .validation(ValidationFailure(reason: .containmentCycle, field: "parent"))
            }
            cursor = current.parent
            depth += 1
        }
    }

    // MARK: - Repair

    /// Brings an item into agreement with its own kind, discarding values that kind
    /// cannot hold.
    ///
    /// Used when the user *changes* an item's kind — turning a task back into a note
    /// must drop the due date rather than fail validation forever. Returns what was
    /// cleared, so the UI can say so rather than losing data silently.
    @discardableResult
    public static func conform(_ item: Item, to newKind: ItemKind) -> [String] {
        var cleared: [String] = []
        let fields = newKind.supportedFields

        item.kind = newKind

        if item.dueAt != nil, !fields.contains(.dueDate) {
            item.dueAt = nil
            cleared.append("due date")
        }
        if item.startAt != nil, !fields.contains(.startDate) {
            item.startAt = nil
            cleared.append("start date")
        }
        if item.deferUntil != nil, !fields.contains(.deferDate) {
            item.deferUntil = nil
            cleared.append("defer date")
        }
        if item.recurrenceData != nil, !fields.contains(.recurrence) {
            item.recurrenceData = nil
            cleared.append("recurrence")
        }
        if item.priority != .normal, !fields.contains(.priority) {
            item.priority = .normal
            cleared.append("priority")
        }
        if item.dayKey != nil, !fields.contains(.dayKey) {
            item.dayKey = nil
            cleared.append("day")
        }
        if !item.body.isEmpty, !fields.contains(.body) {
            item.body = ""
            cleared.append("body")
        }
        if !item.tags.isEmpty, !fields.contains(.tags) {
            item.tags = []
            cleared.append("tags")
        }

        if item.reminderAt != nil, !fields.contains(.reminder) {
            item.reminderAt = nil
            item.reminderIsTimed = false
            item.reminderOwner = .none
            cleared.append("reminder")
        }
        if item.checklistData != nil, !fields.contains(.checklist) {
            item.checklistData = nil
            cleared.append("checklist")
        }
        if item.externalIdentifier != nil, !fields.contains(.externalLink) {
            // The *link* is dropped, never the reminder. Turning a task into a note is not consent
            // to delete something out of somebody's iCloud account.
            item.setReminderLink(nil)
            cleared.append("Reminders link")
        }
        if !fields.contains(.planning) {
            var clearedPlanning = false
            if item.todayCommittedOn != nil || item.isLaterToday { clearedPlanning = true }
            if item.isSomeday || item.isFlagged { clearedPlanning = true }
            if item.waitingSince != nil || item.followUpAt != nil { clearedPlanning = true }

            item.todayCommittedOn = nil
            item.isLaterToday = false
            item.isSomeday = false
            item.isFlagged = false
            item.waitingSince = nil
            item.followUpAt = nil
            if clearedPlanning { cleared.append("planning marks") }
        }

        // The project-workspace columns, cleared on the same terms and reported the same way —
        // turning a bug into a task drops the report, and the caller has to be able to say so.
        if item.bugRecord != nil, newKind != .bug {
            item.bugRecord = nil
            cleared.append("bug report")
        }
        if item.projectKey != nil, newKind != .project {
            item.projectKey = nil
            cleared.append("project key")
        }
        if item.releaseVersion != nil, newKind != .release {
            item.releaseVersion = nil
            cleared.append("version")
        }
        // **Kept when converting between work kinds.** A bug that becomes a task is still the same
        // work sitting in the same column, and emptying the column would move it on the board for a
        // reason nobody would connect to the change they just made.
        if item.workflowStageID != nil, !newKind.isWorkItem {
            item.workflowStageID = nil
            cleared.append("board column")
        }
        if item.goalTargetValue != nil || item.goalCurrentValue != nil || item.goalUnit != nil,
           newKind != .goal {
            item.goalTargetValue = nil
            item.goalCurrentValue = nil
            item.goalUnit = nil
            cleared.append("goal target")
        }

        if !newKind.supportsStatus {
            if item.status != .none || item.completedAt != nil || item.cancelledAt != nil {
                item.status = .none
                item.completedAt = nil
                item.cancelledAt = nil
                cleared.append("completion")
            }
        } else if item.status == .none {
            // A kind that tracks status needs one; a fresh task is open.
            item.status = .open
        }

        // A parent that can no longer contain this kind is detached rather than made
        // invalid — the item survives, it just moves to the top level.
        if let parent = item.parent, !parent.kind.canContain(newKind) {
            item.parent = nil
            cleared.append("parent")
        }

        return cleared
    }
}
