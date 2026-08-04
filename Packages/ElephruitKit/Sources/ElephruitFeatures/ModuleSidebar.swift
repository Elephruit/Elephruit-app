import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Rows shared by the sidebar's per-module sections.
///
/// What remains of the second-level module sidebar: the swap is gone — a module's sources render
/// as sections inside the one primary list — and these are the row shapes those sections still
/// draw.
// MARK: - Shared rows

/// A container — an area, a project, or a list — as a sidebar row.
struct ContainerSidebarRow: View {
    let row: ContainerSidebarEntry
    var isSelected: Bool
    var rowHeight: CGFloat

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: row.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .rowTint(Theme.Palette.color(named: row.colorName, neutral: Theme.Colors.secondaryText))
                .accessibilityHidden(true)

            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Progress, and only where it means something. A list never finishes, so a figure
            // against one would be a number with no destination.
            if let progress = row.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(row.depth) * Theme.Spacing.medium)
        .hoverHighlight(
            isEnabled: !isSelected,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(SidebarSelection.item(id: row.id))
        .help(row.title)
        .accessibilityIdentifier("sidebar.container.\(row.id.uuidString)")
        .accessibilityLabel(row.title)
    }
}

/// A row that turns a mode on rather than selecting a destination.
///
/// Calendar views, time surfaces, windows and groupings are all this shape: the destination does not
/// change, the way it is drawn does.
///
/// ### Why the checkmark became a fill
/// It was a checkmark at the far trailing edge, and in a module whose *only* navigation is rows of
/// this shape that is not a selected state — it is a tick sitting twelve characters away from the
/// word it refers to, in a sidebar where every other current thing is marked by a fill. Two ways of
/// saying "this is the one you are looking at" in one column is one too many, and the quieter of the
/// two was carrying the whole calendar.
///
/// So the fill is drawn here, on the same geometry ``SwiftUICore/View/hoverHighlight(isEnabled:cornerRadius:extending:)``
/// uses — the same radius, the same outward extension, inside the row's own bounds. It is the accent
/// at low opacity rather than the system's solid selected fill, because these rows sit in the same
/// list as genuine destinations and a mode must not be indistinguishable from a place. Hover is
/// suppressed while a row is on, for the reason the hover modifier already gives: a row cannot
/// usefully be both what you are looking at and what you might click next.
struct ModeRow: View {
    let title: String
    let symbolName: String
    let hint: String
    let isOn: Bool
    let identifier: String
    let rowHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: symbolName)
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(isOn ? Theme.Colors.selection : Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                Text(title)
                    .font(isOn ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius, style: .continuous)
                .fill(Theme.Colors.selectionFill)
                .padding(.horizontal, -SidebarMetrics.selectionInset)
                .opacity(isOn ? 1 : 0)
        }
        .hoverHighlight(
            isEnabled: !isOn,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .calmAnimation(Theme.Motion.appearance, value: isOn)
        .help(hint)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
