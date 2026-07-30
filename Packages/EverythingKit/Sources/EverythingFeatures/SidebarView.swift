import EverythingCore
import EverythingDesign
import EverythingModel
import EverythingPersistence
import SwiftData
import SwiftUI

/// The first column.
///
/// Grouped into three bands — the time-based views the user lives in, the kinds, and their own
/// organisation. Counts appear only where a number is actionable: an Inbox count is a prompt to
/// triage, whereas a count of every note ever written is decoration.
public struct SidebarView: View {
    @Environment(\.services) private var services
    private let navigation: NavigationModel

    @Query(sort: \EverythingModel.Tag.slug) private var tags: [EverythingModel.Tag]
    @Query(filter: #Predicate<SavedSearch> { $0.showsInSidebar && $0.deletedAt == nil }, sort: \SavedSearch.sortOrder)
    private var savedSearches: [SavedSearch]

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    public var body: some View {
        List(selection: selectionBinding) {
            Section {
                row(.today, count: count(for: .today))
                row(.upcoming)
                row(.inbox, count: count(for: .inbox))
            }

            Section("Library") {
                ForEach(ItemKind.shippingInMilestoneOne.filter { $0 != .dailyEntry }, id: \.self) { kind in
                    row(.kind(kind))
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(visibleTags, id: \.id) { tag in
                        tagRow(tag)
                    }
                }
            }

            if !savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(savedSearches, id: \.id) { search in
                        savedSearchRow(search)
                    }
                }
            }

            Section {
                row(.trash, count: count(for: .trash))
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.Sidebar.root)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            syncStatusLine
        }
    }

    // MARK: - Rows

    private func row(_ selection: SidebarSelection, count: Int? = nil) -> some View {
        NavigationLink(value: selection) {
            Label {
                HStack {
                    Text(selection.title)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: selection.symbolName)
            }
        }
        .accessibilityIdentifier(selection.accessibilityIdentifier)
        .accessibilityLabel(count.map { "\(selection.title), \($0) items" } ?? selection.title)
    }

    /// Hierarchy is shown by indentation rather than by repeating the full path, so `work/clients`
    /// reads as "clients" nested under "work".
    private func tagRow(_ tag: EverythingModel.Tag) -> some View {
        NavigationLink(value: SidebarSelection.tag(slug: tag.slug)) {
            Label {
                HStack {
                    Text(tag.leafName)
                    Spacer()
                    if tag.activeItemCount > 0 {
                        Text("\(tag.activeItemCount)")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "number")
                    .foregroundStyle(Theme.Palette.color(named: tag.colorName))
            }
            .padding(.leading, CGFloat(tag.depth) * Theme.Spacing.medium)
        }
        .accessibilityIdentifier(AccessibilityID.Sidebar.tag(slug: tag.slug))
        .accessibilityLabel("Tag \(tag.slug), \(tag.activeItemCount) items")
        .contextMenu {
            Button("Rename…") { /* Phase 2: inline rename */ }
                .disabled(true)
            Button("Delete Tag", role: .destructive) { deleteTag(tag) }
        }
    }

    private func savedSearchRow(_ search: SavedSearch) -> some View {
        NavigationLink(value: SidebarSelection.savedSearch(id: search.id)) {
            Label(search.displayName, systemImage: search.effectiveSymbolName)
        }
        .accessibilityIdentifier(AccessibilityID.Sidebar.savedSearch(name: search.displayName))
        .help(search.queryString)
    }

    /// One quiet line. No spinner in the toolbar, no modal — only a failure is tappable.
    private var syncStatusLine: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: statusSymbol)
                .font(Theme.Text.metadata)
            Text(services?.syncStatus.summary ?? "")
                .font(Theme.Text.metadata)
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.Colors.tertiaryText)
        .padding(.horizontal, Theme.Spacing.medium)
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

    /// Only tags whose ancestors are also present, so indentation never shows an orphan indented
    /// under nothing.
    private var visibleTags: [EverythingModel.Tag] {
        tags.filter { !$0.slug.isEmpty }
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

    /// Counts are computed with `count(matching:)` rather than by fetching, so a sidebar badge never
    /// loads a thousand rows to display one number.
    private func count(for selection: SidebarSelection) -> Int? {
        guard let services else { return nil }
        let query = selection.query(using: services.dateProvider)
        return try? services.items.count(matching: query)
    }

    private func deleteTag(_ tag: EverythingModel.Tag) {
        guard let services else { return }
        if navigation.selection == .tag(slug: tag.slug) {
            navigation.select(.today)
        }
        services.perform { try services.tags.delete(tag) }
    }
}

#Preview("Sidebar", traits: .fixedLayout(width: 260, height: 600)) {
    let services = AppServices.inMemory()
    return SidebarView(navigation: NavigationModel())
        .appServices(services)
        .frame(width: 260)
}
