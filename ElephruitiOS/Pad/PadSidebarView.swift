import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftData
import SwiftUI

/// The iPad's global sidebar.
///
/// The Mac's own bands, in the Mac's order and wearing the Mac's names: the day and the inbox
/// first, then the user's project tree — their structure above any of ours — then the Library the
/// six working modules make up, then whichever of those modules has navigation of its own, then
/// what the user pinned, then the tags that belong to no module, and the Archive and the Trash on
/// the bottom rail where Notes keeps Recently Deleted.
///
/// It never swaps itself for a module's own column. That was the Mac's founding sidebar decision
/// (`SidebarView.primaryList` argues it) and it costs more here, not less: an iPad user pivots
/// between a project, Today, a person and Reminders by touch, and a column that erased the other
/// three each time would tax exactly those pivots.
///
/// Nothing here touches the store while a row is drawing. Every band reads a value some service
/// recomputed on change — `projectSidebar.rows`, `sidebar.pinned`, `sidebar.tags`, `counts.counts` —
/// which is the same `FetchAudit` contract the Mac's column is held to.
struct PadSidebarView: View {
    @Environment(\.services) private var services
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    @Binding var selection: PadRoot

    /// Collapse state lives per scene, so a second window can be configured differently — the
    /// Mac's rule, for the same reason.
    @SceneStorage("pad.sidebar.tags.expanded") private var isTagsExpanded = false
    @SceneStorage("pad.sidebar.searches.expanded") private var isSearchesExpanded = false
    @SceneStorage("pad.sidebar.archived.expanded") private var isArchivedExpanded = false

    /// Counts and the user's own lists, read on change and never during a render.
    @State private var todayCount = 0
    @State private var inboxCount = 0
    @State private var savedSmartLists: [SmartListModel] = []
    @State private var savedSearches: [PadSavedSearchRow] = []

    /// The Library, in the Mac's own order — `SidebarView.libraryModules`, said in iPad terms.
    /// Areas are absent because they live in the projects tree above, where they already render
    /// as containers; the Archive and the Trash are absent because they are the bottom rail.
    private static let libraryRoots: [PadRoot] = [
        .kindList(.note), .reminders, .calendar, .records(.all), .time, .kindList(.bookmark),
    ]

    var body: some View {
        List {
            globalBand
            projectsBand
            libraryBand
            contextBand
            pinnedBand
            crossModuleBand
            edgesBand
        }
        .listStyle(.sidebar)
        .navigationTitle("Elephruit")
        .accessibilityIdentifier("pad.sidebar")
        .task(id: services?.changeToken) { refresh() }
    }

    // MARK: - Bands

    /// No header. This band is not a category the user chooses between — it is where you are.
    private var globalBand: some View {
        Section {
            row(.today, title: "Today", systemImage: "sun.horizon", count: todayCount)
            row(.inbox, title: "Inbox", systemImage: "tray", count: inboxCount)
            row(.search, title: "Search", systemImage: "magnifyingglass")
        }
    }

    /// The user's own structure, between the day and the modules — and never replaced by
    /// entering anything.
    @ViewBuilder
    private var projectsBand: some View {
        if let projects = services?.projectSidebar, !projects.isEmpty {
            if !projects.favourites.isEmpty {
                Section("Favorites") {
                    ForEach(projects.favourites) { projectRow($0, indented: false) }
                }
            }

            Section("Projects") {
                ForEach(projects.rows) { projectRow($0, indented: true) }

                if !projects.archived.isEmpty {
                    DisclosureGroup(isExpanded: $isArchivedExpanded) {
                        ForEach(projects.archived) { projectRow($0, indented: false) }
                    } label: {
                        Label("Archived Projects", systemImage: "archivebox")
                            .font(Theme.Text.rowTitle)
                    }
                }
            }
        }
    }

    /// The modules the library is made of.
    private var libraryBand: some View {
        Section("Library") {
            ForEach(Self.libraryRoots, id: \.self) { root in
                row(root, title: root.libraryTitle, systemImage: root.librarySymbolName)
            }
        }
    }

