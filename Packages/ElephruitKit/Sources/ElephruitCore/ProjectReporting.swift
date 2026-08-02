import Foundation

/// How a project is doing, in the figures worth showing at the top of it.
///
/// Every optional here means "not enough information to say", never zero. That distinction is the
/// whole discipline of this file: a report that answers confidently from three data points is worse
/// than one that says it does not know, because the confident answer gets acted on.
public struct ProjectHealth: Sendable, Hashable {
    public var totalWork: Int
    public var completedWork: Int
    public var openWork: Int
    public var blockedWork: Int
    public var overdueWork: Int
    public var unassignedWork: Int
    public var openBugs: Int
    public var criticalBugs: Int
    public var bugsAwaitingVerification: Int
    public var stagesOverLimit: [String]
    public var nextDeadline: Date?

    public init(
        totalWork: Int = 0,
        completedWork: Int = 0,
        openWork: Int = 0,
        blockedWork: Int = 0,
        overdueWork: Int = 0,
        unassignedWork: Int = 0,
        openBugs: Int = 0,
        criticalBugs: Int = 0,
        bugsAwaitingVerification: Int = 0,
        stagesOverLimit: [String] = [],
        nextDeadline: Date? = nil
    ) {
        self.totalWork = totalWork
        self.completedWork = completedWork
        self.openWork = openWork
        self.blockedWork = blockedWork
        self.overdueWork = overdueWork
        self.unassignedWork = unassignedWork
        self.openBugs = openBugs
        self.criticalBugs = criticalBugs
        self.bugsAwaitingVerification = bugsAwaitingVerification
        self.stagesOverLimit = stagesOverLimit
        self.nextDeadline = nextDeadline
    }

    /// How much is done, or `nil` for a project with no work in it.
    ///
    /// **`nil`, not zero.** An empty project is not 0% finished — there is nothing to be finished —
    /// and a progress bar sitting at the far left is a statement about a project that has not made
    /// one yet.
    public var completionFraction: Double? {
        guard totalWork > 0 else { return nil }
        return Double(completedWork) / Double(totalWork)
    }

    /// Something worth saying out loud on the overview.
    public struct Concern: Sendable, Hashable, Identifiable {
        public var id: String
        public var sentence: String
        public var symbolName: String
        public var isUrgent: Bool

        public init(id: String, sentence: String, symbolName: String, isUrgent: Bool) {
            self.id = id
            self.sentence = sentence
            self.symbolName = symbolName
            self.isUrgent = isUrgent
        }
    }

    /// The concerns, in the order they deserve attention.
    ///
    /// Sentences rather than counts, and only when non-zero. A dashboard of eleven figures where
    /// eight read zero is a dashboard people stop looking at; three sentences about the things that
    /// are actually true get read.
    public var concerns: [Concern] {
        var result: [Concern] = []

        if criticalBugs > 0 {
            result.append(Concern(
                id: "critical",
                sentence: criticalBugs == 1
                    ? "One critical bug is open"
                    : "\(criticalBugs) critical bugs are open",
                symbolName: "exclamationmark.octagon.fill",
                isUrgent: true
            ))
        }
        if overdueWork > 0 {
            result.append(Concern(
                id: "overdue",
                sentence: overdueWork == 1
                    ? "One item is past its deadline"
                    : "\(overdueWork) items are past their deadline",
                symbolName: "exclamationmark.triangle.fill",
                isUrgent: true
            ))
        }
        if blockedWork > 0 {
            result.append(Concern(
                id: "blocked",
                sentence: blockedWork == 1
                    ? "One item is waiting on something else"
                    : "\(blockedWork) items are waiting on something else",
                symbolName: "hand.raised.fill",
                isUrgent: false
            ))
        }
        if !stagesOverLimit.isEmpty {
            let names = stagesOverLimit.formatted(.list(type: .and))
            result.append(Concern(
                id: "wip",
                sentence: "\(names) \(stagesOverLimit.count == 1 ? "is" : "are") over the limit",
                symbolName: "arrow.up.and.down.square",
                isUrgent: false
            ))
        }
        if bugsAwaitingVerification > 0 {
            result.append(Concern(
                id: "verify",
                sentence: bugsAwaitingVerification == 1
                    ? "One fix is waiting to be checked"
                    : "\(bugsAwaitingVerification) fixes are waiting to be checked",
                symbolName: "checkmark.seal",
                isUrgent: false
            ))
        }
        if unassignedWork > 0 {
            result.append(Concern(
                id: "unassigned",
                sentence: unassignedWork == 1
                    ? "One item has nobody on it"
                    : "\(unassignedWork) items have nobody on them",
                symbolName: "person.crop.circle.badge.questionmark",
                isUrgent: false
            ))
        }
        return result
    }
}

