import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import SwiftUI
import UniformTypeIdentifiers

/// One window.
///
/// A three-column `NavigationSplitView` — sidebar, list, detail — with the inspector as a trailing
/// pane rather than a fourth column, because an inspector is *about* the detail rather than a peer
/// of it.
///
/// Owns its own ``NavigationModel``, so two windows can look at different things.
public struct RootView: View {
    @Environment(\.services) private var services

    @State private var navigation = NavigationModel()

    /// The window's swipe coordinator.
    ///
    /// One per window, because "only one row is open at a time" is a fact about a window and two
    /// windows are entitled to have a row open each. It installs the event monitors that make a
    /// two-finger trackpad swipe reach a list row at all.
    @State private var swipes = SwipeActionCoordinator()

    /// Where this window was, encoded.
    ///
    /// `@SceneStorage` rather than `@AppStorage`, because "where am I" is a property of a window and
    /// two windows are entitled to disagree. Written on every change and read once, on the task that
    /// runs when the window appears.
    @SceneStorage("navigation.state") private var storedNavigationState = ""

    /// What each module has been left set to.
    ///
    /// Per window like everything else here, but backed by one preference file, so a divider dragged
    /// in this window is where the next window and the next launch find it. See ``ModuleLayoutStore``.
    @State private var moduleLayout = ModuleLayoutStore()

    /// The window's own width, so a restored column width can be clamped to what there is.
    @State private var windowWidth: CGFloat = 0

    /// Widths held fixed for one turn of the run loop while a module change lands.
    ///
    /// AppKit's split view keeps its divider position across everything: changing the constraints
    /// alone moves a column only when its *current* width breaks them, so a People pane at 520 would
    /// happily sit at 520 in Notes, which allows up to 960. Pinning min, ideal and max to the value
    /// this module wants forces the move; relaxing them a moment later gives the divider back.
    @State private var pinnedWidths: [ModuleShellLayout.Column: CGFloat] = [:]

    /// Watches the columns and records only the widths the user chose.
    ///
    /// A reference type rather than a dictionary in `@State`, and that is the point: it is written
    /// to on every frame of every animation the shell runs, and writing to `@State` would invalidate
    /// this view each time. See ``PaneWidthRecorder``.
    @State private var widthRecorder = PaneWidthRecorder()

    @State private var isExportPresented = false
    @State private var isImportPresented = false
    @State private var transferSummary: String?
    @State private var isRepairSheetPresented = false

    /// Held for the window's lifetime so the observation is not cancelled the moment `task` returns.
    @State private var contactRefresh: ContactRefreshCoordinator?
    @State private var reminderRefresh: ReminderRefreshCoordinator?

    @Environment(\.scenePhase) private var scenePhase

    /// Hoisted out of the `onChange` that watches it: inlining the optional chain and the `??` into
    /// a modifier argument pushes this body past the type checker's budget.
    private var isRemindersEnabled: Bool {
        services?.reminders.isEnabled ?? false
    }

    /// What the menu bar or an intent has asked for, if anything.
    ///
    /// Read rather than consumed here: taking it would be a mutation during a view's body, which
    /// SwiftUI is entitled to run at any time and more than once. The window clears it through
    /// ``onCalendarRequestHandled`` once it has actually acted, which is also what stops two open
    /// windows both reacting to one click.
    private let pendingCalendarRequest: PendingCalendarRequest?

    /// Called once the request above has been acted on.
    private let onCalendarRequestHandled: () -> Void

    public init(
        pendingCalendarRequest: PendingCalendarRequest? = nil,
        onCalendarRequestHandled: @escaping () -> Void = {}
    ) {
        self.pendingCalendarRequest = pendingCalendarRequest
        self.onCalendarRequestHandled = onCalendarRequestHandled
    }

