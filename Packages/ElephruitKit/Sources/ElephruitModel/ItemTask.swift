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
        // One pass over the outgoing links, not six.
        //
        // The obvious spelling asks separately for the assignee, the milestone, the release and the
        // blockers, and each of those scans `outgoingLinks` from the start. Six scans per item, over
        // every item in the project, on every refresh — for four answers that one loop produces.
        var assigneeItem: Item?
        var milestoneItem: Item?
        var releaseItem: Item?
        var blocking: [Item] = []
        for link in outgoingLinks {
            guard let target = link.target, target.deletedAt == nil else { continue }
            switch link.kind {
            case .assignee: assigneeItem = assigneeItem ?? target
            case .targetsMilestone: milestoneItem = milestoneItem ?? target
            case .relatesToRelease: releaseItem = releaseItem ?? target
            case .blockedBy: blocking.append(target)
            default: break
            }
        }

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
            hasSubtasks: children.contains { $0.kind.isWorkItem && $0.deletedAt == nil },
            checklistTotal: checklist.total,
            checklistCompleted: checklist.completed,
            source: source.kind,
            syncState: syncState,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            searchText: searchText,
            kind: kind,
            referenceKey: referenceKey,
            workflowStageID: workflowStageID,
            stageCategory: resolvedStageCategory(within: containers.project),
            boardOrder: boardOrder,
            assigneeID: assigneeItem?.id,
            milestoneID: milestoneItem?.id,
            releaseID: releaseItem?.id,
            blockedByIDs: blocking.map(\.id),
            blocksIDs: blockedItems().map(\.id),
            isBlocked: blocking.contains { $0.status == .open || $0.status == .none },
            // A bug whose record has not been created yet reads as `.minor` rather than as nothing.
            // Passing the nil through drops it out of every severity band and files it under "Not a
            // bug", which is a judgement nobody made about a report somebody filed in good faith.
            severity: bugRecord?.severity ?? (kind == .bug ? .minor : nil),
            isRegression: bugRecord?.isRegression ?? false,
            isVerified: bugRecord?.verifiedAt != nil,
            estimateMinutes: estimateMinutes,
            trackedMinutes: trackedMinutes(),
            commentCount: comments.count,
            customFields: userMetadata
        )
    }

    /// What the board column this sits in means, resolved through the owning project.
    ///
    /// `nil` when the work is unplaced or the column has since been deleted — both of which the
    /// board shows as "Unplaced" rather than pretending to a category.
    ///
    /// Takes the project rather than walking up to find it. `taskFacts()` has already computed the
    /// enclosing containers, and walking again meant faulting the `workflowStages` relationship on
    /// every ancestor of every item — a second upward traversal per item, for an answer that was
    /// already in hand.
    public func resolvedStageCategory(within project: Item?) -> WorkflowStageCategory? {
        guard let stageID = workflowStageID, let project else { return nil }
        return project.workflowStages.first { $0.id == stageID }?.category
    }

    /// The person doing this work. At most one — see `WorkItemService.assign`.
    public func assignee() -> Item? {
        linkedTarget(kind: .assignee)
    }

    /// The single item this one points at with a link of the given kind.
    public func linkedTarget(kind: LinkKind) -> Item? {
        outgoingLinks.first { $0.kind == kind }?.target
    }

    /// What must be resolved before this can proceed.
    public func blockers() -> [Item] {
        outgoingLinks
            .filter { $0.kind == .blockedBy }
            .compactMap(\.target)
            .filter { $0.deletedAt == nil }
    }

    /// What this is holding up.
    public func blockedItems() -> [Item] {
        incomingLinks
            .filter { $0.kind == .blockedBy }
            .compactMap(\.source)
            .filter { $0.deletedAt == nil }
    }

    public func duplicateOf() -> Item? {
        linkedTarget(kind: .duplicateOf)
    }

    /// Minutes actually recorded against this item.
    public func trackedMinutes(now: Date = Date()) -> Int {
        let seconds = timeEntries.reduce(into: 0.0) { total, entry in
            total += entry.duration(at: now)
        }
        return Int(seconds / 60)
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
    ///
    /// ### And a list in somebody else's app is a home
    /// This is the fourth answer, and its absence is what flooded the Inbox.
    ///
    /// The Inbox was defined entirely by absences: no parent, no tags, no filing. A reminder brought
    /// in from Apple Reminders has all three of those absences the instant it is created — see
    /// `ReminderSyncEngine.importReminder(_:into:)`, which creates a task with no parent and files it
    /// nowhere, because there is nowhere honest to put it. So nothing *routed* imported reminders
    /// into the Inbox. They matched its definition by construction, and connecting an account with
    /// four hundred reminders in it produced four hundred rows of triage the user had already done
    /// in another app.
    ///
    /// But those reminders are filed. They are filed in the list they came from, which is the list
    /// the user ticked in Settings, and which the app is keeping them in step with. Counting that as
    /// a home is not a special case bolted onto the Inbox; it is the same sentence the other three
    /// clauses say, about a container that happens to live in another application.
    ///
    /// Both halves are required. `.systemStore` alone would catch a task somebody deliberately
    /// unlinked — that one lives only here now and has genuinely never been filed. A link alone
    /// would catch a task captured *here* and then exported to a list, which was an Inbox capture
    /// before the export and has not been processed by being copied somewhere.
    public var hasHome: Bool {
        if parent != nil || !tags.isEmpty || !filedUnderContainers().isEmpty { return true }
        return isKeptInStepWithAnExternalList && inboxedAt == nil
    }

    /// Whether this item arrived from a synchronised source and is still being kept in step with it.
    ///
    /// The pair, not either half — see ``hasHome``.
    public var isKeptInStepWithAnExternalList: Bool {
        source.kind == .systemStore && externalIdentifier != nil
    }

    /// Whether this item is an unprocessed capture: the Inbox, in one place.
    ///
    /// ### Why this is a property of the item rather than three clauses in a query
    /// Because it was three clauses in a query *and* three clauses in a count, and the count carried
    /// a comment reading "must match `ItemQuery.inbox()` exactly, or the badge and the list disagree
    /// — and a badge that says 3 over a list of 2 reads as a bug in the app, not in the query."
    /// A comment is not a mechanism. This is: both callers ask the same question of the same object,
    /// so the badge cannot say three over a list of two, and the rule can be changed once.
    public var isUnprocessedCapture: Bool {
        kind.appearsInInbox && !hasHome
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
        kind.isWorkItem
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
