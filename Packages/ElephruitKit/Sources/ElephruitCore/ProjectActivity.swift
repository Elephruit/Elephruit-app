import Foundation

/// What happened to a work item.
///
/// The sentences are written here rather than in the view because history is read far more often
/// than it is written, and because an activity row is the one place the app has to describe its own
/// past accurately — including the parts it did on its own.
public enum ActivityKind: String, Codable, Sendable, Hashable, CaseIterable {
    case created
    case edited
    case titleChanged
    case statusChanged
    case stageChanged
    case priorityChanged
    case severityChanged
    case assigned
    case unassigned
    case dueDateChanged
    case startDateChanged
    case estimateChanged
    case milestoneChanged
    case releaseChanged
    case blockedByAdded
    case blockedByRemoved
    case markedDuplicate
    case commented
    case verified
    case reopened
    case movedToProject

    /// Ran because a rule said so, not because a person did.
    ///
    /// Its own case rather than a flag on the others because "the rule did this" is the first
    /// question anybody asks about a change they did not make, and it should be answerable by
    /// reading the row rather than by noticing a subtitle.
    case automation

    /// The sentence for a history row.
    ///
    /// Values arrive as display strings, already resolved — see `ItemActivity` for why history
    /// stores words rather than identifiers.
    public func sentence(from old: String?, to new: String?, field: String? = nil) -> String {
        switch self {
        case .created:
            return "Created"
        case .titleChanged:
            return new.map { "Renamed to “\($0)”" } ?? "Renamed"
        case .statusChanged:
            return new.map { "Marked \($0)" } ?? "Status changed"
        case .stageChanged:
            return between("Moved", old, new)
        case .priorityChanged:
            return between("Priority", old, new)
        case .severityChanged:
            return between("Severity", old, new)
        case .assigned:
            return new.map { "Assigned to \($0)" } ?? "Assigned"
        case .unassigned:
            return old.map { "Unassigned from \($0)" } ?? "Unassigned"
        case .dueDateChanged:
            return dateSentence("Due", old, new)
        case .startDateChanged:
            return dateSentence("Starts", old, new)
        case .estimateChanged:
            return between("Estimate", old, new)
        case .milestoneChanged:
            return new.map { "Aimed at \($0)" } ?? "Milestone cleared"
        case .releaseChanged:
            return new.map { "Part of \($0)" } ?? "Release cleared"
        case .blockedByAdded:
            return new.map { "Blocked by \($0)" } ?? "Blocked"
        case .blockedByRemoved:
            return old.map { "No longer blocked by \($0)" } ?? "Unblocked"
        case .markedDuplicate:
            return new.map { "Marked a duplicate of \($0)" } ?? "Marked a duplicate"
        case .commented:
            return "Commented"
        case .verified:
            return "Verified"
        case .reopened:
            return "Reopened"
        case .movedToProject:
            return new.map { "Moved to \($0)" } ?? "Moved"
        case .automation:
            return new ?? "Changed by a rule"
        case .edited:
            guard let field else { return "Edited" }
            return between(field, old, new)
        }
    }

    private func between(_ noun: String, _ old: String?, _ new: String?) -> String {
        switch (old, new) {
        case let (old?, new?): "\(noun) from \(old) to \(new)"
        case let (nil, new?): "\(noun) set to \(new)"
        case let (old?, nil): "\(noun) cleared from \(old)"
        case (nil, nil): "\(noun) changed"
        }
    }

    private func dateSentence(_ noun: String, _ old: String?, _ new: String?) -> String {
        guard let new else { return "\(noun) date cleared" }
        return old == nil ? "\(noun) \(new)" : "\(noun) \(new) — was \(old ?? "")"
    }
}

/// Why the user is being told something.
public enum NotificationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case assigned
    case mentioned
    case commented
    case blocked
    case unblocked
    case dueSoon
    case overdue
    case statusChanged
    case automationRan
    case bugAwaitingVerification

    public var displayName: String {
        switch self {
        case .assigned: "Assigned to you"
        case .mentioned: "Mentioned you"
        case .commented: "New comment"
        case .blocked: "Blocked"
        case .unblocked: "Unblocked"
        case .dueSoon: "Due soon"
        case .overdue: "Overdue"
        case .statusChanged: "Status changed"
        case .automationRan: "A rule ran"
        case .bugAwaitingVerification: "Waiting to be checked"
        }
    }

    public var symbolName: String {
        switch self {
        case .assigned: "person.crop.circle.badge.checkmark"
        case .mentioned: "at"
        case .commented: "bubble.left"
        case .blocked: "hand.raised"
        case .unblocked: "hand.thumbsup"
        case .dueSoon: "clock"
        case .overdue: "exclamationmark.triangle"
        case .statusChanged: "arrow.triangle.swap"
        case .automationRan: "bolt"
        case .bugAwaitingVerification: "checkmark.seal"
        }
    }

    /// Whether this is something to *do* rather than something to know.
    ///
    /// The inbox sorts on it, because a list that mixes "you were assigned a critical bug" with
    /// "somebody renamed a column" in timestamp order is a list people stop opening.
    public var demandsAction: Bool {
        switch self {
        case .assigned, .blocked, .overdue, .dueSoon, .mentioned, .bugAwaitingVerification: true
        case .commented, .unblocked, .statusChanged, .automationRan: false
        }
    }
}

/// What kind of value a custom field holds.
public enum CustomFieldType: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case number
    case flag
    case date
    case choice

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .flag: "Yes or no"
        case .date: "Date"
        case .choice: "One of a list"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: "textformat"
        case .number: "number"
        case .flag: "checkmark.square"
        case .date: "calendar"
        case .choice: "list.bullet.circle"
        }
    }
}

extension String {
    /// `nil` when there is nothing but whitespace here.
    ///
    /// Used everywhere a field is optional-when-empty, so that an empty string and an absent value
    /// do not become two different spellings of the same nothing.
    public var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
