import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import SwiftUI

/// Unified search — journey J7.
///
/// One surface over every kind, with the token grammar available but never required. Results are
/// grouped by kind because a mixed list of notes, tasks, and projects is harder to scan than three
/// short lists.
public struct SearchView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    private let navigation: NavigationModel

    @State private var queryText = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isShowingTokenHelp = false
    @FocusState private var isFieldFocused: Bool

    public init(navigation: NavigationModel) {
        self.navigation = navigation
    }

    private var parsedQuery: SearchQuery {
        SearchQueryParser.parse(queryText)
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 640, height: 520)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .accessibilityIdentifier(AccessibilityID.Search.root)
    }

    // MARK: - Field

    private var searchField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                TextField("Search everything", text: $queryText)
                    .textFieldStyle(.plain)
                    .font(.system(.title3))
                    .focused($isFieldFocused)
                    .onSubmit { openFirstResult() }
                    .onChange(of: queryText) { _, _ in scheduleSearch() }
                    .accessibilityIdentifier(AccessibilityID.Search.field)
                    .accessibilityLabel("Search")

                if isSearching {
                    ProgressView().controlSize(.small)
                }

                Button {
                    isShowingTokenHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .help("Show search tokens")
                .accessibilityIdentifier(AccessibilityID.Search.tokenHelp)
                .accessibilityLabel("Search token help")

                if !results.isEmpty {
                    Button("Save Search") { saveSearch() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier(AccessibilityID.Search.saveSearchButton)
                }
            }

            if !queryText.isEmpty {
                Text(SearchQueryParser.describe(parsedQuery))
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }

            // Nothing the parser did not understand is ever silently dropped.
            if !parsedQuery.unrecognisedTokens.isEmpty {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Not understood: \(parsedQuery.unrecognisedTokens.joined(separator: ", "))")
                }
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.unresolvedLink)
            }

            if isShowingTokenHelp {
                tokenHelp
            }
        }
        .padding(Theme.Spacing.large)
    }

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(Self.tokenExamples, id: \.token) { example in
                HStack(spacing: Theme.Spacing.small) {
                    Text(example.token)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Colors.selection)
                        .frame(width: 150, alignment: .leading)
                    Text(example.meaning)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer()
                }
            }
        }
        .padding(Theme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        )
    }

    private static let tokenExamples: [(token: String, meaning: String)] = [
        ("type:task", "only tasks"),
        ("tag:work", "tagged work, including work/clients"),
        ("project:\"Q3 Launch\"", "inside a named project"),
        ("is:open", "open, completed, favorite, pinned, overdue, untagged, unfiled, trashed"),
        ("due:<7d", "due within seven days"),
        ("due:today", "due today"),
        ("due:none", "with no due date"),
        ("updated:>2026-01-01", "changed since a date"),
    ]

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if queryText.isEmpty {
            recentSearchesOrHint
        } else if results.isEmpty, !isSearching {
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "No matches",
                message: "Nothing in your library matches this search.",
                tone: .noResults
            )
        } else {
            resultsList
        }
    }

    @ViewBuilder
    private var recentSearchesOrHint: some View {
        if navigation.recentSearches.isEmpty {
            EmptyStateView(
                symbolName: "sparkle.magnifyingglass",
                headline: "Search everything",
                message: "Titles, note bodies, and tags. Add tokens like type: and tag: to narrow it down."
            )
        } else {
            List {
                Section("Recent") {
                    ForEach(navigation.recentSearches, id: \.self) { recent in
                        Button {
                            queryText = recent
                            scheduleSearch()
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text(recent)
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(AccessibilityID.Search.recentSearches)
        }
    }

    private var resultsList: some View {
        List {
            ForEach(groupedResults, id: \.kind) { group in
                Section {
                    ForEach(group.results) { result in
                        Button {
                            open(result)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionHeader(group.kind.pluralDisplayName, count: group.results.count)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(AccessibilityID.Search.results)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: result.item.effectiveSymbolName)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)

                highlightedTitle(result)
                    .lineLimit(1)

                Spacer()

                if !result.item.tagSlugs.isEmpty {
                    TagChipRow(slugs: result.item.tagSlugs, limit: 2)
                }

                if let dueAt = result.item.dueAt {
                    DueDateLabel(
                        date: dueAt,
                        dateProvider: services?.dateProvider ?? SystemDateProvider(),
                        isActionable: result.item.isActionable
                    )
                }
            }

            if let excerpt = result.bodyExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.item.accessibilityDescription(using: services?.dateProvider ?? SystemDateProvider()))
    }

    /// Bolds the matched substrings, so the user can see *why* a result matched.
    ///
    /// Built as one `AttributedString` with styled runs rather than by concatenating `Text` values:
    /// `Text` addition is deprecated, and a single attributed value also lays out and truncates
    /// correctly, which a chain of concatenated fragments does not always do.
    private func highlightedTitle(_ result: SearchResult) -> Text {
        let title = result.item.displayTitle
        guard !result.titleMatchRanges.isEmpty else { return Text(title) }

        var attributed = AttributedString(title)
        let characterCount = title.count

        for range in result.titleMatchRanges {
            guard range.lowerBound >= 0, range.upperBound <= characterCount, !range.isEmpty else { continue }

            let characters = attributed.characters
            guard let start = characters.index(
                characters.startIndex,
                offsetBy: range.lowerBound,
                limitedBy: characters.endIndex
            ),
            let end = characters.index(
                start,
                offsetBy: range.count,
                limitedBy: characters.endIndex
            ) else { continue }

            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
            attributed[start..<end].foregroundColor = Theme.Colors.selection
        }

        return Text(attributed)
    }

    private var groupedResults: [(kind: ItemKind, results: [SearchResult])] {
        Dictionary(grouping: results, by: \.item.kind)
            .map { (kind: $0.key, results: $0.value) }
            .sorted { left, right in
                // Ordered by best result in each group, so the most relevant section is first.
                let leftBest = left.results.first?.score ?? 0
                let rightBest = right.results.first?.score ?? 0
                return leftBest == rightBest
                    ? left.kind.rawValue < right.kind.rawValue
                    : leftBest > rightBest
            }
    }

    // MARK: - Running

    /// Debounced, and the previous search is cancelled — so typing quickly does not queue six
    /// searches whose results arrive out of order.
    private func scheduleSearch() {
        searchTask?.cancel()

        let text = queryText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard let services else { return }

        isSearching = true
        defer { isSearching = false }

        let query = SearchQueryParser.parse(text)
        do {
            let found = try await services.search.search(query, limit: 200)
            guard !Task.isCancelled, queryText == text else { return }
            results = found
        } catch {
            services.lastError = error
            results = []
        }
    }

    // MARK: - Actions

    private func open(_ result: SearchResult) {
        navigation.recordSearch(queryText)

        // Selecting the kind's list first means the item is visible in context rather than
        // appearing in whatever list happened to be open.
        navigation.select(.kind(result.item.kind))
        navigation.selectedItemID = result.item.id
        dismiss()
    }

    private func openFirstResult() {
        guard let first = results.first else { return }
        open(first)
    }

    private func saveSearch() {
        guard let services else { return }

        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let search = SavedSearch(
            name: SearchQueryParser.describe(parsedQuery),
            queryString: trimmed,
            createdAt: services.dateProvider.now
        )
        services.context.insert(search)

        services.perform { try services.context.save() }

        navigation.recordSearch(trimmed)
        navigation.select(.savedSearch(id: search.id))
        dismiss()
    }
}

#Preview("Search") {
    SearchView(navigation: NavigationModel())
        .appServices(AppServices.inMemory())
}