    /// The selected module's own sources, as a section below the Library.
    ///
    /// What a module sidebar used to hold, without the amnesia: Notes' kinds, Reminders' smart
    /// lists, Records' scopes. Only the modules with real navigation get one, which is the rule
    /// the Mac states in `AppModule.hasNavigationOfItsOwn` and applies in its own context band.
    ///
    /// Each band leaves out the module's own front door, because the Library row above *is* that
    /// door — `SidebarRegistry.sidebarRows(in:)` is the Mac's version of the same subtraction. A
    /// row called Notes underneath a row called Notes, both drawn selected, is one place claiming
    /// to be two.
    @ViewBuilder
    private var contextBand: some View {
        switch selection {
        case .kindList where isNoteKind(selection), .tag:
            Section("Notes") {
                ForEach(PadRoot.noteKinds.filter { $0 != .note }, id: \.self) { kind in
                    row(
                        .kindList(kind),
                        title: PadRoot.kindList(kind).libraryTitle,
                        systemImage: kind.symbolName
                    )
                }
            }

        case .reminders, .smartList, .builtInSmartList:
            Section("Smart Lists") {
                ForEach(BuiltInSmartList.all) { list in
                    row(.builtInSmartList(list.id), title: list.title, systemImage: list.symbolName)
                }
                ForEach(savedSmartLists) { list in
                    row(.smartList(list.id), title: list.name, systemImage: list.symbolName)
                }
            }

        case .records:
            Section("Records") {
                ForEach(RecordsScope.typeFilters.filter { $0 != .all }) { scope in
                    row(.records(scope), title: scope.title, systemImage: scope.symbolName)
                }
                row(
                    .records(.favorites),
                    title: RecordsScope.favorites.title,
                    systemImage: RecordsScope.favorites.symbolName
                )
            }

        default:
            EmptyView()
        }
    }

