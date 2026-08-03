import ElephruitCore
import ElephruitPersistence
import Foundation
import Observation

/// What the sidebar can select.
///
/// A value type rather than a view reference, so it can be stored for scene restoration, compared
/// for equality, and mapped to a query by a pure function that is unit-testable without a window.
public enum SidebarSelection: Hashable, Sendable, Codable {
    /// The day, whole: what needs doing, what is happening, and who is involved.
    case today

    /// **Superseded by ``today``.** Kept so that a stored scene, a saved window, or a link written
    /// by an earlier build still decodes; ``canonical`` redirects it. See the comment on ``home``.
    case upcoming

    case inbox
    case kind(ItemKind)
    case tag(slug: String)
    case savedSearch(id: UUID)
    case item(id: UUID)
    case archive
    case trash

    // Declared for destinations that later phases build. `SidebarRegistry` marks them unavailable, so
    // they are never enumerated and never reachable — but declaring them now means the phase that
    // builds one flips a flag instead of widening this enum, and a scene restored from a future
    // version decodes without loss.

    /// **Superseded by ``today``.**
    ///
    /// ### Why the case stays
    /// Home and Upcoming were two answers to one question. Home said what is *happening* — meetings,
    /// the day's note, who is waiting — and Upcoming said what is *dated*, which is most of the same
    /// records sorted differently. Somebody opening the app in the morning had to read both and hold
    /// the join in their head, and neither could show the join, because neither had seen the other's
    /// records. ``today`` is that join.
    ///
    /// The case is not deleted, because deleting it would break three things that are not the
    /// sidebar: a `@SceneStorage` string written by the previous build, a `NavigationModel`
    /// restored from it, and any link or shortcut that named it. All three now decode and land on
    /// Today — see ``canonical``.
    case home

    case calendar
    case reminders
    case time

    /// One of the Tasks module's system views.
    ///
    /// One case carrying a ``TaskSystemView`` rather than nine cases, on the same terms as
    /// ``people(_:)``: adding a view does not widen this enum, and a scene restored from a newer
    /// version still decodes.
    case taskView(TaskSystemView)

    /// A saved task smart list.
    case smartList(id: UUID)

    /// A built-in smart list, named by its stable identifier rather than by an index.
    case builtInSmartList(id: String)

    /// One slice of the reusable Records module. Imports are a filing state, not a landing page.
    case records(RecordsScope)

    /// A project's workspace, open on one of its views.
    ///
    /// Carries the view so that leaving a project on its board and coming back lands on the board,
    /// and so that a window restored from `@SceneStorage` reopens where it was. `nil` means "the
    /// first view", which is what a fresh click means and what a link from elsewhere in the app
    /// means — neither of them knows or should know which view the user was last on.
    ///
    /// **Not `.item(id:)`.** A project is not a record you inspect; it is a place you work, with its
    /// own tab bar and its own selection inside it. Routing it through the generic item detail is
    /// what made Projects the thinnest module in the app.
    case project(id: UUID, viewID: UUID?)

    /// Everything across all projects that is waiting to be read.
    case projectInbox

    /// This selection, in its current form.
    ///
    /// The one place a superseded destination is redirected. Applied by ``NavigationModel/select(_:)``
    /// and ``NavigationModel/restore(_:)``, which is every route into the app — a click, a menu
    /// command, the palette, a deep link, an intent, and a restored scene — so a redirect cannot be
    /// forgotten at one of them. Pure and total, so the redirect is a value a test can assert rather
    /// than behaviour somebody has to reproduce in a window.
    public var canonical: SidebarSelection {
        switch self {
        case .home, .upcoming: .today
        default: self
        }
    }

    /// Whether this selection is one an earlier build wrote and this one no longer draws.
    public var isSuperseded: Bool { canonical != self }

    /// The project this selection is inside, if it is one.
    public var projectID: UUID? {
        if case .project(let id, _) = self { return id }
        return nil
    }

    /// The view within that project, if one was named.
    public var projectViewID: UUID? {
        if case .project(_, let viewID) = self { return viewID }
        return nil
    }

    /// Whether the middle column is a project workspace rather than a list.
    public var isProjectWorkspace: Bool {
        if case .project = self { return true }
        return false
    }

    /// The form of this selection a sidebar row is tagged with.
    ///
    /// A project row is tagged `.project(id:viewID: nil)` — the row neither knows nor cares which
    /// of the project's views is open. The live selection *does* carry the view, so that leaving
    /// and returning lands on the same tab. Matching the row against the selection therefore drops
    /// the view, or the highlight would vanish the moment a tab was chosen.
    public var sidebarRowForm: SidebarSelection {
        if case .project(let id, _) = self { return .project(id: id, viewID: nil) }
        return self
    }

