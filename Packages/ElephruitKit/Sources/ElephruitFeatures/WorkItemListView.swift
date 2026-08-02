import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// The grouped list. Draws every arrangement except the board.
///
/// One view for list, table, bugs, calendar and timeline groupings rather than five, because they
/// are the same rows under different groupings — and five copies is how they drift apart.
struct WorkItemListView: View {
    @Environment(\.services) private var services
    let model: ProjectWorkspaceModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.items, id: \.id) { facts in
                            WorkItemRowView(
                                facts: facts,
                                groupSeverity: group.severityForRows,
                                model: model
                            )
                        }
                    } header: {
                        if !group.title.isEmpty {
                            WorkItemGroupHeader(group: group)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.small)
        }
    }
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

    @State private var isExpanded = true

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            // The glyph sits in the *same* column the rows use, so the heading and its rows share a
            // left edge. The chevron hangs outside it, in the gutter overlay below.
            Image(systemName: group.symbolName ?? "circle")
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(tint)

            Text(group.title)
                .font(Theme.Text.rowTitle)
                .foregroundStyle(tint)

            Text("\(group.count)")
                .font(Theme.Text.rowSubtitle)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.tertiaryText)

            if group.isOverLimit {
                Label("over limit", systemImage: "arrow.up.and.down.square")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.warning)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.tight)
        .background(.bar)
        // The chevron in a leading gutter rather than inline. Inline, it pushed the whole heading
        // right and the heading ended up indented further than the rows it described.
        .overlay(alignment: .leading) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.leading, Theme.Spacing.tight)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            accessory.padding(.trailing, Theme.Spacing.large)
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
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Theme.Size.rowHeight)
        .background(isSelected ? Theme.Colors.selectionFill : .clear)
        .contentShape(.rect)
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
}
