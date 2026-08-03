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
        if item.kind == .task || item.kind == .reminder {
            navigation.select(.reminders)
            navigation.selectItem(item.id)
            return
        }

        var cursor = item.parent
        while let candidate = cursor {
            if candidate.kind == .project {
                navigation.select(.project(id: candidate.id, viewID: nil))
                navigation.selectItem(item.id)
                return
            }
            cursor = candidate.parent
        }
    }
}
