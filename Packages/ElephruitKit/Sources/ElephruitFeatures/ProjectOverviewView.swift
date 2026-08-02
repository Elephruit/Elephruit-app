import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The overview: how the project is doing, not another arrangement of its rows.
///
/// Progress, the concerns in full, where the work sits by stage, and what moved most recently.
/// Everything here is read from ``ProjectHealth`` and the facts the model already computed — the
/// overview asks no question of the store that the other views have not already paid for.
struct ProjectOverviewView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                statTiles
                progressSection

                if !model.health.concerns.isEmpty {
                    concernsSection
                }

                if !stageBreakdown.isEmpty {
                    stageSection
                }

                recentSection
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .frame(maxWidth: Theme.Size.editorMaxWidth, alignment: .leading)
        }
        .accessibilityIdentifier("project.overview")
    }

    // MARK: - Tiles

    /// Four figures, chosen because each one changes what you do next. Anything that would
    /// usually read zero stays out of the row — see ``ProjectHealth/concerns``.
    private var statTiles: some View {
        HStack(spacing: Theme.Spacing.medium) {
            StatTile(
                value: "\(model.health.openWork)",
                label: "Open",
                symbolName: "circle",
                tint: Theme.Colors.secondaryText
            )
            StatTile(
                value: "\(model.health.completedWork)",
                label: "Done",
                symbolName: "checkmark.circle.fill",
                tint: Theme.Colors.completed
            )
            StatTile(
                value: "\(model.health.openBugs)",
                label: model.health.openBugs == 1 ? "Open bug" : "Open bugs",
                symbolName: "ant",
                tint: model.health.criticalBugs > 0 ? Theme.Colors.overdue : Theme.Colors.secondaryText
            )
            StatTile(
                value: "\(model.health.overdueWork)",
                label: "Overdue",
                symbolName: "exclamationmark.triangle",
                tint: model.health.overdueWork > 0 ? Theme.Colors.overdue : Theme.Colors.secondaryText
            )
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        if let fraction = model.health.completionFraction {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack {
                    Text("\(model.health.completedWork) of \(model.health.totalWork) done")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer(minLength: 0)
                    if let deadline = model.health.nextDeadline {
                        HStack(spacing: Theme.Spacing.tight) {
                            Text("Next deadline")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            DueDateLabel(date: deadline, dateProvider: dateProvider)
                        }
                    }
                }

                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.Colors.completed)
                    .accessibilityLabel("\(Int(fraction * 100)) per cent complete")
            }
        }
    }

    // MARK: - Concerns

    /// All of them — the header above the tabs shows three, and this is the place the rest live.
    private var concernsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Needs attention")

            ForEach(model.health.concerns) { concern in
                Label(concern.sentence, systemImage: concern.symbolName)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(
                        concern.isUrgent ? Theme.Colors.overdue : Theme.Colors.secondaryText
                    )
            }
        }
    }

    // MARK: - Stages

    private struct StageCount: Identifiable {
        let id: String
        let name: String
        let color: Color
        let count: Int
    }

    /// Open work by board column, in column order. Empty when the project has no stages in use —
    /// a breakdown of one bar saying "everything is somewhere" earns no pixels.
    private var stageBreakdown: [StageCount] {
        let facts = model.allFacts.filter { !$0.status.isResolved }
        guard facts.contains(where: { $0.workflowStageID != nil }) else { return [] }

        let byStage = Dictionary(grouping: facts, by: \.workflowStageID)
        var result: [StageCount] = model.stages.compactMap { stage in
            guard let items = byStage[stage.id], !items.isEmpty else { return nil }
            return StageCount(
                id: stage.id.uuidString,
                name: stage.name,
                color: Theme.Palette.color(named: stage.colorName, neutral: Theme.Colors.secondaryText),
                count: items.count
            )
        }
        if let unstaged = byStage[nil], !unstaged.isEmpty {
            result.append(StageCount(
                id: "unstaged",
                name: "No column",
                color: Theme.Colors.tertiaryText,
                count: unstaged.count
            ))
        }
        return result
    }

    private var stageSection: some View {
        let breakdown = stageBreakdown
        let widest = breakdown.map(\.count).max() ?? 1

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Open work by column")

            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.tight) {
                ForEach(breakdown) { stage in
                    GridRow {
                        Text(stage.name)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .gridColumnAlignment(.leading)

                        BreakdownBar(fraction: Double(stage.count) / Double(widest), color: stage.color)

                        Text("\(stage.count)")
                            .font(Theme.Text.rowSubtitle)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(stage.name), \(stage.count) open")
                }
            }
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            SectionHeader("Recently changed")

            ForEach(recentFacts, id: \.id) { facts in
                HStack(spacing: Theme.Spacing.small) {
                    WorkItemRowView(facts: facts, groupSeverity: nil, model: model)
                        .padding(.horizontal, -Theme.Spacing.large)

                    Text(RelativeDay.text(for: facts.updatedAt, using: dateProvider))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
    }

    /// The five that moved last, from everything in the project rather than the active filter —
    /// the overview is about the project, and a filter belongs to the arranging views.
    private var recentFacts: [TaskFacts] {
        Array(model.allFacts.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    private var dateProvider: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }
}

/// One number with its name under it.
struct StatTile: View {
    let value: String
    let label: String
    let symbolName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: symbolName)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            Text(label)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .fill(Theme.Colors.subtleFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A quiet horizontal bar, scaled against the widest in its set.
struct BreakdownBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color.opacity(0.7))
                .frame(width: max(4, proxy.size.width * fraction), height: 6)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
