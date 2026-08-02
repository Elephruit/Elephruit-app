import Foundation

/// Where a task sits in its life, as the interface talks about it.
///
/// ### Why this is not ``ItemStatus``
/// `ItemStatus` is the *lifecycle of every kind that has one* — open, completed, cancelled — and it
/// is the source of truth for completion. This is narrower and wider at once: narrower because only
/// tasks have it, wider because it folds in the two states a task can be in that are not about
/// having been finished.
///
/// It is **derived**, never stored. Storing it would create a second answer to "is this done?", and
/// the first bug that follows is a task that is `completed` in one column and `waiting` in another.
/// ``TaskFacts/lifecycle`` computes it from the status, the waiting mark, the someday mark, and
/// whether the task has been filed anywhere.
public enum TaskLifecycle: String, Sendable, Hashable, CaseIterable, Codable {
    /// Captured without a decided home. A processing state, not a place to live.
    case inbox

    /// Filed, open, and not held up by anything.
    case active

    /// Open, but the next move belongs to somebody or something else.
    case waiting

    /// Deliberately set aside. Not overdue, not neglected — parked.
    case someday

    case completed

    /// Deliberately abandoned. The record of *not* doing it is worth keeping.
    case cancelled

    /// Whether the task still asks something of the user.
    public var isOpen: Bool {
        switch self {
        case .inbox, .active, .waiting, .someday: true
        case .completed, .cancelled: false
        }
    }

    /// Whether the task competes for attention today.
    ///
    /// `false` for Someday, which is the entire point of it: an idea parked for later must not
    /// appear in a count, a list, or a badge alongside work that is actually live.
    public var competesForAttention: Bool {
        switch self {
        case .inbox, .active, .waiting: true
        case .someday, .completed, .cancelled: false
        }
    }

    public var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .active: "Active"
        case .waiting: "Waiting"
        case .someday: "Someday"
        case .completed: "Completed"
        case .cancelled: "Canceled"
        }
    }
}

/// Whether a task can be worked on now, and if not, why not.
///
/// The distinction this type exists to keep is between *not yet* and *not chosen*. A task with a
/// start date next Tuesday is not neglected and not deferred out of guilt; it simply has not begun.
/// Anything that renders a task as pending work has to be able to tell those apart.
public enum TaskAvailability: Sendable, Hashable {
    /// Workable now.
    case available

    /// Becomes workable on this date, and should not be asked about until then.
    case scheduled(Date)

    /// Parked by choice.
    case someday

    /// Blocked on somebody or something else.
    case waiting

    /// Finished or abandoned.
    case resolved

    public var isAvailable: Bool { self == .available }

    /// The date the task becomes actionable, when that is in the future.
    public var startsOn: Date? {
        if case .scheduled(let date) = self { return date }
        return nil
    }
}

/// How close a deadline is, or how far past.
///
/// A deadline is an **external commitment with a consequence**, which is why this is computed from
/// `deadlineAt` alone and never from a start date. Nothing in the interface may render a start date
/// through this type: a task that becomes available tomorrow is not "due tomorrow", and conflating
/// the two is the single most common way a task manager makes a person feel behind on work they
/// have not been asked for yet.
public enum DeadlineUrgency: Sendable, Hashable {
    /// No deadline. The commonest case, and not a deficiency.
    case none

    /// Further out than the horizon a list bothers to colour.
    case distant

    /// Within the horizon. `days` is whole days from today, always at least 1.
    case soon(days: Int)

    /// Due today.
    case today

    /// Past. `days` is whole days late, always at least 1.
    case overdue(days: Int)

    /// Whether this deadline should be drawn with any emphasis at all.
    public var isEmphasised: Bool {
        switch self {
        case .none, .distant: false
        case .soon, .today, .overdue: true
        }
    }

    /// Whether the task has passed its deadline.
    public var isOverdue: Bool {
        if case .overdue = self { return true }
        return false
    }
}

