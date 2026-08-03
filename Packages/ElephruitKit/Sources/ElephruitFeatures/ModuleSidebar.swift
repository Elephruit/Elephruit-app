import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The sidebar, once a module has been entered.
///
/// One `List` per module rather than one list with ten conditionals inside it, because the sections
/// a module needs are genuinely different: Tasks has a container tree and smart lists, People has
/// scopes and groups, Calendar has views and calendar sets. What they share — the list style, the
/// selection binding, the row geometry — is shared; what differs is written out.
///
/// Only the modules with real navigation are here at all. The rest — Time with its two surfaces,
/// Bookmarks, Archive and the Trash with one list each — declare ``AppModule/hasOwnSidebar`` false
/// and keep the primary sidebar, because a column swap that buys one or two rows costs the user
/// their whole map to show them almost nothing.
struct ModuleSidebar: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    @ViewBuilder
    var body: some View {
        if module == .records {
            RecordsModuleSidebar(navigation: navigation)
        } else {
            List(selection: selectionBinding) {
                switch module {
                case .calendar:
                    CalendarSidebarSection(navigation: navigation)
                case .tasks:
                    TasksSidebarSection(navigation: navigation)
                case .notes:
                    NotesSidebarSection(navigation: navigation)
                case .areas:
                    AreasSidebarSection(navigation: navigation)
                case .records, .reminders, .projects, .time, .bookmarks, .archive, .trash:
                    EmptyView()
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, Theme.Spacing.small)
            .accessibilityIdentifier("sidebar.module.\(module.rawValue).list")
        }
        // ### Why the list is held clear of the header's divider
        // The module header sits above this list with a `Divider` between them, and a `List` starts
        // its first row flush against its own bounds. A selected first row therefore drew its
        // rounded accent fill hard against that divider — no gap, the fill's rounded corner meeting
        // a hairline — which reads as the selection escaping the navigation region rather than
        // sitting in it.
        //
        // ### And why this is padding rather than a content margin
        // Because a content margin was the first attempt and it did nothing. `contentMargins(_:_:for:
        // .scrollContent)` is honoured by a `ScrollView`; a `List` under `.sidebar` style on macOS
        // is an `NSTableView` in a scroll view AppKit owns, and it kept its own insets. The
        // selection carried on touching the line.
        //
        // Padding moves the list's *bounds*, which nothing downstream can decline: every fill the
        // list draws — selected, hovering, a disclosure's — is clipped to those bounds, so none of
        // them can reach the divider however far the list is scrolled. The gap shows the same
        // sidebar material the list is drawn on, so there is no seam to see.
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { navigation.selection },
            set: { newValue in
                guard let newValue else { return }
                navigation.select(newValue)
            }
        )
    }
}

// MARK: - Notes

/// Notes, and the kinds that are notes by every measure this app applies to them.
///
/// Ideas, reference and daily entries are separate rows rather than a filter somebody has to
/// remember, because each is a different question — "what have I half-thought", "what do I look up",
/// "what happened that day" — and each is already a kind the store can answer directly.
struct NotesSidebarSection: View {
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.sidebarRows(in: .notes)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }
    }
}

// MARK: - Areas

/// Standing responsibilities, and what is inside each of them.
struct AreasSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.sidebarRows(in: .areas)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }

        if !rows.isEmpty {
            Section("Yours") {
                ForEach(rows) { row in
                    ContainerSidebarRow(
                        row: row,
                        isSelected: navigation.selection == .item(id: row.id),
                        rowHeight: rowHeight
                    )
                }
            }
        }
    }

    private var rows: [TasksSidebarSection.ContainerRow] {
        services?.taskSidebar.containers ?? []
    }
}

// MARK: - Shared rows

/// A container — an area, a project, or a list — as a sidebar row.
struct ContainerSidebarRow: View {
    let row: TasksSidebarSection.ContainerRow
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
                ProjectProgressDot(progress: progress)
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