    /// The query this selection shows.
    ///
    /// Pure, so "what does Today mean?" is answered in one testable place rather than inside a view.
    public func query(using dateProvider: any DateProvider) -> ItemQuery {
        switch self {
        case .inbox:
            .inbox()
        case .kind(let kind):
            .kind(kind, sort: Self.defaultSort(for: kind))
        case .tag(let slug):
            .tag(slug: slug)
        case .item(let id):
            .children(of: id)
        case .project(let id, _):
            // The workspace runs on the arrangement engine over the project's own descendants, not
            // on a store query. This answers for the places that ask a selection what it contains —
            // the count in a title, an export — and children is the honest answer to that.
            .children(of: id)
        case .projectInbox:
            ItemQuery()
        case .savedSearch:
            // Saved searches run through the search engine, not a store query.
            ItemQuery()
        case .archive:
            .archive()
        case .trash:
            .trash()
        case .today, .home, .upcoming, .calendar, .reminders, .time:
            // These destinations replace the list rather than filtering it, so there is no query to
            // answer with. An empty one is the honest result rather than a crash.
            //
            // Today joined them when it stopped being a filtered list and became the day itself. A
            // day is three kinds of record and a set of relevance rules that no predicate expresses
            // — see ``DailyPlanService`` — and leaving a half-right query here would let some future
            // view use it by mistake. Home and Upcoming are redirected to Today before anything can
            // ask them, and answer the same way if anything ever does.
            ItemQuery()
        case .records:
            // People are fetched through `PersonRepository`, which knows about placeholders and
            // profiles. A kind query would return them but would also return the sketches nobody
            // asked to see.
            ItemQuery()
        case .taskView, .smartList, .builtInSmartList:
            // Every task view is assembled by `TaskViewService`, whose rules compare against today
            // in the user's calendar and read a lifecycle derived from four columns and a traversal.
            // None of that is a predicate, and an empty query is the honest answer rather than a
            // half-right one that a view might use by mistake.
            ItemQuery()
        }
    }

    private static func defaultSort(for kind: ItemKind) -> ItemQuery.Sort {
        switch kind {
        case .task, .reminder: .dueSoonestFirst
        case .project, .area: .manual
        default: .updatedNewestFirst
        }
    }

    /// The kind a "New Item" action should create here, so `⌘N` does the obvious thing.
    public var defaultNewItemKind: ItemKind {
        switch self {
        case .today, .home, .upcoming: .reminder
        case .inbox: .note
        case .kind(let kind): kind
        case .tag, .savedSearch, .item, .archive, .trash: .note
        // Inside a project, the obvious new thing is work. Which *kind* of work depends on the view
        // you are on — a bug view makes a bug — and the workspace intercepts the command before this
        // is reached; this is the fallback for a project opened with no view resolved yet.
        case .project: .reminder
        case .projectInbox: .reminder
        // A meeting, in the calendar. `⌘N` there means an event rather than a note, and the
        // workspace intercepts it before this is consulted — this is the honest fallback.
        case .calendar: .meeting
        case .reminders: .reminder
        case .time: .note
        case .records: .reference
        case .taskView, .smartList, .builtInSmartList: .reminder
        }
    }

    public var title: String {
        switch self {
        case .today, .home, .upcoming: "Today"
        case .inbox: "Inbox"
        case .kind(let kind): kind.pluralDisplayName
        case .tag(let slug): "#" + (TextNormalizer.slugComponents(slug).last ?? slug)
        case .savedSearch: "Saved Search"
        case .item: "Contents"
        case .archive: "Archive"
        case .trash: "Trash"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .time: "Time"
        case .records(let scope): scope.title
        case .taskView(let view): view.title
        case .project: "Project"
        case .projectInbox: "Project Inbox"
        case .smartList: "Smart List"
        case .builtInSmartList(let id): BuiltInSmartList.list(id: id)?.title ?? "Smart List"
        }
    }

