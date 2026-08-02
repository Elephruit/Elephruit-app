import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// The figures a project is judged by.
///
/// Every method here is a read. Nothing is cached and nothing is stored, because a stored figure is
/// a figure that can be wrong — and a project's completion percentage being stale is exactly the
/// kind of wrong nobody notices until a decision has been made on it.
@MainActor
public final class ProjectReportingService {
    private let workspace: ProjectWorkspaceService
    private let bugs: BugService
    private let dateProvider: any DateProvider

    public init(workspace: ProjectWorkspaceService, bugs: BugService, dateProvider: any DateProvider) {
        self.workspace = workspace
        self.bugs = bugs
        self.dateProvider = dateProvider
    }

    // MARK: - Health

    /// Health, from facts the caller has already computed.
    ///
    /// The `facts` parameter is the whole point. Computing them is the expensive part — a walk of
    /// the project plus a relationship fault or two per item — and the workspace has already done it
    /// to draw the arrangement. Asking for them again turned one pass into three: this walk, the
    /// arrangement's walk, and `awaitingVerification`'s walk on top. Measured at 25ms per project on
    /// every mutation, for numbers that were already sitting in a local variable.
    public func health(
        of project: Item,
        facts precomputed: [TaskFacts]? = nil,
        calendar: Calendar = .current
    ) -> ProjectHealth {
        let now = dateProvider.now
        let facts = precomputed ?? project.descendantWork().map { $0.taskFacts() }

        let open = facts.filter { $0.status == .open || $0.status == .none }
        let today = calendar.startOfDay(for: now)

        let overLimit = workspace.stages(in: project)
            .filter { stage in
                let count = facts.filter { $0.workflowStageID == stage.id }.count
                return stage.facts.isOverLimit(count)
            }
            .map(\.name)

        let openBugFacts = open.filter { $0.kind == .bug }

        return ProjectHealth(
            totalWork: facts.count,
            completedWork: facts.filter { $0.status == .completed }.count,
            openWork: open.count,
            blockedWork: open.filter(\.isBlocked).count,
            overdueWork: open.filter { ($0.deadlineAt.map { calendar.startOfDay(for: $0) < today }) == true }.count,
            unassignedWork: open.filter { $0.assigneeID == nil }.count,
            openBugs: openBugFacts.count,
            criticalBugs: openBugFacts.filter { $0.severity == .critical }.count,
            // From the facts rather than a fourth walk of the project.
            bugsAwaitingVerification: facts.filter {
                $0.kind == .bug && $0.status == .completed && !$0.isVerified
            }.count,
            stagesOverLimit: overLimit,
            nextDeadline: open.compactMap(\.deadlineAt).filter { $0 >= now }.min()
        )
    }

    // MARK: - Velocity

