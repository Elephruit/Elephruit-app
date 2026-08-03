import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The first column.
///
/// ### Two levels, not one list
/// The previous sidebar showed every destination of every feature at the same time: the day's work,
/// the task system's nine views, the Records module's scopes, the library's kinds, tags, saved
/// searches, the Archive and the Trash. Nothing was wrong with any one of those rows; what was wrong
/// was that all of them were on screen at once, which turned the sidebar into an index of the app
/// rather than a statement of where you are in it.
///
/// So there are two levels. The first holds the four destinations that belong to no module — Home,
/// Today, Upcoming, Inbox — and then the modules themselves. Entering one replaces the list with
/// *that module's* navigation, and a compact header names where you are and offers the way back.
/// Nothing about a destination changes on the way in: a module is an ordered slice of the same
/// ``SidebarSelection`` values the app already had. See ``AppModule``.
///
/// ### On native selection
/// This uses `.listStyle(.sidebar)` and the system's own selection rather than a bespoke treatment.
/// macOS already draws a quiet rounded accent fill, it tracks window activation, Increase Contrast,
/// and the user's accent colour for free, and reimplementing it would mean losing keyboard
/// navigation or rebuilding it worse. Everything else about a row — content, spacing, glyph column,
/// counts, truncation — is ours.
public struct SidebarView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    /// Collapse state lives per scene, so a second window can be configured differently.
    @SceneStorage("sidebar.tags.expanded") private var isTagsExpanded = false
    @SceneStorage("sidebar.searches.expanded") private var isSearchesExpanded = false

    @State private var pendingSavedSearchDeletion: SidebarDerivedRow?

    /// Grows with the system text-size and control-size preferences.
    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    /// Whether the sidebar swaps to a module's own level for this active module.
    ///
    /// One answer, asked by the header and the levels alike. The regression this guards against was
    /// precisely the two drifting apart: the header checked ``AppModule/hasOwnSidebar`` and the
    /// levels did not, so entering a project suppressed the header *and* swapped the list for a
    /// module sidebar that draws nothing — a blank column with no way back.
    static func showsModuleLevel(for module: AppModule?) -> Bool {
        module?.hasOwnSidebar == true
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let module = navigation.activeModule, Self.showsModuleLevel(for: module) {
                ModuleHeader(module: module, navigation: navigation)
                Divider()
            }

            levels
        }
        .accessibilityIdentifier(AccessibilityID.Sidebar.root)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                newListFooter
                statusLine
            }
            // Opaque, because the list scrolls behind this inset. Without a surface of its own the
            // status line printed straight over "Across Everything" whenever the sidebar was taller
            // than the window — two lines of text through each other, reading as a rendering fault.
            .background(.bar)
        }
        .confirmationDialog(
            "Delete “\(pendingSavedSearchDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { pendingSavedSearchDeletion != nil },
                set: { if !$0 { pendingSavedSearchDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Saved Search", role: .destructive) { confirmSavedSearchDeletion() }
            Button("Cancel", role: .cancel) { pendingSavedSearchDeletion = nil }
        } message: {
            Text("The search is only its text. Nothing it finds is affected.")
        }
    }

    private func confirmSavedSearchDeletion() {
        defer { pendingSavedSearchDeletion = nil }
        guard let services,
              let row = pendingSavedSearchDeletion,
              case .savedSearch(let id) = row.selection
        else { return }
        services.deleteSavedSearch(id: id)
        if navigation.selection == row.selection { navigation.select(.today) }
    }

    // MARK: - Making a container

    /// The one control that adds to the sidebar rather than navigating it.
    ///
    /// ### Why it is here and not in the toolbar
    /// A project and an area are *sidebar* objects: they are the shape of the column, not content in
    /// the view beside it. The toolbar's `+` makes a task, in whichever list is open — a second `+`
    /// up there making a container instead would be two plus signs a few points apart meaning two
    /// different things.
    ///
    /// New Project is a direct button because a menu owns the keyboard until it has dismissed. A
    /// naming field revealed by a menu action therefore cannot accept the first keystroke. The less
    /// frequent Area action remains in the adjacent menu and carries the distinction in its help.
    ///
    /// Only in Tasks. Notes and Calendar have no containers of this kind, and a disabled control in
    /// every other module would be a permanent offer the app never intends to honour.
    @ViewBuilder
    private var newListFooter: some View {
        if navigation.activeModule == .tasks {
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    navigation.beginCreatingProject()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.plain)
                .help("Something with an end. It shows progress and can be finished.")

                Menu {
                    Button("New Area") { create(.area) }
                        .help("A standing responsibility. It never finishes, so it never shows progress.")
                } label: {
                    Image(systemName: "chevron.down")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .fixedSize()
            .padding(.horizontal, SidebarMetrics.leadingInset)
            .padding(.top, Theme.Spacing.small)
            .help("Add a project, or choose the menu for a new area")
            .accessibilityIdentifier("sidebar.tasks.newList")
        }
    }

    /// Creates the container, then opens it so the first thing that happens is naming it.
    ///
    /// The empty title is intentional: the detail header supplies a clear kind-specific prompt and
    /// takes keyboard focus, so the first typing becomes the name instead of editing placeholder
    /// content such as "New Project".
    private func create(_ kind: ItemKind) {
        guard let services else { return }
        let draft = ItemDraft(kind: kind, title: "")
        var created: Item?
        guard services.perform({ created = try services.items.create(draft) }), let created else { return }
        services.noteChange(to: created)
        navigation.select(.item(id: created.id))
        navigation.beginNaming(created.id)
    }

    /// The two levels, and the move between them.
    ///
    /// A push rather than a cross-fade, because the two levels are a hierarchy and a push is how
    /// macOS says so. `calmAnimation` is what makes it honour Reduce Motion, where the same change
    /// happens with no movement at all.
    private var levels: some View {
        ZStack {
            if let module = navigation.activeModule, Self.showsModuleLevel(for: module) {
                ModuleSidebar(module: module, navigation: navigation)
                    .transition(.push(from: .trailing))
            } else {
                primaryList
                    .transition(.push(from: .leading))
            }
        }
        .calmAnimation(Theme.Motion.appearance, value: navigation.activeModule)
    }

    // MARK: - The primary level

    private var primaryList: some View {
        List(selection: selectionBinding) {
            globalBand
            projectsBand
            moduleBand
            pinnedBand
            crossModuleBand
        }
        .listStyle(.sidebar)
        // The fixed root container supplies the sidebar surface. Let it show through instead of
        // letting AppKit's sidebar list add a second, darker material over the whole column.
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("sidebar.primary")
    }

    /// No header. This band is not a category the user chooses between — it is the default place.
    private var globalBand: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .primary)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
            }
        }
    }

    /// The Projects tree, between the day and the modules.
    ///
    /// Above the modules because a project is what people are actually in most of the time, and
    /// below the global band because Today still comes first.
    private var projectsBand: some View {
        ProjectsSidebarSection(navigation: navigation, rowHeight: rowHeight)
    }

    /// The modules.
    ///
    /// Buttons rather than selectable rows, and deliberately. Arrow keys in a `List` change the
    /// selection as they move, so tagging these would mean arrowing past Calendar *entered*
    /// Calendar and replaced the list under the cursor — the sidebar would rearrange itself while
    /// somebody was still reading it. A module is entered by activating it: click, Return, Tab and
    /// Space under Full Keyboard Access, `⌘1`–`⌘9`, the View menu, or the command palette.
    private var moduleBand: some View {
        Section("Modules") {
            ForEach(AppModule.displayOrder) { module in
                ModuleRow(module: module, navigation: navigation, rowHeight: rowHeight)
            }
        }
    }

    /// Absent when empty, rather than an empty band with a header explaining that it is empty.
    @ViewBuilder
    private var pinnedBand: some View {
        if let sidebar = services?.sidebar, !sidebar.pinned.isEmpty {
            Section("Pinned") {
                ForEach(sidebar.pinned) { row in
                    SidebarDerivedRowView(
                        row: row,
                        isSelected: navigation.selection == row.selection,
                        rowHeight: rowHeight
                    )
                }
            }
        }
    }

    /// Tags and saved searches, which belong to no module because they reach across all of them.
    ///
    /// A tag is put on a note, a task and a bookmark alike, and a saved search runs over the whole
    /// library. Filing either inside a module would be a claim about their scope that is not true,
    /// so they stay at the top level — collapsed, and absent entirely when there are none.
    @ViewBuilder
    private var crossModuleBand: some View {
        if hasCrossModuleRows {
            Section("Across Everything") {
                tagsDisclosure
                savedSearchesDisclosure
            }
        }
    }

    private var hasCrossModuleRows: Bool {
        guard let sidebar = services?.sidebar else { return false }
        return !sidebar.tags.isEmpty || !sidebar.savedSearches.isEmpty
    }

    // MARK: - Disclosure groups

    /// Bounded on purpose.
    ///
    /// Listing every tag ever created turns the sidebar into a scroll pit — one of the concrete
    /// faults of the previous design. The eight most-used are shown; the rest live behind *All Tags…*,
    /// where there is room for search and rename.
    @ViewBuilder
    private var tagsDisclosure: some View {
        if let sidebar = services?.sidebar, !sidebar.tags.isEmpty {
            DisclosureGroup(isExpanded: $isTagsExpanded) {
                ForEach(sidebar.tags) { row in
                    SidebarDerivedRowView(
                        row: row,
                        isSelected: navigation.selection == row.selection,
                        rowHeight: rowHeight
                    )
                }

                if sidebar.hasMoreTags {
                    Button("All Tags…") { navigation.isTagBrowserVisible = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(minHeight: rowHeight)
                        .hoverHighlight(
                            cornerRadius: SidebarMetrics.selectionRadius,
                            extending: SidebarMetrics.selectionInset
                        )
                        .help("Every tag, with room to search and rename")
                        .accessibilityIdentifier("sidebar.allTags")
                }
            } label: {
                Label("Tags", systemImage: "number")
                    .frame(minHeight: rowHeight)
                    .hoverHighlight(
                        cornerRadius: SidebarMetrics.selectionRadius,
                        extending: SidebarMetrics.selectionInset
                    )
                    .help("The eight tags you use most. The rest are behind All Tags.")
            }
        }
    }

    @ViewBuilder
    private var savedSearchesDisclosure: some View {
        if let sidebar = services?.sidebar, !sidebar.savedSearches.isEmpty {
            DisclosureGroup(isExpanded: $isSearchesExpanded) {
                ForEach(sidebar.savedSearches) { row in
                    SidebarDerivedRowView(
                        row: row,
                        isSelected: navigation.selection == row.selection,
                        rowHeight: rowHeight
                    )
                    // The delete a saved search never had: once made, one was permanent. Confirmed
                    // rather than trashed — a search is configuration, and the dialog says so.
                    .contextMenu {
                        Button("Delete Saved Search…", role: .destructive) {
                            pendingSavedSearchDeletion = row
                        }
                    }
                }
            } label: {
                Label("Saved Searches", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(minHeight: rowHeight)
                    .hoverHighlight(
                        cornerRadius: SidebarMetrics.selectionRadius,
                        extending: SidebarMetrics.selectionInset
                    )
                    .help("Searches you kept, re-run each time you open one")
            }
        }
    }

    // MARK: - Status

    /// One quiet line. Never a spinner in the toolbar, never a modal.
    private var statusLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: statusSymbol)
                .font(Theme.Text.metadata)
            Text(services?.syncStatus.summary ?? "")
                .font(Theme.Text.metadata)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.tertiaryText)
        .padding(.horizontal, SidebarMetrics.leadingInset)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityIdentifier(AccessibilityID.Sidebar.syncStatus)
        .accessibilityLabel(services?.syncStatus.summary ?? "")
    }

    private var statusSymbol: String {
        switch services?.syncStatus {
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .failed: "exclamationmark.triangle"
        case .idle: "checkmark.icloud"
        default: "internaldrive"
        }
    }

    // MARK: - Data

    /// Reads two stored integers. **No store access happens here** — that is criterion A1-1, and
    /// `FetchAudit` is what proves it rather than a stopwatch.
    ///
    /// Returns `nil` until the first computation lands, so the sidebar shows no badge rather than a
    /// provisional zero that later becomes three.
    private func count(for destination: SidebarDestination) -> Int? {
        guard let counts = services?.counts, counts.hasLoaded else { return nil }

        switch destination.selection {
        case .today: return counts.counts.today
        case .inbox: return counts.counts.inbox
        default: return nil
        }
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { navigation.selection.sidebarRowForm },
            set: { newValue in
                guard let newValue else { return }
                navigation.select(newValue)
            }
        )
    }
}

