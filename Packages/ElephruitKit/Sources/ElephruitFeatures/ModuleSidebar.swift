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
/// The modules whose navigation is a single destination say so with one row and stop. A module is
/// not obliged to have a lot in it; Bookmarks genuinely is one list, and inventing three rows to
/// make it look busier would be inventing three claims about the data.
struct ModuleSidebar: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        List(selection: selectionBinding) {
            switch module {
            case .calendar:
                CalendarSidebarSection(navigation: navigation)
            case .tasks:
                TasksSidebarSection(navigation: navigation)
            case .people:
                if PeoplePerformanceIsolation.usesIsolatedSidebar {
                    IsolatedPeopleSidebarSection(navigation: navigation)
                } else {
                    PeopleSidebarSection(navigation: navigation)
                }
            case .notes:
                NotesSidebarSection(navigation: navigation)
            case .time:
                TimeSidebarSection(navigation: navigation)
            case .projects:
                ProjectsSidebarSection(navigation: navigation)
            case .areas:
                AreasSidebarSection(navigation: navigation)
            case .bookmarks, .archive, .trash:
                SingleDestinationSection(module: module, navigation: navigation)
            }
        }
        .listStyle(.sidebar)
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
        .padding(.top, Theme.Spacing.small)
        .accessibilityIdentifier("sidebar.module.\(module.rawValue).list")
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

// MARK: - Time

/// Time, and which of its two surfaces is on screen.
///
/// ### Why the period and the grouping left this sidebar
/// They were here, as two sections of checkmark rows, *and* in the log's toolbar as two menus — and
/// once Reports grew a filter rail in the view, in a third place. Three copies of one control.
///
/// The rail won because of what these controls are. A period is not a destination: choosing *Last
/// Week* does not take you somewhere, it changes what the thing you are already looking at is a
/// picture of. A sidebar is for *where am I*, and filling it with rows that answer *what am I
/// filtering by* is what made the previous version of this whole sidebar an index. The rail sits
/// with the content it governs, shows every option without being opened, and is one component both
/// surfaces draw — see ``TimeFilterBar``.
///
/// What is left is navigation: which surface, and the running timer as a way back to it. That is
/// genuinely all Time has to navigate.
///
/// ### Why there is no "Tracked Time" row
/// The same reason Calendar has no "Calendar" row: the module header already names the module, and a
/// front-door destination row underneath it is a second name for where you already are. It is drawn
/// only by the modules that have no navigation of their own — see ``SingleDestinationSection`` — and
/// Time has two surfaces and two settings, which is navigation. `.time` remains the module's
/// ``AppModule/defaultSelection`` and what the numeric shortcut selects; it is simply not restated.
struct TimeSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        if let running = services?.timer.running {
            Section {
                RunningTimerRow(running: running, rowHeight: rowHeight) {
                    navigation.select(.time)
                    navigation.timeSurface = .log
                }
            }
        }

        Section("View") {
            ForEach(TimeSurface.allCases, id: \.self) { surface in
                ModeRow(
                    title: surface.displayName,
                    symbolName: surface.symbolName,
                    hint: surface.hint,
                    isOn: navigation.timeSurface == surface,
                    identifier: "sidebar.time.surface.\(surface.rawValue)",
                    rowHeight: rowHeight
                ) {
                    navigation.select(.time)
                    navigation.timeSurface = surface
                }
            }
        }
    }
}

// MARK: - Projects and Areas

/// Every project, then the ones the user actually made.
///
/// The rows come from `TaskSidebarModel`, which already computes the container tree for the Tasks
/// module. Reading it here rather than fetching again is what keeps "no store access while
/// rendering" true, and means a project renamed in one module is renamed in both.
struct ProjectsSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section {
            ForEach(SidebarRegistry.sidebarRows(in: .projects)) { destination in
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

    /// Projects and lists, with their area shown as an inset rather than repeated on every row.
    private var rows: [TasksSidebarSection.ContainerRow] {
        (services?.taskSidebar.containers ?? []).filter { $0.kind != .area }
    }
}

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

// MARK: - One-destination modules

/// Bookmarks, Archive and Trash, each of which genuinely is one list.
///
/// ### The rule about front-door rows
/// A module draws its own destination row **only when it has no other navigation**. Bookmarks really
/// is one list, and a sidebar with nothing in it would be worse than one row; Calendar and Time have
/// views, calendars, sets, periods and groupings, and a row naming the module on top of a header
/// naming the module is the duplication this rule exists to prevent. Modules whose front door has a
/// name of its own — *All Notes*, *All Projects* — keep it, because "All Notes" and "Notes" are not
/// the same claim: one is a destination among four, the other is the module.
///
/// The Trash carries the one action that belongs beside it rather than in a menu three levels away,
/// and it is the one action in this app that cannot be undone — so it asks first, and says why.
struct SingleDestinationSection: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight
    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true
    @State private var isConfirmingEmpty = false

    var body: some View {
        Section {
            ForEach(SidebarRegistry.sidebarRows(in: module)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }

            if module == .trash {
                Button("Empty Trash…", systemImage: "xmark.bin") {
                    if confirmBeforeEmptyingTrash {
                        isConfirmingEmpty = true
                    } else {
                        emptyTrash()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(minHeight: rowHeight)
                .hoverHighlight(
                    cornerRadius: SidebarMetrics.selectionRadius,
                    extending: SidebarMetrics.selectionInset
                )
                .help("Removes everything in the Trash. This cannot be undone.")
                .accessibilityIdentifier("sidebar.trash.empty")
                .confirmationDialog(
                    "Empty the Trash?",
                    isPresented: $isConfirmingEmpty
                ) {
                    Button("Empty Trash", role: .destructive) { emptyTrash() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Everything in the Trash is removed permanently. This cannot be undone.")
                }
            }
        }
    }

    private func emptyTrash() {
        guard let services else { return }
        services.perform { try services.items.emptyTrash() }
        navigation.selectItem(nil)
        Task { await services.warmSearchIndex() }
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
                .rowTint(row.colorName == nil ? Theme.Colors.secondaryText : Theme.Palette.color(named: row.colorName))
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
                .fill(Theme.Colors.selection.opacity(0.16))
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


/// The running timer, in the sidebar, wherever you are in the app.
///
/// ### Why the sidebar and not only the tracker
/// Because the tracker is on one screen and a timer runs while you are on the others. Elephruit
/// already puts the elapsed time in the menu bar, which covers being in a different *app*; this
/// covers being in a different part of this one. Toggl keeps a live clock in its own sidebar for
/// the same reason, and it is the difference between a timer you trust is going and one you keep
/// navigating back to check.
///
/// Clicking it goes to the log rather than stopping anything. A stop control here would be a
/// destructive action one pixel from a navigation row.
struct RunningTimerRow: View {
    let running: RunningTimer
    let rowHeight: CGFloat
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "record.circle")
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(Theme.Colors.destructive)
                    .symbolEffect(.pulse, options: .repeating)

                Text(running.displayTitle)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.tight)

                TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                    Text(TimeFormatting.stopwatch(running.elapsed(at: context.date)))
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.Colors.destructive)
                }
            }
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Timing “\(running.displayTitle)” since \(running.startedAt.formatted(date: .omitted, time: .shortened))")
        .accessibilityLabel("Timer running: \(running.displayTitle)")
        .accessibilityIdentifier("sidebar.time.running")
    }
}
