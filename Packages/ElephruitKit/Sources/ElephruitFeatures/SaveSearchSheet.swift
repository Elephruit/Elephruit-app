import ElephruitCore
import ElephruitDesign
import SwiftUI

/// A `String` that `.sheet(item:)` will accept.
///
/// SwiftUI's item-based presentation needs `Identifiable`, and a bare `String?` is not. Wrapping is
/// less machinery than a parallel `isPresented` Boolean that can disagree with the value it guards.
struct IdentifiedString: Identifiable, Hashable {
    let value: String
    var id: String { value }

    init(_ value: String) {
        self.value = value
    }
}

/// Naming a search so it can be kept.
///
/// Small and modal *because it is a commitment* — something is about to appear in the sidebar and
/// stay there. That is different from running a search, which is why running one is not a sheet and
/// this is.
struct SaveSearchSheet: View {
    let initialName: String
    let queryText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        initialName: String,
        queryText: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.queryText = queryText
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Save Search")
                .font(Theme.Text.title)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                TextField("Name", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(save)
                    .accessibilityLabel("Saved search name")

                // The query is shown, not hidden behind the name. What was saved should be
                // legible later, when the name alone has stopped being a reminder.
                Text(queryText)
                    .font(Theme.Text.metadata)
                    .monospaced()
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 360)
        .onAppear { isNameFocused = true }
        .accessibilityIdentifier("search.saveSheet")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
    }
}
