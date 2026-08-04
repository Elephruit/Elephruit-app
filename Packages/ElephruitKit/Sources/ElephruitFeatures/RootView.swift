import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import SwiftUI
import UniformTypeIdentifiers

/// One window.
///
/// A fixed leading sidebar beside an independently resizing content surface, with the inspector as
/// a trailing pane because an inspector is *about* the detail rather than a peer of it.
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

    /// The sidebar changes width through one path only: the user dragging its handle.
    ///
    /// The root `HStack` gives the sidebar this exact width, so destinations, empty states, module
    /// policies and sibling panes cannot negotiate it. Scene storage preserves the user's choice
    /// for this window without measuring the rendered sidebar and feeding layout back into itself.
    @SceneStorage("layout.sidebar.width") private var storedSidebarWidth = Double(SidebarMetrics.defaultWidth)
    @State private var sidebarDragStart: CGFloat?
    @State private var isWindowFullScreen = false

    /// The window's own width, so a restored column width can be clamped to what there is.
    @State private var windowWidth: CGFloat = 0

    @State private var isExportPresented = false
    @State private var isImportPresented = false
    @State private var transferSummary: String?
    @State private var isRepairSheetPresented = false

    /// Held for the window's lifetime so the observation is not cancelled the moment `task` returns.
    @State private var contactRefresh: ContactRefreshCoordinator?
    @State private var reminderRefresh: ReminderRefreshCoordinator?

    @Environment(\.scenePhase) private var scenePhase

    /// This window's own undo manager — the one `⌘Z` and the Edit menu actually reach.
    @Environment(\.undoManager) private var windowUndoManager

    /// Whether this window is key, so structural undo registers on the focused window's history.
    @Environment(\.controlActiveState) private var controlActiveState

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
        // Event monitors are application-wide even though the coordinator is window-scoped. The
        // hover tells it which shell may claim a swipe that did not begin over an action row.
        .onHover { swipes.setWindowHovered($0) }
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
        .sheet(isPresented: commandPaletteBinding) {
            CommandPaletteView(navigation: navigation, commands: paletteCommands)
        }
        .sheet(isPresented: recordsCommandBarBinding) {
            RecordsCommandBarView(navigation: navigation)
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

            // Horizontal two-finger gestures that do not belong to a row change the leading
            // sidebar. The weak capture avoids joining the two window-scoped coordinators into a
            // retain cycle: navigation already owns the callback that closes row actions above.
            swipes.onSidebarSwipe = { [weak navigation = navigation] direction in
                withAnimation(.easeOut(duration: 0.2)) {
                    navigation?.setSidebarVisible(direction == .show)
                }
            }

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
        // Structural undo registers on the focused window's manager, so Edit ▸ Undo — which is
        // dispatched to the first responder — can actually reach it. Without this, every trash,
        // move, retag and status change lands on a manager no menu has ever heard of, and ⌘Z
        // silently does nothing. Re-adopted whenever this window becomes key, so a two-window
        // session keeps each change on the history of the window it was made in.
        .task { adoptUndoManagerIfKey() }
        .onChange(of: controlActiveState) { _, _ in adoptUndoManagerIfKey() }
    }

    private func adoptUndoManagerIfKey() {
        guard controlActiveState == .key || controlActiveState == .active else { return }
        services?.undo.adopt(windowUndoManager)
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

    /// The user's sidebar width, bounded only to keep the column usable.
    private var sidebarWidth: CGFloat {
        let stored = storedSidebarWidth.isFinite
            ? CGFloat(storedSidebarWidth)
            : SidebarMetrics.defaultWidth
        return min(max(stored, SidebarMetrics.floorWidth), SidebarMetrics.maximumWidth)
    }

    /// A deliberate replacement for the split view's automatic divider negotiation.
    ///
    /// The start is captured once so every update uses the gesture's total translation rather than
    /// accumulating deltas. Nothing outside this gesture writes `storedSidebarWidth`.
    private var sidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = sidebarDragStart ?? sidebarWidth
                if sidebarDragStart == nil { sidebarDragStart = start }

                let proposed = start + value.translation.width
                storedSidebarWidth = Double(min(
                    max(proposed, SidebarMetrics.floorWidth),
                    SidebarMetrics.maximumWidth
                ))
            }
            .onEnded { _ in
                sidebarDragStart = nil
            }
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
            // The sidebar is intentionally fixed. Budget the same width the view is given below so
            // no column can borrow from it while the shell changes shape.
            sidebarWidth: navigation.layoutMode.showsSidebar ? sidebarWidth : nil,
            showsList: navigation.layoutMode.showsList,
            userWantsInspector: navigation.isInspectorVisible,
            hasSelection: hasInspectableSelection,
            stored: moduleLayout.storedWidths(in: navigation.activeModule)
        )
    }

    private var splitView: some View {
        HStack(spacing: 0) {
            if navigation.layoutMode.showsSidebar {
                SidebarView(navigation: navigation)
                    .frame(width: sidebarWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.Colors.windowBackground)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(.clear)
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .gesture(sidebarResizeGesture)
                            .help("Drag to resize the sidebar")
                            .accessibilityLabel("Resize sidebar")
                    }

            }

            NavigationStack {
                contentPanes
                    // Every destination supplies a nearer title. This keeps the unified toolbar
                    // present during the loading frames between destinations.
                    .navigationTitle(navigation.windowTitle)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                navigation.toggleSidebar()
                            } label: {
                                Label("Toggle Sidebar", systemImage: "sidebar.leading")
                            }
                            .help("Toggle Sidebar")
                        }

                        // Keep this outside the button's toolbar item. Putting the invisible
                        // alignment space beside the button made macOS draw one enormous rounded
                        // control background around both views.
                        ToolbarItem(placement: .navigation) {
                            Color.clear
                                .frame(
                                    width: max(
                                        0,
                                        sidebarWidth - (isWindowFullScreen ? 40 : 128)
                                    ),
                                    height: 1
                                )
                                .accessibilityHidden(true)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The content begins below the unified toolbar, but the sidebar is a window region rather
        // than page content. Paint its surface and boundary through the title bar as well.
        .background(alignment: .leading) {
            Theme.Colors.windowBackground
                .frame(width: navigation.layoutMode.showsSidebar ? sidebarWidth : 0)
                .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(width: 1)
                // Follow the collapsing column instead of fading at its old edge while content
                // moves through it. Opacity finishes the disappearance at the window edge.
                .offset(x: navigation.layoutMode.showsSidebar ? sidebarWidth : 0)
                .opacity(navigation.layoutMode.showsSidebar ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .background {
            WindowFullScreenReader(isFullScreen: $isWindowFullScreen)
        }
        .inspector(isPresented: inspectorBinding) {
            // SwiftUI retains the inspector content even while its binding is false. Building the
            // real inspector for a module whose policy says it is unavailable gave AppKit both the
            // inspector's 300-point content minimum and the policy's zero-point split-item maximum.
            // Omitting that content removes the contradictory constraints instead of asking the
            // split view to recover from them during layout.
            if shellLayout.inspector.isAvailable {
                InspectorView(navigation: navigation)
                    .inspectorColumnWidth(
                        min: shellLayout.inspector.width.minimum,
                        ideal: shellWidths.inspector ?? shellLayout.inspector.width.ideal,
                        max: shellWidths.inspector ?? shellLayout.inspector.width.ideal
                    )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            windowWidth = width
        }
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

    /// The sidebar is not part of this layout. These panes may redistribute all remaining space
    /// without moving or resizing the fixed sibling at the window's leading edge.
    @ViewBuilder
    private var contentPanes: some View {
        if case .records(let scope) = navigation.selection, !navigation.isSearchActive {
            RecordsWorkspaceView(navigation: navigation, scope: scope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
            if navigation.layoutMode.showsList || shellWidths.detail == nil {
                primaryPane
                    .frame(width: shellWidths.detail == nil ? nil : shellWidths.primary)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: shellWidths.detail == nil ? .infinity : nil)
            }

            if shellWidths.detail != nil {
                if navigation.layoutMode.showsList {
                    Divider()
                }

                ItemDetailView(navigation: navigation)
                    .frame(
                        maxWidth: navigation.layoutMode == .focus
                            ? Theme.Size.editorMaxWidth
                            : .infinity,
                        maxHeight: .infinity
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var primaryPane: some View {
        // Search wins over every module surface: ⌘F means "search from here", and five of the
        // seven primary surfaces had no search UI at all — `beginSearch()` set state nothing
        // rendered, and the window sat in an invisible mode whose Escape consumed a keypress to
        // leave. `ItemListView` owns the one search field and the results; while search is
        // active it renders nothing else.
        if navigation.isSearchActive {
            ItemListView(navigation: navigation)
        } else if case .project(let id, let viewID) = navigation.selection {
            ProjectWorkspaceView(navigation: navigation, projectID: id, viewID: viewID)
        } else if navigation.selection.isTaskDestination || navigation.selection == .reminders {
            RemindersWorkspaceView(navigation: navigation)
        } else if navigation.selection == .time {
            switch navigation.timeSurface {
            case .log:
                TimeView(navigation: navigation)
            case .report:
                TimeReportView(navigation: navigation)
            }
        } else if navigation.selection == .calendar {
            CalendarWorkspaceView(navigation: navigation)
        } else if navigation.selection == .today {
            TodayView(navigation: navigation)
        } else {
            ItemListView(navigation: navigation)
        }
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
            DesignReviewLaunch.applyProjectSelection(to: navigation, using: services)
            DesignReviewLaunch.applyReviewHops(to: navigation)
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
            PaletteCommand(id: "new-record", title: "New Record…", category: .create, symbolName: "plus.square.on.square") {
                navigation.select(.records(.all))
                navigation.isNewRecordVisible = true
            },
            PaletteCommand(id: "records-bar", title: "Records Command Bar", category: .navigate, symbolName: "person.text.rectangle") {
                navigation.isRecordsCommandBarVisible = true
            },
            PaletteCommand(id: "go-celebrations", title: "Go to Celebrations", category: .navigate, symbolName: "birthday.cake") {
                navigation.select(.records(.celebrations))
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

    // MARK: - Bindings

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
            set: { isVisible in
                // A hidden native inspector may echo `false` while SwiftUI is reconciling it. Do
                // not turn that echo into an observable-model write, especially for modules such
                // as Reminders that have no inspector in the first place.
                guard shellLayout.inspector.isAvailable,
                      navigation.isInspectorVisible != isVisible
                else { return }
                navigation.isInspectorVisible = isVisible
            }
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

    private var tagBrowserBinding: Binding<Bool> {
        Binding(get: { navigation.isTagBrowserVisible }, set: { navigation.isTagBrowserVisible = $0 })
    }

    private var recordsCommandBarBinding: Binding<Bool> {
        Binding(
            get: { navigation.isRecordsCommandBarVisible },
            set: { navigation.isRecordsCommandBarVisible = $0 }
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
