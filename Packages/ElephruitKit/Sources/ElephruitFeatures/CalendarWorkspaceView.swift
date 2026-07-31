import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The calendar, as a place in the app.
///
/// Replaces the middle column rather than opening beside it, in the same way Time and the People
/// workspace already do: a calendar *is* the contents of that column for this destination, and the
/// inspector on the trailing edge is what shows one event.
public struct CalendarWorkspaceView: View {
    @Environment(\.services) private var services
    @Environment(\.scenePhase) private var scenePhase

    @State private var editorRequest: EditorRequest?
    @State private var quickEntryStart: Date?
    @State private var pendingChange: ScopedChangeRequest?
    @State private var annotatedKeys: Set<String> = []
    @State private var isShowingSetEditor = false
    @State private var isShowingTemplates = false

    /// Whether the calendar has the keyboard. See the note on `focusable()` below.
    @FocusState private var isGridFocused: Bool

    let navigation: NavigationModel

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    /// The calendar's own state, which lives on the navigation model.
    ///
    /// Owned there rather than here because the Calendar module's sidebar sets the view kind, and
    /// state private to this view is state a sidebar cannot reach. Everything else about it is
    /// unchanged — it is still per-window, and two windows still show two different weeks.
    private var workspace: CalendarWorkspaceModel? { navigation.calendarWorkspace }