/// Who is responsible for delivering a task's notification.
///
/// Recorded rather than inferred, because both systems can hold an alarm for the same task and the
/// user would then be told twice. The moment a task is linked to a system reminder that carries an
/// alarm, the system owns it and the app schedules nothing.
public enum ReminderOwner: String, Sendable, Hashable, Codable, CaseIterable {
    /// No notification is wanted.
    case none

    /// This app schedules and delivers it.
    case app

    /// The linked system reminder carries the alarm; the app must not schedule a second one.
    case system

    public var displayName: String {
        switch self {
        case .none: "No notification"
        case .app: "Elephruit"
        case .system: "Reminders"
        }
    }
}

/// How a task's dates relate to a system reminder, and whether they still agree.
public enum TaskSyncState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Lives only here. The default, and the private one.
    case local

    /// Linked to a system reminder and in step with it.
    case linked

    /// Linked, with local changes not yet written out.
    case pendingUpload

    /// Both sides changed since the last reconciliation. Surfaced, never resolved silently.
    case conflicted

    /// The reminder this was linked to no longer exists in the system store.
    case externalMissing

    /// The reminder's list refuses writes, so changes here cannot be sent.
    case externalReadOnly

    public var displayName: String {
        switch self {
        case .local: "Local only"
        case .linked: "Linked to Reminders"
        case .pendingUpload: "Waiting to sync"
        case .conflicted: "Needs review"
        case .externalMissing: "Reminder missing"
        case .externalReadOnly: "Read-only list"
        }
    }

    /// Whether the state is one the user has to do something about.
    public var needsAttention: Bool {
        switch self {
        case .conflicted, .externalMissing, .externalReadOnly: true
        case .local, .linked, .pendingUpload: false
        }
    }
}

/// Why a migrated date was left alone and flagged instead.
///
/// The migration's whole posture is that it does not know what an old value meant. Where the meaning
/// is unambiguous it converts; where it is not, it converts nothing and records one of these, so the
/// user can decide with the task in front of them.
public enum DateReviewReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// A deadline carrying a time of day, from before reminders existed as a separate field.
    ///
    /// It could have been "finish by 5pm" or "remind me at 5pm", and those are different requests.
    /// The value stays exactly where it was, as a deadline, and the task says it is worth a look.
    case deadlineMayHaveBeenAReminder

    /// Both a legacy defer date and a start date were present and disagreed.
    ///
    /// The fold is only lossless when there is one value; two means somebody's intent is in there
    /// and picking one would throw the other away.
    case startAndDeferDisagreed

    public var summary: String {
        switch self {
        case .deadlineMayHaveBeenAReminder:
            "This deadline has a time on it. Did you mean a deadline, or a reminder?"
        case .startAndDeferDisagreed:
            "This task had two different start dates. The earlier one was kept."
        }
    }
}

// MARK: - Facts