// MARK: - Module header

/// Where you are, and the two ways out of it.
///
/// One row: a back control that returns to the primary navigation, and the module's name as a menu
/// that switches straight to another one. Two affordances in the space of one, because a sidebar
/// header that takes three rows to say "Tasks" has spent the room the navigation needed.
struct ModuleHeader: View {
    let module: AppModule
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button {
                navigation.leaveModule()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(Theme.Text.metadata.weight(.semibold))
                    .frame(width: SidebarMetrics.iconColumn, height: rowHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Back to the main navigation")
            .accessibilityLabel("Back to all modules")
            .accessibilityIdentifier("sidebar.module.back")

            Menu {
                ForEach(AppModule.displayOrder) { candidate in
                    Button {
                        navigation.enterModule(candidate)
                    } label: {
                        Label(
                            candidate.title,
                            systemImage: candidate == module ? "checkmark" : candidate.symbolName
                        )
                    }
                }

                Divider()

                Button("All Modules", systemImage: "square.grid.2x2") {
                    navigation.leaveModule()
                }
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: module.symbolName)
                        .accessibilityHidden(true)
                    Text(module.title)
                        .font(Theme.Text.rowTitleEmphasised)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(module.hint)
            .accessibilityLabel("\(module.title) module. Switch module")
            .accessibilityIdentifier("sidebar.module.switcher")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarMetrics.leadingInset)
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityElement(children: .contain)
        // Announced rather than merely redrawn: the sidebar's whole contents have just been
        // replaced, and a VoiceOver user who is not looking at it needs to be told which.
        .onChange(of: module) { _, newValue in
            AccessibilityNotification.Announcement("\(newValue.title) module").post()
        }
    }
}