    public var body: some View {
        Group {
            if let services, let workspace {
                content(services: services, workspace: workspace)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard navigation.calendarWorkspace == nil, let services else { return }
            let model = CalendarWorkspaceModel(
                dateProvider: services.dateProvider,
                calendar: services.calendar.displayCalendar
            )
            navigation.calendarWorkspace = model

            // A day asked for before this view existed — which is the case when the app was
            // launched by the link rather than merely brought forward by it.
            if let day = navigation.requestedCalendarDay {
                navigation.requestedCalendarDay = nil
                model.go(to: day)
                model.setViewKind(.day)
            }

            await services.calendar.start()
            await reload(services: services, workspace: model)
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.workspace)
    }

    @ViewBuilder
    private func content(services: AppServices, workspace: CalendarWorkspaceModel) -> some View {
        VStack(spacing: 0) {
            CalendarToolbar(
                workspace: workspace,
                calendar: services.calendar,
                now: services.dateProvider.now,
                onCreate: { quickEntryStart = defaultStart(workspace: workspace, services: services) },
                onEditSets: { isShowingSetEditor = true }
            )

            Divider()

            if services.calendar.isShowingCachedEvents {
                CalendarOfflineBanner(authorization: services.calendar.authorization)
            }

            // The cache wins over the permission state when it has something.
            //
            // Access revoked in System Settings should not blank a calendar the app read five
            // minutes ago: what it read is still true, and the banner above says where it came from.
            // Replacing it with an explanation would throw away the only useful thing on screen in
            // order to explain why there is nothing on screen.
            if services.calendar.isShowingCachedEvents {
                views(services: services, workspace: workspace)
            } else if !services.calendar.isEnabled || !services.calendar.authorization.canRead {
                CalendarPermissionState(calendar: services.calendar)
            } else {
                views(services: services, workspace: workspace)
            }
        }
        .background(Theme.Colors.contentBackground)
        .onChange(of: workspace.viewKind) { _, _ in
            Task { await reload(services: services, workspace: workspace) }
        }
        .onChange(of: workspace.anchor) { _, _ in
            Task { await reload(services: services, workspace: workspace) }
        }
        .onChange(of: services.calendar.events.count) { _, _ in
            refreshAnnotations(services: services)
        }
        .onChange(of: navigation.requestedCalendarDay) { _, day in
            guard let day else { return }
            navigation.requestedCalendarDay = nil
            workspace.go(to: day)
            workspace.setViewKind(.day)
        }
        .onChange(of: navigation.isCalendarQuickEntryVisible) { _, wanted in
            guard wanted else { return }
            navigation.isCalendarQuickEntryVisible = false
            Task { await prepareQuickEntry(services: services, workspace: workspace) }
        }
        .sheet(item: $editorRequest) { request in
            EventEditorView(existing: request.existing, draft: request.draft) { event in
                workspace.selectedEventID = event.id
                Task { await reload(services: services, workspace: workspace) }
            }
        }
        .sheet(item: quickEntryBinding) { start in
            EventQuickEntryView(
                dateProvider: services.dateProvider,
                suggestedStart: start.date,
                onCreated: { event in
                    workspace.selectedEventID = event.id
                    Task { await reload(services: services, workspace: workspace) }
                },
                onOpenEditor: { draft in
                    editorRequest = EditorRequest(existing: nil, draft: draft)
                }
            )
        }
        .sheet(item: $pendingChange) { request in
            EventScopeSheet(
                confirmation: request.confirmation,
                isDeletion: request.change.isDeletion,
                onChoose: { scope in
                    let captured = request
                    pendingChange = nil
                    Task { await perform(captured.change, scope: scope, services: services, workspace: workspace) }
                },
                onCancel: { pendingChange = nil }
            )
        }
        .sheet(isPresented: $isShowingSetEditor) {
            CalendarSetListView()
        }
        .sheet(isPresented: searchBinding) {
            CalendarSearchView { result in
                // Landing on the day rather than opening the event: a search result is a *place* in
                // the calendar, and arriving there with its neighbours visible is what makes the
                // result readable.
                workspace.go(to: result.startAt)
                workspace.setViewKind(.day)
                workspace.selectedEventID = result.id
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                EventTemplateMenu(
                    start: defaultStart(workspace: workspace, services: services),
                    onCreated: { event in
                        workspace.selectedEventID = event.id
                        Task { await reload(services: services, workspace: workspace) }
                    },
                    onManage: { isShowingTemplates = true }
                )
            }
        }
        .sheet(isPresented: $isShowingTemplates) {
            EventTemplateListView()
        }
        .focusedSceneValue(\.calendarWorkspace, workspace)
        .onChange(of: scenePhase) { _, phase in
            // Permission can be revoked in System Settings while the app is running, and the first
            // sign of it should not be a silently empty day. Re-read on becoming active, which is
            // the moment somebody comes back from having changed it.
            guard phase == .active else { return }
            Task {
                await services.calendar.refreshAuthorization()
                await reload(services: services, workspace: workspace)
            }
        }
        .onOpenURL { url in
            guard let link = CalendarDeepLink.parse(url) else { return }
            Task { await follow(link, services: services, workspace: workspace) }
        }
        // Focusable, and focused on appearing. `onKeyPress` only fires on a focused view, so
        // without this every keyboard shortcut in the calendar would compile, read correctly, and
        // do nothing — the sort of failure that survives a code review and fails the first person
        // who presses an arrow key.
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onAppear { isGridFocused = true }
        .onKeyPress(action: { press in handle(press, services: services, workspace: workspace) })
    }

    /// Makes a global New Event request actionable before showing a field that promises it can save.
    ///
    /// Full EventKit access is both read and write access on macOS. The service asks for that tier,
    /// then exposes only calendars whose account allows modification. If either part is unavailable,
    /// the Calendar permission/read-only state remains visible instead of opening a composer whose
    /// Add button can never work.
    private func prepareQuickEntry(services: AppServices, workspace: CalendarWorkspaceModel) async {
        if !services.calendar.isEnabled || !services.calendar.authorization.canRead {
            let authorization = await services.calendar.enable()
            guard authorization.canRead else { return }
        } else {
            await services.calendar.start()
        }

        guard services.calendar.defaultCalendarIdentifier != nil else { return }
        quickEntryStart = defaultStart(workspace: workspace, services: services)
    }

    @ViewBuilder
    private func views(services: AppServices, workspace: CalendarWorkspaceModel) -> some View {
        let calendarService = services.calendar
        let displayCalendar = calendarService.displayCalendar
        let set = calendarService.activeSet

        switch workspace.viewKind {
        case .agenda:
            CalendarAgendaView(
                days: workspace.visibleDays,
                events: calendarService.events,
                calendar: displayCalendar,
                timeZone: calendarService.timeZoneDisplay.displayZone,
                now: services.dateProvider.now,
                annotatedKeys: annotatedKeys,
                selectedEventID: selectionBinding(workspace),
                onOpen: { open($0, services: services) },
                onCreate: { quickEntryStart = $0 }
            )

        case .day, .week:
            CalendarTimeGridView(
                days: workspace.viewKind == .day ? [workspace.anchor] : workspace.visibleWeekDays,
                events: calendarService.events,
                calendar: displayCalendar,
                workingHours: set?.workingHours ?? .standard,
                density: set?.density ?? .standard,
                timeZoneDisplay: calendarService.timeZoneDisplay,
                now: services.dateProvider.now,
                annotatedKeys: annotatedKeys,
                selectedEventID: selectionBinding(workspace),
                onCreate: { start, end in
                    editorRequest = EditorRequest(
                        existing: nil,
                        draft: EventDraft(
                            calendarIdentifier: calendarService.defaultCalendarIdentifier ?? "",
                            startAt: start,
                            endAt: end
                        )
                    )
                },
                onMove: { event, newStart in
                    request(.move(event: event, target: newStart), services: services, workspace: workspace)
                },
                onResize: { event, newEnd in
                    request(.resize(event: event, target: newEnd), services: services, workspace: workspace)
                },
                onOpen: { open($0, services: services) }
            )

        case .month:
            CalendarMonthView(
                days: workspace.visibleDays,
                events: calendarService.events,
                calendar: displayCalendar,
                anchorMonth: workspace.anchor,
                density: set?.density ?? .standard,
                workingHours: set?.workingHours ?? .standard,
                now: services.dateProvider.now,
                showsWeekNumbers: showsWeekNumbers,
                annotatedKeys: annotatedKeys,
                selectedEventID: selectionBinding(workspace),
                focusedDay: focusedDayBinding(workspace),
                onOpenDay: { workspace.drillInto(day: $0) },
                onCreate: { quickEntryStart = $0 },
                onOpen: { open($0, services: services) }
            )

        case .quarter:
            CalendarQuarterView(
                range: workspace.unpaddedRange,
                events: calendarService.events,
                calendar: displayCalendar,
                workingHours: set?.workingHours ?? .standard,
                now: services.dateProvider.now,
                onOpenDay: { workspace.drillInto(day: $0) },
                onOpen: { open($0, services: services) }
            )

        case .year:
            CalendarYearView(
                range: workspace.unpaddedRange,
                events: calendarService.events,
                calendar: displayCalendar,
                workingHours: set?.workingHours ?? .standard,
                now: services.dateProvider.now,
                onOpenDay: { workspace.drillInto(day: $0) }
            )
        }
    }

    // MARK: Loading

    private func reload(services: AppServices, workspace: CalendarWorkspaceModel) async {
        workspace.calendar = services.calendar.displayCalendar
        await services.calendar.load(range: workspace.visibleRange)
        refreshAnnotations(services: services)
    }

    /// Which events have something attached, in one fetch rather than one per row.
    private func refreshAnnotations(services: AppServices) {
        let identities = services.calendar.events.map(\.identity)
        annotatedKeys = (try? services.eventLinks.annotatedKeys(among: identities)) ?? []
    }

    // MARK: Actions

    private func open(_ event: CalendarEventSummary, services: AppServices) {
        guard event.isEditable else {
            // A read-only event still opens — for reading, and for attaching Elephruit's own notes,
            // which the calendar never sees.
            editorRequest = nil
            navigation.isInspectorVisible = true
            return
        }
        editorRequest = EditorRequest(existing: event, draft: EventDraft(editing: event))
    }

    /// Where a new event lands when nothing said otherwise.
    private func defaultStart(workspace: CalendarWorkspaceModel, services: AppServices) -> Date {
        let calendar = services.calendar.displayCalendar
        let day = workspace.focusedDay ?? workspace.anchor

        // The next whole hour on the day being looked at, or now when that day is today.
        if calendar.isDate(day, inSameDayAs: services.dateProvider.now) {
            let hour = calendar.component(.hour, from: services.dateProvider.now)
            return calendar.date(bySettingHour: min(23, hour + 1), minute: 0, second: 0, of: day) ?? day
        }
        let start = services.calendar.activeSet?.workingHours.startMinutes ?? 9 * 60
        return calendar.date(byAdding: .minute, value: start, to: calendar.startOfDay(for: day)) ?? day
    }

    /// A change that is ready to happen, and whatever has to be asked before it does.
    ///
    /// One entry point for a drag, a resize, and a deletion, because the question in front of all
    /// three is the same and three paths would be three chances to ask it with the wrong verb — or,
    /// as this did until a re-read caught it, to answer it and then perform the wrong operation.
    private func request(
        _ change: ScopedChange,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) {
        let event = change.event

        guard event.isRecurring else {
            Task { await perform(change, scope: .thisEvent, services: services, workspace: workspace) }
            return
        }

        pendingChange = ScopedChangeRequest(
            change: change,
            confirmation: .changingRecurringEvent(
                seriesTitle: event.displayTitle,
                isDeletion: change.isDeletion
            )
        )
    }

    private func perform(
        _ change: ScopedChange,
        scope: EventEditScope,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) async {
        switch change {
        case .move(let event, let target):
            await services.calendar.move(event, to: target, scope: scope)
        case .resize(let event, let target):
            await services.calendar.resize(event, newEnd: target, scope: scope)
        case .delete(let event):
            await services.calendar.delete(event.identity, scope: scope)
        }
        await reload(services: services, workspace: workspace)
    }

    // MARK: Deep links

    /// Acts on a link.
    ///
    /// Every case navigates. The one with a side effect — switching a Calendar Set — changes which
    /// calendars are on screen and nothing about their contents, is reversible with one click, and
    /// is visible the moment it happens. See ``ElephruitCore/CalendarDeepLink``.
    private func follow(
        _ link: CalendarDeepLink,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) async {
        navigation.select(.calendar)

        switch link {
        case .calendar:
            break

        case .day(let components):
            // Resolved in the zone the calendar is *drawn* in, which is the only one that gives the
            // day somebody meant when they wrote the link.
            guard let day = components.resolve(in: services.calendar.displayCalendar) else { return }
            workspace.go(to: day)
            workspace.setViewKind(.day)

        case .event(let identity):
            guard let event = await services.calendar.event(matching: identity) else { return }
            workspace.go(to: event.startAt)
            workspace.setViewKind(.day)
            workspace.selectedEventID = event.id

        case .set(let name):
            let match = services.calendar.sets.first {
                TextNormalizer.foldedForMatching($0.name) == TextNormalizer.foldedForMatching(name)
            }
            await services.calendar.activate(setID: match?.id)
        }

        await reload(services: services, workspace: workspace)
    }

    // MARK: Keyboard

    /// Every key the calendar answers to.
    ///
    /// Handled in one place rather than scattered across the views, so the same key cannot mean two
    /// things in two layouts — and so the list of what the calendar responds to is readable.
    private func handle(
        _ press: KeyPress,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            press.modifiers.contains(.shift) ? workspace.step(-1) : workspace.moveFocus(byDays: -1)
            return .handled
        case .rightArrow:
            press.modifiers.contains(.shift) ? workspace.step(1) : workspace.moveFocus(byDays: 1)
            return .handled
        case .upArrow:
            workspace.moveFocus(byDays: workspace.viewKind == .month ? -7 : -1)
            return .handled
        case .downArrow:
            workspace.moveFocus(byDays: workspace.viewKind == .month ? 7 : 1)
            return .handled
        case .return:
            if let day = workspace.focusedDay { workspace.drillInto(day: day) }
            return .handled
        case .escape:
            workspace.selectedEventID = nil
            return .handled
        case .delete, .deleteForward:
            deleteSelection(services: services, workspace: workspace)
            return .handled
        default:
            break
        }

        switch press.characters {
        case "t", "T":
            workspace.goToToday()
            return .handled
        case "n", "N":
            quickEntryStart = defaultStart(workspace: workspace, services: services)
            return .handled
        case "s", "S":
            // Cycling rather than opening a menu: switching context is something done often and
            // quickly, and "everything" is part of the cycle rather than somewhere you have to
            // reach for the mouse to get back to.
            let next = services.calendar.setAfterActive()
            Task { await services.calendar.activate(setID: next?.id) }
            return .handled
        case "1"..."6":
            guard let index = Int(press.characters),
                  index - 1 < CalendarViewKind.allCases.count
            else { return .ignored }
            workspace.setViewKind(CalendarViewKind.allCases[index - 1])
            return .handled
        default:
            return .ignored
        }
    }

