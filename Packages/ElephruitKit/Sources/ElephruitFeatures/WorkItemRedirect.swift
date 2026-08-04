import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Sends linked work to the module that owns its full editing surface.
struct WorkItemRedirect: View {
    let item: Item
    let navigation: NavigationModel

    var body: some View {
        EmptyStateView(
            symbolName: "arrow.forward",
            headline: headline,
            message: "Opening “\(item.displayTitle)” where it lives."
        )
        .task(id: item.id) { redirect() }
        .accessibilityIdentifier("workItem.redirect")
    }

    private var headline: String {
        item.kind == .task || item.kind == .reminder ? "Opening in Reminders" : "Opening in Projects"
    }

    private func redirect() {
        // One rule, stated on the navigation model, shared with the command palette — the two
        // doors this mistake used to be made through.
        navigation.open(item)
    }
}

/// Sends a project selected as an item to its workspace Home.
///
/// The old path rendered a second project page here — a hidden landing surface that drifted from
/// the real one. Every door now leads to the same room.
struct ProjectHomeRedirect: View {
    let project: Item
    let navigation: NavigationModel

    var body: some View {
        EmptyStateView(
            symbolName: "arrow.forward",
            headline: "Opening in Projects",
            message: "Opening “\(project.displayTitle)” on its Home page."
        )
        .task(id: project.id) { navigation.open(project) }
        .accessibilityIdentifier("project.redirect")
    }
}