/// Everything the scheduling rules need to know about one task, as a value.
///
/// ### Why a snapshot rather than the stored object
/// Every rule in this file — availability, urgency, Today membership, smart-list matching — is a
/// pure function of these fields. Taking a `Sendable` value rather than a `PersistentModel` means
/// the whole of the scheduling model is testable with a struct literal, runs on any actor, and
/// cannot accidentally fetch a relationship while a list is drawing.
///
/// The fields that require a traversal to compute — whether the task has a home, whether anybody is
/// waited on — are computed once by the persistence layer and carried here, so no rule below ever
/// walks the graph.
public struct TaskFacts: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String

    // MARK: Status

    public var status: ItemStatus
    public var completedAt: Date?

    /// Set when a task is abandoned rather than finished. Distinct from `completedAt` so history can
    /// tell "I did it" from "I decided not to".
    public var cancelledAt: Date?

    // MARK: The three dates, which are three different things

    /// When the task becomes actionable. **Not** a deadline and never rendered as one.
    ///
    /// A future value means: do not ask me to think about this until then.
    public var startAt: Date?

    /// The date by which the task must be finished. The only date that can make a task overdue.
    public var deadlineAt: Date?

    /// When to interrupt the user. Independent of both dates above.
    ///
    /// Never created as a side effect of setting a date. Visibility and interruption are different
    /// requests, and an app that turns the first into the second is one people switch off.
    public var reminderAt: Date?

    /// Whether ``reminderAt`` names a time of day or only a day.
    public var reminderIsTimed: Bool

    public var reminderOwner: ReminderOwner

    // MARK: Commitment

    /// The day the user chose to work on this. `nil` means they have not.
    ///
    /// A *day*, not a flag, so a commitment made on Monday can be told from one made today — and so
    /// carrying work forward is a fact in the data rather than a guess in a view.
    public var todayCommittedOn: Date?

    /// Placed in the back half of today. Only meaningful while the commitment is for today itself.
    public var isLaterToday: Bool

    /// Position within Today, independent of position within the owning project.
    public var todayOrder: Double

    // MARK: Marks

    public var isSomeday: Bool
    public var isFlagged: Bool
    public var priority: Priority

    /// When the task started waiting on somebody else. `nil` means it is not waiting.
    public var waitingSince: Date?

    /// When to chase, for a waiting task.
    public var followUpAt: Date?

    // MARK: Structure

    /// Whether the task has been filed anywhere at all — a project, a list, an area, or a tag.
    ///
    /// The Inbox is *unprocessed*, not *unparented*, so this is what decides membership.
    public var hasHome: Bool

    public var parentID: UUID?
    public var areaID: UUID?
    public var projectID: UUID?
    public var listID: UUID?
    public var sectionID: UUID?

    public var tagSlugs: [String]
    public var relatedPersonIDs: [UUID]

    /// The person this task is waiting on, when there is one.
    public var waitingOnPersonID: UUID?

    public var hasAttachments: Bool
    public var isRepeating: Bool
    public var hasSubtasks: Bool
    public var checklistTotal: Int
    public var checklistCompleted: Int

    public var source: SourceKind
    public var syncState: TaskSyncState

    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Double

    /// Title and notes, folded for matching. Supplied rather than recomputed so a filter over ten
    /// thousand tasks folds nothing.
    public var searchText: String

    // MARK: Project workspace
    //
    // Every field below defaults, and the defaults are the pre-Projects behaviour: a plain task in
    // no project answers `.task`, no stage, no assignee, nothing blocked. That is what lets one
    // fact type serve both the scheduling model and the board without the scheduling model
    // acquiring a project's vocabulary.

    /// Which kind of work this is. `.task` for everything the task system already managed.
    public var kind: ItemKind

    /// The human-readable handle — `ELE-42`.
    public var referenceKey: String?

    /// The board column this sits in, if the project has a board.
    public var workflowStageID: UUID?

    /// What that column means. Carried alongside the identifier so grouping and filtering never
    /// have to reach back to the project to find out whether a column is terminal.
    public var stageCategory: WorkflowStageCategory?

    /// Position within the column, independent of ``sortOrder``, which is position within the
    /// project. The same work is in two orders at once and both are the user's.
    public var boardOrder: Double

    /// The person doing it. At most one — enforced where it is written, not here.
    public var assigneeID: UUID?

    public var milestoneID: UUID?
    public var releaseID: UUID?

    /// What must be resolved before this can proceed.
    public var blockedByIDs: [UUID]

    /// What this is holding up.
    public var blocksIDs: [UUID]

    /// Whether anything blocking it is still unresolved.
    ///
    /// Stored rather than derived from ``blockedByIDs`` because the answer needs the *status* of
    /// those items, which a fact about this one does not have. Computing it here would mean either
    /// carrying every blocker's status or fetching during a filter.
    public var isBlocked: Bool

    /// `nil` for anything that is not a bug — and for a bug whose record has not been created yet,
    /// which is why the model layer substitutes `.minor` rather than passing the nil through.
    public var severity: BugSeverity?

    public var isRegression: Bool

    /// Whether somebody has confirmed the fix works. Always `false` for anything that is not a bug.
    ///
    /// Carried here so a project's health does not need a second walk of the whole project just to
    /// count the fixes nobody has checked.
    public var isVerified: Bool

    public var estimateMinutes: Int?

    /// Time actually recorded against it.
    public var trackedMinutes: Int

    public var commentCount: Int

    /// Custom field values, by field name. Values live in `Item.userMetadata`, so a custom field
    /// costs no storage of its own — see `CustomFieldDefinition`.
    public var customFields: [String: MetadataValue]

    public init(
        id: UUID = UUID(),
        title: String = "",
        status: ItemStatus = .open,
        completedAt: Date? = nil,
        cancelledAt: Date? = nil,
        startAt: Date? = nil,
        deadlineAt: Date? = nil,
        reminderAt: Date? = nil,
        reminderIsTimed: Bool = false,
        reminderOwner: ReminderOwner = .none,
        todayCommittedOn: Date? = nil,
        isLaterToday: Bool = false,
        todayOrder: Double = 0,
        isSomeday: Bool = false,
        isFlagged: Bool = false,
        priority: Priority = .normal,
        waitingSince: Date? = nil,
        followUpAt: Date? = nil,
        hasHome: Bool = false,
        parentID: UUID? = nil,
        areaID: UUID? = nil,
        projectID: UUID? = nil,
        listID: UUID? = nil,
        sectionID: UUID? = nil,
        tagSlugs: [String] = [],
        relatedPersonIDs: [UUID] = [],
        waitingOnPersonID: UUID? = nil,
        hasAttachments: Bool = false,
        isRepeating: Bool = false,
        hasSubtasks: Bool = false,
        checklistTotal: Int = 0,
        checklistCompleted: Int = 0,
        source: SourceKind = .manual,
        syncState: TaskSyncState = .local,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0,
        searchText: String = "",
        kind: ItemKind = .task,
        referenceKey: String? = nil,
        workflowStageID: UUID? = nil,
        stageCategory: WorkflowStageCategory? = nil,
        boardOrder: Double = 0,
        assigneeID: UUID? = nil,
        milestoneID: UUID? = nil,
        releaseID: UUID? = nil,
        blockedByIDs: [UUID] = [],
        blocksIDs: [UUID] = [],
        isBlocked: Bool = false,
        severity: BugSeverity? = nil,
        isRegression: Bool = false,
        isVerified: Bool = false,
        estimateMinutes: Int? = nil,
        trackedMinutes: Int = 0,
        commentCount: Int = 0,
        customFields: [String: MetadataValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.completedAt = completedAt
        self.cancelledAt = cancelledAt
        self.startAt = startAt
        self.deadlineAt = deadlineAt
        self.reminderAt = reminderAt
        self.reminderIsTimed = reminderIsTimed
        self.reminderOwner = reminderOwner
        self.todayCommittedOn = todayCommittedOn
        self.isLaterToday = isLaterToday
        self.todayOrder = todayOrder
        self.isSomeday = isSomeday
        self.isFlagged = isFlagged
        self.priority = priority
        self.waitingSince = waitingSince
        self.followUpAt = followUpAt
        self.hasHome = hasHome
        self.parentID = parentID
        self.areaID = areaID
        self.projectID = projectID
        self.listID = listID
        self.sectionID = sectionID
        self.tagSlugs = tagSlugs
        self.relatedPersonIDs = relatedPersonIDs
        self.waitingOnPersonID = waitingOnPersonID
        self.hasAttachments = hasAttachments
        self.isRepeating = isRepeating
        self.hasSubtasks = hasSubtasks
        self.checklistTotal = checklistTotal
        self.checklistCompleted = checklistCompleted
        self.source = source
        self.syncState = syncState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.searchText = searchText
        self.kind = kind
        self.referenceKey = referenceKey
        self.workflowStageID = workflowStageID
        self.stageCategory = stageCategory
        self.boardOrder = boardOrder
        self.assigneeID = assigneeID
        self.milestoneID = milestoneID
        self.releaseID = releaseID
        self.blockedByIDs = blockedByIDs
        self.blocksIDs = blocksIDs
        self.isBlocked = isBlocked
        self.severity = severity
        self.isRegression = isRegression
        self.isVerified = isVerified
        self.estimateMinutes = estimateMinutes
        self.trackedMinutes = trackedMinutes
        self.commentCount = commentCount
        self.customFields = customFields
    }
}