    private func deleteSelection(services: AppServices, workspace: CalendarWorkspaceModel) {
        guard let id = workspace.selectedEventID,
              let event = services.calendar.events.first(where: { $0.id == id }),
              event.isEditable
        else { return }

        request(.delete(event: event), services: services, workspace: workspace)
    }

    // MARK: Bindings

    private var searchBinding: Binding<Bool> {
        Binding(
            get: { navigation.isCalendarSearchVisible },
            set: { navigation.isCalendarSearchVisible = $0 }
        )
    }

    private var showsWeekNumbers: Bool {
        UserDefaults.standard.bool(forKey: "calendar.showsWeekNumbers")
    }

    private func selectionBinding(_ workspace: CalendarWorkspaceModel) -> Binding<String?> {
        Binding(get: { workspace.selectedEventID }, set: { workspace.selectedEventID = $0 })
    }

    private func focusedDayBinding(_ workspace: CalendarWorkspaceModel) -> Binding<Date?> {
        Binding(get: { workspace.focusedDay }, set: { workspace.focusedDay = $0 })
    }

    private var quickEntryBinding: Binding<QuickEntryRequest?> {
        Binding(
            get: { quickEntryStart.map { QuickEntryRequest(date: $0) } },
            set: { quickEntryStart = $0?.date }
        )
    }
}

