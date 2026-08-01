import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The Calendar module's own sidebar: which view, which calendars, which set.
///
/// ### Why these controls moved out of the toolbar
/// They were three menus and a segmented control crammed into the top of the middle column, which is
/// where they had to live while the sidebar belonged to the whole app. A module has its own sidebar,
/// and a sidebar is where a Mac puts "which of my things am I looking at" — Calendar.app, Mail and
/// Finder all agree. Moving them gives each calendar a full-width row with room for its colour and
/// its account, instead of a menu the user has to open to find out what is switched off.
///
/// The toolbar keeps what is genuinely about *navigating time* — back, Today, forward — because that
/// changes on every glance and belongs beside what it moves.
///
/// ### Why the word "Calendar" appears once
/// It appeared twice. The module header named the module — `‹ 􀉉 Calendar ⌄` — and directly beneath
/// it, flush against the header's divider, sat a lone destination row also called *Calendar*, which
/// was the module's front door and therefore already where you were. It was the only selectable row
/// in the column, so the sidebar's one piece of selection state was spent restating the header, and
/// its accent fill ran into the divider above it because a `List` begins its first row flush against
/// its own bounds.
///
/// Deleting it costs nothing. `.calendar` is still the module's ``AppModule/defaultSelection`` and
/// still what `⌘6` and every deep link select; it simply is not drawn as a row that says the name of
/// the place you are standing in. What the column navigates instead is the thing that genuinely
/// differs — **which view of your days**, then which calendars are being read, then which set — with
/// *Views* first because it is the choice made most often.
struct CalendarSidebarSection: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    @SceneStorage("sidebar.calendar.calendars") private var isCalendarsExpanded = true
    @SceneStorage("sidebar.calendar.sets") private var isSetsExpanded = false

    @State private var isShowingSetEditor = false

    var body: some View {
        Section("Views") {
            ForEach(CalendarViewKind.allCases) { kind in
                ModeRow(
                    title: kind.displayName,
                    symbolName: kind.symbolName,
                    hint: hint(for: kind),
                    isOn: currentViewKind == kind,
                    identifier: "sidebar.calendar.view.\(kind.rawValue)",
                    rowHeight: rowHeight
                ) {
                    navigation.select(.calendar)
                    navigation.calendarWorkspace?.setViewKind(kind)
                }
            }
        }

        calendarsSection
        setsSection
    }

    /// Which view is current, including before the workspace has been built.
    ///
    /// The workspace is `nil` until the calendar has been drawn once, and the module can be entered
    /// from a menu, a shortcut, or a restored scene before that happens. Reading only the workspace
    /// meant arriving in Calendar to a column of six views with none of them marked — the sidebar
    /// saying it did not know what you were looking at, in the one second where you had just asked.
    /// The workspace restores its own kind from the same stored value, so asking for it here is the
    /// same answer one frame early rather than a second source of truth.
    private var currentViewKind: CalendarViewKind {
        navigation.calendarWorkspace?.viewKind ?? CalendarWorkspaceModel.storedViewKind()
    }

    /// Every calendar the app can read, grouped by the account it came from.
    ///
    /// Ticking one off here hides it for now and does **not** edit a saved set — the same
    /// distinction the toolbar menu drew, kept because it is the one people get wrong. A calendar
    /// outside the active set is shown disabled with the reason on the row rather than hidden, so
    /// "where did my work calendar go" has an answer on screen.
    @ViewBuilder
    private var calendarsSection: some View {
        if let calendar = services?.calendar, !calendar.calendarsByAccount.isEmpty {
            Section("Calendars", isExpanded: $isCalendarsExpanded) {
                ForEach(calendar.calendarsByAccount, id: \.account) { group in
                    ForEach(group.calendars) { entry in
                        CalendarVisibilityRow(
                            entry: entry,
                            account: group.account,
                            isVisible: calendar.isVisible(entry),
                            isInActiveSet: inActiveSet(entry, calendar: calendar),
                            activeSetName: calendar.activeSet?.name,
                            rowHeight: rowHeight
                        ) {
                            Task { await calendar.toggleVisibility(of: entry.id) }
                        }
                    }
                }

                if !calendar.hiddenCalendarIdentifiers.isEmpty {
                    Button("Show All Calendars", systemImage: "eye") {
                        Task { await calendar.showAllCalendars() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(minHeight: rowHeight)
                    .hoverHighlight(
                        cornerRadius: SidebarMetrics.selectionRadius,
                        extending: SidebarMetrics.selectionInset
                    )
                    .accessibilityIdentifier("sidebar.calendar.showAll")
                }
            }
        }
    }

    @ViewBuilder
    private var setsSection: some View {
        if let calendar = services?.calendar {
            Section("Calendar Sets", isExpanded: $isSetsExpanded) {
                ModeRow(
                    title: "All Calendars",
                    symbolName: "calendar",
                    hint: "Every calendar you have access to, with nothing scoped out.",
                    isOn: calendar.activeSet == nil,
                    identifier: "sidebar.calendar.set.all",
                    rowHeight: rowHeight
                ) {
                    Task { await calendar.activate(setID: nil) }
                }

                ForEach(calendar.sets) { set in
                    ModeRow(
                        title: set.name,
                        symbolName: set.symbolName,
                        hint: "A set you composed. Only the calendars in it are read.",
                        isOn: calendar.activeSet?.id == set.id,
                        identifier: AccessibilityID.Calendar.setRow(id: set.id.uuidString),
                        rowHeight: rowHeight
                    ) {
                        Task { await calendar.activate(setID: set.id) }
                    }
                }

                Button("Edit Calendar Sets…") { isShowingSetEditor = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(minHeight: rowHeight)
                    .hoverHighlight(
                        cornerRadius: SidebarMetrics.selectionRadius,
                        extending: SidebarMetrics.selectionInset
                    )
                    .accessibilityIdentifier("sidebar.calendar.editSets")
                    .sheet(isPresented: $isShowingSetEditor) {
                        CalendarSetListView()
                    }
            }
        }
    }

    private func inActiveSet(_ entry: CalendarInfo, calendar: CalendarService) -> Bool {
        guard let scope = calendar.activeSet?.calendarIdentifiers(among: calendar.calendars) else {
            return true
        }
        return scope.contains(entry.id)
    }

    /// What the view shows, rather than what it is called.
    private func hint(for kind: CalendarViewKind) -> String {
        switch kind {
        case .agenda: "The next month as a list, with the empty days left out."
        case .day: "One day, hour by hour."
        case .week: "Your week, with everything that overlaps drawn side by side."
        case .month: "The month as a grid, for spotting where the space is."
        case .quarter: "Three months at once, for planning further than a page."
        case .year: "The whole year, at a glance."
        }
    }
}

/// One calendar, with its colour, its account, and whether it is showing.
struct CalendarVisibilityRow: View {
    let entry: CalendarInfo
    let account: String
    let isVisible: Bool
    let isInActiveSet: Bool
    let activeSetName: String?
    let rowHeight: CGFloat
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
                    .frame(width: SidebarMetrics.iconColumn)
                    .rowTint(Theme.Palette.color(named: entry.colorName))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(account)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isInActiveSet)
        .hoverHighlight(
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .help(helpText)
        .accessibilityIdentifier("sidebar.calendar.visibility.\(entry.id)")
        .accessibilityLabel("\(entry.title), \(account)")
        .accessibilityValue(isVisible ? "Showing" : "Hidden")
        .accessibilityAddTraits(isVisible ? [.isButton, .isSelected] : .isButton)
    }

    private var helpText: String {
        guard isInActiveSet else {
            return "Not in the “\(activeSetName ?? "")” set, so it is not being read at all."
        }
        return isVisible ? "Showing. Click to hide it for now." : "Hidden for now. Click to show it."
    }
}
