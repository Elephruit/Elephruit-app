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
public struct CaptureSuggestionSource {
    public var services: AppServices?

    /// The project and person names the parser is working from. Refreshed with the library.
    ///
    /// No default, deliberately. It had one — ``CaptureVocabulary/empty`` — and the composer built
    /// this without passing anything, so the picker, the destination list and the `@` and `>`
    /// completions all reported an empty library in a library that was not. Nothing failed; the type
    /// answered every question truthfully about the names it had been given, which were none. A
    /// default value here is a way of saying "not knowing which people exist is a reasonable state
    /// for this to be in", and it never is: this type's entire purpose is knowing.
    public var vocabulary: CaptureVocabulary

    public init(services: AppServices?, vocabulary: CaptureVocabulary) {
        self.services = services
        self.vocabulary = vocabulary
    }

    /// Existing tag slugs, whole or matching.
    ///
    /// Reads them all, which is right here and would be wrong for items: the tag table is small by
    /// construction — it is the vocabulary one person has invented for themselves — and it is the
    /// only one of the three lists that is not already in memory.
    public func tagSlugs(matching query: String, limit: Int = 8) -> [String] {
        let slugs = ((try? services?.tags.allTags()) ?? []).map(\.slug)
        return matches(for: query, in: slugs, limit: limit)
    }

    public func people(matching query: String, limit: Int = 8) -> [String] {
        matches(for: query, in: vocabulary.people, limit: limit)
    }

    /// Projects, areas and goals — everything `>` and the destination button mean by a place to file
    /// something.
    public func containers(matching query: String, limit: Int = 8) -> [String] {
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