    /// Work finished per period, most recent last.
    ///
    /// **Empty periods are included.** Skipping them turns a fortnight where nothing shipped into a
    /// chart that looks continuous, and a velocity chart that hides the weeks with no velocity is
    /// worse than no chart: it is a chart that lies in exactly the direction people want it to.
    public func velocity(
        of project: Item,
        period: ReportingPeriod = .week,
        periods count: Int = 8,
        calendar: Calendar = .current
    ) -> [VelocityPoint] {
        let now = dateProvider.now
        let facts = project.descendantWork().map { $0.taskFacts() }
        var points: [VelocityPoint] = []

        for index in stride(from: count - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -period.days * (index + 1), to: now),
                  let end = calendar.date(byAdding: .day, value: -period.days * index, to: now)
            else { continue }

            let completed = facts.filter {
                guard let at = $0.completedAt else { return false }
                return at >= start && at < end
            }.count
            let created = facts.filter { $0.createdAt >= start && $0.createdAt < end }.count

            points.append(VelocityPoint(periodStart: start, completed: completed, created: created))
        }
        return points
    }

    // MARK: - Cycle time

    /// How long finished work took, from start to completion.
    ///
    /// Uses the start date where there is one and falls back to creation, and reports its sample
    /// size so the caller can decline to draw a conclusion from four items.
    public func cycleTime(of project: Item) -> CycleTimeSummary? {
        let durations: [Double] = project.descendantWork().compactMap { item in
            guard let completed = item.completedAt else { return nil }
            let began = item.availableFrom ?? item.createdAt
            let seconds = completed.timeIntervalSince(began)
            guard seconds > 0 else { return nil }
            return seconds / 86_400
        }
        return CycleTimeSummary.from(durationsInDays: durations)
    }

    // MARK: - Workload

    /// Open work per person, **including the unassigned lane**.
    ///
    /// See ``WorkloadEntry/personID``: a chart of only the named people implies the work is all
    /// accounted for, and the unassigned pile is usually the largest column and always the most
    /// actionable one.
    public func workload(of project: Item, calendar: Calendar = .current) -> [WorkloadEntry] {
        let now = dateProvider.now
        let today = calendar.startOfDay(for: now)
        let open = project.descendantWork().filter { $0.status == .open || $0.status == .none }

        var byPerson: [UUID?: [Item]] = [:]
        for item in open { byPerson[item.assignee()?.id, default: []].append(item) }

        let names: [UUID: String] = open.reduce(into: [:]) { result, item in
            if let person = item.assignee() { result[person.id] = person.title }
        }

        var entries = byPerson.compactMap { personID, work -> WorkloadEntry? in
            guard let personID else { return nil }
            return WorkloadEntry(
                personID: personID,
                name: names[personID] ?? "Unknown",
                openCount: work.count,
                estimatedMinutes: work.compactMap(\.estimateMinutes).reduce(0, +),
                unestimatedCount: work.filter { $0.estimateMinutes == nil }.count,
                overdueCount: work.filter { ($0.dueAt.map { calendar.startOfDay(for: $0) < today }) == true }.count
            )
        }
        .sorted { $0.openCount > $1.openCount }

        let loose = byPerson[nil] ?? []
        if !loose.isEmpty {
            entries.append(
                WorkloadEntry(
                    personID: nil,
                    name: "Unassigned",
                    openCount: loose.count,
                    estimatedMinutes: loose.compactMap(\.estimateMinutes).reduce(0, +),
                    unestimatedCount: loose.filter { $0.estimateMinutes == nil }.count,
                    overdueCount: loose.filter { ($0.dueAt.map { calendar.startOfDay(for: $0) < today }) == true }.count
                )
            )
        }
        return entries
    }

    // MARK: - Burndown

    /// Open work remaining on each of the last `days` days.
    ///
    /// Reconstructed from completion timestamps rather than recorded daily, so it is exact for work
    /// that still exists and silently forgets anything deleted — which is the honest trade for not
    /// storing a snapshot table nobody would ever prune.
    public func burndown(
        of project: Item,
        days: Int = 30,
        calendar: Calendar = .current
    ) -> [(date: Date, remaining: Int)] {
        let now = dateProvider.now
        let facts = project.descendantWork().map { $0.taskFacts() }

        return stride(from: days - 1, through: 0, by: -1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let endOfDay = calendar.startOfDay(for: day).addingTimeInterval(86_400)
            let remaining = facts.filter { fact in
                guard fact.createdAt < endOfDay else { return false }
                guard let resolved = fact.completedAt ?? fact.cancelledAt else { return true }
                return resolved >= endOfDay
            }.count
            return (calendar.startOfDay(for: day), remaining)
        }
    }

    // MARK: - Goals

    /// How far along a measurable goal is, or `nil` when it has no target to measure against.
    public func goalProgress(of goal: Item) -> Double? {
        guard goal.kind == .goal,
              let target = goal.goalTargetValue,
              target > 0
        else { return nil }
        return min(1, max(0, (goal.goalCurrentValue ?? 0) / target))
    }
}
