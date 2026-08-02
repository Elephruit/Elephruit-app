import Foundation

/// Filters, groups and sorts work — the one engine every project view runs on.
///
/// ### Why there is only one of these
///
/// A board, a list, a table, a bug tracker, a calendar and a roadmap all answer the same three
/// questions: what is shown, how is it divided, and in what order. Written per view they drift, and
/// the drift is always in the same places — unassigned sorts to the top on the board and the bottom
/// in the table, "no milestone" is a group here and a gap there, a subtask appears twice in one view
/// and never in another. The entire promise of a project workspace is that every view shows the same
/// work; six implementations is six chances to break that promise quietly.
///
/// Pure, and taking its clock as an argument, so every date-relative decision is testable without
/// touching the machine's settings — the same contract `TaskFilter` already keeps.
public enum WorkItemArrangement {

    /// One division of the work, with everything the header needs to describe itself.
    public struct Group: Sendable, Hashable, Identifiable {
        /// Stable and derived from what the group *is* — `"stage.<uuid>"`, `"severity.major"` —
        /// never from its position. A collapsed group has to stay collapsed across a refresh, and
        /// an index would reassign itself the moment anything moved.
        public let key: String
        public let title: String
        public let symbolName: String?
        public let colorName: String?

        /// Set when this group is a board column, so a drop knows where it landed.
        public let stageID: UUID?
        public let wipLimit: Int

        public var items: [TaskFacts]

        /// Whether this is the "none of the above" group — unassigned, no milestone, no severity.
        public let isUnset: Bool

        public var id: String { key }
        public var count: Int { items.count }

        public var isOverLimit: Bool { wipLimit > 0 && items.count > wipLimit }
        public var isAtLimit: Bool { wipLimit > 0 && items.count == wipLimit }

        public init(
            key: String,
            title: String,
            symbolName: String? = nil,
            colorName: String? = nil,
            stageID: UUID? = nil,
            wipLimit: Int = 0,
            items: [TaskFacts] = [],
            isUnset: Bool = false
        ) {
            self.key = key
            self.title = title
            self.symbolName = symbolName
            self.colorName = colorName
            self.stageID = stageID
            self.wipLimit = wipLimit
            self.items = items
            self.isUnset = isUnset
        }
    }

    /// The names the arrangement cannot know on its own.
    ///
    /// Grouping by assignee needs people's names; by milestone, the milestones' titles. Passing a
    /// lookup closure rather than a dictionary keeps this pure while letting the caller resolve
    /// from whatever it already has in memory — the alternative is the arrangement reaching into
    /// the store, which `FetchAudit` forbids during a render anyway.
    public struct Vocabulary: Sendable {
        public var stages: [WorkflowStageFacts]
        public var name: @Sendable (UUID) -> String?

        public init(
            stages: [WorkflowStageFacts] = [],
            name: @escaping @Sendable (UUID) -> String? = { _ in nil }
        ) {
            self.stages = stages
            self.name = name
        }
    }

    // MARK: - Entry point

    /// Filter, then group, then sort **within** each group.
    ///
    /// The order matters: sorting the whole set first and then grouping produces groups that are
    /// each sorted correctly by accident, until the day a grouping is added whose order is not the
    /// global one.
    public static func arrange(
        _ facts: [TaskFacts],
        configuration: ProjectViewConfiguration,
        vocabulary: Vocabulary,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        let visible = filter(facts, configuration: configuration, now: now, calendar: calendar)
        let grouped = group(visible, by: configuration.grouping, vocabulary: vocabulary, calendar: calendar, now: now)
        return grouped.map { group in
            var group = group
            group.items = sort(
                group.items,
                by: configuration.sortField,
                ascending: configuration.sortAscending
            )
            return group
        }
    }

    // MARK: - Filtering

    static func filter(
        _ facts: [TaskFacts],
        configuration: ProjectViewConfiguration,
        now: Date,
        calendar: Calendar
    ) -> [TaskFacts] {
        // Built once. Asking `facts.contains { $0.id == parentID }` inside the loop makes this
        // quadratic, which is invisible on a demo project and very visible on a real one.
        let presentIDs = Set(facts.map(\.id))

        return facts.filter { item in
            guard configuration.kinds.contains(item.kind) else { return false }
            if !configuration.showsResolved, item.status == .completed || item.status == .cancelled {
                return false
            }

            // A subtask whose parent is on screen is already represented by its parent's row. One
            // whose parent was filtered out keeps its own row — otherwise filtering to "assigned to
            // me" hides my subtask because somebody else owns the parent.
            if !configuration.showsSubtasks,
               let parentID = item.parentID,
               presentIDs.contains(parentID) {
                return false
            }

            guard configuration.filter.rules.isEmpty
                || configuration.filter.matches(item, now: now, calendar: calendar)
            else { return false }

            return true
        }
    }

