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

    @State private var workspace: CalendarWorkspaceModel?
    @State private var editorRequest: EditorRequest?
    @State private var quickEntryStart: Date?
    @State private var pendingDrag: DragRequest?
    @State private var annotatedKeys: Set<String> = []
    @State private var isShowingSetEditor = false
    @State private var isShowingTemplates = false

    let navigation: NavigationModel

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

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
            guard workspace == nil, let services else { return }
            let model = CalendarWorkspaceModel(
                dateProvider: services.dateProvider,
                calendar: services.calendar.displayCalendar
            )
            workspace = model
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

            if !services.calendar.isEnabled || !services.calendar.authorization.canRead {
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
        .onChange(of: navigation.isCalendarQuickEntryVisible) { _, wanted in
            guard wanted else { return }
            navigation.isCalendarQuickEntryVisible = false
            quickEntryStart = defaultStart(workspace: workspace, services: services)
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
        .sheet(item: $pendingDrag) { request in
            EventScopeSheet(
                confirmation: request.confirmation,
                isDeletion: false,
                onChoose: { scope in
                    let captured = request
                    pendingDrag = nil
                    Task { await apply(captured, scope: scope, services: services, workspace: workspace) }
                },
                onCancel: { pendingDrag = nil }
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
        .onKeyPress(action: { press in handle(press, services: services, workspace: workspace) })
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

    /// A drag that finished, and whatever has to be asked before it is applied.
    private func request(_ drag: DragKind, services: AppServices, workspace: CalendarWorkspaceModel) {
        let event = drag.event

        guard event.isRecurring else {
            Task { await perform(drag, scope: .thisEvent, services: services, workspace: workspace) }
            return
        }

        pendingDrag = DragRequest(
            kind: drag,
            confirmation: .changingRecurringEvent(seriesTitle: event.displayTitle, isDeletion: false)
        )
    }

    private func apply(
        _ request: DragRequest,
        scope: EventEditScope,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) async {
        await perform(request.kind, scope: scope, services: services, workspace: workspace)
    }

    private func perform(
        _ drag: DragKind,
        scope: EventEditScope,
        services: AppServices,
        workspace: CalendarWorkspaceModel
    ) async {
        switch drag {
        case .move(let event, let target):
            await services.calendar.move(event, to: target, scope: scope)
        case .resize(let event, let target):
            await services.calendar.resize(event, newEnd: target, scope: scope)
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

        guard event.isRecurring else {
            Task {
                await services.calendar.delete(event.identity, scope: .thisEvent)
                await reload(services: services, workspace: workspace)
            }
            return
        }

        pendingDrag = DragRequest(
            kind: .move(event: event, target: event.startAt),
            confirmation: .changingRecurringEvent(seriesTitle: event.displayTitle, isDeletion: true)
        )
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

private enum DragKind {
    case move(event: CalendarEventSummary, target: Date)
    case resize(event: CalendarEventSummary, target: Date)

    var event: CalendarEventSummary {
        switch self {
        case .move(let event, _), .resize(let event, _): event
        }
    }
}

private struct DragRequest: Identifiable {
    let kind: DragKind
    let confirmation: EventChangeConfirmation
    var id: String { confirmation.id + kind.event.id }
}

// MARK: - Toolbar

/// Navigation, the view switcher, and the set switcher.
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

            Spacer(minLength: Theme.Spacing.small)

            setSwitcher
            viewSwitcher

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

    private var viewSwitcher: some View {
        Picker("View", selection: viewBinding) {
            ForEach(CalendarViewKind.allCases) { kind in
                Image(systemName: kind.symbolName)
                    .help(kind.displayName)
                    .tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Calendar view")
        .accessibilityIdentifier(AccessibilityID.Calendar.viewSwitcher)
    }

    private var setSwitcher: some View {
        Menu {
            Button {
                Task { await calendar.activate(setID: nil) }
            } label: {
                Label("All Calendars", systemImage: calendar.activeSet == nil ? "checkmark" : "calendar")
            }

            if !calendar.sets.isEmpty { Divider() }

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

            Divider()
            Button("Edit Calendar Sets…", action: onEditSets)
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: calendar.activeSet?.symbolName ?? "calendar")
                Text(calendar.activeSet?.name ?? "All Calendars")
                    .font(Theme.Text.metadata)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch which calendars are showing (⌥⌘S)")
        .accessibilityIdentifier(AccessibilityID.Calendar.setSwitcher)
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