    /// Absent when empty, rather than a header explaining that it is empty.
    @ViewBuilder
    private var pinnedBand: some View {
        if let pinned = services?.sidebar.pinned, !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { pin in
                    derivedRow(pin)
                }
            }
        }
    }

    /// Tags and saved searches, which belong to no module because they reach across all of them.
    ///
    /// A tag goes on a note, a reminder and a bookmark alike, and a saved search runs over the
    /// whole library; filing either inside a module would be a claim about their scope that is not
    /// true. Absent entirely when there are none, rather than a header explaining its own emptiness.
    @ViewBuilder
    private var crossModuleBand: some View {
        let tags = services?.sidebar.tags ?? []
        if !tags.isEmpty || !savedSearches.isEmpty {
            Section("Across Everything") {
                if !tags.isEmpty {
                    DisclosureGroup(isExpanded: $isTagsExpanded) {
                        ForEach(tags) { tag in
                            row(
                                .tag(tagSlug(of: tag)),
                                title: tag.title,
                                systemImage: "number",
                                color: Theme.Palette.color(named: tag.colorName),
                                count: tag.count ?? 0,
                                indent: tag.depth
                            )
                        }
                    } label: {
                        Label("Tags", systemImage: "number")
                            .font(Theme.Text.rowTitle)
                    }
                }

                if !savedSearches.isEmpty {
                    DisclosureGroup(isExpanded: $isSearchesExpanded) {
                        ForEach(savedSearches) { saved in
                            row(
                                .savedSearch(saved.id),
                                title: saved.name,
                                systemImage: saved.symbolName,
                                color: Theme.Palette.color(named: saved.colorName)
                            )
                        }
                    } label: {
                        Label("Saved Searches", systemImage: "magnifyingglass")
                            .font(Theme.Text.rowTitle)
                    }
                }
            }
        }
    }

    /// The bottom rail: keeping places and the app's own settings, no longer peers of the places
    /// work actually happens.
    private var edgesBand: some View {
        Section {
            row(.archive, title: "Archive", systemImage: "archivebox")
            row(.trash, title: "Trash", systemImage: "trash")
            row(.settings, title: "Settings", systemImage: "gearshape")
        }
    }

    // MARK: - Rows

    /// One destination. A button, not a selectable row: a button's tap is unambiguous under a
    /// finger, a pointer, and an automated test alike, and the selected state is drawn
    /// deliberately rather than borrowed from list machinery.
    private func row(
        _ root: PadRoot,
        title: String,
        systemImage: String,
        color: Color? = nil,
        count: Int = 0,
        indent: Int = 0
    ) -> some View {
        let isSelected = selection == root

        return Button {
            selection = root
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(
                        isSelected ? Theme.Colors.selection : (color ?? Theme.Colors.secondaryText)
                    )
                    .frame(width: Theme.Size.rowGlyph)

                Text(title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .padding(.leading, CGFloat(indent) * Theme.Spacing.large)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(isSelected ? Theme.Colors.selection.opacity(0.16) : Color.clear)
                .padding(.horizontal, Theme.Spacing.tight)
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(root.accessibilityIdentifier)
    }

    /// One project or area, with the overdue dot and unread count the Mac's tree draws — and
    /// nothing else. Progress is deliberately absent, on `ProjectSidebarRow.hasIndicators`'
    /// argument: a mark on every row at once draws the eye everywhere and therefore nowhere.
    private func projectRow(_ project: ProjectSidebarRow, indented: Bool) -> some View {
        let root: PadRoot = project.isArea ? .area(project.id) : .project(project.id)
        let isSelected = selection == root

        return Button {
            selection = root
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: project.symbolName)
                    .foregroundStyle(
                        Theme.Palette.color(named: project.colorName, neutral: Theme.Colors.secondaryText)
                    )
                    .frame(width: Theme.Size.rowGlyph)

                Text(project.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if project.overdueCount > 0 {
                    Circle()
                        .fill(Theme.Colors.destructive)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("\(project.overdueCount) overdue")
                }
                if project.unreadCount > 0 {
                    Text("\(project.unreadCount)")
                        .font(Theme.Text.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .padding(.leading, indented ? CGFloat(project.depth) * Theme.Spacing.large : 0)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(isSelected ? Theme.Colors.selection.opacity(0.16) : Color.clear)
                .padding(.horizontal, Theme.Spacing.tight)
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("pad.sidebar.container.\(project.id.uuidString)")
        .contextMenu {
            if supportsMultipleWindows, !project.isArea {
                Button("Open in New Window", systemImage: "rectangle.badge.plus") {
                    openWindow(value: MobileRoute.project(project.id))
                }
            }
        }
    }

    /// A pinned record. Pins are leaves, so one opens in the reading pane of wherever you are
    /// rather than becoming the sidebar's selection — the same answer `PadShellModel.route(_:)`
    /// gives every other leaf.
    @ViewBuilder
    private func derivedRow(_ pin: SidebarDerivedRow) -> some View {
        if case .item(let id) = pin.selection {
            PadPinnedRowButton(row: pin, id: id)
        }
    }

    // MARK: - Values

    /// Whether a root is one of the kind lists the Notes module holds.
    private func isNoteKind(_ root: PadRoot) -> Bool {
        guard case .kindList(let kind) = root else { return false }
        return PadRoot.noteKinds.contains(kind)
    }

    /// A tag row's slug, which its identifier carries and its title does not — the title is the
    /// leaf name, so a nested tag would otherwise select the wrong thing.
    private func tagSlug(of row: SidebarDerivedRow) -> String {
        if case .tag(let slug) = row.selection { return slug }
        return row.title
    }

    /// Everything this column draws that is not already a service's stored value, computed on
    /// change and never during a render.
    ///
    /// A smart list is a `SavedSearch` carrying a task filter — that is the only thing telling it
    /// apart from a saved text search — so it takes a fetch, and a fetch read from `body` would be
    /// a database query per render of the sidebar.
    private func refresh() {
        guard let services else { return }
        todayCount = services.counts.counts.today
        inboxCount = services.counts.counts.inbox

        let descriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil && $0.taskFilterData != nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        savedSmartLists = ((try? services.context.fetch(descriptor)) ?? []).map {
            SmartListModel(
                id: $0.id,
                name: $0.name,
                symbolName: $0.symbolName ?? "line.3.horizontal.decrease.circle"
            )
        }

        // The other half of the same table: a saved search is one without a task filter, and it
        // reaches across every module rather than belonging to Reminders.
        let searches = FetchDescriptor<SavedSearch>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.taskFilterData == nil && $0.showsInSidebar
            },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        savedSearches = ((try? services.context.fetch(searches)) ?? []).map {
            PadSavedSearchRow(
                id: $0.id,
                name: $0.name,
                symbolName: $0.symbolName ?? "magnifyingglass",
                colorName: $0.colorName
            )
        }
    }
}

/// A saved search, named without holding the record.
struct PadSavedSearchRow: Identifiable {
    let id: UUID
    let name: String
    let symbolName: String
    let colorName: String?
}

/// A pinned record's row, which routes rather than selects.
private struct PadPinnedRowButton: View {
    @Environment(PadShellModel.self) private var pad

    let row: SidebarDerivedRow
    let id: UUID

    var body: some View {
        Button {
            pad.route(.item(id))
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: row.symbolName)
                    .foregroundStyle(
                        Theme.Palette.color(named: row.colorName, neutral: Theme.Colors.secondaryText)
                    )
                    .frame(width: Theme.Size.rowGlyph)
                Text(row.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pad.sidebar.pin.\(id.uuidString)")
    }
}

extension PadRoot {
    /// The kinds the Notes module holds — everything written down.
    static let noteKinds: [ItemKind] = [.note, .idea, .reference, .dailyEntry]

    /// The name this root wears in the Library band.
    var libraryTitle: String {
        switch self {
        case .kindList(.note): "Notes"
        case .kindList(.idea): "Ideas"
        case .kindList(.reference): "Reference"
        case .kindList(.dailyEntry): "Daily Notes"
        case .kindList(.bookmark): "Bookmarks"
        case .kindList(.area): "Areas"
        case .kindList(let kind): kind.pluralDisplayName
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .records: "Records"
        case .time: "Time"
        case .today: "Today"
        case .inbox: "Inbox"
        case .search: "Search"
        case .archive: "Archive"
        case .trash: "Trash"
        case .settings: "Settings"
        case .project, .area: "Project"
        case .smartList, .builtInSmartList, .tag: "List"
        case .savedSearch: "Saved Search"
        }
    }

    /// The Mac's symbol wherever the Mac names the same place, so the two shells cannot drift into
    /// two vocabularies for one destination.
    var librarySymbolName: String {
        switch self {
        case .kindList(let kind): kind.symbolName
        case .reminders: "bell"
        case .calendar: "calendar"
        case .records: "person.text.rectangle"
        case .time: "timer"
        case .today: "sun.horizon"
        case .inbox: "tray"
        case .search: "magnifyingglass"
        case .archive: "archivebox"
        case .trash: "trash"
        case .settings: "gearshape"
        case .project: "square.stack.3d.up"
        case .area: "square.grid.2x2"
        case .smartList, .builtInSmartList: "line.3.horizontal.decrease.circle"
        case .savedSearch: "magnifyingglass"
        case .tag: "number"
        }
    }

    /// A stable name for the row, so a UI test can reach a place by what it is rather than by
    /// what it is currently called.
    var accessibilityIdentifier: String {
        switch self {
        case .today: "pad.sidebar.today"
        case .inbox: "pad.sidebar.inbox"
        case .search: "pad.sidebar.search"
        case .reminders: "pad.sidebar.reminders"
        case .calendar: "pad.sidebar.calendar"
        case .time: "pad.sidebar.time"
        case .archive: "pad.sidebar.archive"
        case .trash: "pad.sidebar.trash"
        case .settings: "pad.sidebar.settings"
        case .records(let scope): "pad.sidebar.records.\(scope.id)"
        case .kindList(let kind): "pad.sidebar.kind.\(kind.rawValue)"
        case .tag(let slug): "pad.sidebar.tag.\(slug)"
        case .smartList(let id): "pad.sidebar.smartList.\(id.uuidString)"
        case .builtInSmartList(let id): "pad.sidebar.smartList.\(id)"
        case .savedSearch(let id): "pad.sidebar.savedSearch.\(id.uuidString)"
        case .project(let id), .area(let id): "pad.sidebar.container.\(id.uuidString)"
        }
    }
}