    public var symbolName: String {
        switch self {
        case .today, .home, .upcoming: "sun.max"
        case .inbox: "tray"
        case .kind(let kind): kind.symbolName
        case .tag: "number"
        case .savedSearch: "line.3.horizontal.decrease.circle"
        case .item: "square.stack.3d.up"
        case .project: "square.stack.3d.up"
        case .projectInbox: "tray.full"
        case .archive: "archivebox"
        case .trash: "trash"
        case .calendar: "calendar.day.timeline.left"
        case .reminders: "bell"
        case .time: "timer"
        case .records(let scope): scope.symbolName
        case .taskView(let view): view.symbolName
        case .smartList: "line.3.horizontal.decrease.circle"
        case .builtInSmartList(let id): BuiltInSmartList.list(id: id)?.symbolName ?? "line.3.horizontal.decrease.circle"
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .today, .home, .upcoming: AccessibilityID.Sidebar.today
        case .inbox: AccessibilityID.Sidebar.inbox
        case .kind(let kind): "sidebar.kind.\(kind.rawValue)"
        case .tag(let slug): AccessibilityID.Sidebar.tag(slug: slug)
        case .savedSearch(let id): AccessibilityID.Sidebar.savedSearch(name: id.uuidString)
        case .item(let id): "sidebar.item.\(id.uuidString)"
        case .project(let id, _): "sidebar.project.\(id.uuidString)"
        case .projectInbox: "sidebar.projectInbox"
        case .archive: "sidebar.archive"
        case .trash: AccessibilityID.Sidebar.trash
        case .calendar: "sidebar.calendar"
        case .reminders: "sidebar.reminders"
        case .time: "sidebar.time"
        case .records(let scope): "sidebar.records.\(scope.id)"
        case .taskView(let view): "sidebar.tasks.\(view.rawValue)"
        case .smartList(let id): "sidebar.smartList.\(id.uuidString)"
        case .builtInSmartList(let id): "sidebar.smartList.\(id)"
        }
    }

    /// Whether this selection is one the Tasks workspace draws.
    public var taskSystemView: TaskSystemView? {
        if case .taskView(let view) = self { return view }
        return nil
    }

    public var isTaskDestination: Bool {
        switch self {
        case .taskView, .smartList, .builtInSmartList: true
        default: false
        }
    }

    /// Whether items shown here are in the Trash, which changes what actions are offered.
    public var showsTrashedItems: Bool {
        self == .trash
    }
}

/// The two halves of the Time module.
public enum TimeSurface: String, Hashable, Sendable, CaseIterable, Codable {
    /// What you did, newest first, correctable in place.
    case log

    /// Where it went, over any stretch, ready to take somewhere else.
    case report

    public var displayName: String {
        switch self {
        case .log: "Log"
        case .report: "Reports"
        }
    }

    public var symbolName: String {
        switch self {
        case .log: "list.bullet.rectangle"
        case .report: "chart.bar.xaxis"
        }
    }

    public var hint: String {
        switch self {
        case .log: "Every stretch, day by day, in the order you tracked it."
        case .report: "Totals over any period, grouped how you like, ready to export."
        }
    }
}

/// One window's navigation and presentation state.
///
/// Per-window rather than global, so two windows can look at different things — which is most of
/// the point of supporting multiple windows.
@Observable
@MainActor
public final class NavigationModel {
    public private(set) var selection: SidebarSelection = .today

    // MARK: Modules

    /// Which module the sidebar is inside, or `nil` for the primary navigation.
    ///
    /// Never set directly from a view. ``select(_:)`` derives it, so a destination reached from a
    /// menu, a deep link, the command palette, or a restored scene lands in the same place as one
    /// reached by clicking — which is the whole reason the module is derived rather than stored
    /// alongside the selection as a second source of truth.
    public private(set) var activeModule: AppModule?

    /// Where each module was left, so returning to one resumes rather than restarting.
    ///
    /// Per window, like everything else here: two windows may be in the same module looking at
    /// different things.
    public private(set) var moduleSelections: [AppModule: SidebarSelection] = [:]

    /// The open project workspace, when there is one.
    ///
    /// Held here rather than reached through a `@FocusedValue` because the shell asks *whether an
    /// inspector exists at all* before anything inside it is drawn. A focused value reaches the
    /// pane's contents and not that decision — which is how a project's work became uneditable:
    /// `hidesWhenNothingSelected` asked only about `selectedItemID` and the calendar's event, got no
    /// for both, and kept the pane permanently shut.
    public var projectWorkspace: ProjectWorkspaceModel?

    /// Everything selected in the list.
    ///
    /// The set is the truth; ``selectedItemID`` is the one the detail pane shows. Keeping both means
    /// a multi-selection can act on twenty items while the editor still shows something coherent
    /// rather than going blank.
    public var selectedItemIDs: Set<UUID> = [] {
        didSet {
            let previousPrimary = selectedItemID
            reconcilePrimarySelection()
            guard !isApplyingHistory, previousPrimary != selectedItemID else { return }
            recordNavigation(
                NavigationLocation(
                    selection: selection,
                    activeModule: activeModule,
                    moduleSelections: moduleSelections,
                    selectedItemIDs: oldValue,
                    selectedItemID: previousPrimary
                )
            )
        }
    }

