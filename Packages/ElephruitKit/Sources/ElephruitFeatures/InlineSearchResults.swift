import ElephruitCore
import ElephruitDesign
import ElephruitSearch
import SwiftUI

/// Search results, in the place the list was.
///
/// ### Why this is not a sheet
/// The previous version opened search in a modal sheet over the window. That made search a *place
/// you go* rather than a way of looking at what you already have: the sidebar vanished, the item you
/// were reading vanished, and dismissing it threw away the context you searched from.
///
/// Here the middle column changes what it is showing and nothing else moves. The sidebar still shows
/// where you were, the detail pane still shows what you were reading, and one Escape puts the list
/// back exactly as it was — including the selection.
struct InlineSearchResults: View {
    @Environment(\.services) private var services

    let session: SearchSessionModel
    let listTitle: String
    let onOpen: (SearchResult) -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if let tokens = unrecognisedNote {
                UnrecognisedTokenNote(message: tokens)
            }

            content
        }
        .accessibilityIdentifier(AccessibilityID.Search.results)
    }

    // MARK: - Header

    /// One line: what matched, how many, and how to keep it.
    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(session.resultSummary)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .monospacedDigit()

            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }

            if let explanation = indexExplanation {
                Text(explanation)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.small)

            if !session.results.isEmpty {
                Button("Save Search", systemImage: "plus.circle", action: onSave)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Search.saveSearchButton)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// What the index has to say about itself, if anything.
    ///
    /// Only shown while it matters. A ready index says nothing, because a permanent status line
    /// about a thing that is working is noise.
    private var indexExplanation: String? {
        (services?.search as? FTSSearchEngine)?.status.explanation
    }

    private var unrecognisedNote: String? {
        let tokens = session.unrecognisedTokens
        guard !tokens.isEmpty else { return nil }

        let quoted = tokens.map { "“\($0)”" }.joined(separator: ", ")
        return tokens.count == 1
            ? "\(quoted) was not understood, so it was ignored."
            : "\(quoted) were not understood, so they were ignored."
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.vacancy {
        case .none:
            resultsList

        case .idle:
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "Search \(listTitle == "" ? "everything" : "your library")",
                message: "Words match titles and text. Add `type:`, `tag:`, `in:`, `person:`, "
                    + "`is:` or `due:` to narrow it."
            )

        case .tooShort:
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "Keep typing",
                message: "One letter matches almost everything. Two is enough to start."
            )

        case .noMatches:
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "No matches",
                message: "Nothing matches \(session.explanation).",
                tone: .noResults
            )
        }
    }

    private var resultsList: some View {
        List {
            ForEach(session.groups) { group in
                Section {
                    ForEach(group.results) { result in
                        Button {
                            onOpen(result)
                        } label: {
                            SearchResultRow(
                                result: result,
                                dateProvider: services?.dateProvider ?? SystemDateProvider()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionHeader(group.kind.pluralDisplayName, count: group.results.count)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }
}

/// One result: why it matched, and enough to recognise it.
struct SearchResultRow: View {
    let result: SearchResult
    let dateProvider: any DateProvider

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: result.item.effectiveSymbolName)
                    .foregroundStyle(Theme.Palette.color(named: result.item.colorName))
                    .frame(width: Theme.Size.rowGlyph)
                    .accessibilityHidden(true)

                SearchHighlightedText(text: result.item.displayTitle, ranges: result.titleMatchRanges)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.small)

                if let parent = result.item.parentTitle, !parent.isEmpty {
                    Text(parent)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }

                if !result.item.tagSlugs.isEmpty {
                    TagChipRow(slugs: result.item.tagSlugs, limit: 2)
                }

                if let dueAt = result.item.dueAt {
                    DueDateLabel(date: dueAt, dateProvider: dateProvider, isActionable: result.item.isActionable)
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
        .accessibilityLabel(result.item.accessibilityDescription(using: dateProvider))
        .accessibilityIdentifier(AccessibilityID.Search.result(id: result.id.uuidString))
    }
}

/// A title with its matched runs emphasised.
///
/// Built as one `AttributedString` with styled runs rather than concatenated `Text` values: a single
/// attributed value lays out and truncates correctly, which a chain of fragments does not.
struct SearchHighlightedText: View {
    let text: String
    let ranges: [Range<Int>]

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        guard !ranges.isEmpty else { return AttributedString(text) }

        var attributed = AttributedString(text)
        let characterCount = text.count

        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= characterCount, !range.isEmpty else { continue }

            let characters = attributed.characters
            guard let start = characters.index(
                characters.startIndex,
                offsetBy: range.lowerBound,
                limitedBy: characters.endIndex
            ),
            let end = characters.index(start, offsetBy: range.count, limitedBy: characters.endIndex)
            else { continue }

            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
            attributed[start..<end].foregroundColor = Theme.Colors.selection
        }

        return attributed
    }
}

/// The amber note for a fragment the parser could not read.
///
/// Surfaced rather than dropped: silently ignoring part of a query produces results that look right
/// and are not, and the user has no way of telling.
struct UnrecognisedTokenNote: View {
    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Colors.warning)
            Text(message)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Search.unrecognisedNote)
    }
}
