import ElephruitCore
import ElephruitDesign
import SwiftUI

/// A project's defect queue.
///
/// Bugs need denser, more explicit information than a general work list: stable references,
/// severity, workflow state, verification and regression markers all matter while triaging. This
/// keeps those facts scannable without turning the screen into a spreadsheet.
struct BugTrackerView: View {
    let model: ProjectWorkspaceModel

    private var bugs: [TaskFacts] { model.allFacts.filter { $0.kind == .bug } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                BugTrackerSummaryBar(facts: bugs)

                ForEach(model.groups) { group in
                    BugTrackerSeveritySection(
                        group: group,
                        model: model,
                        expandedBugID: Binding(
                            get: { model.expandedBugID },
                            set: { model.expandedBugID = $0 }
                        )
                    )
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.subtleFill.opacity(0.45))
        .accessibilityIdentifier("project.bugs.tracker")
    }
}

struct BugTrackerSummaryBar: View {
    let facts: [TaskFacts]

    private var openCount: Int { facts.count { !$0.status.isResolved } }
    private var urgentCount: Int {
        facts.count { $0.severity == .critical || $0.severity == .major }
    }
    private var awaitingVerification: Int {
        facts.count { $0.status == .completed && !$0.isVerified }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            summary("Open", value: openCount, symbol: "ladybug")
            Divider().frame(height: 18)
            summary("Critical or major", value: urgentCount, symbol: "exclamationmark.triangle.fill")
            Divider().frame(height: 18)
            summary("Awaiting verification", value: awaitingVerification, symbol: "checkmark.seal")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(Theme.Colors.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func summary(_ label: String, value: Int, symbol: String) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.secondaryText)
            Text("\(value)")
                .font(Theme.Text.rowTitleEmphasised)
                .monospacedDigit()
            Text(label)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
    }
}

struct BugTrackerSeveritySection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: WorkItemArrangement.Group
    let model: ProjectWorkspaceModel
    @Binding var expandedBugID: UUID?

    private var severity: BugSeverity? { group.severityForRows }
    private var tint: Color {
        Theme.Palette.color(named: severity?.colorName, neutral: Theme.Colors.secondaryText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, facts in
                VStack(spacing: 0) {
                    BugTrackerRow(
                        facts: facts,
                        severity: severity,
                        model: model,
                        isExpanded: expandedBugID == facts.id,
                        toggleExpanded: { toggle(facts.id) }
                    )

                    if expandedBugID == facts.id, let item = model.item(facts.id) {
                        BugInlineDetailView(item: item, model: model) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                                expandedBugID = nil
                            }
                        }
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
                            )
                        )
                    }
                }
                .id(WorkItemGroupRowID(groupKey: group.key, itemID: facts.id))

                if index < group.items.count - 1 {
                    Divider().padding(.leading, 118)
                }
            }
        }
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.Colors.separator, lineWidth: 0.5)
        )
    }

    private func toggle(_ id: UUID) {
        guard model.rowGesturesAreActive(for: id) else { return }
        model.select(id)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.34, extraBounce: 0.04)) {
            expandedBugID = expandedBugID == id ? nil : id
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: severity?.symbolName ?? group.symbolName ?? "circle")
                .foregroundStyle(tint)
                .frame(width: Theme.Size.rowGlyph)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(group.title)
                        .font(Theme.Text.rowTitleEmphasised)
                    Text("\(group.count)")
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                if let severity {
                    Text(severity.hint)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, Theme.Spacing.small)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BugTrackerRow: View {
    @Environment(\.services) private var services
    let facts: TaskFacts
    let severity: BugSeverity?
    let model: ProjectWorkspaceModel
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedItemIDs.contains(facts.id) }
    private var tint: Color {
        Theme.Palette.color(named: severity?.colorName, neutral: Theme.Colors.secondaryText)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            severityMarker

            if let key = facts.referenceKey {
                WorkItemReferenceLabel(reference: key)
                    .frame(width: 66, alignment: .leading)
            } else {
                Color.clear.frame(width: 66, height: 1)
            }

            WorkItemTitleField(facts: facts, model: model)

            Spacer(minLength: Theme.Spacing.medium)

            if facts.isRegression {
                BugTrackerPill(label: "Regression", symbol: "arrow.counterclockwise", tint: Theme.Colors.warning)
            }
            if facts.isBlocked {
                BugTrackerPill(label: "Blocked", symbol: "hand.raised.fill", tint: Theme.Colors.warning)
            }
            if facts.isVerified {
                BugTrackerPill(label: "Verified", symbol: "checkmark.seal.fill", tint: Theme.Colors.completed)
            }
            if facts.priority == .high {
                BugTrackerPill(label: "High", symbol: "exclamationmark", tint: Theme.Colors.warning)
            }

            if let assigneeName {
                Label(assigneeName, systemImage: "person.crop.circle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .trailing)
            }

            if facts.commentCount > 0 {
                Label("\(facts.commentCount)", systemImage: "bubble.left")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .monospacedDigit()
                    .accessibilityLabel("\(facts.commentCount) comments")
            }

            BugTrackerStatusPill(facts: facts, stageName: stageName)
                .frame(width: 82, alignment: .trailing)

            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isExpanded ? Theme.Colors.selection : Theme.Colors.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(
                        isExpanded ? Theme.Colors.selectionFill : Theme.Colors.subtleFill,
                        in: Circle()
                    )
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse bug details" : "Expand bug details")
            .accessibilityLabel(isExpanded ? "Collapse bug details" : "Expand bug details")
            .accessibilityIdentifier("bug.row.expand.\(facts.id.uuidString)")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: 38)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            model.select(facts.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            toggleExpanded()
        })
        .contextMenu { WorkItemMenu(facts: facts, model: model, services: services) }
        .accessibilityIdentifier("bug.row.\(facts.id.uuidString)")
    }

    private var severityMarker: some View {
        Circle()
            .fill(tint.opacity(0.14))
            .frame(width: 24, height: 24)
            .overlay {
                Image(systemName: severity?.symbolName ?? "ladybug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityLabel(severity.map { "\($0.displayName) severity" } ?? "No severity")
    }

    private var rowBackground: Color {
        if isSelected { return Theme.Colors.selectionFill }
        if isHovering { return Theme.Colors.hoverFill }
        return .clear
    }

    private var assigneeName: String? {
        model.item(facts.id)?.assignee()?.title
    }

    private var stageName: String? {
        guard let id = facts.workflowStageID else { return nil }
        return model.stages.first { $0.id == id }?.name
    }
}

struct BugTrackerPill: View {
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(label, systemImage: symbol)
            .font(Theme.Text.metadata)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.tight)
            .padding(.vertical, Theme.Spacing.hairline)
            .background(tint.opacity(0.10), in: Capsule())
            .fixedSize()
    }
}

struct BugTrackerStatusPill: View {
    let facts: TaskFacts
    let stageName: String?

    private var label: String {
        if facts.status.isResolved { return facts.status.displayName }
        return stageName ?? facts.stageCategory?.displayName ?? "Open"
    }

    private var symbol: String {
        if facts.status.isResolved { return facts.status.symbolName }
        return facts.stageCategory?.symbolName ?? "circle"
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .font(Theme.Text.metadata)
            .foregroundStyle(facts.status.isResolved ? Theme.Colors.secondaryText : Theme.Colors.primaryText)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Status: \(label)")
    }
}
