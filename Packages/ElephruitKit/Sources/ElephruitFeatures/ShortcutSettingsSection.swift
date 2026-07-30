import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Keyboard shortcuts in Settings, and — more importantly — what went wrong with them.
///
/// The whole reason a native global shortcut was declined for a phase was that Carbon
/// "collides silently". This is the part that makes that untrue: a registration the system refused
/// is stated here, in a sentence, with what to do about it. A shortcut that silently does nothing
/// is the failure being avoided; one that says why is an inconvenience.
public struct ShortcutSettingsSection: View {
    private let registry: ShortcutRegistry
    private let globalResults: [ShortcutCommand: HotKeyRegistration]

    public init(
        registry: ShortcutRegistry,
        globalResults: [ShortcutCommand: HotKeyRegistration] = [:]
    ) {
        self.registry = registry
        self.globalResults = globalResults
    }

    public var body: some View {
        Section {
            LabeledContent("Quick Jot") {
                HStack(spacing: Theme.Spacing.small) {
                    if let binding = registry.binding(for: .quickCapture) {
                        Text(binding.display)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Not set").foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    globalStatusBadge
                }
            }

            ForEach(registry.collisions, id: \.binding) { collision in
                Label(collision.explanation, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
            }

            if let explanation = globalResults[.quickCapture]?.explanation {
                Label(explanation, systemImage: "keyboard.badge.exclamationmark")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.unresolvedLink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text(
                "Quick Jot works from any app. Elephruit asks the system for these keys and does "
                    + "not require the Accessibility permission."
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    @ViewBuilder
    private var globalStatusBadge: some View {
        switch globalResults[.quickCapture] {
        case .registered:
            Label("Working everywhere", systemImage: "checkmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("This shortcut works from any application.")
        case .alreadyClaimed, .unsupportedKey:
            Label("Not available", systemImage: "exclamationmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Colors.unresolvedLink)
        case .unbound, .none:
            EmptyView()
        }
    }
}