// MARK: - Rows

/// A declared destination. Never truncated — see ``SidebarMetrics``.
struct SidebarDestinationRow: View {
    let destination: SidebarDestination
    var count: Int?
    var isSelected: Bool
    var rowHeight: CGFloat

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: destination.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .accessibilityHidden(true)

            Text(destination.title)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(minHeight: rowHeight)
        .hoverHighlight(
            isEnabled: !isSelected,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(destination.selection)
        // What the destination holds, rather than what it is called — the label is already on the
        // row, and a tooltip that repeats it is a pause that teaches nothing.
        .help(destination.hint)
        .accessibilityIdentifier(destination.selection.accessibilityIdentifier)
        .accessibilityLabel(destination.title)
        .accessibilityHint(destination.hint)
    }
}

/// One module, at the top level.
struct ModuleRow: View {
    @Environment(\.services) private var services

    let module: AppModule
    let navigation: NavigationModel
    var rowHeight: CGFloat

    /// Whether this row is where the window currently is.
    ///
    /// Only answered for modules that keep the primary sidebar on screen: their row is the one
    /// place "you are here" can show. A module with its own sidebar never needs this — entering it
    /// replaces the list, and the module header names it.
    private var isCurrent: Bool {
        navigation.activeModule == module && !module.hasOwnSidebar
    }

