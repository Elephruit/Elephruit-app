import Foundation
import Testing

@testable import ElephruitCore

@Suite("Work item arrangement")
struct WorkItemArrangementTests {

    // MARK: Fixtures

    static let backlogID = UUID()
    static let activeID = UUID()
    static let doneID = UUID()
    static let samID = UUID()
    static let rowanID = UUID()
    static let betaID = UUID()

    static var stages: [WorkflowStageFacts] {
        [
            WorkflowStageFacts(id: backlogID, name: "Triage", category: .backlog, sortOrder: 0),
            WorkflowStageFacts(id: activeID, name: "In progress", category: .active, sortOrder: 1, wipLimit: 2),
            WorkflowStageFacts(id: doneID, name: "Done", category: .done, sortOrder: 2),
        ]
    }

    static var vocabulary: WorkItemArrangement.Vocabulary {
        let names: [UUID: String] = [samID: "Sam", rowanID: "Rowan", betaID: "Beta"]
        return WorkItemArrangement.Vocabulary(stages: stages) { names[$0] }
    }

    static func work(
        _ title: String,
        kind: ItemKind = .feature,
        status: ItemStatus = .open,
        stage: UUID? = nil,
        category: WorkflowStageCategory? = nil,
        assignee: UUID? = nil,
        severity: BugSeverity? = nil,
        priority: Priority = .normal,
        due: Date? = nil,
        reference: String? = nil,
        order: Double = 0,
        boardOrder: Double = 0,
        parent: UUID? = nil,
        tags: [String] = [],
        id: UUID = UUID()
    ) -> TaskFacts {
        TaskFacts(
            id: id,
            title: title,
            status: status,
            deadlineAt: due,
            priority: priority,
            parentID: parent,
            tagSlugs: tags,
            sortOrder: order,
            kind: kind,
            referenceKey: reference,
            workflowStageID: stage,
            stageCategory: category,
            boardOrder: boardOrder,
            assigneeID: assignee,
            severity: severity
        )
    }

    /// Every group's items, flattened.
    static func allItems(_ groups: [WorkItemArrangement.Group]) -> [TaskFacts] {
        groups.flatMap(\.items)
    }

    // MARK: Totality

    @Test("Grouping never loses or invents work")
    func groupingIsTotal() {
        // The invariant the whole workspace rests on. Every view claims to show the same work; if a
        // grouping can drop an item, one view quietly disagrees with the others and nobody finds
        // out until something important is missing.
        let items = [
            Self.work("A", stage: Self.backlogID, assignee: Self.samID, severity: .major),
            Self.work("B", kind: .bug, severity: .critical),
            Self.work("C", assignee: Self.rowanID, due: .now),
            Self.work("D", priority: .high, tags: ["urgent"]),
            Self.work("E"),
        ]

        for grouping in WorkItemGrouping.allCases {
            // Tags are the one grouping that legitimately multiplies an item into several groups,
            // so it is counted distinctly rather than added up.
            var configuration = ProjectViewConfiguration.default(for: .list)
            configuration.grouping = grouping
            configuration.showsResolved = true

            let groups = WorkItemArrangement.arrange(
                items,
                configuration: configuration,
                vocabulary: Self.vocabulary
            )
            let seen = Set(Self.allItems(groups).map(\.id))
            #expect(seen == Set(items.map(\.id)), "\(grouping) lost or invented work")
        }
    }

    // MARK: Stages

