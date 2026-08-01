import Foundation
import Testing

@testable import ElephruitCore

/// Which date a list row shows.
///
/// The rule is short and the precedence is the whole of it, so precedence is what this asserts. Each
/// case below is a state where two or three dates are all present and true, and only one of them is
/// the thing the person looking at the row is deciding about.
@Suite("Row date")
struct RowDateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        due: Date? = nil,
        archived: Date? = nil,
        deleted: Date? = nil,
        updated: Date? = nil
    ) -> ItemSnapshot {
        ItemSnapshot(
            kind: .note,
            title: "A note",
            updatedAt: updated ?? now,
            dueAt: due,
            archivedAt: archived,
            deletedAt: deleted
        )
    }

    /// The branch that gives a note a date at all. Before this, a list of notes was the one list in
    /// the app that showed no date anywhere, because notes carry no deadline.
    @Test("A note with no deadline shows when it last changed")
    func fallsBackToChanged() throws {
        let resolved = try #require(RowDate.resolve(for: item()))
        #expect(resolved.role == .changed)
        #expect(resolved.date == now)
    }

    @Test("A deadline beats when it last changed")
    func deadlineWins() throws {
        let due = now.addingTimeInterval(86_400)
        let resolved = try #require(RowDate.resolve(for: item(due: due)))
        #expect(resolved.role == .due)
        #expect(resolved.date == due)
    }

    /// In the Trash the decision is about the deletion. A deadline the item still nominally carries
    /// is not the live question, and answering with it would leave the two things somebody actually
    /// wants to know — when this went, and what it was — both unanswered.
    @Test("In the Trash, the deletion wins over everything")
    func deletionWins() throws {
        let deleted = now.addingTimeInterval(-3_600)
        let resolved = try #require(
            RowDate.resolve(for: item(due: now, archived: now, deleted: deleted))
        )
        #expect(resolved.role == .deleted)
        #expect(resolved.date == deleted)
    }

    @Test("Archiving wins over a deadline, and loses to deletion")
    func archiveOrder() throws {
        let archived = now.addingTimeInterval(-7_200)
        let resolved = try #require(RowDate.resolve(for: item(due: now, archived: archived)))
        #expect(resolved.role == .archived)

        let alsoDeleted = try #require(
            RowDate.resolve(for: item(archived: archived, deleted: now))
        )
        #expect(alsoDeleted.role == .deleted)
    }

    // MARK: - What the date says about itself

    /// A deadline and a last-edited date each follow a convention strong enough to go unlabelled —
    /// the first from every task application, the second from Finder and Notes. Deletion and
    /// archiving do not, and both live in small lists where a word is affordable.
    @Test("Only the two surprising dates carry a word")
    func onlySurprisingDatesArePrefixed() {
        #expect(RowDate.Role.due.prefix == nil)
        #expect(RowDate.Role.changed.prefix == nil)
        #expect(RowDate.Role.deleted.prefix == "Deleted")
        #expect(RowDate.Role.archived.prefix == "Archived")
    }

    /// The rule that stops "Edited Yesterday" being drawn in red. Lateness is a property of an
    /// obligation, and only one of these four is one.
    @Test("Only a deadline is coloured by lateness")
    func onlyDueShowsUrgency() {
        #expect(RowDate.Role.due.showsUrgency)
        #expect(!RowDate.Role.deleted.showsUrgency)
        #expect(!RowDate.Role.archived.showsUrgency)
        #expect(!RowDate.Role.changed.showsUrgency)
    }
}
