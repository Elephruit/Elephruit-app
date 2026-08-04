import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The first column.
///
/// ### One level, in bands
/// Today and the Inbox first, then the projects tree, then the Library — the six modules work
/// happens in — then, while a module with real navigation of its own is active, that module's
/// sources as sections beneath it. Tags and saved searches keep their place, and the Archive and
/// the Trash sit at the bottom the way Notes keeps Recently Deleted. The earlier design swapped
/// this whole column for a module's own list on entry; see `primaryList` for why that lost.
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

    public var body: some View {
        primaryList
        .accessibilityIdentifier(AccessibilityID.Sidebar.root)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusLine
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

    // MARK: - The one level

    /// One scrolling source list, in the pattern of Notes, Mail and Reminders.
    ///
    /// ### Why the second level is gone
    /// The sidebar used to swap wholesale when a module with its own navigation was entered — a
    /// push, a compact header, a back chevron. The argument was short lists; the price was that
    /// entering Calendar erased the projects tree, the tags, the pinned items, and every other
    /// place the user could go. The flows this app is actually used through pivot constantly
    /// between Today, a project, Reminders and a person, and the swap taxed exactly those pivots.
    /// No first-party app replaces its whole source list on selection; sections do the same work
    /// without amnesia. A module's own sources — Calendar's views and calendars, Notes' kinds —
    /// now appear as sections *below* the Library while that module is active: where you are never
    /// erases where you can go.
    private var primaryList: some View {
        List(selection: selectionBinding) {
            globalBand
            projectsBand
            libraryBand
            contextBand
            pinnedBand
            crossModuleBand
            libraryEdgesBand
        }
        .listStyle(.sidebar)
        // No background suppression any more: the shell is a real split view, so this column
        // finally wears the sidebar material — vibrancy, desktop tint, the lot — that the
        // hand-rolled shell had been painting over with flat window background.
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

    /// The modules the library is made of.
    ///
    /// Six, not ten: Areas live in the projects tree where they already render as containers, and
    /// Archive and Trash move to the bottom rail — a wastebasket listed as a peer of Calendar was
    /// most of what made the old band read as an index rather than a map.
    ///
    /// Still buttons rather than selectable rows: entering a module restores where you last were
    /// in it, which is a side effect arrowing through a `List` must not trigger row by row.
    static let libraryModules: [AppModule] = [
        .notes, .reminders, .calendar, .records, .time, .bookmarks,
    ]

    private var libraryBand: some View {
        Section("Library") {
            ForEach(Self.libraryModules) { module in
                ModuleRow(module: module, navigation: navigation, rowHeight: rowHeight)
            }
        }
    }

    /// The active module's own sources, as sections below the Library.
    ///
    /// What the second level used to hold, without the amnesia: Calendar's views, calendars and
    /// sets; Notes' kinds. Only the modules with real navigation get one — the rule the old
    /// design stated and paid a column swap for.
    @ViewBuilder
    private var contextBand: some View {
        switch navigation.activeModule {
        case .calendar:
            CalendarSidebarSection(navigation: navigation)

        case .notes:
            Section("Notes") {
                ForEach(notesContextRows) { destination in
                    SidebarDestinationRow(
                        destination: destination,
                        isSelected: navigation.selection == destination.selection,
                        rowHeight: rowHeight
                    )
                }
            }

        default:
            EmptyView()
        }
    }

    /// Notes' sub-destinations — the front door is the Library row itself.
    private var notesContextRows: [SidebarDestination] {
        SidebarRegistry.sidebarRows(in: .notes)
            .filter { $0.selection != AppModule.notes.defaultSelection }
    }

    /// Archive and Trash, at the bottom where Notes keeps Recently Deleted — reachable, and no
    /// longer peers of the places work actually happens.
    private var libraryEdgesBand: some View {
        Section {
            ForEach(SidebarRegistry.sidebarRows(in: .archive) + SidebarRegistry.sidebarRows(in: .trash)) { destination in
                SidebarDestinationRow(
                    destination: destination,
                    isSelected: navigation.selection == destination.selection,
                    rowHeight: rowHeight
                )
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
    private var isCurrent: Bool {
        navigation.activeModule == module
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
    /// Module badges are deliberately absent. A count beside every module would be a scoreboard of
    /// figures nobody asked for.
    private var badge: Int? {
        nil
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
    navigation.enterModule(.reminders)
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