// MARK: - Requests

private struct EditorRequest: Identifiable {
    let existing: CalendarEventSummary?
    let draft: EventDraft
    var id: String { existing?.id ?? "new" }
}

private struct QuickEntryRequest: Identifiable {
    let date: Date
    var id: Date { date }
}

/// A change to an existing event, waiting on a scope.
///
/// Deletion is a case here rather than a separate path, because the question asked before it is
/// exactly the same question — *which occurrences* — and having two paths is how one of them ends up
/// with the wrong verb on its buttons, or performing the wrong operation.
private enum ScopedChange {
    case move(event: CalendarEventSummary, target: Date)
    case resize(event: CalendarEventSummary, target: Date)
    case delete(event: CalendarEventSummary)

    var event: CalendarEventSummary {
        switch self {
        case .move(let event, _), .resize(let event, _), .delete(let event): event
        }
    }

    var isDeletion: Bool {
        if case .delete = self { return true }
        return false
    }
}

private struct ScopedChangeRequest: Identifiable {
    let change: ScopedChange
    let confirmation: EventChangeConfirmation
    var id: String { confirmation.id + change.event.id }
}

// MARK: - Toolbar

/// Moving through time, and making something.
///
/// ### What is no longer here
/// The view switcher, the calendar visibility menu and the set switcher moved into the Calendar
/// module's sidebar, where each gets a full row instead of being a menu somebody has to open to find
/// out what is switched off. What stays is what is about *navigating time* — back, Today, forward —
/// which changes on every glance and belongs beside the thing it moves.
///
/// The switcher is still reachable when the sidebar is collapsed: `⌘1`–`⌘6` select a view, the
/// overflow menu at the trailing edge lists them, and both go through the same
/// ``CalendarWorkspaceModel/setViewKind(_:)``.
struct CalendarToolbar: View {
    let workspace: CalendarWorkspaceModel
    let calendar: CalendarService
    let now: Date

