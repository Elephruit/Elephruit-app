import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The one place the Quick Jot card asks the library what exists.
///
/// ### Why this is a type rather than four call sites
/// The inline `@` completion and the person picker are answering the same question — *which people
/// are there whose names start with this* — and there is no version of this app where they should
/// answer it differently. Two lookups written separately drift: one of them starts filtering out
/// archived people, or stops folding accents, or gets a limit raised, and for a while nobody notices
/// because you have to use both in the same minute to see it.
///
/// The lookups are also the only part of the panel that touches storage, so keeping them together is
/// what keeps everything else a pure function of what has been typed.
@MainActor
struct CaptureSuggestionSource {
    var services: AppServices?

    /// Existing tag slugs beginning with `query`.
    ///
    /// Synchronous, and reads them all. That is right here and would not be right for items: the
    /// whole tag table is small by construction — it is the vocabulary one person has invented for
    /// themselves — and a menu cannot await.
    func tagSlugs(matching query: String, limit: Int = 8) -> [String] {
        let folded = query.lowercased()
        let slugs = ((try? services?.tags.allTags()) ?? [])
            .map(\.slug)
            .filter { folded.isEmpty || $0.contains(folded) }
        return Array(slugs.prefix(limit))
    }

    /// Titles of items of the given kinds whose names begin with `query`.
    ///
    /// Goes through the search index rather than a store query, because "every person in the library"
    /// is a question with an unbounded answer and a menu only ever shows eight of them. Reading the
    /// whole table to display a handful is the shape of a stall that only appears once somebody has
    /// been using the app for a year.
    func titles(matching query: String, kinds: Set<ItemKind>, limit: Int = 8) async -> [String] {
        guard let services else { return [] }

        let suggestions = await services.search.titleSuggestions(prefix: query, limit: limit * 3)
        let matches = suggestions
            .compactMap { try? services.items.item(id: $0.id) }
            .filter { kinds.contains($0.kind) }
            .map(\.title)

        return Array(matches.prefix(limit))
    }

    /// The kinds `>` and the destination picker mean by "a place to file this".
    static let containerKinds: Set<ItemKind> = [.project, .area, .goal]
}

/// A search field and a list of what it found, for the pickers that need more than a menu.
///
/// A popover rather than a `Menu` for people and projects, and a `Menu` for tags, which is not an
/// inconsistency: a tag list is a closed vocabulary of a few dozen that somebody invented and can
/// recognise, and people and projects are an open list that has to be searched. Putting a search
/// field in a menu is possible and is worse than either.
struct CaptureSearchPicker: View {
    let prompt: String
    let symbolName: String
    /// Runs on every keystroke and on first appearance.
    let search: (String) async -> [String]
    let choose: (String) -> Void

    @State private var query = ""
    @State private var results: [String] = []
    @FocusState private var isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearching)
                .onSubmit { if let first = results.first { choose(first) } }

            if results.isEmpty {
                Text(query.isEmpty ? "Start typing a name" : "Nothing by that name")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.vertical, Theme.Spacing.tight)
            } else {
                ForEach(results, id: \.self) { title in
                    Button {
                        choose(title)
                    } label: {
                        Label(title, systemImage: symbolName)
                            .font(Theme.Text.metadata)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 240)
        .task(id: query) { results = await search(query) }
        .onAppear { isSearching = true }
    }
}