    // MARK: - Grouping

    static func group(
        _ facts: [TaskFacts],
        by grouping: WorkItemGrouping,
        vocabulary: Vocabulary,
        calendar: Calendar,
        now: Date
    ) -> [Group] {
        switch grouping {
        case .none:
            return [Group(key: "all", title: "", items: facts)]

        case .stage:
            return groupByStage(facts, vocabulary: vocabulary)

        case .status:
            return bucket(
                facts,
                order: [ItemStatus.open, .completed, .cancelled],
                keyed: { $0.status },
                key: { "status.\($0.rawValue)" },
                title: { $0.displayName },
                keepEmpty: false
            )

        case .priority:
            // Empty priority bands are dropped. A heading over a void is noise; a board column with
            // nothing in it is somewhere to *drop* something, which is why stages keep theirs.
            return bucket(
                facts,
                order: [Priority.high, .normal, .low],
                keyed: \.priority,
                key: { "priority.\($0.rawValue)" },
                title: { $0.displayName },
                keepEmpty: false
            )

        case .severity:
            return groupBySeverity(facts)

        case .kind:
            return bucket(
                facts,
                order: ItemKind.workItemKinds,
                keyed: \.kind,
                key: { "kind.\($0.rawValue)" },
                title: { $0.pluralDisplayName },
                symbol: { $0.symbolName },
                keepEmpty: false
            )

        case .assignee:
            return groupByIdentifier(
                facts,
                identifier: \.assigneeID,
                prefix: "assignee",
                unsetTitle: "Unassigned",
                unsetSymbol: "person.crop.circle.badge.questionmark",
                unsetFirst: true,
                vocabulary: vocabulary
            )

        case .milestone:
            return groupByIdentifier(
                facts,
                identifier: \.milestoneID,
                prefix: "milestone",
                unsetTitle: "No milestone",
                unsetSymbol: "flag.slash",
                unsetFirst: false,
                vocabulary: vocabulary
            )

        case .release:
            return groupByIdentifier(
                facts,
                identifier: \.releaseID,
                prefix: "release",
                unsetTitle: "No release",
                unsetSymbol: "shippingbox",
                unsetFirst: false,
                vocabulary: vocabulary
            )

        case .heading:
            return groupByIdentifier(
                facts,
                identifier: \.sectionID,
                prefix: "heading",
                unsetTitle: "No section",
                unsetSymbol: "text.append",
                unsetFirst: false,
                vocabulary: vocabulary
            )

        case .dueDate:
            return groupByDueDate(facts, calendar: calendar, now: now)

        case .tag:
            return groupByTag(facts)
        }
    }

    /// Board columns. **Empty ones are kept.**
    ///
    /// A column with nothing in it is not an empty heading — it is the place you are reaching for
    /// when you drag. Dropping it means the board rearranges itself under the cursor.
    private static func groupByStage(_ facts: [TaskFacts], vocabulary: Vocabulary) -> [Group] {
        var byStage: [UUID: [TaskFacts]] = [:]
        var unplaced: [TaskFacts] = []
        for item in facts {
            // Lifecycle wins visually when work is resolved outside the board. Completing a card
            // from its menu changes the status, not the independent workflow stage; grouping only
            // by the stored stage would therefore leave a completed card sitting in “In progress”.
            // Keep that working stage stored so reopening can return the card to it, but project the
            // resolved card into the board's matching terminal column in the meantime.
            let terminalCategory: WorkflowStageCategory? = switch item.status {
            case .completed: .done
            case .cancelled: .cancelled
            case .none, .open: nil
            }
            let stageID = terminalCategory.flatMap { category in
                vocabulary.stages
                    .filter { $0.category == category }
                    .min { $0.sortOrder < $1.sortOrder }?
                    .id
            } ?? item.workflowStageID

            if let stageID, vocabulary.stages.contains(where: { $0.id == stageID }) {
                byStage[stageID, default: []].append(item)
            } else {
                unplaced.append(item)
            }
        }

        var groups = vocabulary.stages.sorted { $0.sortOrder < $1.sortOrder }.map { stage in
            Group(
                key: "stage.\(stage.id.uuidString)",
                title: stage.name,
                symbolName: stage.category.symbolName,
                colorName: stage.colorName,
                stageID: stage.id,
                wipLimit: stage.wipLimit,
                items: byStage[stage.id] ?? []
            )
        }

        // Work that belongs to no column gets one, at the front, so it is not silently absent from
        // the only view that claims to show everything.
        if !unplaced.isEmpty {
            groups.insert(
                Group(
                    key: "stage.none",
                    title: "Unplaced",
                    symbolName: "tray",
                    items: unplaced,
                    isUnset: true
                ),
                at: 0
            )
        }
        return groups
    }