    var onCreate: () -> Void
    var onEditSets: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            navigationControls

            Text(workspace.title)
                .font(.system(.headline, design: .default, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            if calendar.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading your calendar")
            }

            Spacer(minLength: Theme.Spacing.small)

            overflowMenu

            Button(action: onCreate) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New event (N)")
            .accessibilityLabel("New event")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    /// Everything the sidebar owns, still reachable when the sidebar is not on screen.
    ///
    /// A two-column layout and a collapsed sidebar are both ordinary states, and a control that
    /// exists only in the sidebar would be a control that disappears when somebody widens their
    /// editor. So it is duplicated here — deliberately, and as a menu rather than a second row of
    /// controls, because this is the fallback rather than the place it is meant to be used.
    private var overflowMenu: some View {
        Menu {
            Section("View") {
                ForEach(CalendarViewKind.allCases) { kind in
                    Button {
                        workspace.setViewKind(kind)
                    } label: {
                        Label(
                            kind.displayName,
                            systemImage: workspace.viewKind == kind ? "checkmark" : kind.symbolName
                        )
                    }
                }
            }

            Section("Calendars") {
                ForEach(calendar.calendarsByAccount, id: \.account) { group in
                    ForEach(group.calendars) { entry in
                        Button {
                            Task { await calendar.toggleVisibility(of: entry.id) }
                        } label: {
                            Label(
                                entry.title,
                                systemImage: calendar.isVisible(entry) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .disabled(!inActiveSet(entry))
                    }
                }

                if !calendar.hiddenCalendarIdentifiers.isEmpty {
                    Button("Show All Calendars") {
                        Task { await calendar.showAllCalendars() }
                    }
                }
            }

            Section("Calendar Sets") {
                Button {
                    Task { await calendar.activate(setID: nil) }
                } label: {
                    Label("All Calendars", systemImage: calendar.activeSet == nil ? "checkmark" : "calendar")
                }

                ForEach(calendar.sets) { set in
                    Button {
                        Task { await calendar.activate(setID: set.id) }
                    } label: {
                        Label(
                            set.name,
                            systemImage: calendar.activeSet?.id == set.id ? "checkmark" : set.symbolName
                        )
                    }
                    .accessibilityIdentifier(AccessibilityID.Calendar.setRow(id: set.id.uuidString))
                }

                Button("Edit Calendar Sets…", action: onEditSets)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("View, calendars, and sets — the same choices the sidebar offers")
        .accessibilityLabel("Calendar options")
        .accessibilityIdentifier(AccessibilityID.Calendar.viewSwitcher)
    }

    private var navigationControls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button { workspace.step(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back (⇧←)")
            .accessibilityLabel("Previous \(workspace.viewKind.displayName.lowercased())")
            .accessibilityIdentifier(AccessibilityID.Calendar.previousButton)

            Button("Today") { workspace.goToToday() }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .disabled(workspace.showsToday(now: now) && workspace.focusedDay == nil)
                .help("Jump to today (T)")
                .accessibilityIdentifier(AccessibilityID.Calendar.todayButton)

            Button { workspace.step(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Forward (⇧→)")
            .accessibilityLabel("Next \(workspace.viewKind.displayName.lowercased())")
            .accessibilityIdentifier(AccessibilityID.Calendar.nextButton)
        }
    }

    /// Whether a calendar is in the active set's scope at all.
    private func inActiveSet(_ entry: CalendarInfo) -> Bool {
        guard let scope = calendar.activeSet?.calendarIdentifiers(among: calendar.calendars) else {
            return true
        }
        return scope.contains(entry.id)
    }

    private var viewBinding: Binding<CalendarViewKind> {
        Binding(get: { workspace.viewKind }, set: { workspace.setViewKind($0) })
    }
}

// MARK: - States

/// Shown when what is on screen came from the cache.
struct CalendarOfflineBanner: View {
    let authorization: IntegrationAuthorization

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle")
                .foregroundStyle(Theme.Colors.warning)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer(minLength: Theme.Spacing.small)

            if !authorization.isWorthAsking, !authorization.canRead {
                Button("Open System Settings") {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    ) else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.subtleFill)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Calendar.offlineBanner)
    }

    private var message: String {
        authorization.canRead
            ? "Showing what was last read. Reconnecting…"
            : "Showing what was last read. \(authorization.explanation ?? "")"
    }
}

/// What the calendar shows before anybody has turned it on, or after a refusal.
struct CalendarPermissionState: View {
    let calendar: CalendarService

    var body: some View {
        if !calendar.isEnabled {
            EmptyStateView(
                symbolName: "calendar",
                headline: "Your calendar, alongside your work",
                message: """
                    Elephruit can show and edit your events, link them to the people and projects \
                    they are about, and keep your own notes about a meeting private. macOS will ask \
                    for “full access” because EventKit offers nothing narrower.
                    """,
                actionTitle: "Show My Calendar",
                action: { Task { await calendar.enable() } }
            )
        } else {
            EmptyStateView(
                symbolName: "lock",
                headline: "Calendar access is turned off",
                message: calendar.authorization.explanation,
                tone: .noResults,
                actionTitle: calendar.authorization.isWorthAsking ? "Ask Again" : "Open System Settings",
                action: {
                    if calendar.authorization.isWorthAsking {
                        Task { await calendar.enable() }
                    } else if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
    }
}

extension FocusedValues {
    /// The focused window's calendar, so menu commands act on the right one.
    @Entry public var calendarWorkspace: CalendarWorkspaceModel?
}

import AppKit