    /// The item the detail pane shows.
    public private(set) var selectedItemID: UUID?

    /// A newly created item whose title field should take the keyboard when its detail appears.
    ///
    /// This is a one-shot request rather than a general focus preference: opening an existing item
    /// should not unexpectedly put the insertion point in its title.
    public var titleEditRequest: UUID?

    /// A direct request to reveal the unsaved project-name field in the primary sidebar.
    ///
    /// The Tasks sidebar can make this request while the Projects section is not mounted. Keeping
    /// the token here lets the section consume it after navigation brings the primary sidebar back.
    public private(set) var projectCreationRequestID: UUID?

    // MARK: Browser-style history

    private struct NavigationLocation: Equatable {
        var selection: SidebarSelection
        var activeModule: AppModule?
        var moduleSelections: [AppModule: SidebarSelection]
        var selectedItemIDs: Set<UUID>
        var selectedItemID: UUID?
    }

    private var backHistory: [NavigationLocation] = []
    private var forwardHistory: [NavigationLocation] = []
    @ObservationIgnored private var isApplyingHistory = false

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    // MARK: Layout and focus

    public var layoutMode: LayoutMode = .full
    public var focusedPane: ShellPane = .list

    /// Whether the inspector is open, in the module the window is currently in.
    ///
    /// ### Why this is per module and not one flag
    /// It was one flag, and one flag is the same mistake as one width. The inspector shows a
    /// different thing in every module — an event in the calendar, a person's context in People,
    /// the field editor elsewhere — so "I want the inspector" is a sentence about the module you
    /// said it in. Opening the event inspector to check a meeting's guest list should not mean that
    /// every note you open for the rest of the session arrives with a field editor beside it.
    ///
    /// Per *window*, not persisted, unlike the widths: a width is an opinion about the module and a
    /// window's open panes are the shape of this window's session. Two windows in People are
    /// entitled to disagree about whether the context sidebar is showing.
    ///
    /// A module absent from the dictionary uses its own policy's answer, so a module whose
    /// inspector is the point of it does not start closed.
    public var isInspectorVisible: Bool {
        get {
            inspectorVisibility[activeModule] ?? !activeModule.shellLayout.inspector.hidesWhenNothingSelected
        }
        set { inspectorVisibility[activeModule] = newValue }
    }

    private var inspectorVisibility: [AppModule?: Bool] = [:]

    public var isQuickCaptureVisible = false

    /// The task entry surface.
    ///
    /// A different panel from Quick Jot, because the two answer different questions. Quick Jot takes
    /// a thought and files it as a note; this one reads a sentence about a *task* and shows what it
    /// understood — dates, a repeat, a destination — before anything is created. Merging them would
    /// mean one field whose behaviour changed depending on what the first word turned out to be.
    public var isTaskEntryVisible = false
    public var isCommandPaletteVisible = false

    /// The Records command bar, which is a different surface from the general ⌘K palette.
    ///
    /// Two bars rather than one because they answer different questions. The palette runs *commands*
    /// the app defines; this one reads a sentence about a person and shows what it understood before
    /// anything happens. Merging them would mean one field whose behaviour changes depending on what
    /// the first word turned out to be.
    public var isRecordsCommandBarVisible = false

    /// The plain form for adding any person or thing by hand.
    public var isNewRecordVisible = false

    /// The full tag list, reached from the sidebar's bounded disclosure group.
    public var isTagBrowserVisible = false

    /// The calendar's natural-language entry field, which can be opened from anywhere.
    public var isCalendarQuickEntryVisible = false

    /// Searching the calendar, which is a different question from searching the library and so has
    /// its own surface rather than a scope switch on the general field.
    public var isCalendarSearchVisible = false

    /// The calendar's own state, once the workspace has built it.
    ///
    /// Held here rather than inside `CalendarWorkspaceView` because the Calendar module's sidebar
    /// needs to read and set the view kind, and a `@State` on the middle column is reachable only
    /// from the middle column. Per window, like the rest of this type: two windows may be looking at
    /// different weeks.
    ///
    /// `nil` until the workspace has been on screen once, which is what the sidebar's own fallback
    /// is for — the module can be entered before the calendar has ever been drawn.
    public var calendarWorkspace: CalendarWorkspaceModel?

