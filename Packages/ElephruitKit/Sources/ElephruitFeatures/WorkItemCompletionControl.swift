import ElephruitDesign
import ElephruitModel
import SwiftUI

/// A compact completion control shared by Today and work-item surfaces.
struct WorkItemCompletionControl: View {
    let item: Item
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: symbolName)
                .font(.system(size: 13))
                .rowTint(controlColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .calmAnimation(value: item.status)
        .accessibilityLabel(item.status == .completed ? "Mark incomplete" : "Mark complete")
        .accessibilityIdentifier("workItem.toggle.\(item.id.uuidString)")
    }

    private var symbolName: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        default: item.isFlagged ? "circle.dotted.circle" : "circle"
        }
    }

    private var controlColor: Color {
        switch item.status {
        case .completed: Theme.Colors.completed
        case .cancelled: Theme.Colors.tertiaryText
        default: Theme.Colors.secondaryText
        }
    }
}