// MARK: - Derived state

extension TaskFacts {
    /// The lifecycle state, derived. See ``TaskLifecycle`` for why it is not stored.
    ///
    /// The order of the checks is the precedence, and it is deliberate:
    /// resolved beats everything, someday beats waiting (a parked task is not blocked, it is
    /// parked), and waiting beats inbox (a task you are chasing somebody about has been processed
    /// whether or not it was ever filed).
    public var lifecycle: TaskLifecycle {
        switch status {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .none, .open: break
        }

        if isSomeday { return .someday }
        if waitingSince != nil { return .waiting }
        if !hasHome { return .inbox }
        return .active
    }

    public var isResolved: Bool { !lifecycle.isOpen }

    /// Whether the user has said they intend to do this today.
    ///
    /// A commitment made on an earlier day still counts. That is a decision rather than an
    /// oversight: a plan you did not finish is still your plan, and silently emptying Today
    /// overnight throws away the only piece of thinking the user actually did.
    public func isCommittedToToday(on day: Date, calendar: Calendar) -> Bool {
        guard let todayCommittedOn else { return false }
        return calendar.startOfDay(for: todayCommittedOn) <= calendar.startOfDay(for: day)
    }

    /// Whether the commitment was made for *this* day rather than carried forward.
    ///
    /// Later Today is a placement inside one day, so it only means anything for a commitment made
    /// today. A task carried over from last Thursday has no back-half of today to sit in.
    public func isCommittedForExactly(_ day: Date, calendar: Calendar) -> Bool {
        guard let todayCommittedOn else { return false }
        return calendar.isDate(todayCommittedOn, inSameDayAs: day)
    }