    /// Severity bands. Only bugs have one, so everything else lands in a band named for what it is
    /// — **"Not a bug"**, never "Not a defect", which reads as a judgement nobody made.
    private static func groupBySeverity(_ facts: [TaskFacts]) -> [Group] {
        var groups: [Group] = []
        for severity in BugSeverity.allCases.sorted() {
            let items = facts.filter { $0.severity == severity }
            guard !items.isEmpty else { continue }
            groups.append(
                Group(
                    key: "severity.\(severity.rawValue)",
                    title: severity.displayName,
                    symbolName: severity.symbolName,
                    colorName: severity.colorName,
                    items: items
                )
            )
        }
        let unset = facts.filter { $0.severity == nil }
        if !unset.isEmpty {
            groups.append(
                Group(
                    key: "severity.none",
                    title: "Not a bug",
                    symbolName: "checkmark.circle",
                    items: unset,
                    isUnset: true
                )
            )
        }
        return groups
    }

    /// Grouping by something that points at another item or person.
    ///
    /// `unsetFirst` is the whole reason this is one function taking a flag rather than three copies.
    /// **Unassigned sorts first** — work nobody has taken is the most urgent thing on a board
    /// grouped by person. **No milestone sorts last** — a milestone residue is not a queue, it is
    /// what is left over.
    private static func groupByIdentifier(
        _ facts: [TaskFacts],
        identifier: KeyPath<TaskFacts, UUID?>,
        prefix: String,
        unsetTitle: String,
        unsetSymbol: String,
        unsetFirst: Bool,
        vocabulary: Vocabulary
    ) -> [Group] {
        var byID: [UUID: [TaskFacts]] = [:]
        var unset: [TaskFacts] = []
        for item in facts {
            if let id = item[keyPath: identifier] {
                byID[id, default: []].append(item)
            } else {
                unset.append(item)
            }
        }

        var groups = byID
            .map { id, items in
                Group(
                    key: "\(prefix).\(id.uuidString)",
                    title: vocabulary.name(id) ?? "Unknown",
                    items: items
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        guard !unset.isEmpty else { return groups }
        let unsetGroup = Group(
            key: "\(prefix).none",
            title: unsetTitle,
            symbolName: unsetSymbol,
            items: unset,
            isUnset: true
        )
        if unsetFirst { groups.insert(unsetGroup, at: 0) } else { groups.append(unsetGroup) }
        return groups
    }

    private static func groupByDueDate(_ facts: [TaskFacts], calendar: Calendar, now: Date) -> [Group] {
        let today = calendar.startOfDay(for: now)

        func bandIndex(_ facts: TaskFacts) -> Int {
            guard let due = facts.deadlineAt else { return 5 }
            let day = calendar.startOfDay(for: due)
            guard let delta = calendar.dateComponents([.day], from: today, to: day).day else { return 5 }
            if delta < 0 { return 0 }
            if delta == 0 { return 1 }
            if delta <= 7 { return 2 }
            if delta <= 30 { return 3 }
            return 4
        }

        let titles = ["Overdue", "Today", "This week", "This month", "Later", "No date"]
        let symbols = [
            "exclamationmark.triangle", "sun.max", "calendar", "calendar.badge.clock",
            "calendar.badge.plus", "calendar.badge.minus",
        ]
        let colors: [String?] = ["red", "orange", nil, nil, nil, nil]

        var buckets: [[TaskFacts]] = Array(repeating: [], count: titles.count)
        for item in facts { buckets[bandIndex(item)].append(item) }

        return zip(buckets.indices, buckets).compactMap { index, items in
            guard !items.isEmpty else { return nil }
            return Group(
                key: "due.\(index)",
                title: titles[index],
                symbolName: symbols[index],
                colorName: colors[index],
                items: items,
                isUnset: index == titles.count - 1
            )
        }
    }

    /// Grouping by tag, where **one item legitimately appears in several groups**.
    ///
    /// The only grouping that does. A tag is not a partition — that is what makes tags useful — so
    /// the counts across groups deliberately sum to more than the number of items, and anything
    /// reading a total has to count distinct identifiers rather than adding the groups up.
    private static func groupByTag(_ facts: [TaskFacts]) -> [Group] {
        var byTag: [String: [TaskFacts]] = [:]
        var untagged: [TaskFacts] = []
        for item in facts {
            if item.tagSlugs.isEmpty {
                untagged.append(item)
            } else {
                for slug in item.tagSlugs { byTag[slug, default: []].append(item) }
            }
        }

        var groups = byTag
            .map { slug, items in
                Group(key: "tag.\(slug)", title: "#\(slug)", symbolName: "number", items: items)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        if !untagged.isEmpty {
            groups.append(
                Group(key: "tag.none", title: "Untagged", symbolName: "number", items: untagged, isUnset: true)
            )
        }
        return groups
    }

    /// The generic path for grouping by a small closed enum.
    private static func bucket<Value: Hashable>(
        _ facts: [TaskFacts],
        order: [Value],
        keyed: (TaskFacts) -> Value,
        key: (Value) -> String,
        title: (Value) -> String,
        symbol: ((Value) -> String)? = nil,
        keepEmpty: Bool
    ) -> [Group] {
        var byValue: [Value: [TaskFacts]] = [:]
        for item in facts { byValue[keyed(item), default: []].append(item) }

        return order.compactMap { value in
            let items = byValue[value] ?? []
            guard keepEmpty || !items.isEmpty else { return nil }
            return Group(
                key: key(value),
                title: title(value),
                symbolName: symbol?(value),
                items: items
            )
        }
    }

    // MARK: - Sorting

    static func sort(
        _ facts: [TaskFacts],
        by field: WorkItemSortField,
        ascending: Bool
    ) -> [TaskFacts] {
        // Optional dates are handled apart from the comparator because "no date" is not a very
        // early date or a very late one — it is an absence, and it belongs at the end whichever way
        // the arrow points. Folding it into the comparison makes reversing the sort move every
        // undated item from the bottom to the top, which nobody has ever wanted.
        switch field {
        case .dueDate:
            return sortByOptionalDate(facts, \.deadlineAt, ascending: ascending)
        case .startDate:
            return sortByOptionalDate(facts, \.startAt, ascending: ascending)
        default:
            break
        }

        let sorted = facts.sorted { lhs, rhs in
            switch field {
            case .manual:
                // Board position first, then position within the project. One order per axis, and
                // the board's wins because the board is what you dragged it in.
                if lhs.boardOrder != rhs.boardOrder { return lhs.boardOrder < rhs.boardOrder }
                return lhs.sortOrder < rhs.sortOrder
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .reference:
                return WorkItemReference.sortKey(lhs.referenceKey)
                    < WorkItemReference.sortKey(rhs.referenceKey)
            case .priority:
                // Comparable puts low first; a priority sort means most important first.
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.sortOrder < rhs.sortOrder
            case .severity:
                switch (lhs.severity, rhs.severity) {
                case let (l?, r?): return l == r ? lhs.sortOrder < rhs.sortOrder : l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.sortOrder < rhs.sortOrder
                }
            case .createdAt:
                return lhs.createdAt < rhs.createdAt
            case .updatedAt:
                return lhs.updatedAt < rhs.updatedAt
            case .estimate:
                return (lhs.estimateMinutes ?? Int.max) < (rhs.estimateMinutes ?? Int.max)
            case .dueDate, .startDate:
                return false  // handled above
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private static func sortByOptionalDate(
        _ facts: [TaskFacts],
        _ date: KeyPath<TaskFacts, Date?>,
        ascending: Bool
    ) -> [TaskFacts] {
        let dated = facts.filter { $0[keyPath: date] != nil }
            .sorted { ($0[keyPath: date] ?? .distantPast) < ($1[keyPath: date] ?? .distantPast) }
        let undated = facts.filter { $0[keyPath: date] == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        return (ascending ? dated : dated.reversed()) + undated
    }
}
