import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// A work item's title, editable where it sits.
///
/// Used by every view that draws a title, which is the point. Drawn as plain `Text` on the board
/// card and in the bug row, work created by the `+` button could be named nowhere at all — the `+`
/// makes an item with an empty title, and there was no way to give it one.
///
/// **It also reports its own focus to the model.** That is what stops the workspace's keyboard
/// shortcuts from firing while somebody is typing: a space would otherwise mark the item complete
/// and never reach the field.
struct WorkItemTitleField: View {
    @Environment(\.services) private var services
    let facts: TaskFacts
    let model: ProjectWorkspaceModel

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var isRenaming: Bool { model.renamingItemID == facts.id }

    var body: some View {
        Group {
            if isRenaming {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.rowTitle)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand { model.endRenaming() }
                    .onAppear {
                        draft = facts.title
                        isFocused = true
                    }
                    .onChange(of: isFocused) { _, focused in
                        model.isEditingText = focused
                        if !focused { commit() }
                    }
            } else {
                Text(facts.title.isEmpty ? "Untitled" : facts.title)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(
                        facts.title.isEmpty ? Theme.Colors.placeholderText : Theme.Colors.primaryText
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onDisappear {
            // A row scrolled out of view while focused would otherwise leave the gate stuck open,
            // and every shortcut in the workspace silently dead.
            if isRenaming { model.isEditingText = false }
        }
    }

    private func commit() {
        defer { model.endRenaming() }
        guard let services,
              let item = model.item(facts.id),
              let title = draft.nilIfBlank,
              title != facts.title
        else { return }
        try? services.workItems.setTitle(title, on: item)
        model.refresh()
    }
}