    /// When the task becomes workable, and why it might not be yet.
    public func availability(on now: Date, calendar: Calendar) -> TaskAvailability {
        if isResolved { return .resolved }
        if isSomeday { return .someday }
        if waitingSince != nil { return .waiting }

        if let startAt, calendar.startOfDay(for: startAt) > calendar.startOfDay(for: now) {
            return .scheduled(startAt)
        }
        return .available
    }

    /// How close the deadline is.
    ///
    /// - Parameter horizon: How many days ahead still counts as ``DeadlineUrgency/soon(days:)``.
    ///   Beyond it a deadline is real but not yet worth colouring.
    public func deadlineUrgency(on now: Date, calendar: Calendar, horizon: Int = 7) -> DeadlineUrgency {
        guard let deadlineAt, !isResolved else { return .none }

        let today = calendar.startOfDay(for: now)
        let due = calendar.startOfDay(for: deadlineAt)

        guard let days = calendar.dateComponents([.day], from: today, to: due).day else { return .none }

        if days < 0 { return .overdue(days: -days) }
        if days == 0 { return .today }
        if days <= horizon { return .soon(days: days) }
        return .distant
    }

    /// Subtask and checklist progress as a fraction, or `nil` when there is nothing to measure.
    ///
    /// Deliberately `nil` rather than zero for a task with no steps: a progress bar reading 0% on a
    /// task that simply has no checklist is an accusation, not information.
    public var checklistProgress: Double? {
        guard checklistTotal > 0 else { return nil }
        return Double(checklistCompleted) / Double(checklistTotal)
    }
}

// MARK: - Invariants

/// The combinations a task must never be in, and the one place they are corrected.
///
/// ### Why this is a separate type
/// Every one of these rules was reachable from more than one place — a context menu, the inspector,
/// a batch action, the reminder sync, the recurrence roll-forward. Enforcing them at each site means
/// enforcing them five times and forgetting once. This runs on every write, and the persistence
/// layer has no other sanctioned way to change a task.
///
/// It **corrects** rather than throws. A user who completes a task they were waiting on has not made
/// an error; they have made the waiting irrelevant, and the right response is to clear it, not to
/// refuse the completion.
public enum TaskInvariants {
    /// One field that had to be cleared, and why — so the interface can say so rather than appearing
    /// to lose data.
    public struct Correction: Sendable, Hashable {
        public var field: String
        public var reason: String

