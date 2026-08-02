import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The one place the Quick Jot card asks what exists to be named.
///
/// ### Why this is a type rather than six call sites
/// The inline `@` completion and the person picker are answering the same question — *which people
/// are there* — and there is no version of this app where they should answer it differently. Two
/// lookups written separately drift: one starts folding accents, or gets a limit raised, and nobody
/// notices, because you have to use both in the same minute to see it.
///
/// ### Why not the search index
/// It was the index, and that was wrong twice.
///
/// The first fault is plain. `SearchIndexStore.titles(prefix:)` returns nothing for an empty query,
/// deliberately — an index is for finding, and finding nothing in particular is not a question. So
/// the person picker, which opens before anybody has typed a letter, opened empty every time. A
/// picker whose whole job is to show you the list cannot begin by asking you to guess what is in it.
///
/// The second is subtler and worse. It made "which people are in this library" depend on whether
/// those people had been *indexed*, which is a fact about a background task rather than about the
/// library. Somebody created a moment ago, or somebody whose indexing failed quietly a month ago, is
/// a person you can see in the sidebar and cannot mention.
///
/// The store already has the answer, and the panel already has it in hand. ``CaptureVocabulary`` is
/// fetched when the panel opens because the *parser* needs it — it is how `>Q3 Launch` is read as one
/// name rather than as "Q3" followed by a word — so the names are in memory whether or not anything
/// asks for them. Filtering them costs nothing, and it cannot disagree with what the parser will do,
/// which is the property that matters most here: a picker offering "Q3 Launch" beside a grammar that
/// files under "Q3" would be two answers to one question.
@MainActor
struct CaptureSuggestionSource {
    var services: AppServices?

    /// The project and person names the parser is working from. Refreshed with the library.
    ///
    /// No default, deliberately. It had one — ``CaptureVocabulary/empty`` — and the composer built
    /// this without passing anything, so the picker, the destination list and the `@` and `>`
    /// completions all reported an empty library in a library that was not. Nothing failed; the type
    /// answered every question truthfully about the names it had been given, which were none. A
    /// default value here is a way of saying "not knowing which people exist is a reasonable state
    /// for this to be in", and it never is: this type's entire purpose is knowing.
    var vocabulary: CaptureVocabulary

    /// Existing tag slugs, whole or matching.
    ///
    /// Reads them all, which is right here and would be wrong for items: the tag table is small by
    /// construction — it is the vocabulary one person has invented for themselves — and it is the
    /// only one of the three lists that is not already in memory.
    func tagSlugs(matching query: String, limit: Int = 8) -> [String] {
        let slugs = ((try? services?.tags.allTags()) ?? []).map(\.slug)
        return matches(for: query, in: slugs, limit: limit)
    }

    func people(matching query: String, limit: Int = 8) -> [String] {
        matches(for: query, in: vocabulary.people, limit: limit)
    }

    /// Projects, areas and goals — everything `>` and the destination button mean by a place to file
    /// something.
    func containers(matching query: String, limit: Int = 8) -> [String] {
        matches(for: query, in: vocabulary.projects, limit: limit)
    }

    /// Names beginning with the query first, then names merely containing it.
    ///
    /// Two passes rather than one, because they are different strengths of evidence and mixing them
    /// buries the obvious answer. Typing `sar` should offer Sarah ahead of anybody with "sar" in the
    /// middle of a surname — but it should still offer them, because a search that only matches the
    /// start of a name is one you have to know the answer to use.
    ///
    /// An empty query lists everything, up to the limit. That is what a picker is for.
    private func matches(for query: String, in names: [String], limit: Int) -> [String] {
        let folded = TextNormalizer.foldedForMatching(query)
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !folded.isEmpty else { return Array(sorted.prefix(limit)) }

        let prefixed = sorted.filter { TextNormalizer.foldedForMatching($0).hasPrefix(folded) }
        let contained = sorted.filter {
            let name = TextNormalizer.foldedForMatching($0)
            return !name.hasPrefix(folded) && name.contains(folded)
        }

        return Array((prefixed + contained).prefix(limit))
    }
}

/// A search field and the list of what it found.
///
/// ### Why a popover here and a menu for tags
/// Not an inconsistency. A tag list is a closed vocabulary of a few dozen that somebody invented and
/// will recognise on sight, which is what a menu is for. People and projects are an open list that
/// grows past what anybody can scan, and needs a search field — which is a thing you cannot put in a
/// menu without the result being worse than either.
///
/// It opens with the list already showing. A picker that starts by asking what you are looking for is
/// no better than the field you clicked it from.
struct CaptureSearchPicker: View {
    let prompt: String
    let symbolName: String
    /// What to say when the library holds none of these at all — a different situation from a search
    /// that found nothing, and one that deserves a sentence about how to make the first one.
    let emptyLibraryMessage: String
    let search: (String) -> [String]
    let choose: (String) -> Void

    @State private var query = ""
    @FocusState private var isSearching: Bool

    private var results: [String] { search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearching)
                .onSubmit { if let first = results.first { choose(first) } }

            if results.isEmpty {
                Text(query.isEmpty ? emptyLibraryMessage : "Nothing by that name")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Spacing.tight)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results, id: \.self) { title in
                            Button {
                                choose(title)
                            } label: {
                                Label(title, systemImage: symbolName)
                                    .font(Theme.Text.metadata)
                                    .lineLimit(1)
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, Theme.Spacing.tight)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 240)
        .onAppear { isSearching = true }
    }
}
