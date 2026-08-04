import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The shared keyboard-oriented completion list used by both global capture panels.
struct CaptureSuggestionList: View {
    let prefix: String
    let suggestions: [String]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text(prefix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.CaptureToken.accent)
                    Text(value)
                        .font(Theme.Text.metadata)
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.tight)
                .padding(.horizontal, Theme.Spacing.small)
                .background(
                    index == selection ? Theme.Colors.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
        }
        .accessibilityLabel(
            "\(suggestions.count) suggestions. Use the arrow keys, then Tab to accept."
        )
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
                                    .padding(.vertical, Theme.Spacing.tight)
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
