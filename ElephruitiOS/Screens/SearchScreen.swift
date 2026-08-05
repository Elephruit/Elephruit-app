import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import SwiftUI

/// Global search: the same engine, grammar, and grouping as the Mac's ⌘⇧F.
///
/// Results are grouped by kind, previews carry the matched excerpt, unreadable query
/// fragments are named rather than swallowed, and every result type navigates — through
/// the same route table as every other tap in the app.
struct SearchScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    @State private var session: SearchSessionModel?
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
        .navigationTitle("Search")
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
            session = SearchSessionModel(engine: services.search)
        }
    }

    private func results(_ session: SearchSessionModel) -> some View {
        List {
            grammarWarnings(session)
            indexingState

            switch session.vacancy {
            case .idle:
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
