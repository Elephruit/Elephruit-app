import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// A person's relationships, drawn.
///
/// ### Why ranked rows rather than a force-directed graph
/// The requirement is that the visualisation be legible and useful rather than decorative, and a
/// spring-laid blob is the opposite: it looks impressive in a screenshot and cannot answer "who is
/// Jack's mother". Rows ranked by generation — parents above, the subject and their partner and
/// siblings level, children below — answer that at a glance, and the same ranking makes an
/// organisation chart read the way an organisation chart should.
///
/// The whole thing is also a list. Every node is a focusable button in reading order, so the chart is
/// navigable by Tab and readable by VoiceOver without a parallel "accessible version" that would
/// immediately drift out of step with the drawing.
struct RelationshipChartSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let person: Item
    let initialKind: RelationshipChartKind
    let onSelect: (UUID) -> Void

    @State private var kind: RelationshipChartKind
    @State private var chart: RelationshipChart?

    init(person: Item, initialKind: RelationshipChartKind, onSelect: @escaping (UUID) -> Void) {
        self.person = person
        self.initialKind = initialKind
        self.onSelect = onSelect
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(person.displayTitle)
                    .font(Theme.Text.title)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.medium)

            Picker("View", selection: $kind) {
                ForEach(RelationshipChartKind.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.medium)
            .accessibilityLabel("Which relationships to show")

            Divider()

            Group {
                if let chart, !chart.isEmpty {
                    RelationshipChartCanvas(chart: chart, subjectID: person.id, onSelect: onSelect)
                } else {
                    EmptyStateView(
                        symbolName: kind.symbolName,
                        headline: "Nothing to draw",
                        message: kind.emptyMessage
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 480)
        .accessibilityIdentifier(AccessibilityID.Records.chartSheet)
        .task(id: kind) { reload() }
    }

    private func reload() {
        guard let services else { return }
        chart = try? services.personWorkspace.chart(kind, for: person)
    }
}

/// The drawing itself: rows of nodes, with lines behind them.
struct RelationshipChartCanvas: View {
    let chart: RelationshipChart
    let subjectID: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: Theme.Spacing.section) {
                ForEach(chart.rows, id: \.rank) { row in
                    VStack(spacing: Theme.Spacing.tight) {
                        if row.rank != 0 {
                            Text(rankLabel(row.rank))
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }

                        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                            ForEach(row.nodes) { node in
                                ChartNodeView(
                                    node: node,
                                    isSubject: node.id == subjectID,
                                    onSelect: { onSelect(node.id) }
                                )
                            }
                        }
                    }
                    // A hairline between generations, which is all the "line" a ranked chart needs:
                    // the rows themselves carry the structure, and drawing every edge over the top
                    // of three generations produces a thicket.
                    .overlay(alignment: .top) {
                        if row.rank != chart.rows.first?.rank {
                            Rectangle()
                                .fill(Theme.Colors.separator)
                                .frame(width: 1, height: Theme.Spacing.medium)
                                .offset(y: -Theme.Spacing.medium)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.section)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(chart.kind.displayName) chart, \(chart.nodes.count) people")
    }

    /// What a rank means, in words, so the drawing does not have to be interpreted spatially.
    private func rankLabel(_ rank: Int) -> String {
        switch chart.kind {
        case .family, .household:
            rank < 0 ? "Older generation" : "Younger generation"
        case .professional:
            rank < 0 ? "Reports to" : "Reporting in"
        case .network:
            ""
        }
    }
}

struct ChartNodeView: View {
    let node: RelationshipNode
    let isSubject: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: Theme.Spacing.tight) {
                PersonAvatar(name: node.name, colorName: nil, size: isSubject ? 44 : 34)

                Text(node.name)
                    .font(isSubject ? Theme.Text.rowTitleEmphasised : Theme.Text.rowSubtitle)
                    .lineLimit(1)

                if let role = node.roleLabel, !isSubject {
                    Text(node.isPlaceholder ? "\(role) · sketch" : role)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .frame(width: 110)
            .padding(Theme.Spacing.small)
            .background(
                isSubject ? Theme.Colors.selection.opacity(0.14) : Theme.Colors.subtleFill,
                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(isSubject ? Theme.Colors.selection : Theme.Colors.separator.opacity(0.6))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens their page")
    }

    private var accessibilityDescription: String {
        var parts = [node.name]
        if isSubject {
            parts.append("this person")
        } else if let role = node.roleLabel {
            parts.append(role)
        }
        if node.isPlaceholder { parts.append("a lightweight record with no details yet") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Meeting brief

/// Everything worth knowing before seeing somebody.
///
/// Every line says how sure it is and links to where it came from. The count of estimates is stated
/// once at the top rather than left for the reader to notice across nine rows.
struct MeetingBriefSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    let person: Item
    let onOpen: (UUID) -> Void

    @State private var brief: MeetingBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Before you see \(person.displayTitle)")
                        .font(Theme.Text.title)
                    if let brief {
                        Text(brief.summaryLine)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Spacing.medium)

            Divider()

            if let brief, !brief.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(brief.sections, id: \.section) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                                Label(group.section.displayName, systemImage: group.section.symbolName)
                                    .font(Theme.Text.sectionHeader)
                                    .foregroundStyle(Theme.Colors.secondaryText)

                                ForEach(group.entries) { entry in
                                    BriefEntryRow(entry: entry) { onOpen($0) }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
            } else {
                EmptyStateView(
                    symbolName: "list.bullet.rectangle",
                    headline: "Nothing to brief yet",
                    message: "Record a conversation or a fact about \(person.displayTitle) and it will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 560)
        .accessibilityIdentifier(AccessibilityID.Records.meetingBrief)
        .task { brief = try? services?.personWorkspace.brief(for: person) }
    }
}

struct BriefEntryRow: View {
    let entry: BriefEntry
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(entry.text)
                    .font(Theme.Text.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)

                if entry.needsEstimateLabel {
                    Label(entry.confidence.displayName, systemImage: entry.confidence.symbolName)
                        .font(Theme.Text.chip)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .labelStyle(.titleAndIcon)
                }

                Spacer(minLength: 0)
            }

            if let detail = entry.detail {
                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let sourceID = entry.sourceItemID {
                Button {
                    onOpen(sourceID)
                } label: {
                    Label("Source", systemImage: "arrow.up.right.square")
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.link)
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            entry.needsEstimateLabel
                ? "\(entry.text). \(entry.confidence.displayName). \(entry.detail ?? "")"
                : entry.text
        )
    }
}
