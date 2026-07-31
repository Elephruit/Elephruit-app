import ElephruitCore
import Foundation

// MARK: - Typed accessors

extension Item {
    /// Who delivers this item's notification.
    public var reminderOwner: ReminderOwner {
        get { ReminderOwner(rawValue: reminderOwnerRaw) ?? .none }
        set { reminderOwnerRaw = newValue.rawValue }
    }

    /// Whether this item is in step with a linked system reminder.
    public var syncState: TaskSyncState {
        get { TaskSyncState(rawValue: syncStateRaw) ?? .local }
        set { syncStateRaw = newValue.rawValue }
    }

    /// The steps inside this single action. Never subtasks — see ``ChecklistItem``.
    public var checklist: TaskChecklist {
        get { TaskChecklist.decode(from: checklistData) }
        set { checklistData = newValue.encoded() }
    }

    /// Why a migrated date is worth a second look, if it is.
    public var dateReview: DateReviewReason? {
        get { dateReviewRaw.flatMap(DateReviewReason.init(rawValue:)) }
        set { dateReviewRaw = newValue?.rawValue }
    }

    /// What was recorded at the last successful reconciliation with a system reminder.
    ///
    /// `nil` unless all five parts are present. A half-written link is not a link, and treating one
    /// as though it were is how a sync pass ends up comparing against a fingerprint it never took.
    public var reminderLink: ReminderLinkState? {
        guard let externalIdentifier,
              let externalListIdentifier,
              let externalFingerprint,
              let externalSyncedAt,
              let externalLocalStamp
        else { return nil }

        return ReminderLinkState(
            externalID: externalIdentifier,
            listID: externalListIdentifier,
            lastSyncedFingerprint: externalFingerprint,
            lastSyncedAt: externalSyncedAt,
            lastSyncedLocalStamp: externalLocalStamp
        )
    }

    /// Records a reconciliation, or clears the link when passed `nil`.
    public func setReminderLink(_ link: ReminderLinkState?) {
        externalIdentifier = link?.externalID
        externalListIdentifier = link?.listID
        externalFingerprint = link?.lastSyncedFingerprint
        externalSyncedAt = link?.lastSyncedAt
        externalLocalStamp = link?.lastSyncedLocalStamp
        if link == nil, syncState != .local { syncState = .local }
    }
}

// MARK: - The scheduling projection

extension Item {
    /// Everything the scheduling rules need, as a `Sendable` value.
    ///
    /// ### Why the traversals happen here
    /// Three of these fields cannot be read off a column: whether the item has a home, which
    /// containers it sits under, and who it is waiting on. Computing them here — once, on the actor
    /// that owns the object — is what lets every rule in `ElephruitCore` be a pure function that
    /// never touches a relationship. The alternative was passing `Item` into the rules, and then
    /// every predicate in Today would be a fault-in while a list was drawing.
    public func taskFacts() -> TaskFacts {
        let containers = enclosingContainers()

        return TaskFacts(
            id: id,
            title: title,
            status: status,
            completedAt: completedAt,
            cancelledAt: cancelledAt,
            startAt: availableFrom,
            deadlineAt: dueAt,
            reminderAt: reminderAt,
            reminderIsTimed: reminderIsTimed,
            reminderOwner: reminderOwner,
            todayCommittedOn: todayCommittedOn,
            isLaterToday: isLaterToday,
            todayOrder: todayOrder,
            isSomeday: isSomeday,
            isFlagged: isFlagged,
            priority: priority,
            waitingSince: waitingSince,
            followUpAt: followUpAt,
            hasHome: hasHome,
            parentID: parent?.id,
            areaID: containers.area?.id,
            projectID: containers.project?.id,
            listID: containers.list?.id,
            sectionID: containers.section?.id,
            tagSlugs: tagSlugs,
            relatedPersonIDs: linkedPeople(kinds: [.mentions, .participant, .related, .promisedTo]).map(\.id),
            waitingOnPersonID: waitingOnPerson()?.id,
            hasAttachments: !attachments.isEmpty,
            isRepeating: recurrenceData != nil,
            hasSubtasks: children.contains { $0.kind == .task && $0.deletedAt == nil },
            checklistTotal: checklist.total,
            checklistCompleted: checklist.completed,
            source: source.kind,
            syncState: syncState,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            searchText: searchText
        )
    }

    /// When this item becomes actionable.
    ///
    /// ### Why two columns produce one answer
    /// `deferUntil` predates the scheduling model and means exactly what `startAt` now means:
    /// *hidden until this date*. The migration folds one into the other, and this accessor is what
    /// keeps a library that has not been migrated yet — an archive being imported, a store opened by
    /// an older build and handed back — reading correctly in the meantime. `startAt` wins where both
    /// exist, because the migration is what put it there.
    ///
    /// Nothing writes `deferUntil` any more. See `TaskDateMigration`.
    public var availableFrom: Date? {
        startAt ?? deferUntil
    }

    /// Whether this item has been filed anywhere at all.
    ///
    /// A home is a container, a filing, or a tag — any one of the three. The Inbox means
    /// *unprocessed*, not *unparented*, which is why a tagged capture leaves it.
    public var hasHome: Bool {
        parent != nil || !tags.isEmpty || !filedUnderContainers().isEmpty
    }

    /// The containers above this item, each identified by what it is rather than by how far up it
    /// sits.
    ///
    /// One walk producing four answers, because a task in a section of a project in an area needs
    /// all of them and walking four times is four times the fault-ins.
    public func enclosingContainers() -> (area: Item?, project: Item?, list: Item?, section: Item?) {
        var area: Item?
        var project: Item?
        var list: Item?
        var section: Item?

        for ancestor in ancestors() {
            switch ancestor.kind {
            case .area where area == nil: area = ancestor
            case .project where project == nil: project = ancestor
            case .list where list == nil: list = ancestor
            case .heading where section == nil: section = ancestor
            default: break
            }
        }

        return (area, project, list, section)
    }

    /// People this item points at, by the kinds of link named.
    public func linkedPeople(kinds: Set<LinkKind>) -> [Item] {
        outgoingLinks
            .filter { kinds.contains($0.kind) }
            .compactMap(\.target)
            .filter { $0.kind == .person && $0.deletedAt == nil }
    }

    /// The person this task is waiting on, if any.
    public func waitingOnPerson() -> Item? {
        linkedPeople(kinds: [.waitingOn]).first
    }

    /// Whether this item is one the task system manages.
    public var isTaskLike: Bool {
        kind == .task
    }
}

// MARK: - Series

extension Item {
    /// Occurrences of the same repeating series, newest first.
    ///
    /// Found by the shared ``seriesID`` rather than by walking a chain of links: a chain has to be
    /// traversed from one end, and the interesting question — "when did I last do this?" — is asked
    /// from the middle.
    public static func seriesPredicateID(for item: Item) -> UUID? {
        item.seriesID
    }

    /// Whether this row is the live occurrence of its series rather than a logged one.
    public var isLiveOccurrence: Bool {
        seriesID != nil && !status.isResolved
    }
}