/// Work finished in one period.
public struct VelocityPoint: Sendable, Hashable, Identifiable {
    public var periodStart: Date
    public var completed: Int
    public var created: Int

    public var id: Date { periodStart }
    public var net: Int { completed - created }

    public init(periodStart: Date, completed: Int, created: Int) {
        self.periodStart = periodStart
        self.completed = completed
        self.created = created
    }
}

/// How long work takes from start to finish.
public struct CycleTimeSummary: Sendable, Hashable {
    public var sampleCount: Int
    public var medianDays: Double
    public var meanDays: Double
    public var ninetiethPercentileDays: Double

    /// Below this, the numbers are arithmetic rather than information.
    ///
    /// Five is a judgement, not a theorem. What it protects against is the median of two items
    /// being reported as though it described how the team works.
    public static let minimumUsefulSample = 5

    public var isMeaningful: Bool { sampleCount >= Self.minimumUsefulSample }

    /// Whether a few very slow items are dragging the average away from the typical case.
    ///
    /// When this is true the median is the number to show and the mean is the misleading one —
    /// which is exactly the situation in which most tools show the mean.
    public var hasLongTail: Bool {
        medianDays > 0 && meanDays > medianDays * 1.5
    }

    public init(sampleCount: Int, medianDays: Double, meanDays: Double, ninetiethPercentileDays: Double) {
        self.sampleCount = sampleCount
        self.medianDays = medianDays
        self.meanDays = meanDays
        self.ninetiethPercentileDays = ninetiethPercentileDays
    }

    /// `nil` for an empty sample — see the note on ``ProjectHealth/completionFraction``.
    public static func from(durationsInDays durations: [Double]) -> CycleTimeSummary? {
        guard !durations.isEmpty else { return nil }
        let sorted = durations.sorted()
        let count = sorted.count

        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }

        let mean = sorted.reduce(0, +) / Double(count)
        let index = min(count - 1, Int((Double(count) * 0.9).rounded(.down)))

        return CycleTimeSummary(
            sampleCount: count,
            medianDays: median,
            meanDays: mean,
            ninetiethPercentileDays: sorted[index]
        )
    }
}

/// One person's share of the work.
public struct WorkloadEntry: Sendable, Hashable, Identifiable {
    /// `nil` for the unassigned lane, which is **always included**.
    ///
    /// A workload chart that shows only the named people implies the work is all accounted for. The
    /// unassigned pile is usually the largest column and always the most actionable one.
    public var personID: UUID?
    public var name: String
    public var openCount: Int
    public var estimatedMinutes: Int
    public var unestimatedCount: Int
    public var overdueCount: Int

    public var id: String { personID?.uuidString ?? "unassigned" }
    public var isUnassigned: Bool { personID == nil }

    /// Whether the estimate total actually describes all of this person's work.
    ///
    /// When false, the hours figure is a floor rather than a total, and anything comparing people
    /// by it is comparing how diligently they estimate.
    public var isFullyEstimated: Bool { unestimatedCount == 0 }

    public init(
        personID: UUID?,
        name: String,
        openCount: Int,
        estimatedMinutes: Int,
        unestimatedCount: Int,
        overdueCount: Int
    ) {
        self.personID = personID
        self.name = name
        self.openCount = openCount
        self.estimatedMinutes = estimatedMinutes
        self.unestimatedCount = unestimatedCount
        self.overdueCount = overdueCount
    }
}

/// The window a report covers.
public enum ReportingPeriod: String, Codable, Sendable, Hashable, CaseIterable {
    case week
    case fortnight
    case month
    case quarter

    public var displayName: String {
        switch self {
        case .week: "Weekly"
        case .fortnight: "Fortnightly"
        case .month: "Monthly"
        case .quarter: "Quarterly"
        }
    }

    public var days: Int {
        switch self {
        case .week: 7
        case .fortnight: 14
        case .month: 30
        case .quarter: 90
        }
    }
}