        public init(field: String, reason: String) {
            self.field = field
            self.reason = reason
        }
    }

    /// Brings a task's marks into agreement with each other.
    ///
    /// Returns what it changed. An empty result is the ordinary case.
    @discardableResult
    public static func normalise(_ facts: inout TaskFacts) -> [Correction] {
        var corrections: [Correction] = []

        // A finished task is not waiting on anybody, is not parked, and is not on anybody's plan for
        // today. All three are statements about *pending* work.
        if !facts.lifecycle.isOpen || facts.status == .completed || facts.status == .cancelled {
            if facts.waitingSince != nil {
                facts.waitingSince = nil
                facts.waitingOnPersonID = nil
                facts.followUpAt = nil
                corrections.append(
                    Correction(field: "waiting", reason: "A finished task is not waiting on anybody.")
                )
            }
            if facts.isSomeday {
                facts.isSomeday = false
                corrections.append(
                    Correction(field: "someday", reason: "A finished task is no longer a maybe.")
                )
            }
            if facts.todayCommittedOn != nil || facts.isLaterToday {
                facts.todayCommittedOn = nil
                facts.isLaterToday = false
                corrections.append(
                    Correction(field: "today", reason: "A finished task leaves today's plan.")
                )
            }
        }

        // A cancelled task must not interrupt anybody. Deliberately abandoning something and then
        // being notified about it is the worst possible outcome of keeping the record.
        if facts.status == .cancelled, facts.reminderAt != nil {
            facts.reminderAt = nil
            facts.reminderOwner = .none
            corrections.append(
                Correction(field: "reminder", reason: "A canceled task does not send notifications.")
            )
        }

        // Parked and committed are opposites. Choosing one clears the other, and Someday is the
        // stronger statement because it was made later — a task is committed by a plan and parked by
        // a decision.
        if facts.isSomeday, facts.todayCommittedOn != nil || facts.isLaterToday {
            facts.todayCommittedOn = nil
            facts.isLaterToday = false
            corrections.append(
                Correction(field: "today", reason: "Someday work does not compete for today.")
            )
        }

        // Later Today is a placement inside today. On a commitment carried forward from an earlier
        // day it means nothing, and leaving it set would sort the task into a section it does not
        // belong to.
        if facts.isLaterToday, facts.todayCommittedOn == nil {
            facts.isLaterToday = false
            corrections.append(
                Correction(field: "laterToday", reason: "Later Today needs a commitment to today.")
            )
        }

        // A follow-up date without a waiting mark is a reminder wearing the wrong name.
        if facts.followUpAt != nil, facts.waitingSince == nil {
            facts.followUpAt = nil
            corrections.append(
                Correction(field: "followUp", reason: "Only a waiting task has somebody to chase.")
            )
        }

        // Completion and its date are one fact. `ItemValidator` enforces the same rule at the store
        // boundary; this keeps the value type honest before it ever gets there.
        if facts.status == .completed, facts.completedAt == nil {
            facts.completedAt = facts.updatedAt
        }
        if facts.status != .completed, facts.completedAt != nil {
            facts.completedAt = nil
        }
        if facts.status != .cancelled, facts.cancelledAt != nil {
            facts.cancelledAt = nil
        }

        // Reminder ownership is meaningless without a reminder, and a reminder nobody owns is one
        // that never fires.
        if facts.reminderAt == nil, facts.reminderOwner != .none {
            facts.reminderOwner = .none
        }
        if facts.reminderAt != nil, facts.reminderOwner == .none {
            facts.reminderOwner = .app
        }

        return corrections
    }

    /// Whether a start date and a deadline are the right way round.
    ///
    /// Reported rather than corrected: which of the two the user meant to move is not knowable from
    /// here, and guessing would silently rewrite a commitment.
    public static func datesAreOrdered(_ facts: TaskFacts) -> Bool {
        guard let startAt = facts.startAt, let deadlineAt = facts.deadlineAt else { return true }
        return startAt <= deadlineAt
    }
}