    public var body: some View {
        Group {
            if services == nil {
                // The shell can render before services exist only in a misconfigured scene; saying so
                // beats an empty window with no explanation.
                EmptyStateView(
                    symbolName: "exclamationmark.triangle",
                    headline: "Library unavailable",
                    message: "Elephruit could not reach your library. Restart the app to try again."
                )
            } else {
                shellWithBanner
            }
        }
        // Above every screen in the window, in the corner nothing else uses. See
        // ``FloatingTimerView`` — the sidebar row it duplicates is only present while the Time
        // module's sidebar is, and a timer must not vanish because somebody opened Tasks.
        .overlay(alignment: .bottomTrailing) {
            FloatingTimerView(
                onOpen: {
                    navigation.select(.time)
                    navigation.timeSurface = .log
                },
                onCollapse: { services?.miniTimer.collapse() }
            )
        }
        .environment(navigation)
        .swipeActionCoordinator(swipes)
        // Changing what is selected puts away anything a row was offering. The actions were about
        // the row you were on, and you are no longer on it.
        .onChange(of: navigation.selection) { _, _ in swipes.closeAll() }
        .onChange(of: navigation.selectedItemIDs) { _, _ in swipes.closeAll() }
        .onChange(of: swipes.openRow) { _, open in
            navigation.hasRevealedRowActions = open != nil
        }
        .sheet(isPresented: quickCaptureBinding) {
            QuickCaptureView { id in
                navigation.selectItem(id)
            }
        }
        .sheet(isPresented: taskEntryBinding) {
            TaskQuickEntryView { created in
                navigation.select(.taskView(.inbox))
                navigation.selectItem(created.id)
            }
        }
        .sheet(isPresented: commandPaletteBinding) {
            CommandPaletteView(navigation: navigation, commands: paletteCommands)
        }
        .sheet(isPresented: peopleCommandBarBinding) {
            PeopleCommandBarView(navigation: navigation)
        }
        .sheet(isPresented: newPersonBinding) {
            NewPersonSheet(navigation: navigation)
        }
        // The sheet the sidebar's "All Tags…" button always promised. The flag existed and was
        // set; nothing observed it, so the button was the one control in the app that did nothing.
        .sheet(isPresented: tagBrowserBinding) {
            TagBrowserView()
        }
        .sheet(isPresented: $isExportPresented) {
            ExportSheet()
        }
        .fileImporter(
            isPresented: $isImportPresented,
            allowedContentTypes: [.json, UTType(filenameExtension: "md") ?? .plainText, .plainText],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .alert(
            errorTitle,
            isPresented: errorBinding,
            presenting: services?.lastError
        ) { error in
            // The recovery options come from `AppError` itself, so the same failure always offers the
            // same way out no matter where it was raised.
            ForEach(error.recovery, id: \.self) { option in
                Button(option.title, role: option.isDestructive ? .destructive : nil) {
                    handleRecovery(option, for: error)
                }
            }
        } message: { error in
            Text(error.failureReason ?? "")
        }
        .alert("Transfer complete", isPresented: transferSummaryBinding) {
            Button("OK") { transferSummary = nil }
        } message: {
            Text(transferSummary ?? "")
        }
        .onChange(of: pendingCalendarRequest) { _, request in
            handleCalendarRequest(request)
        }
        .onChange(of: navigation.restorationState) { _, state in
            guard let encoded = state.encoded else { return }
            storedNavigationState = encoded
        }
        .task {
            // The ladder decides that Escape should close a revealed row; this is what does it.
            navigation.onCloseRowActions = { swipes.closeAll() }

            // Before the calendar request, so a link that arrived at launch wins over the place the
            // window was last left rather than being overwritten by it.
            restoreNavigation()

            // Everything the sidebar reads is computed on change and never during a render, so the
            // *first* computation has to come from somewhere — and at launch this is the only
            // somewhere there is. Without it the Projects tree stayed empty until the user created a
            // project, at which point the new one and every old one appeared together.
            services?.refreshDerivedState()

            // On launch, when the request arrived before this window existed — which is the case
            // when a Shortcut or a link started the app rather than merely bringing it forward.
            handleCalendarRequest(pendingCalendarRequest)

            // Watching for address-book changes, so a number edited in Contacts reaches the CRM
            // without anybody pressing anything. Coalesced inside the coordinator, and a no-op until
            // the integration is turned on.
            if let services {
                let coordinator = ContactRefreshCoordinator(services: services)
                contactRefresh = coordinator
                coordinator.start()

                // The same arrangement for Reminders, and for a sharper reason: until this existed
                // every sync was a control somebody had to press, so a reminder added on a phone
                // never arrived and linking the integration imported nothing until the user went
                // looking. `start()` also runs the pass that should happen at launch.
                let reminderCoordinator = ReminderRefreshCoordinator(services: services)
                reminderRefresh = reminderCoordinator
                reminderCoordinator.start()
            }

            services?.checkForContainmentRepair()
            // Housekeeping, in the same place and on the same terms: looked at once the store is
            // open, reported if there is anything to say, and never acted on unasked.
            services?.checkForAttachmentTidy()
            // Before the index warm, because a timer left running deserves an answer sooner than
            // search deserves to be fast.
            services?.startTimeTracking()
            await services?.warmSearchIndex()
        }
        .sheet(isPresented: repairSheetBinding) {
            if let services, let report = services.pendingContainmentRepair {
                ContainmentRepairSheet(
                    report: report,
                    onApply: {
                        services.applyContainmentRepair()
                        isRepairSheetPresented = false
                    },
                    onDefer: {
                        services.deferContainmentRepair()
                        isRepairSheetPresented = false
                    }
                )
            }
        }
        // One handler for the whole window. The ladder decides; the view only reports the key.
        // Returning `.ignored` when nothing happened lets the event fall through rather than being
        // silently swallowed.
        .onKeyPress(.escape) {
            navigation.handleEscape() ? .handled : .ignored
        }
    }

    /// The shell, with the repair offer above it when there is one.
    ///
    /// Lifted out of `body` because the combined expression exceeded the type checker's budget — the
    /// same limit documented on `ItemPredicateBuilder`, in a different guise.
    @ViewBuilder
    private var shellWithBanner: some View {
        VStack(spacing: 0) {
            if let report = services?.pendingContainmentRepair {
                ContainmentRepairBanner(report: report) {
                    isRepairSheetPresented = true
                }
            }
            splitView
        }
    }

    /// The column widths whatever this window is showing has asked for.
    private var shellLayout: ModuleShellLayout { navigation.shellLayout }

    /// What the shell's shape depends on.
    ///
    /// The module, and — because Today is a canvas where the rest of primary navigation is a list —
    /// whether Today is what is on screen. Watching the module alone meant moving between Inbox and
    /// Today changed every column without the shell being told, so the width recorder read the snap
    /// as a drag and stored the day's full width as somebody's preferred Inbox list.
    private struct ShellShape: Equatable {
        var module: AppModule?
        var isToday: Bool
    }

    private var shellShape: ShellShape {
        ShellShape(
            module: navigation.activeModule,
            isToday: navigation.activeModule == nil && navigation.selection.canonical == .today
        )
    }

    /// What primary navigation needs, at the current text size.
    private var sidebarWidths: SidebarWidths {
        SidebarMetrics.widths(fittingTitles: SidebarRegistry.nonTruncatingTitles)
    }

    /// Every column's width, decided together.
    ///
    /// ### Why one value rather than a question per pane
    /// Because the panes were asked separately and each was told about the *window*. Each one then
    /// helped itself to the space the window had spare, and there is only one lot of spare space —
    /// so the list took it, the editor got 118 points of it, and the empty state in there wrapped a
    /// syllable to a line. Which columns fit, and how wide each is, is one calculation over all of
    /// them; this is where the window asks for it and
    /// ``ElephruitDesign/ModuleShellLayout/widths(windowWidth:sidebarWidth:showsList:userWantsInspector:hasSelection:stored:)``
    /// is where it is worked out and where it is tested.
    private var shellWidths: ModuleShellLayout.Widths {
        shellLayout.widths(
            // Before the window has been measured, assume the size it opens at rather than zero —
            // a window of no width holds no columns, and the first frame would drop the editor and
            // then put it back.
            windowWidth: windowWidth > 0 ? windowWidth : Theme.Size.assumedWindowWidth,
            sidebarWidth: navigation.layoutMode.showsSidebar ? sidebarWidths.minimum : nil,
            showsList: navigation.layoutMode.showsList,
            userWantsInspector: navigation.isInspectorVisible,
            hasSelection: hasInspectableSelection,
            stored: moduleLayout.storedWidths(in: navigation.activeModule)
        )
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            SidebarView(navigation: navigation)
                // Derived, not fixed: the minimum is whatever primary navigation needs at the current
                // text size, so a long or localised title widens the sidebar rather than truncating.
                // Derived *once* per text size, because this runs on every evaluation of this body
                // and measuring twenty-five titles is not free — see ``SidebarMetrics/widths(fittingTitles:)``.
                .navigationSplitViewColumnWidth(
                    min: sidebarWidths.minimum,
                    ideal: sidebarWidths.ideal,
                    max: sidebarWidths.maximum
                )
        } content: {
            // Time replaces the list rather than opening beside it: it *is* the middle column's
            // contents for that destination, in the same way a project's task list is.
            // A concrete container is essential here. `Group` is layout-transparent, so AppKit's
            // split view can miss the width modifier below and let this column consume half the
            // window despite the module's declared maximum.
            ZStack {
                if case .project(let id, let viewID) = navigation.selection {
                    // A project replaces the middle column, on the same terms as Time, the calendar
                    // and Today: it *is* that column's contents, and it brings its own tab bar.
                    ProjectWorkspaceView(navigation: navigation, projectID: id, viewID: viewID)
                } else if navigation.selection.isTaskDestination {
                    // Tasks replace the middle column rather than filtering it. The sections, the
                    // headings, and the inline row are all specific to the scheduling model, and
                    // routing them through the generic item list would mean either a second copy of
                    // those rules or a list that cannot show them.
                    TaskWorkspaceView(navigation: navigation)
                } else if navigation.selection == .time {
                    switch navigation.timeSurface {
                    case .log:
                        TimeView(navigation: navigation)
                    case .report:
                        TimeReportView(navigation: navigation)
                    }
                } else if navigation.selection == .calendar {
                    // The calendar replaces the middle column rather than opening beside it, on the
                    // same terms as Time and the People workspace: it *is* that column's contents
                    // for this destination.
                    CalendarWorkspaceView(navigation: navigation)
                } else if navigation.selection == .today {
                    // Today replaces the middle column on the same terms as the calendar and the
                    // time sheet: it *is* that column's contents. It is not a filtered list, so
                    // there is nothing for `ItemListView` to draw and nothing for a third column to
                    // be about until something is picked.
                    TodayView(navigation: navigation)
                } else if case .people(let scope) = navigation.selection {
                    if PeoplePerformanceIsolation.usesIsolatedList {
                        IsolatedPeopleListView()
                    } else {
                        // Celebrations and My Card are not lists of people, so they replace the column
                        // rather than filtering it — the same arrangement Time already uses.
                        switch scope {
                        case .celebrations:
                            CelebrationsView(navigation: navigation)
                        case .duplicates:
                            DuplicatesView(navigation: navigation)
                        default:
                            PeopleListView(navigation: navigation, scope: scope)
                        }
                    }
                } else {
                    ItemListView(navigation: navigation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .moduleColumnWidth(
                .primary,
                layout: shellLayout,
                resolved: shellWidths.primary,
                pinned: pinnedWidths[.primary]
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                sample(width, of: .primary)
            }
        } detail: {
            // A canvas module — the calendar, the time sheet — has nothing to put in a third column,
            // and the honest expression of that is no column rather than a narrow one. What used to
            // be here was 720 points of "Nothing selected" sitting where the month should have been.
            //
            // A window too narrow to hold a usable editor gets no editor, on the same terms: a strip
            // of wrapped fragments is not a smaller editor, it is a broken one.
            if let detailWidth = shellWidths.detail {
                ItemDetailView(navigation: navigation)
                    .frame(
                        // Focus mode caps the measure: long lines are hard to read, and the point of
                        // the mode is reading and writing rather than filling the window.
                        maxWidth: navigation.layoutMode == .focus ? Theme.Size.editorMaxWidth : .infinity
                    )
                    .frame(maxWidth: .infinity)
                    .moduleColumnWidth(
                        .detail,
                        layout: shellLayout,
                        resolved: detailWidth,
                        pinned: pinnedWidths[.detail]
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        sample(width, of: .detail)
                    }
            } else {
                Color.clear
                    .navigationSplitViewColumnWidth(0)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorBinding) {
            InspectorView(navigation: navigation)
                .inspectorColumnWidth(
                    min: shellLayout.inspector.width.minimum,
                    ideal: shellWidths.inspector ?? shellLayout.inspector.width.ideal,
                    max: shellWidths.inspector ?? shellLayout.inspector.width.ideal
                )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            windowWidth = width
        }
        // Applying a module's own widths on arrival is the whole point: AppKit's split view keeps
        // its divider wherever it was last put, so without this, widening the pane to read somebody's
        // profile also moved the calendar's divider — and the calendar had no say in it.
        .task(id: shellShape) { await applyModuleLayout() }
        .onAppear { wireWidthRecorder() }
        // Anything that happened in Reminders while the app was in the background arrives when it
        // comes back. `reconcile()` is idempotent, so a pass that finds nothing writes nothing.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            reminderRefresh?.applicationDidBecomeActive()
        }
        // Linking the integration builds the adapter the coordinator needs to watch, and that
        // adapter did not exist when the coordinator started. Restarting it here is what makes the
        // first import happen at the moment the user turns Reminders on, rather than at next launch.
        .onChange(of: isRemindersEnabled) { _, isEnabled in
            guard isEnabled else {
                reminderRefresh?.stop()
                return
            }
            reminderRefresh?.start()
        }
        // Hiding the sidebar makes every other column wider without the window changing size, which
        // is precisely what the drag test mistakes for a preference. Saying so in advance is what
        // stops collapsing the sidebar from rewriting the width of the pane beside it.
        .onChange(of: navigation.layoutMode) { _, _ in
            widthRecorder.expectShellMove(of: [.primary, .detail])
        }
        .onChange(of: inspectorBinding.wrappedValue) { _, _ in
            widthRecorder.expectShellMove(of: [.primary, .detail])
        }
        // A pane that closed itself for want of anything to show comes back when there is something.
        // A pane the *user* closed stays closed — see `shouldOpenAfterSelection`.
        .onChange(of: hasInspectableSelection) { _, hasSelection in
            guard hasSelection, shellLayout.inspector.shouldOpenAfterSelection() else { return }
            navigation.isInspectorVisible = true
        }
        .focusedSceneValue(\.navigationModel, navigation)
        .focusedSceneValue(\.transferActions, TransferActions(
            export: { isExportPresented = true },
            importFiles: { isImportPresented = true }
        ))
    }

    /// Puts the window back where it was, if there is a where.
    ///
    /// Failure is silent and lands on Today: a scene string written by an older build, or one that
    /// names a module this build does not have, is not something to raise an alert about while
    /// somebody is opening their library.
    private func restoreNavigation() {
        defer {
            // After the restore, so that `-ElephruitStartModule` is an override of where the window
            // was left rather than a competitor to it. See ``DesignReviewLaunch``.
            DesignReviewLaunch.applyStart(to: navigation)
            DesignReviewLaunch.applySelection(to: navigation, using: services)
        }

        guard !storedNavigationState.isEmpty,
              let state = NavigationModel.RestorationState(encoded: storedNavigationState)
        else { return }
        navigation.restore(state)
    }

    /// Acts on a request from the menu bar, an intent, or a link.
    private func handleCalendarRequest(_ request: PendingCalendarRequest?) {
        guard let request else { return }

        navigation.select(.calendar)
        switch request {
        case .open:
            break
        case .quickEntry:
            navigation.isCalendarQuickEntryVisible = true
        case .day(let day):
            navigation.requestedCalendarDay = day
        }

        onCalendarRequestHandled()
    }

    // MARK: - Palette commands

    /// The palette's contents.
    ///
    /// Built here rather than in a global registry so that every command closes over *this* window's
    /// navigation model — a palette action in one window must not move another window.
    private var paletteCommands: [PaletteCommand] {
        // Glyphs come from the registry, never from a literal beside the row.
        let registry = services?.shortcuts ?? ShortcutRegistry()

        var commands: [PaletteCommand] = [
            PaletteCommand(id: "go-today", title: "Go to Today", category: .navigate, symbolName: "sun.max", command: .goToday, in: registry) {
                navigation.select(.today)
            },
            PaletteCommand(id: "go-inbox", title: "Go to Inbox", category: .navigate, symbolName: "tray", command: .goInbox, in: registry) {
                navigation.select(.inbox)
            },
        ]

        // One entry per module, in sidebar order, so every module is reachable from ⌘K by name.
        // Entering rather than selecting: the palette should leave the window in the same state a
        // click on the module row does, including the sidebar it puts up.
        for module in AppModule.displayOrder {
            commands.append(
                PaletteCommand(
                    id: "go-module-\(module.rawValue)",
                    title: "Go to \(module.title)",
                    category: .navigate,
                    symbolName: module.symbolName
                ) {
                    navigation.enterModule(module)
                }
            )
        }

        // Projects is not in `displayOrder` — the tree lives at the top level of the sidebar — so
        // the palette names its front door and every open project here rather than in the module
        // loop above. Individual projects by name, because "get back to the project I was in" is
        // the single most common navigation in the app and should never require the pointer.
        commands.append(
            PaletteCommand(
                id: "go-projects",
                title: "Go to All Projects",
                category: .navigate,
                symbolName: AppModule.projects.symbolName,
                command: .goProjects,
                in: registry
            ) {
                navigation.select(.kind(.project))
            }
        )

        // Time's two surfaces, by name. The tabs at the top of the Time content are the pointer
        // route; this is the keyboard one, and it works from anywhere.
        for surface in TimeSurface.allCases {
            commands.append(
                PaletteCommand(
                    id: "go-time-\(surface.rawValue)",
                    title: "Go to Time \(surface.displayName)",
                    category: .navigate,
                    symbolName: surface.symbolName
                ) {
                    navigation.select(.time)
                    navigation.timeSurface = surface
                }
            )
        }

        if let projectSidebar = services?.projectSidebar {
            var listed = Set<UUID>()
            for row in projectSidebar.favourites + projectSidebar.rows
            where !row.isArea && listed.insert(row.id).inserted {
                commands.append(
                    PaletteCommand(
                        id: "go-project-\(row.id.uuidString)",
                        title: "Go to \(row.title)",
                        category: .navigate,
                        symbolName: row.symbolName
                    ) {
                        navigation.select(.project(id: row.id, viewID: nil))
                    }
                )
            }
        }

        for kind in ItemKind.shippingInMilestoneOne where kind != .dailyEntry {
            commands.append(
                PaletteCommand(
                    id: "new-\(kind.rawValue)",
                    title: "New \(kind.displayName)",
                    category: .create,
                    symbolName: "plus"
                ) {
                    create(kind: kind)
                }
            )
        }

        commands.append(contentsOf: [
            PaletteCommand(id: "quick-capture", title: "Quick Jot", category: .create, symbolName: "square.and.pencil", command: .quickCapture, in: registry) {
                navigation.isQuickCaptureVisible = true
            },
            PaletteCommand(id: "search", title: "Search Everything", category: .navigate, symbolName: "magnifyingglass", command: .search, in: registry) {
                navigation.beginSearch()
            },
            PaletteCommand(id: "start-timer", title: "Start Timer", category: .create, symbolName: "play.circle", command: .toggleTimer, in: registry) {
                services?.timer.switchTo(item: nil)
            },
            PaletteCommand(id: "quick-log", title: "Quick Log", category: .create, symbolName: "record.circle", command: .quickLog, in: registry) {
                services?.quickLog.show()
            },
            PaletteCommand(id: "stop-timer", title: "Stop Timer", category: .create, symbolName: "stop.circle") {
                services?.timer.stop()
            },
            PaletteCommand(id: "new-event", title: "New Event…", category: .create, symbolName: "calendar.badge.plus", command: .newEvent, in: registry) {
                navigation.select(.calendar)
                navigation.isCalendarQuickEntryVisible = true
            },
            PaletteCommand(id: "search-calendar", title: "Search Calendar", category: .navigate, symbolName: "magnifyingglass") {
                navigation.select(.calendar)
                navigation.isCalendarSearchVisible = true
            },
            PaletteCommand(id: "new-person", title: "New Person…", category: .create, symbolName: "person.badge.plus") {
                navigation.isNewPersonVisible = true
            },
            PaletteCommand(id: "people-bar", title: "People Command Bar", category: .navigate, symbolName: "person.text.rectangle") {
                navigation.isPeopleCommandBarVisible = true
            },
            PaletteCommand(id: "go-celebrations", title: "Go to Celebrations", category: .navigate, symbolName: "birthday.cake") {
                navigation.select(.people(.celebrations))
            },
            PaletteCommand(id: "toggle-inspector", title: "Toggle Inspector", category: .view, symbolName: "sidebar.trailing", command: .toggleInspectorAlternate, in: registry) {
                navigation.isInspectorVisible.toggle()
            },
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", category: .view, symbolName: "sidebar.leading", command: .toggleSidebar, in: registry) {
                navigation.toggleSidebar()
            },
            PaletteCommand(id: "focus-mode", title: "Focus Mode", category: .view, symbolName: "rectangle.center.inset.filled", command: .focusMode, in: registry) {
                navigation.toggleFocusMode()
            },
            PaletteCommand(id: "export", title: "Export Library…", category: .transfer, symbolName: "square.and.arrow.up", command: .exportLibrary, in: registry) {
                isExportPresented = true
            },
            PaletteCommand(id: "import", title: "Import Files…", category: .transfer, symbolName: "square.and.arrow.down") {
                isImportPresented = true
            },
            PaletteCommand(id: "rebuild-index", title: "Rebuild Search Index", category: .view, symbolName: "arrow.clockwise") {
                Task {
                    await services?.invalidateAndWarmIndex()
                }
            },
        ])

        return commands
    }

    // MARK: - Module layout

    /// Snaps every column to what the module being entered asks for, then hands the dividers back.
    ///
    /// The pause is a single turn of the run loop rather than an animation: the split view needs one
    /// layout pass to adopt the pinned constraints, and relaxing them in the same pass would leave
    /// the old width in place. It is short enough to read as the module arriving rather than as the
    /// window rearranging itself afterwards.
    private func applyModuleLayout() async {
        // A drag detector that saw the old module's widths would read the snap as a preference.
        widthRecorder.expectShellMove(of: [.primary, .detail])

        // Pinned to what the *shell* worked out, not to what the store remembers.
        //
        // These two answers are not the same, and the difference is the whole of a bug. The store
        // knows one column's remembered width, or the module's ideal where there is none. The shell
        // knows what every column should be *given the window* — which columns fit, what each is
        // entitled to, and where any spare width goes. Pinning the store's answer therefore snapped
        // the list back to its ideal and threw the spare room away: a Notes list declared a maximum
        // of 480, was computed at 480 for a 1710-point window, and was then pinned to 340 by this
        // line, with the remaining 140 points going to a detail pane whose editor caps its own
        // measure at 720 and could not use them.
        //
        // `shellWidths` already reads the store — it passes it into `widths(…)` as `stored:` — so
        // nothing is forgotten by going through it. What is gained is that there is one calculation
        // rather than two that agree until they do not.
        let widths = shellWidths
        var pinned: [ModuleShellLayout.Column: CGFloat] = [.primary: widths.primary]
        if let detail = widths.detail { pinned[.detail] = detail }
        pinnedWidths = pinned

        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        pinnedWidths = [:]
    }

    /// Hands a column's current width to the recorder, which decides later whether it was a choice.
    ///
    /// Nothing is stored here and nothing is invalidated: the recorder is a reference type precisely
    /// so that a stream of widths arriving one per frame does not redraw the window that produced
    /// them. Samples taken while the shell has the columns pinned are dropped outright — those
    /// widths are the shell's, and it already knows what it asked for.
    private func sample(_ width: CGFloat, of column: ModuleShellLayout.Column) {
        guard pinnedWidths.isEmpty else { return }
        widthRecorder.sample(width, of: column, windowWidth: windowWidth)
    }

    /// Says what to do with a width once the recorder has decided it was one the user chose.
    ///
    /// The two models are captured by name rather than through `self`, deliberately: the recorder
    /// holds this closure for the window's lifetime, and capturing the view would mean the closure
    /// held the `@State` that holds the recorder.
    private func wireWidthRecorder() {
        let layout = moduleLayout
        let navigation = navigation

        widthRecorder.onDrag = { column, width, windowWidth in
            layout.setWidth(width, of: column, in: navigation.activeModule, available: windowWidth)
        }
    }

    // MARK: - Bindings

    /// Layout mode drives column visibility, rather than the two states drifting apart.
    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch navigation.layoutMode {
                case .full: .all
                case .twoPane: .doubleColumn
                case .focus: .detailOnly
                }
            },
            set: { visibility in
                // A drag on the divider is a layout-mode change, so the two cannot disagree.
                switch visibility {
                case .all: navigation.setLayoutMode(.full)
                case .doubleColumn: navigation.setLayoutMode(.twoPane)
                case .detailOnly: navigation.setLayoutMode(.focus)
                default: break
                }
            }
        )
    }

    private var repairSheetBinding: Binding<Bool> {
        Binding(
            get: { isRepairSheetPresented && services?.pendingContainmentRepair != nil },
            set: { isRepairSheetPresented = $0 }
        )
    }

    /// The inspector is open when the user asked for it *and* the module's policy allows it here.
    ///
    /// Three things can close it and only one of them is the user: a module whose inspector is about
    /// a selection has nothing to show when nothing is selected, and a window too narrow to hold the
    /// module's primary column and an inspector should keep the primary column. Both are decisions
    /// the module makes about itself — see ``DetailPanePolicy/isVisible(userWants:hasSelection:windowWidth:)`` —
    /// and neither overwrites what the user asked for, so widening the window again brings the
    /// inspector back rather than making them ask twice.
    /// The inspector is open when the user asked for it *and* the shell found room for a usable one.
    ///
    /// Both halves are decided in one place now. The module's policy still says whether an inspector
    /// belongs here at all and whether it needs a selection to be about; what is new is that the
    /// arithmetic gets a say — a pane that would have to be squeezed below its minimum is not shown
    /// at all, because a strip of wrapped fragments is not a narrower inspector, it is a broken one.
    /// Nothing here overwrites what the user asked for, so widening the window brings it back rather
    /// than making them ask twice.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { shellWidths.inspector != nil },
            set: { navigation.isInspectorVisible = $0 }
        )
    }

    /// Whether there is anything for the inspector to be about.
    ///
    /// An event is not an `Item`, so the calendar's selection lives on its own workspace model —
    /// which is why this asks two questions rather than reading one identifier.
    private var hasInspectableSelection: Bool {
        if navigation.selectedItemID != nil { return true }
        return navigation.calendarWorkspace?.selectedEventID != nil
    }

    private var quickCaptureBinding: Binding<Bool> {
        Binding(get: { navigation.isQuickCaptureVisible }, set: { navigation.isQuickCaptureVisible = $0 })
    }

    private var commandPaletteBinding: Binding<Bool> {
        Binding(get: { navigation.isCommandPaletteVisible }, set: { navigation.isCommandPaletteVisible = $0 })
    }

    private var taskEntryBinding: Binding<Bool> {
        Binding(get: { navigation.isTaskEntryVisible }, set: { navigation.isTaskEntryVisible = $0 })
    }

    private var tagBrowserBinding: Binding<Bool> {
        Binding(get: { navigation.isTagBrowserVisible }, set: { navigation.isTagBrowserVisible = $0 })
    }

    private var peopleCommandBarBinding: Binding<Bool> {
        Binding(
            get: { navigation.isPeopleCommandBarVisible },
            set: { navigation.isPeopleCommandBarVisible = $0 }
        )
    }

    private var newPersonBinding: Binding<Bool> {
        Binding(
            get: { navigation.isNewPersonVisible },
            set: { navigation.isNewPersonVisible = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { services?.lastError != nil },
            set: { isPresented in
                if !isPresented { services?.clearError() }
            }
        )
    }

    private var transferSummaryBinding: Binding<Bool> {
        Binding(
            get: { transferSummary != nil },
            set: { if !$0 { transferSummary = nil } }
        )
    }

    private var errorTitle: String {
        services?.lastError?.errorDescription ?? "Something went wrong"
    }

    // MARK: - Actions

    private func create(kind: ItemKind) {
        guard let services else { return }
        services.perform {
            let created = try services.items.create(ItemDraft(kind: kind))
            navigation.select(.kind(kind))
            navigation.selectItem(created.id)
            services.noteChange(to: created)
        }
    }

    /// Reads the chosen files inside their security-scoped access and imports them.
    ///
    /// The archive and Markdown paths are distinguished by extension. Each file's access is balanced
    /// by a `defer` inside one helper, so a scope can never be left open.
    private func handleImport(_ result: Result<[URL], any Error>) {
        guard let services else { return }

        switch result {
        case .failure(let error):
            services.lastError = .importFailed(format: "file", reason: error.localizedDescription)

        case .success(let urls):
            var markdownFiles: [(filename: String, contents: String)] = []
            var reports: [ImportReport] = []

            for url in urls {
                let isJSON = url.pathExtension.lowercased() == "json"

                let outcome = withSecurityScopedAccess(url) { () -> Result<Data, AppError> in
                    do {
                        return .success(try Data(contentsOf: url))
                    } catch {
                        return .failure(.fileAccessDenied(path: url.path(percentEncoded: false)))
                    }
                }

                switch outcome {
                case .failure(let error):
                    services.lastError = error
                    return
                case .success(let data):
                    if isJSON {
                        let didImport = services.perform {
                            reports.append(try services.importer.importArchive(data))
                        }
                        guard didImport else { return }
                    } else if let text = String(data: data, encoding: .utf8) {
                        markdownFiles.append((filename: url.lastPathComponent, contents: text))
                    } else {
                        services.lastError = .importFailed(
                            format: "Markdown",
                            reason: "“\(url.lastPathComponent)” is not valid UTF-8 text."
                        )
                        return
                    }
                }
            }

            if !markdownFiles.isEmpty {
                let didImport = services.perform {
                    reports.append(try services.importer.importMarkdownFiles(markdownFiles))
                }
                guard didImport else { return }
            }

            presentImportSummary(reports)
            Task { await services.invalidateAndWarmIndex() }
        }
    }

    /// Runs work inside a security-scoped resource access, always balanced.
    ///
    /// One helper so the `stopAccessing` call cannot be forgotten — the sandbox leaks quietly when it
    /// is, and the symptom appears much later as an unexplained permission failure.
    private func withSecurityScopedAccess<Value>(_ url: URL, _ work: () -> Value) -> Value {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return work()
    }

    private func presentImportSummary(_ reports: [ImportReport]) {
        guard !reports.isEmpty else { return }

        var lines = reports.map { "\($0.format): \($0.summary)" }
        let warnings = reports.flatMap(\.warnings)
        if !warnings.isEmpty {
            lines.append("")
            lines.append(contentsOf: warnings.prefix(5))
            if warnings.count > 5 {
                lines.append("…and \(warnings.count - 5) more.")
            }
        }
        transferSummary = lines.joined(separator: "\n")
    }

    private func handleRecovery(_ option: RecoveryOption, for error: AppError) {
        guard let services else { return }
        services.clearError()

        switch option {
        case .retry:
            Task { await services.invalidateAndWarmIndex() }
        case .chooseFile:
            isExportPresented = true
        case .revealLibraryInFinder:
            if let location = services.stack.location {
                NSWorkspace.shared.activateFileViewerSelecting([location.storeURL])
            }
        case .revealBackupInFinder:
            if let location = services.stack.location {
                NSWorkspace.shared.activateFileViewerSelecting([location.backupsRoot])
            }
        case .quit:
            NSApplication.shared.terminate(nil)
        case .dismiss, .locateFile, .removeReference, .keepBoth, .skip:
            break
        }
    }
}