    @Test("An empty board column is still drawn")
    func emptyColumnsSurvive() {
        // A column with nothing in it is where you are reaching to drop something. Dropping it
        // means the board rearranges under the cursor.
        let configuration = ProjectViewConfiguration.default(for: .board)
        let groups = WorkItemArrangement.arrange(
            [Self.work("A", stage: Self.backlogID)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.count == 3)
        #expect(groups.map(\.title) == ["Triage", "In progress", "Done"])
    }

    @Test("An empty priority band is not drawn")
    func emptyPriorityBandsDropped() {
        // A heading over a void is noise. The asymmetry with columns is deliberate.
        var configuration = ProjectViewConfiguration.default(for: .list)
        configuration.grouping = .priority
        let groups = WorkItemArrangement.arrange(
            [Self.work("A", priority: .high)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.count == 1)
        #expect(groups.first?.title == "High")
    }

    @Test("Work in no column gets a column of its own, at the front")
    func unplacedWorkIsVisible() {
        var configuration = ProjectViewConfiguration.default(for: .board)
        configuration.grouping = .stage
        let groups = WorkItemArrangement.arrange(
            [Self.work("Homeless"), Self.work("Placed", stage: Self.activeID)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.first?.isUnset == true)
        #expect(groups.first?.title == "Unplaced")
    }

    @Test("A column reports being over its limit")
    func wipLimitReported() {
        var configuration = ProjectViewConfiguration.default(for: .board)
        configuration.grouping = .stage
        let items = (1...3).map { Self.work("W\($0)", stage: Self.activeID) }
        let groups = WorkItemArrangement.arrange(
            items,
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        let active = groups.first { $0.stageID == Self.activeID }
        #expect(active?.isOverLimit == true)

        // And a column with no limit never reports one, however full.
        let triage = groups.first { $0.stageID == Self.backlogID }
        #expect(triage?.isOverLimit == false)
    }

    // MARK: Unset groups, and where they sort

    @Test("Unassigned sorts first; no milestone sorts last")
    func unsetGroupPlacement() {
        // Work nobody has taken is the most important group on a board grouped by person. A
        // milestone residue is not a queue — it is what is left over.
        var byAssignee = ProjectViewConfiguration.default(for: .list)
        byAssignee.grouping = .assignee
        let assigned = WorkItemArrangement.arrange(
            [Self.work("Taken", assignee: Self.samID), Self.work("Loose")],
            configuration: byAssignee,
            vocabulary: Self.vocabulary
        )
        #expect(assigned.first?.isUnset == true)
        #expect(assigned.first?.title == "Unassigned")

        var byMilestone = ProjectViewConfiguration.default(for: .list)
        byMilestone.grouping = .milestone
        let aimed = WorkItemArrangement.arrange(
            [Self.work("Loose"), Self.work("Aimed")],
            configuration: byMilestone,
            vocabulary: Self.vocabulary
        )
        #expect(aimed.last?.isUnset == true)
        #expect(aimed.last?.title == "No milestone")
    }

    @Test("Work with no severity is grouped as “Not a bug”")
    func severityUnsetWording() {
        // Never "Not a defect", which reads as a judgement somebody made about a report they filed
        // in good faith.
        var configuration = ProjectViewConfiguration.default(for: .bugs)
        configuration.kinds = ItemKind.workItemKindSet
        let groups = WorkItemArrangement.arrange(
            [Self.work("Plain feature"), Self.work("Crash", kind: .bug, severity: .critical)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.map(\.title) == ["Critical", "Not a bug"])
    }

    @Test("Severity groups run most severe first")
    func severityOrder() {
        let configuration = ProjectViewConfiguration.default(for: .bugs)
        let items: [TaskFacts] = [
            Self.work("d", kind: .bug, severity: .cosmetic),
            Self.work("a", kind: .bug, severity: .critical),
            Self.work("c", kind: .bug, severity: .minor),
            Self.work("b", kind: .bug, severity: .major),
        ]
        let groups = WorkItemArrangement.arrange(
            items,
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.map(\.title) == ["Critical", "Major", "Minor", "Cosmetic"])
    }

    // MARK: Subtasks

    @Test("A subtask hides under a visible parent and surfaces without one")
    func subtaskVisibility() {
        // Otherwise filtering to "assigned to me" hides my subtask because somebody else owns its
        // parent — the item vanishes from a list that claims to hold everything of mine.
        let parentID = UUID()
        let parent = Self.work("Parent", id: parentID)
        let child = Self.work("Child", parent: parentID)

        var configuration = ProjectViewConfiguration.default(for: .list)
        configuration.grouping = .none
        configuration.showsSubtasks = false

        let withParent = WorkItemArrangement.arrange(
            [parent, child],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(Self.allItems(withParent).map(\.title) == ["Parent"])

        let orphaned = WorkItemArrangement.arrange(
            [child],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(Self.allItems(orphaned).map(\.title) == ["Child"])
    }

    // MARK: Sorting

    @Test("No deadline sorts last whichever way the arrow points")
    func undatedAlwaysLast() {
        // "No date" is not a very early date and not a very late one. Folding it into the
        // comparison makes reversing the sort march every undated item to the top.
        var configuration = ProjectViewConfiguration.default(for: .list)
        configuration.grouping = .none
        configuration.sortField = .dueDate

        let items = [
            Self.work("None"),
            Self.work("Late", due: Date(timeIntervalSince1970: 2_000_000)),
            Self.work("Early", due: Date(timeIntervalSince1970: 1_000_000)),
        ]

        configuration.sortAscending = true
        let up = Self.allItems(
            WorkItemArrangement.arrange(items, configuration: configuration, vocabulary: Self.vocabulary)
        )
        #expect(up.map(\.title) == ["Early", "Late", "None"])

        configuration.sortAscending = false
        let down = Self.allItems(
            WorkItemArrangement.arrange(items, configuration: configuration, vocabulary: Self.vocabulary)
        )
        #expect(down.map(\.title) == ["Late", "Early", "None"])
    }

    @Test("References sort numerically, not as text")
    func referenceSorting() {
        var configuration = ProjectViewConfiguration.default(for: .table)
        configuration.grouping = .none
        configuration.sortField = .reference

        let items = [
            Self.work("ten", reference: "ELE-10"),
            Self.work("nine", reference: "ELE-9"),
            Self.work("one", reference: "ELE-1"),
        ]
        let sorted = Self.allItems(
            WorkItemArrangement.arrange(items, configuration: configuration, vocabulary: Self.vocabulary)
        )
        #expect(sorted.map(\.title) == ["one", "nine", "ten"])
    }

    @Test("A priority sort puts the most important first")
    func prioritySorting() {
        var configuration = ProjectViewConfiguration.default(for: .list)
        configuration.grouping = .none
        configuration.sortField = .priority

        let items = [Self.work("low", priority: .low), Self.work("high", priority: .high)]
        let sorted = Self.allItems(
            WorkItemArrangement.arrange(items, configuration: configuration, vocabulary: Self.vocabulary)
        )
        #expect(sorted.first?.title == "high")
    }

    @Test("Manual order follows the board first, then the project")
    func manualSorting() {
        var configuration = ProjectViewConfiguration.default(for: .board)
        configuration.grouping = .none
        configuration.sortField = .manual

        let items = [
            Self.work("second", order: 0, boardOrder: 2),
            Self.work("first", order: 9, boardOrder: 1),
        ]
        let sorted = Self.allItems(
            WorkItemArrangement.arrange(items, configuration: configuration, vocabulary: Self.vocabulary)
        )
        #expect(sorted.map(\.title) == ["first", "second"])
    }

    // MARK: Group keys

    @Test("Group keys describe the group, not its position")
    func stableGroupKeys() {
        // A collapsed group has to stay collapsed across a refresh, and an index would reassign
        // itself the moment anything moved.
        var configuration = ProjectViewConfiguration.default(for: .board)
        configuration.grouping = .stage

        let sparse = WorkItemArrangement.arrange(
            [Self.work("A", stage: Self.doneID)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        let full = WorkItemArrangement.arrange(
            [Self.work("A", stage: Self.doneID), Self.work("B", stage: Self.backlogID)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )

        let doneKey = "stage.\(Self.doneID.uuidString)"
        #expect(sparse.contains { $0.key == doneKey })
        #expect(full.contains { $0.key == doneKey })
    }

    @Test("Resolving work outside the board moves its card to a terminal column")
    func resolvedWorkUsesTerminalColumn() throws {
        let configuration = ProjectViewConfiguration.default(for: .board)
        let completed = Self.work(
            "Fixed bug",
            kind: .bug,
            status: .completed,
            stage: Self.backlogID
        )

        let groups = WorkItemArrangement.arrange(
            [completed],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )

        let done = try #require(groups.first { $0.stageID == Self.doneID })
        #expect(done.items.map(\.id) == [completed.id])
        #expect(groups.first { $0.stageID == Self.backlogID }?.items.isEmpty == true)
    }

    // MARK: Filtering

    @Test("Resolved work is hidden unless the view asks for it")
    func resolvedVisibility() {
        // A board shows it — the Done column is most of the point. A list does not, because a list
        // of everything ever finished is not a working list.
        let items = [Self.work("Open"), Self.work("Done", status: .completed)]

        var list = ProjectViewConfiguration.default(for: .list)
        list.grouping = .none
        #expect(Self.allItems(
            WorkItemArrangement.arrange(items, configuration: list, vocabulary: Self.vocabulary)
        ).count == 1)

        var board = ProjectViewConfiguration.default(for: .board)
        board.grouping = .none
        #expect(Self.allItems(
            WorkItemArrangement.arrange(items, configuration: board, vocabulary: Self.vocabulary)
        ).count == 2)
    }

    @Test("A bug view shows only bugs")
    func bugViewScope() {
        let configuration = ProjectViewConfiguration.default(for: .bugs)
        let groups = WorkItemArrangement.arrange(
            [Self.work("Task"), Self.work("Bug", kind: .bug, severity: .minor)],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(Self.allItems(groups).map(\.title) == ["Bug"])
    }

    @Test("One item lands in several tag groups, and only tags do that")
    func tagsMultiply() {
        // A tag is not a partition — that is what makes tags useful — so group counts deliberately
        // sum to more than the number of items, and anything reading a total counts distinct ids.
        var configuration = ProjectViewConfiguration.default(for: .list)
        configuration.grouping = .tag

        let groups = WorkItemArrangement.arrange(
            [Self.work("Both", tags: ["a", "b"])],
            configuration: configuration,
            vocabulary: Self.vocabulary
        )
        #expect(groups.count == 2)
        #expect(Self.allItems(groups).count == 2)
        #expect(Set(Self.allItems(groups).map(\.id)).count == 1)
    }
}