    /// Which period the Time module is reporting over.
    ///
    /// Held here rather than inside `TimeView` so the Time module's sidebar can offer it. A mode
    /// that only one control in the middle column can reach is a mode the sidebar cannot navigate
    /// by, which is what left that module with a single row that did nothing.
    public var timeWindow: TimeWindow = .today

    /// How the Time module's entries are rolled up.
    public var timeGrouping: TimeGrouping = .item

    /// Which half of the Time module is on screen.
    ///
    /// A mode rather than a second sidebar destination, because the two are the same *content* asked
    /// two different questions — what did I do, and where did it go — and a destination would give
    /// them separate selections, separate window titles, and two places for the period to be
    /// remembered differently.
    public var timeSurface: TimeSurface = .log

    /// A day something outside the window asked the calendar to show.
    ///
    /// Cleared by the workspace once it has landed there, so a request cannot fire twice — and held
    /// here rather than on the workspace because the workspace may not exist yet when the request
    /// arrives, which is exactly the case when the app was launched by the link.
    public var requestedCalendarDay: Date?

    // MARK: Search as a mode

    /// Whether the list is currently showing search results rather than its usual contents.
    public private(set) var isSearchActive = false

    /// A new value for every explicit request to focus search, including while search is active.
    ///
    /// A Boolean describes mode but cannot describe the event “focus it again.” Without this, ⌘F
    /// after Escape cleared or dismissed a field assigned `true` to an already-true value, so no
    /// observer ran and focus stayed wherever it was.
    public private(set) var searchFocusRequest = 0

    /// The live query while search is active.
    public var searchQuery = ""

    /// The query from the last search, kept so reopening search can offer it again.
    ///
    /// This is what lets one Escape leave search without losing what was typed. Clearing a query has
    /// its own familiar affordances — select and delete, or the clear button — and is not Escape's job.
    public private(set) var lastSearchQuery = ""

    /// Set when search opens with a restored query, so the field selects it and typing replaces it.
    public private(set) var shouldSelectSearchQuery = false

    /// What was selected before search began, restored when it ends.
    @ObservationIgnored private var selectionBeforeSearch: UUID?

    /// Sort override for the current list. Reset when the selection changes, because a sort that
    /// made sense for Tasks rarely makes sense for Notes.
    public var sortOverride: ItemQuery.Sort?

    /// Recent search queries, newest first. Session-scoped: a search history that outlives the
    /// session is a privacy liability nobody asked for.
    public private(set) var recentSearches: [String] = []

    public init() {}

    public func select(_ requested: SidebarSelection) {
        // Every route into the app funnels through here — a click, a menu command, the palette, a
        // deep link, an intent — so redirecting a superseded destination once, at the door, is what
        // makes "Home and Upcoming still work" true everywhere rather than at the call sites
        // somebody remembered.
        let selection = requested.canonical
        guard self.selection != selection else { return }

        recordNavigation(currentLocation)

        // Before anything moves. A debounced editor write is the one piece of state a navigation
        // can destroy, and flushing here means it cannot matter *which* navigation happened —
        // module switch, deep link, menu command, or a click in the list.
        withoutRecordingHistory {
            flushPendingEdits()
            self.selection = selection
            applyModule(for: selection)
            selectedItemIDs = []
            sortOverride = nil
        }
    }

    /// Enters a module, resuming wherever it was last left.
    ///
    /// Re-entering the module you are already in is deliberately *not* a no-op at the sidebar level
    /// — it is how the header's module menu confirms a choice — but it does not disturb the
    /// selection, so choosing "Tasks" while inside Tasks does not throw away where you were.
    public func enterModule(_ module: AppModule) {
        let resumed = moduleSelections[module] ?? module.defaultSelection
        // Guard against a remembered selection that has since stopped belonging to the module —
        // which is what a deleted smart list looks like from here.
        let destination = module.contains(resumed) ? resumed : module.defaultSelection

        guard selection != destination || activeModule != module else { return }
        recordNavigation(currentLocation)

        withoutRecordingHistory {
            if selection != destination {
                select(destination)
            }

            // Set explicitly rather than relying on `select`. Stepping back into the module you just
            // left lands on the selection you left it at, so `select` has nothing to do and would
            // otherwise leave the sidebar outside the module it was asked to enter.
            activeModule = module
            moduleSelections[module] = selection
        }
    }

