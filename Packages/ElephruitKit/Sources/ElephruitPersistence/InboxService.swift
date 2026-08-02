import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// What the user is told, and how often.
///
/// The whole design constraint is that a badge people ignore is worse than no badge, so this errs
/// heavily towards saying less: repeated unread notices of the same kind collapse into one, and the
/// pruning drops what has been read before it touches anything that has not.
@MainActor
public final class InboxService {
    /// How many notifications a project keeps before old ones are dropped.
    private static let retentionLimit = 200

    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(context: ModelContext, dateProvider: any DateProvider) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Posting

    /// Records something worth telling the user, **collapsing repeats**.
    ///
    /// If an unread notification of the same kind already exists on the same item, its timestamp and
    /// wording are updated rather than a second one being added. Four comments on one bug is one
    /// thing to look at, not four; posting it four times teaches people that the count is noise.
    @discardableResult
    public func post(
        _ kind: NotificationKind,
        about item: Item,
        summary: String,
        actorID: UUID? = nil,
        automationRuleID: UUID? = nil
    ) throws(AppError) -> InboxNotification {
        if let existing = item.notifications.first(where: { !$0.isRead && $0.kind == kind }) {
            existing.at = dateProvider.now
            existing.summary = summary
            existing.actorID = actorID
            existing.automationRuleID = automationRuleID
            try save()
            return existing
        }

        let notification = InboxNotification(
            at: dateProvider.now,
            kind: kind,
            summary: summary,
            actorID: actorID,
            automationRuleID: automationRuleID
        )
        notification.item = item
        context.insert(notification)
        try save()
        return notification
    }

    // MARK: - Reading

    /// Everything for a project, unread first, then most recent.
    ///
    /// Uses `descendantWork`, so a project's inbox includes work nested under headings and subtasks
    /// rather than only its direct children.
    public func notifications(in project: Item) -> [InboxNotification] {
        let scope = [project] + project.descendantWork() + project.planningMarkers()
        return scope
            .flatMap(\.notifications)
            .sorted { lhs, rhs in
                if lhs.isRead != rhs.isRead { return !lhs.isRead }
                return lhs.at > rhs.at
            }
    }

    public func unread(in project: Item) -> [InboxNotification] {
        notifications(in: project).filter { !$0.isRead }
    }

    /// What the sidebar shows beside a project's name, or `0` for nothing at all.
    public func badgeCount(for project: Item) -> Int {
        unread(in: project).count
    }

    /// The unread notices that are something to *do* rather than something to know.
    public func actionable(in project: Item) -> [InboxNotification] {
        unread(in: project).filter { $0.kind.demandsAction }
    }

    // MARK: - Marking

    public func markRead(_ notification: InboxNotification) throws(AppError) {
        guard !notification.isRead else { return }
        notification.isRead = true
        try save()
    }

    public func markAllRead(in project: Item) throws(AppError) {
        let unreadOnes = unread(in: project)
        guard !unreadOnes.isEmpty else { return }
        for notification in unreadOnes { notification.isRead = true }
        try save()
    }

    public func markUnread(_ notification: InboxNotification) throws(AppError) {
        guard notification.isRead else { return }
        notification.isRead = false
        try save()
    }

    // MARK: - Pruning

    /// Drops the oldest notifications past the retention limit.
    ///
    /// **Read ones go first, whatever their age.** Dropping strictly by date would discard an unread
    /// notice about a critical bug to make room for a read one about a renamed column — which is
    /// precisely backwards, because the unread one is the only kind that still has a job to do.
    public func prune(in project: Item) throws(AppError) {
        let all = notifications(in: project)
        guard all.count > Self.retentionLimit else { return }

        let excess = all.count - Self.retentionLimit
        let expendable = all
            .sorted { lhs, rhs in
                if lhs.isRead != rhs.isRead { return lhs.isRead }
                return lhs.at < rhs.at
            }
            .prefix(excess)

        for notification in expendable { context.delete(notification) }
        try save()
    }

    private func save() throws(AppError) {
        do {
            try context.save()
        } catch {
            throw .writeFailed(path: "inbox", reason: error.localizedDescription)
        }
    }
}
