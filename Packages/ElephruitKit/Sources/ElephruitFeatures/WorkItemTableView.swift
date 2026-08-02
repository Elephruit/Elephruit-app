import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The table view: the same work as the list, as a spreadsheet.
///
/// A real `Table`, not the grouped list wearing column headers. The view's configuration decides
/// which columns exist and in what order — `WorkItemField.defaultTableColumns` for a fresh table,
/// the bug columns for a bug view somebody switched to tabular — and each field draws with the
/// same components the rows and cards use, so a bug looks like the same bug everywhere.
struct WorkItemTableView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    /// The arrangement, flattened. The table draws grouping as a sort rather than as bands:
    /// `model.groups` is already ordered by the view's grouping and sort, so concatenating keeps
    /// grouped neighbours adjacent without the table needing section machinery of its own.
    private var rows: [TaskFacts] {
        model.groups.flatMap(\.items)
    }

    private var columns: [WorkItemField] {
        model.activeView?.configuration.columns ?? WorkItemField.defaultTableColumns
    }

    var body: some View {
        Table(of: TaskFacts.self, selection: selectionBinding) {
            TableColumnForEach(columns, id: \.self) { field in
                TableColumn(field.displayName) { facts in
                    WorkItemTableCell(field: field, facts: facts, model: model)
                }
                .width(min: Self.minimumWidth(for: field), ideal: Self.idealWidth(for: field))
            }
        } rows: {
            ForEach(rows) { facts in
                TableRow(facts)
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                WorkItemMenu(facts: item, model: model, services: services)
            }
        } primaryAction: { ids in
            // Double-click opens, the same gesture the list and the board honour.
            if let id = ids.first {
                model.present(id)
            }
        }
        .accessibilityIdentifier("project.table")
    }

    /// The table writes straight into the workspace's selection, so the bulk bar, ⌘⌫ and the
    /// inspector all keep working when the selection was made here.
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { model.selectedItemIDs },
            set: { model.selectedItemIDs = $0 }
        )
    }

    /// Titles get the room; handles and figures get what they need.
    private static func idealWidth(for field: WorkItemField) -> CGFloat? {
        switch field {
        case .title: nil
        case .reference: 70
        case .kind, .status, .stage, .priority, .severity: 90
        case .assignee, .milestone, .release: 120
        case .dueDate, .startDate, .updatedAt: 90
        case .estimate, .tracked, .comments: 70
        case .tags: 140
        case .blocked, .regression: 70
        case .affectedVersion, .fixVersion: 80
        }
    }

    private static func minimumWidth(for field: WorkItemField) -> CGFloat {
        field == .title ? 160 : 50
    }
}

/// One cell. Every field renders with the vocabulary the rest of the app already uses — the same
/// glyphs, the same urgency colours, the same duration format — so the table is a denser view of
/// the work rather than a second opinion about it.
struct WorkItemTableCell: View {
    @Environment(\.services) private var services
    let field: WorkItemField
    let facts: TaskFacts
    let model: ProjectWorkspaceModel

    var body: some View {
        switch field {
        case .reference:
            if let key = facts.referenceKey {
                WorkItemReferenceLabel(reference: key)
            } else {
                blank
            }

        case .title:
            HStack(spacing: Theme.Spacing.small) {
                WorkItemKindGlyph(kind: facts.kind, severity: facts.severity)
                Text(facts.title.isEmpty ? "Untitled" : facts.title)
                    .lineLimit(1)
                    .foregroundStyle(
                        facts.title.isEmpty ? Theme.Colors.placeholderText : Theme.Colors.primaryText
                    )
            }

        case .kind:
            Text(facts.kind.displayName)
                .foregroundStyle(Theme.Colors.secondaryText)

        case .status:
            Label(facts.status.displayName, systemImage: facts.status.symbolName)
                .foregroundStyle(
                    facts.status == .completed ? Theme.Colors.completed : Theme.Colors.secondaryText
                )

        case .stage:
            if let name = stageName {
                Text(name).foregroundStyle(Theme.Colors.secondaryText)
            } else {
                blank
            }

        case .priority:
            // Normal is rendered as absence, the same convention the rows use: priority is only
            // visible when it says something.
            if facts.priority == .normal {
                blank
            } else {
                Label {
                    Text(facts.priority.displayName)
                } icon: {
                    if let symbol = facts.priority.symbolName {
                        Image(systemName: symbol)
                    }
                }
                .foregroundStyle(
                    facts.priority == .high ? Theme.Colors.dueToday : Theme.Colors.secondaryText
                )
            }

        case .severity:
            if let severity = facts.severity {
                Label(severity.displayName, systemImage: severity.symbolName)
                    .foregroundStyle(
                        Theme.Palette.color(named: severity.colorName, neutral: Theme.Colors.secondaryText)
                    )
            } else {
                blank
            }

        case .assignee:
            if let name = model.item(facts.id)?.assignee()?.title {
                Text(name).lineLimit(1)
            } else {
                blank
            }

        case .dueDate:
            if let due = facts.deadlineAt {
                DueDateLabel(
                    date: due,
                    dateProvider: dateProvider,
                    isActionable: facts.status.isActionable
                )
            } else {
                blank
            }

        case .startDate:
            if let start = facts.startAt {
                Text(RelativeDay.text(for: start, using: dateProvider))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                blank
            }

        case .estimate:
            if let estimate = facts.estimateMinutes {
                EstimateLabel(minutes: estimate)
            } else {
                blank
            }

        case .tracked:
            if facts.trackedMinutes > 0 {
                Text(EstimateLabel.duration(facts.trackedMinutes))
                    .font(Theme.Text.rowSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                blank
            }

        case .milestone:
            linkedTitle(.targetsMilestone)

        case .release:
            linkedTitle(.relatesToRelease)

        case .tags:
            if facts.tagSlugs.isEmpty {
                blank
            } else {
                Text(facts.tagSlugs.map { "#\($0)" }.joined(separator: " "))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

        case .comments:
            if facts.commentCount > 0 {
                Label("\(facts.commentCount)", systemImage: "bubble")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            } else {
                blank
            }

        case .blocked:
            if facts.isBlocked {
                BlockedMarker()
            } else {
                blank
            }

        case .regression:
            if facts.isRegression {
                Label("Regression", systemImage: "arrow.uturn.backward")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Regression")
            } else {
                blank
            }

        case .affectedVersion:
            versionText(model.item(facts.id)?.bugRecord?.affectedVersion)

        case .fixVersion:
            versionText(model.item(facts.id)?.bugRecord?.fixVersion)

        case .updatedAt:
            Text(RelativeDay.text(for: facts.updatedAt, using: dateProvider))
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    /// An empty cell says nothing rather than "—" forty times a screen.
    private var blank: some View {
        Text(verbatim: "")
    }

    private var dateProvider: any DateProvider {
        services?.dateProvider ?? SystemDateProvider()
    }

    private var stageName: String? {
        guard let stageID = facts.workflowStageID else { return nil }
        return model.stages.first { $0.id == stageID }?.name
    }

    @ViewBuilder
    private func linkedTitle(_ kind: LinkKind) -> some View {
        if let title = model.item(facts.id)?.linkedTarget(kind: kind)?.title {
            Text(title).lineLimit(1).foregroundStyle(Theme.Colors.secondaryText)
        } else {
            blank
        }
    }

    @ViewBuilder
    private func versionText(_ version: String?) -> some View {
        if let version, !version.isEmpty {
            Text(version)
                .font(Theme.Text.metadata)
                .monospaced()
                .foregroundStyle(Theme.Colors.secondaryText)
        } else {
            blank
        }
    }
}
