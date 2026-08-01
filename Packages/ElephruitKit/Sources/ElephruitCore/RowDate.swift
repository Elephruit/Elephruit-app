import Foundation

/// Which date a list row shows, and what that date means.
///
/// ### Why a row needs a rule rather than a field
/// The row showed `dueAt` and nothing else. That is right for a task and leaves a note with no date
/// at all — so a list of notes, where "when did I last touch this" is the most useful thing there
/// is to know, was the one list in the app that answered nothing. Meanwhile the Trash showed the
/// same nothing, in the one place where the two questions a person actually has are *when did I
/// delete this* and *how long have I got*.
///
/// Reaching for `updatedAt` as a blanket fallback would fix the notes list and make the Trash say
/// "modified 3 Jul" about something deleted yesterday — technically true, and an answer to a
/// question nobody asked. So the rule is stated once: **a row shows the date that matters for the
/// state the item is in**, and says which date it is when that is not obvious.
///
/// Pure, and separated from the view, so the rule can be asserted rather than inspected.
public enum RowDate {
    /// What the date on a row is telling you.
    public enum Role: Sendable, Hashable {
        /// A deadline. The only role that is ever coloured by urgency.
        case due
        /// When it was deleted. Shown in the Trash, where it is half of the decision.
        case deleted
        /// When it was archived.
        case archived
        /// When it last changed. The default for anything with no obligation attached.
        case changed

        /// The word shown before the date, or `nil` where the date speaks for itself.
        ///
        /// Two of the four need one. "3 Jul" beside a deleted note is a date with no question
        /// attached to it, and the Trash and the Archive are small lists where a word costs little.
        ///
        /// The other two do not, for opposite reasons. A date on an actionable row means the
        /// deadline — the convention every task application shares. And a date on anything else
        /// means when it last changed, which is the convention Finder and Notes share; spelling it
        /// out cost about a third of the width of a list column, on every row, to repeat a word that
        /// was the same all the way down. Where the two can appear together, the leading glyph
        /// already says which kind of row it is, so the distinction never rests on colour alone.
        public var prefix: String? {
            switch self {
            case .due, .changed: nil
            case .deleted: "Deleted"
            case .archived: "Archived"
            }
        }

        /// Whether lateness should colour this date.
        ///
        /// Only a deadline. Colouring "Edited 3 Jul" red because it is in the past would be the
        /// interface inventing an obligation the user never made.
        public var showsUrgency: Bool { self == .due }
    }

    public struct Resolved: Sendable, Hashable {
        public var date: Date
        public var role: Role

        public init(date: Date, role: Role) {
            self.date = date
            self.role = role
        }
    }

    /// The date this row should show.
    ///
    /// Ordered by what the item's current state makes urgent. Deleted wins over everything, because
    /// an item in the Trash is being looked at in order to decide about the deletion and nothing
    /// else; a deadline it still nominally carries is not the live question. Archived follows for
    /// the same reason. Only then does a deadline win, and only then does "when did this change".
    public static func resolve(for item: some ContentItem) -> Resolved? {
        if let deletedAt = item.deletedAt {
            return Resolved(date: deletedAt, role: .deleted)
        }
        if let archivedAt = item.archivedAt {
            return Resolved(date: archivedAt, role: .archived)
        }
        if let dueAt = item.dueAt {
            return Resolved(date: dueAt, role: .due)
        }

        // Everything has an `updatedAt`, so this is the branch that finally gives a note a date.
        return Resolved(date: item.updatedAt, role: .changed)
    }
}
