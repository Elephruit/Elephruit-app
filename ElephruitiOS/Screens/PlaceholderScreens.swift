import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// The screens the shell promises, before each one is built.
///
/// Every placeholder is honest about being one: the shell, the drawer, the routes, the
/// restoration, and the deep links are real, and each screen replaces its placeholder in its
/// own reviewed pass — one module at a time, photographed. A placeholder that pretended to be
/// a screen would make the review pass unable to say what changed.
private struct PlaceholderScreen: View {
    let title: String
    let symbolName: String

    var body: some View {
        EmptyStateView(
            symbolName: symbolName,
            headline: title,
            message: "This screen arrives in its own reviewed pass."
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RemindersScreen: View {
    var body: some View { PlaceholderScreen(title: "Reminders", symbolName: "checkmark.circle") }
}

// MARK: - Routed screens

struct ProjectScreen: View {
    let projectID: UUID
    var body: some View { PlaceholderScreen(title: "Project", symbolName: "folder") }
}

struct PersonScreen: View {
    let personID: UUID
    var body: some View { PlaceholderScreen(title: "Record", symbolName: "person") }
}

struct ReminderListScreen: View {
    enum Source: Hashable {
        case smartList(UUID)
        case builtIn(String)
    }

    let source: Source
    var body: some View { PlaceholderScreen(title: "List", symbolName: "list.bullet") }
}
