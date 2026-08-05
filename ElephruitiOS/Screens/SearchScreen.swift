import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import SwiftData
import SwiftUI

/// Global search: the same engine, grammar, and grouping as the Mac's ⌘⇧F.
///
/// Results are grouped by kind, previews carry the matched excerpt, unreadable query
/// fragments are named rather than swallowed, and every result type navigates — through
/// the same route table as every other tap in the app.
struct SearchScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    /// The saved search this screen opened on, if any.
    ///
    /// A saved search is the *text somebody typed*, kept — not a second kind of query — so
    /// opening one seeds this same session and leaves it fully editable. That is the whole
    /// argument for `SavedSearch.queryString` storing raw text, and honouring it here is what
    /// keeps "a saved search is a search" true rather than a claim.
    var savedSearchID: UUID?

    @State private var session: SearchSessionModel?
    @State private var savedSearchName: String?
    /// Whether the search field holds the keyboard. SwiftUI's focus, not UIKit's responder —
    /// releasing the responder underneath `.searchable` leaves SwiftUI thinking it is still
    /// focused, and it takes the keyboard straight back.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if let session {
                results(session)
            } else {
                Color.clear
            }
        }
        .navigationTitle(savedSearchName ?? "Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: Binding(
                get: { session?.text ?? "" },
                set: { session?.text = $0 }
            ),
            prompt: "Search everything"
        )
        .searchFocused($isSearchFocused)
        .task {
            guard session == nil, let services else { return }
            let session = SearchSessionModel(engine: services.search)
            if let savedSearchID, let saved = savedSearch(id: savedSearchID, services: services) {
                savedSearchName = saved.name
                session.text = saved.queryString
            }
            self.session = session
        }
    }

    private func results(_ session: SearchSessionModel) -> some View {
        List {
            grammarWarnings(session)
            indexingState

            switch session.vacancy {
            case .idle:
                savedSearchesSection
                suggestionsSection

            case .tooShort:
                Section {
                    Text("Keep typing — search starts at two characters.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .listRowBackground(Color.clear)

            case .noMatches:
                Section {
                    EmptyStateView(
                        symbolName: "magnifyingglass",
                        headline: "Nothing matches",
                        message: session.explanation
                    )
                }
                .listRowBackground(Color.clear)

            case .none:
                ForEach(session.groups) { group in
                    Section(group.kind.pluralDisplayName) {
                        ForEach(group.results) { result in
                            resultRow(result)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - States

    /// Fragments the parser could not use, said out loud — nothing is silently dropped.
    @ViewBuilder
    private func grammarWarnings(_ session: SearchSessionModel) -> some View {
        if !session.unrecognisedTokens.isEmpty {
            Section {
                Label {
                    Text("Didn't understand: \(session.unrecognisedTokens.joined(separator: ", "))")
                        .font(Theme.Text.metadata)
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .foregroundStyle(Theme.Colors.warning)
            }
        }
    }

    /// The index being built is a fact about a background task; searching still works
    /// through the store meanwhile, and this row says so instead of letting results
    /// quietly arrive slower.
    @ViewBuilder
    private var indexingState: some View {
        if let services, let engine = services.search as? FTSSearchEngine,
            case .building(let progress) = engine.status {
            Section {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text("Indexing \(progress.indexed) of \(progress.expected)")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    /// The searches the user named and kept.
    ///
    /// Only where the shell has no sidebar listing them — on the iPad they are a band of the
    /// sidebar, and a second copy inside the results would be the same list twice.
    @ViewBuilder
    private var savedSearchesSection: some View {
        if savedSearchID == nil, !savedSearches.isEmpty {
            Section("Saved") {
                ForEach(savedSearches, id: \.id) { saved in
                    Button {
                        isSearchFocused = false
                        shell.push(.savedSearch(saved.id))
                    } label: {
                        HStack(spacing: Theme.Spacing.medium) {
                            Image(systemName: saved.symbolName ?? "magnifyingglass")
                                .foregroundStyle(
                                    Theme.Palette.color(named: saved.colorName, neutral: Theme.Colors.secondaryText)
                                )
                                .frame(width: Theme.Size.rowGlyph)
                            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                Text(saved.name)
                                    .font(Theme.Text.rowTitle)
                                    .foregroundStyle(Theme.Colors.primaryText)
                                // The rule, under the name. A saved search that shows six of your
                                // eleven overdue notes and does not say why is one you stop
                                // trusting.
                                Text(saved.queryString)
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search.saved.\(saved.id.uuidString)")
                }
            }
        }
    }

    /// The ordinary saved searches — a smart list is a `SavedSearch` carrying a task filter, and
    /// it belongs to Reminders rather than here.
    private var savedSearches: [SavedSearch] {
        guard let services else { return [] }
        let descriptor = FetchDescriptor<SavedSearch>(
            predicate: #Predicate { $0.deletedAt == nil && $0.taskFilterData == nil && $0.showsInSidebar },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? services.context.fetch(descriptor)) ?? []
    }

    private func savedSearch(id: UUID, services: AppServices) -> SavedSearch? {
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.id == id })
        return (try? services.context.fetch(descriptor))?.first
    }

    /// What an empty search offers: the grammar, so the narrowing tokens are learnable.
    private var suggestionsSection: some View {
        Section("Narrow with") {
            ForEach(searchHints, id: \.token) { hint in
                Button {
                    session?.text = hint.token + " "
                } label: {
                    HStack {
                        Text(hint.token)
                            .font(Theme.Text.keyHint)
                            .padding(.horizontal, Theme.Spacing.tight)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                        Text(hint.meaning)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchHints: [(token: String, meaning: String)] {
        [
            ("type:note", "only one kind of thing"),
            ("tag:work", "tagged, including nested tags"),
            ("project:\"Q3 Launch\"", "inside one project or area"),
            ("person:maya", "linked to a person"),
            ("is:open", "by state — open, overdue, pinned…"),
            ("due:<7d", "by date — due, created, updated"),
        ]
    }

    // MARK: - Rows

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            open(result)
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                Image(systemName: result.item.effectiveSymbolName)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    highlightedTitle(result)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(Theme.Colors.primaryText)
                        .lineLimit(2)

                    if let excerpt = result.bodyExcerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(2)
                    }

                    if let parent = result.item.parentTitle {
                        Text(parent)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel("\(result.item.kind.displayName): \(result.item.displayTitle)")
    }

    /// The matched characters, bolded — the same offsets the engine reported.
    private func highlightedTitle(_ result: SearchResult) -> Text {
        let title = result.item.displayTitle
        guard !result.titleMatchRanges.isEmpty else { return Text(title) }

        var attributed = AttributedString(title)
        for range in result.titleMatchRanges {
            guard range.lowerBound >= 0, range.upperBound <= title.count else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: range.upperBound)
            attributed[start..<end].font = Theme.Text.rowTitleEmphasised
        }
        return Text(attributed)
    }

    /// Search results push onto the Search tab's own stack, so back always returns to
    /// the results — the journey is preserved, never discarded.
    private func open(_ result: SearchResult) {
        // Focus first, then the push. The keyboard belongs to SwiftUI's focus state, so
        // that is what has to be released — and before navigating, not after.
        isSearchFocused = false
        shell.push(MobileShellModel.route(for: result.item.kind, id: result.item.id))
    }
}
