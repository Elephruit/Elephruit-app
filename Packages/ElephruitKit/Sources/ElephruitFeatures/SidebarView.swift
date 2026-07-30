import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The first column.
///
/// ### Three bands, not one list
/// The previous sidebar mixed *where I work* — Today, Upcoming, Inbox — with *where things are filed*
/// — Notes, Tasks, Projects — in one undifferentiated list, which is precisely what made it read as a
/// file browser rather than a workspace. The bands separate those two things:
///
/// - **Primary** has no header at all. It is not a category; it is simply where you are.
/// - **Pinned** is what you chose to keep close, and is *absent* rather than empty when you have not.
/// - **Library** is everything else, collapsible, one step quieter.
///
/// ### On native selection
/// The spec drafted a bespoke selection treatment — accent at 12%, 6pt radius, 4pt inset. This uses
/// `.listStyle(.sidebar)` and the system's own selection instead. macOS 26 already draws a quiet
/// rounded accent fill, it tracks window activation, Increase Contrast, and the user's accent colour
/// for free, and reimplementing it would mean losing keyboard navigation or rebuilding it worse.
/// Everything else about the row — content, spacing, glyph column, counts, truncation — is ours.
public struct SidebarView: View {
    @Environment(\.services) private var services

    private let navigation: NavigationModel

    /// Collapse state lives per scene, so a second window can be configured differently.
    @SceneStorage("sidebar.library.expanded") private var isLibraryExpanded = true
    @SceneStorage("sidebar.tags.expanded") private var isTagsExpanded = false
    @SceneStorage("sidebar.searches.expanded") private var isSearchesExpanded = false

    /// Grows with the system text-size and control-size preferences.
    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        List(selection: selectionBinding) {
            primaryBand
            pinnedBand
            libraryBand
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.Sidebar.root)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusLine }
    }

    // MARK: - Bands

    /// No header. This band is not a category the user chooses between — it is the default place.
    private var primaryBand: some View {
        Section {
            ForEach(SidebarRegistry.destinations(in: .primary)) { destination in
                destinationRow(destination)
            }
        }
    }

    /// Absent when empty, rather than an empty band with a header explaining that it is empty.
    @ViewBuilder
    private var pinnedBand: some View {
        if let sidebar = services?.sidebar, !sidebar.pinned.isEmpty {
            Section("Pinned") {
                ForEach(sidebar.pinned) { row in
                    derivedRow(row)
                }
            }
        }
    }

    private var libraryBand: some View {
        Section(isExpanded: $isLibraryExpanded) {
            ForEach(SidebarRegistry.destinations(in: .library)) { destination in
                destinationRow(destination)
            }

            tagsDisclosure
            savedSearchesDisclosure
        } header: {
            Text("Library")
        }
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
                    derivedRow(row)
                }

                if sidebar.hasMoreTags {
                    Button("All Tags…") { navigation.isTagBrowserVisible = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(minHeight: rowHeight)
                        .accessibilityIdentifier("sidebar.allTags")
                }
            } label: {
                Label("Tags", systemImage: "number")
                    .frame(minHeight: rowHeight)
            }
        }
    }

    @ViewBuilder
    private var savedSearchesDisclosure: some View {
        if let sidebar = services?.sidebar, !sidebar.savedSearches.isEmpty {
            DisclosureGroup(isExpanded: $isSearchesExpanded) {
                ForEach(sidebar.savedSearches) { row in
                    derivedRow(row)
                }
            } label: {
                Label("Saved Searches", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(minHeight: rowHeight)
            }
        }
    }

    // MARK: - Rows

    /// A declared destination. Never truncated — see ``SidebarMetrics``.
    private func destinationRow(_ destination: SidebarDestination) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: destination.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .accessibilityHidden(true)

            Text(destination.title)
                .lineLimit(1)

            Spacer(minLength: 0)

            if destination.showsCount, let count = count(for: destination), count > 0 {
                countLabel(count)
            }
        }
        .frame(minHeight: rowHeight)
        .tag(destination.selection)
        .accessibilityIdentifier(destination.selection.accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel(for: destination))
    }

    /// A row derived from the store — a pinned item, a tag, a saved search.
    ///
    /// These *may* truncate: they carry user-chosen names of unbounded length, and the full text is
    /// always one hover away.
    private func derivedRow(_ row: SidebarDerivedRow) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: row.symbolName)
                .frame(width: SidebarMetrics.iconColumn)
                .foregroundStyle(row.colorName == nil ? Color.secondary : Theme.Palette.color(named: row.colorName))
                .accessibilityHidden(true)

            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let count = row.count, count > 0 {
                countLabel(count)
            }
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(row.depth) * Theme.Spacing.medium)
        .tag(row.selection)
        .help(row.title)
        .accessibilityIdentifier(row.selection.accessibilityIdentifier)
        .accessibilityLabel(row.count.map { "\(row.title), \($0) items" } ?? row.title)
    }

    private func countLabel(_ count: Int) -> some View {
        Text("\(count)")
            .font(Theme.Text.metadata)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.tertiaryText)
            .accessibilityHidden(true)
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

    private func accessibilityLabel(for destination: SidebarDestination) -> String {
        guard destination.showsCount, let count = count(for: destination), count > 0 else {
            return destination.title
        }
        return "\(destination.title), \(count) items"
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

#Preview("Sidebar", traits: .fixedLayout(width: 220, height: 620)) {
    let services = AppServices.inMemory()
    return SidebarView(navigation: NavigationModel())
        .appServices(services)
        .frame(width: 220, height: 620)
}

#Preview("Sidebar at its narrowest", traits: .fixedLayout(width: 180, height: 620)) {
    let services = AppServices.inMemory()
    return SidebarView(navigation: NavigationModel())
        .appServices(services)
        .frame(width: SidebarMetrics.floorWidth, height: 620)
}
