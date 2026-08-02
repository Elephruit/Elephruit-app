import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The grouped list: compact rows inside the same contained sections the bug tracker uses.
struct WorkItemListView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(model.groups) { group in
                    VStack(spacing: 0) {
                        if !group.title.isEmpty {
                            WorkItemGroupHeader(group: group)
                            Divider()
                        }

                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, facts in
                            WorkItemRowView(
                                facts: facts,
                                groupSeverity: group.severityForRows,
                                model: model
                            )
                            // An item changing severity moves between two nested `ForEach` trees.
                            // Its item ID alone is not enough identity for that move: SwiftUI can
                            // preserve the old row subtree, including its old severity tint. Include
                            // the group so a move creates the row that belongs to its new band.
                            .id(WorkItemGroupRowID(groupKey: group.key, itemID: facts.id))

                            if index < group.items.count - 1 {
                                Divider()
                                    .padding(.leading, Theme.Spacing.medium + Theme.Size.rowGlyph)
                            }
                        }
                    }
                    .background(
                        Theme.Colors.contentBackground,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.large)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.large)
                            .stroke(Theme.Colors.separator, lineWidth: 0.5)
                    )
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.subtleFill.opacity(0.45))
        .accessibilityIdentifier("project.list")
    }
}

struct WorkItemGroupRowID: Hashable {
    let groupKey: String
    let itemID: UUID
}

extension WorkItemArrangement.Group {
    /// The severity a row in this group should draw, when the group *is* a severity band.
    ///
    /// Passed down rather than read off each item, because a heading drawn from the group and a row
    /// drawn from the item can disagree — which is exactly how an orange "Major" heading ended up
    /// sitting over a yellow row.
    var severityForRows: BugSeverity? {
        guard key.hasPrefix("severity.") else { return nil }
        return BugSeverity(rawValue: String(key.dropFirst("severity.".count)))
    }
}

/// A group heading that lines up with the rows beneath it.
struct WorkItemGroupHeader<Accessory: View>: View {
    let group: WorkItemArrangement.Group
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: group.symbolName ?? "circle")
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(tint)

            Text(group.title)
                .font(Theme.Text.rowTitleEmphasised)

            Text("\(group.count)")
                .font(Theme.Text.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)

            if group.isOverLimit {
                Label("over limit", systemImage: "arrow.up.and.down.square")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.warning)
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
        .overlay(alignment: .trailing) {
            accessory.padding(.trailing, Theme.Spacing.medium)
        }
    }

    private var tint: Color {
        Theme.Palette.color(named: group.colorName, neutral: Theme.Colors.secondaryText)
    }
}

extension WorkItemGroupHeader where Accessory == EmptyView {
    init(group: WorkItemArrangement.Group) {
        self.init(group: group) { EmptyView() }
    }
}

/// One row of work.
struct WorkItemRowView: View {
    @Environment(\.services) private var services
    let facts: TaskFacts
    let groupSeverity: BugSeverity?
    let model: ProjectWorkspaceModel

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedItemIDs.contains(facts.id) }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            WorkItemKindGlyph(kind: facts.kind, severity: groupSeverity ?? facts.severity)
                .frame(width: Theme.Size.rowGlyph)

            if let key = facts.referenceKey {
                WorkItemReferenceLabel(reference: key)
            }

            WorkItemTitleField(facts: facts, model: model)

            Spacer(minLength: 0)

            if facts.isBlocked { BlockedMarker() }
            if let estimate = facts.estimateMinutes { EstimateLabel(minutes: estimate) }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: 38)
        .background(rowBackground)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // Both gestures stand down while this row's title is being edited in place — the whole
        // row is hit-testable, so without the gate a double-click meant to select a word in the
        // title threw the sheet over the editor.
        .onTapGesture {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            model.select(facts.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard model.rowGesturesAreActive(for: facts.id) else { return }
            model.present(facts.id)
        })
        .contextMenu { WorkItemMenu(facts: facts, model: model, services: services) }
        .accessibilityIdentifier("workItem.row.\(facts.id.uuidString)")
    }

    private var rowBackground: Color {
        if isSelected { return Theme.Colors.selectionFill }
        if isHovering { return Theme.Colors.hoverFill }
        return .clear
    }
}