    /// Returns to Today and remembers where the module was left.
    /// Browser-style Back still returns to the module, while the main sidebar never frames a module
    /// workspace as though it were a narrow generic list.
    public func leaveModule() {
        guard let activeModule else { return }
        recordNavigation(currentLocation)
        withoutRecordingHistory {
            moduleSelections[activeModule] = selection
            self.activeModule = nil
            selection = .today
            selectedItemIDs = []
            sortOverride = nil
        }
    }

    /// Goes to the previous place visited in this window, including the selected record.
    public func goBack() {
        guard let destination = backHistory.popLast() else { return }
        flushPendingEdits()
        forwardHistory.append(currentLocation)
        apply(destination)
    }

    /// Returns to a place left by ``goBack()``.
    public func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        flushPendingEdits()
        backHistory.append(currentLocation)
        apply(destination)
    }

    private var currentLocation: NavigationLocation {
        NavigationLocation(
            selection: selection,
            activeModule: activeModule,
            moduleSelections: moduleSelections,
            selectedItemIDs: selectedItemIDs,
            selectedItemID: selectedItemID
        )
    }

    private func recordNavigation(_ location: NavigationLocation) {
        guard !isApplyingHistory else { return }
        if backHistory.last != location { backHistory.append(location) }
        if backHistory.count > 100 { backHistory.removeFirst(backHistory.count - 100) }
        forwardHistory.removeAll()
    }

    private func apply(_ location: NavigationLocation) {
        withoutRecordingHistory {
            selection = location.selection
            activeModule = location.activeModule
            moduleSelections = location.moduleSelections
            selectedItemIDs = location.selectedItemIDs
            selectedItemID = location.selectedItemID
            sortOverride = nil
        }
    }

    private func withoutRecordingHistory(_ operation: () -> Void) {
        let wasApplyingHistory = isApplyingHistory
        isApplyingHistory = true
        defer { isApplyingHistory = wasApplyingHistory }
        operation()
    }

    /// Keeps ``activeModule`` and ``moduleSelections`` true after a selection change.
    private func applyModule(for selection: SidebarSelection) {
        if let module = AppModule.module(for: selection) {
            activeModule = module
            moduleSelections[module] = selection
        } else if GlobalDestination.contains(selection) {
            if let activeModule { moduleSelections[activeModule] = self.selection }
            activeModule = nil
        } else if let activeModule {
            // A pinned item, a tag, or a saved search opened from inside a module. It belongs to no
            // module of its own, so the one you are in keeps you.
            moduleSelections[activeModule] = selection
        }
    }

    // MARK: - Unsaved work

    /// Editors with a debounced write outstanding, keyed so a window can hold several.
    @ObservationIgnored private var editFlushes: [UUID: () -> Void] = [:]

    /// Registers a flush to run before any navigation.
    ///
    /// The editor already flushes when the item it is showing changes. This exists for the changes
    /// it cannot see — leaving a module, following a deep link, a menu command — where the view that
    /// owns the pending write may be torn down before its own `task(id:)` runs.
    public func registerEditFlush(_ id: UUID, _ flush: @escaping () -> Void) {
        editFlushes[id] = flush
    }

    public func unregisterEditFlush(_ id: UUID) {
        editFlushes.removeValue(forKey: id)
    }

    /// Runs every outstanding write now. Idempotent — ``PendingSave`` clears its work before running
    /// it, so a flush racing the debounce cannot write twice.
    public func flushPendingEdits() {
        for flush in editFlushes.values { flush() }
    }

    // MARK: - Restoration

    /// Everything about *where the user is* that survives a relaunch.
    ///
    /// The selection alone is not enough: a tag opened from inside Notes restores as a tag, and
    /// without the module the sidebar would come back showing the primary navigation with a
    /// selection that is not in it.
    public struct RestorationState: Codable, Hashable, Sendable {
        public var module: AppModule?
        public var selection: SidebarSelection
        public var moduleSelections: [AppModule: SidebarSelection]

        /// Which of Time's two surfaces was open. Optional so a scene written by an earlier
        /// build — which never recorded it — still decodes; `nil` restores to the log.
        public var timeSurface: TimeSurface?

        public init(
            module: AppModule?,
            selection: SidebarSelection,
            moduleSelections: [AppModule: SidebarSelection] = [:],
            timeSurface: TimeSurface? = nil
        ) {
            self.module = module
            self.selection = selection
            self.moduleSelections = moduleSelections
            self.timeSurface = timeSurface
        }

        /// Encoded for `@SceneStorage`, which stores strings.
        ///
        /// Returns `nil` rather than throwing: a state that cannot be written is a scene that
        /// restores to Today, which is a worse outcome than nothing but not an error worth raising
        /// to somebody in the middle of their work.
        public var encoded: String? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public init?(encoded: String) {
            guard let data = encoded.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Self.self, from: data)
            else { return nil }
            self = decoded
        }
    }

    public var restorationState: RestorationState {
        RestorationState(
            module: activeModule,
            selection: selection,
            moduleSelections: moduleSelections,
            timeSurface: timeSurface
        )
    }

    /// Puts the window back where it was.
    ///
    /// A restored selection is checked against the module it claims to be in. A scene written by a
    /// build where Bookmarks was its own module, restored into one where it is not, must land
    /// somewhere real rather than in a module whose sidebar would not draw it.
    public func restore(_ state: RestorationState) {
        backHistory.removeAll()
        forwardHistory.removeAll()
        withoutRecordingHistory {
            moduleSelections = state.moduleSelections
            timeSurface = state.timeSurface ?? .log
            select(state.selection)

            if let module = state.module, activeModule == nil, !GlobalDestination.contains(state.selection) {
                // A tag or a pinned item, which belongs to no module of its own but was being read
                // inside one.
                activeModule = module
            }
        }
    }

    // MARK: - Titles

    /// What the window is called.
    ///
    /// The selection's own name, except at a module's front door, where the module's name is the
    /// more useful of the two: "Tasks" says where you are, and "Today" — which is also a global
    /// destination — does not.
    public var windowTitle: String {
        guard let activeModule, selection == activeModule.defaultSelection else {
            return selection.title
        }
        return activeModule.title
    }

    /// Selects exactly one item.
    public func selectItem(_ id: UUID?) {
        selectedItemIDs = id.map { [$0] } ?? []
    }

    /// Selects a new item and puts its title field into the typing path.
    public func beginNaming(_ id: UUID) {
        titleEditRequest = id
        selectItem(id)
    }

    /// Opens the Projects section in naming mode without creating or saving anything first.
    public func beginCreatingProject() {
        projectCreationRequestID = UUID()
        select(.kind(.project))
    }

    public func consumeProjectCreationRequest(_ id: UUID) {
        guard projectCreationRequestID == id else { return }
        projectCreationRequestID = nil
    }

    /// A task somebody asked to open, from somewhere that is not the task list.
    ///
    /// ### Why this is a request rather than a navigation
    /// Because a task no longer has a pane of its own to be shown in: it is opened by making its row
    /// taller, in the list it lives in — see ``TaskCard``. So a backlink, a person's page, a search
    /// result or a deep link cannot simply *show* a task; it has to say "go to where this lives and
    /// open it there", and the two halves of that happen in different views. The destination is set
    /// here, and ``TaskWorkspaceView`` picks the request up when it arrives and opens the card.
    ///
    /// Cleared by the workspace on the way through, so a second click on the same task opens it
    /// again rather than being swallowed as a duplicate.
    public var taskToOpen: UUID?

    /// Goes to a task, wherever it lives.
    ///
    /// - Parameters:
    ///   - id: the task.
    ///   - destination: the list it lives in — its project, its list, or the system view it falls
    ///     into. The caller resolves this because it has the store and this does not.
    public func openTask(_ id: UUID, in destination: SidebarSelection) {
        select(destination)
        selectItem(id)
        taskToOpen = id
    }

    /// Whether a batch action bar should appear.
    public var hasMultipleSelection: Bool {
        selectedItemIDs.count > 1
    }

    /// Keeps the detail pane pointed at something that is still selected.
    ///
    /// When a selection shrinks, the previously-shown item may no longer be in it; when it grows,
    /// the first one stays put rather than the pane jumping around as the user shift-clicks.
    private func reconcilePrimarySelection() {
        if let current = selectedItemID, selectedItemIDs.contains(current) { return }
        selectedItemID = selectedItemIDs.first
    }

    // MARK: - Search mode

    /// Enters search, offering the previous query back.
    public func beginSearch(clearingQuery: Bool = false) {
        searchFocusRequest &+= 1

        if !isSearchActive {
            selectionBeforeSearch = selectedItemID
            isSearchActive = true
            searchQuery = clearingQuery ? "" : lastSearchQuery
            shouldSelectSearchQuery = !searchQuery.isEmpty
        } else {
            // Repeating ⌘F means “take me to search so I can replace this,” matching Finder and
            // Safari. Focus alone strands the insertion point inside the old query.
            shouldSelectSearchQuery = !searchQuery.isEmpty
        }

        focusedPane = .list
    }

    /// Leaves search, restoring the previous list and selection.
    ///
    /// The query survives in ``lastSearchQuery``. Nothing the user typed is thrown away, and the
    /// selection they had before searching comes back — Escape never destroys work.
    public func endSearch() {
        guard isSearchActive else { return }

        if !searchQuery.isEmpty {
            lastSearchQuery = searchQuery
            recordSearch(searchQuery)
        }

        isSearchActive = false
        searchQuery = ""
        shouldSelectSearchQuery = false
        selectItem(selectionBeforeSearch)
        selectionBeforeSearch = nil
    }

    /// Called by the search field once it has consumed the select-all hint.
    public func didSelectSearchQuery() {
        shouldSelectSearchQuery = false
    }

    // MARK: - Layout and focus

    /// Whether a list row is showing its swipe actions.
    ///
    /// Mirrored from the window's ``SwipeActionCoordinator`` rather than read from it, because the
    /// Escape ladder is a pure function of a value type and reaching into a coordinator from inside
    /// it would make the ladder untestable in exactly the case worth testing.
    public var hasRevealedRowActions = false

    /// Runs when the ladder decides Escape should put a row's actions away.
    ///
    /// A closure because the coordinator lives in the design module, below this one. The window
    /// wires the two together; neither has to know about the other.
    @ObservationIgnored public var onCloseRowActions: (() -> Void)?

    public var shellState: ShellState {
        ShellState(
            hasOverlay: isQuickCaptureVisible || isCommandPaletteVisible || isTagBrowserVisible
                || isTaskEntryVisible,
            hasRevealedRowActions: hasRevealedRowActions,
            isSearchActive: isSearchActive,
            focusedPane: focusedPane,
            layoutMode: layoutMode
        )
    }

    /// Applies one rung of the Escape ladder. Returns whether anything happened, so the key event is
    /// only consumed when it did something.
    @discardableResult
    public func handleEscape() -> Bool {
        let outcome = EscapeLadder.outcome(for: shellState)

        switch outcome {
        case .dismissOverlay:
            isQuickCaptureVisible = false
            isCommandPaletteVisible = false
            isTagBrowserVisible = false
            isTaskEntryVisible = false

        case .closeRowActions:
            onCloseRowActions?()
            hasRevealedRowActions = false

        case .leaveSearch:
            endSearch()

        case .leaveFocusMode:
            setLayoutMode(.full)

        case .focusList, .focusSidebar:
            guard let destination = EscapeLadder.destination(for: outcome) else { return false }
            focusedPane = destination

        case .nothing:
            return false
        }

        return true
    }

    /// Changes layout mode, keeping focus somewhere visible.
    public func setLayoutMode(_ mode: LayoutMode) {
        layoutMode = mode

        // Focus must never be left on a pane the mode has just hidden.
        if !mode.isVisible(focusedPane) {
            focusedPane = mode.showsList ? .list : .detail
        }
    }

    public func toggleSidebar() {
        setLayoutMode(layoutMode == .full ? .twoPane : .full)
    }

    /// Shows or hides the leading sidebar without making an already-satisfied gesture toggle it.
    ///
    /// Directional trackpad gestures can arrive more than once near their threshold. Expressing
    /// the intended visibility, rather than toggling, makes repeated left events stay hidden and
    /// repeated right events stay shown.
    public func setSidebarVisible(_ isVisible: Bool) {
        if isVisible {
            guard !layoutMode.showsSidebar else { return }
            setLayoutMode(.full)
        } else {
            guard layoutMode.showsSidebar else { return }
            setLayoutMode(.twoPane)
        }
    }

    public func toggleFocusMode() {
        setLayoutMode(layoutMode == .focus ? .full : .focus)
    }

    /// Moves focus to the next visible pane.
    public func advanceFocus(reversed: Bool = false) {
        focusedPane = PaneTraversal.next(
            after: focusedPane,
            layoutMode: layoutMode,
            isInspectorVisible: isInspectorVisible,
            reversed: reversed
        )
    }

    /// Moves focus to a pane, if that pane is on screen.
    public func focus(_ pane: ShellPane) {
        guard layoutMode.isVisible(pane) else { return }
        guard pane != .inspector || isInspectorVisible else { return }
        focusedPane = pane
    }

    public func recordSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 12 {
            recentSearches.removeLast(recentSearches.count - 12)
        }
    }

    public func clearRecentSearches() {
        recentSearches.removeAll()
    }

    /// The query for the current selection, with any sort override applied.
    public func currentQuery(using dateProvider: any DateProvider) -> ItemQuery {
        var query = selection.query(using: dateProvider)
        if let sortOverride {
            query.sort = sortOverride
        }
        return query
    }
}