    var body: some View {
        Button {
            navigation.enterModule(module)
        } label: {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: module.symbolName)
                    .frame(width: SidebarMetrics.iconColumn)
                    .accessibilityHidden(true)

                Text(module.title)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // The chevron promises a level to descend into. Only drawn where that is true.
                if module.hasOwnSidebar {
                    Image(systemName: "chevron.forward")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius)
                .fill(isCurrent ? Theme.Colors.selectionFill : .clear)
                .padding(.horizontal, -SidebarMetrics.selectionInset)
        )
        .hoverHighlight(
            isEnabled: !isCurrent,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .help(module.hint)
        .accessibilityIdentifier(module.accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the \(module.title) module. \(module.hint)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// The one number worth carrying up to the module list.
    ///
    /// Only Tasks, and only what is waiting to be sorted. A count beside every module would be a
    /// scoreboard of ten figures nobody asked for, which is the thing this app has decided not to be.
    private var badge: Int? {
        guard module == .tasks else { return nil }
        return services?.taskSidebar.badges[.inbox]
    }

    private var accessibilityLabel: String {
        guard let count = badge, count > 0 else { return module.title }
        return "\(module.title), \(count) in the inbox"
    }
}

/// A row derived from the store — a pinned item, a tag, a saved search.
///
/// These *may* truncate: they carry user-chosen names of unbounded length, and the full text is
/// always one hover away.
struct SidebarDerivedRowView: View {
    let row: SidebarDerivedRow
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
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(row.depth) * Theme.Spacing.medium)
        .hoverHighlight(
            isEnabled: !isSelected,
            cornerRadius: SidebarMetrics.selectionRadius,
            extending: SidebarMetrics.selectionInset
        )
        .tag(row.selection)
        // The full name, because unlike a destination this one *may* have been truncated, and
        // recovering the rest of it is what the tooltip is for here.
        .help(row.title)
        .accessibilityIdentifier(row.selection.accessibilityIdentifier)
        .accessibilityLabel(row.count.map { "\(row.title), \($0) items" } ?? row.title)
    }
}

struct SidebarCountLabel: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.Text.metadata)
            .monospacedDigit()
            .rowForeground(.tertiary)
            .accessibilityHidden(true)
    }
}

#Preview("Sidebar", traits: .fixedLayout(width: 220, height: 620)) {
    let services = AppServices.inMemory()
    return SidebarView(navigation: NavigationModel())
        .appServices(services)
        .frame(width: 220, height: 620)
}

#Preview("Inside a module", traits: .fixedLayout(width: 220, height: 620)) {
    let services = AppServices.inMemory()
    let navigation = NavigationModel()
    navigation.enterModule(.tasks)
    return SidebarView(navigation: navigation)
        .appServices(services)
        .frame(width: 220, height: 620)
}

#Preview("Sidebar at its narrowest", traits: .fixedLayout(width: 180, height: 620)) {
    let services = AppServices.inMemory()
    return SidebarView(navigation: NavigationModel())
        .appServices(services)
        .frame(width: SidebarMetrics.floorWidth, height: 620)
}