import AppKit

extension AppServices {
    /// Throws away the index and rebuilds it. The user-visible "Rebuild Search Index" command.
    func invalidateAndWarmIndex() async {
        await search.invalidateIndex()
        await warmSearchIndex()
    }
}

/// What the menu bar or an intent asked the calendar to do.
///
/// Declared here rather than in the app target so a window can be handed one without the shell
/// depending on the app's own types — and so the same request can be produced by a test.
public enum PendingCalendarRequest: Sendable, Hashable {
    case open
    case quickEntry
    case day(Date)
}

/// Deleting whatever the list has selected, exposed to the menu bar.
///
/// The menu item existed from milestone one and was disabled, which meant `⌘⌫` did nothing in a
/// list where ⌫ already worked — a shortcut printed in a menu that does not fire is worse than an
/// absent one. Each middle column publishes its own, because what "delete" means differs between
/// them and the menu should not have to know.
public struct RowActions: Sendable, Equatable {
    public var moveToTrash: @MainActor () -> Void

    /// Whether there is anything selected to act on.
    public var isEnabled: Bool

    public init(isEnabled: Bool, moveToTrash: @escaping @MainActor () -> Void) {
        self.isEnabled = isEnabled
        self.moveToTrash = moveToTrash
    }

    /// Equal when they would look the same in the menu.
    ///
    /// The closure is deliberately not part of this, and cannot be: closures do not compare. A fresh
    /// one is built on every body evaluation of the list that publishes it, so without an `==` that
    /// ignores it SwiftUI sees a new focused value on every frame and raises
    /// *"FocusedValue update tried to update multiple times per frame"* — which is what it did.
    ///
    /// Ignoring it is also correct rather than merely convenient. Every one of those closures acts
    /// on whatever the list currently holds, so they are interchangeable; the only thing that
    /// changes what the *menu* does is whether it is enabled.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isEnabled == rhs.isEnabled
    }
}

/// Export and import, exposed to the menu bar through the focused scene.
public struct TransferActions: Sendable {
    public var export: @MainActor () -> Void
    public var importFiles: @MainActor () -> Void

    public init(export: @escaping @MainActor () -> Void, importFiles: @escaping @MainActor () -> Void) {
        self.export = export
        self.importFiles = importFiles
    }
}

extension FocusedValues {
    /// The focused window's navigation model, so menu commands act on the right window.
    @Entry public var navigationModel: NavigationModel?

    @Entry public var transferActions: TransferActions?

    /// What the focused list can do to its selection.
    @Entry public var rowActions: RowActions?
}

#Preview("Root", traits: .fixedLayout(width: 1180, height: 720)) {
    RootView()
        .appServices(AppServices.inMemory())
        .frame(width: 1180, height: 720)
}
