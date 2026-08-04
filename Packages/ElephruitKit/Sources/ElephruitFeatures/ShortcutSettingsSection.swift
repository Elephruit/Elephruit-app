import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// Keyboard shortcuts in Settings — every command, rebindable, plus what went wrong globally.
///
/// The registry has had `setBinding`, `reset` and `resetAll` since it was written; this section
/// showed three of its thirty-odd commands as static text, so "you can rebind all of them" was a
/// model-layer fact and an interface fiction. Now each row is a recorder: click, press the keys,
/// done. Collisions are reported rather than prevented — refusing an assignment would make
/// swapping two shortcuts impossible without an intermediate state.
public struct ShortcutSettingsSection: View {
    private let services: AppServices
    private let globalResults: [ShortcutCommand: HotKeyRegistration]

    /// The commands offered to the whole system, in the order they appear.
    ///
    /// Three, and all three create something. A global shortcut is worth the collision risk only
    /// when the thing it does is wanted *while you are in another application* — which is true of
    /// capturing a thought, of putting a meeting in the calendar, of starting the clock on work as
    /// it begins, and true of almost nothing else.
    private static let globalCommands: [ShortcutCommand] = [.quickCapture, .quickLog, .newEvent]

    /// Everything else, in declaration order — which groups related commands the way the enum does.
    private static let applicationCommands: [ShortcutCommand] = ShortcutCommand.allCases
        .filter { !globalCommands.contains($0) }

    /// Which row is currently capturing keys. One at a time, app-wide within this window —
    /// two open recorders would both hear the same keystroke.
    @State private var recordingCommand: ShortcutCommand?

    public init(
        services: AppServices,
        globalResults: [ShortcutCommand: HotKeyRegistration] = [:]
    ) {
        self.services = services
        self.globalResults = globalResults
    }

    public var body: some View {
        Section {
            ForEach(Self.globalCommands, id: \.self) { command in
                row(for: command) {
                    statusBadge(for: command)
                }

                if let explanation = globalResults[command]?.explanation {
                    Label(explanation, systemImage: "exclamationmark.triangle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.unresolvedLink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Everywhere")
        } footer: {
            Text(
                "Quick Jot, Quick Log and New Event work from any app. Elephruit asks the system "
                    + "for these keys and does not require the Accessibility permission. A change "
                    + "here reaches the rest of the system at the next launch."
            )
            .font(Theme.Text.metadata)
            .foregroundStyle(Theme.Colors.tertiaryText)
        }

        Section {
            ForEach(Self.applicationCommands, id: \.self) { command in
                row(for: command) { EmptyView() }
            }
        } header: {
            Text("In Elephruit")
        } footer: {
            HStack {
                if !services.shortcuts.collisions.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        ForEach(services.shortcuts.collisions, id: \.binding) { collision in
                            Label(collision.explanation, systemImage: "exclamationmark.triangle")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.unresolvedLink)
                        }
                    }
                }
                Spacer()
                Button("Reset All to Defaults") {
                    services.shortcuts.resetAll()
                }
                .disabled(services.shortcuts.overrides.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func row(for command: ShortcutCommand, @ViewBuilder badge: () -> some View) -> some View {
        LabeledContent(command.title) {
            HStack(spacing: Theme.Spacing.small) {
                badge()

                if isOverridden(command) {
                    Button {
                        services.shortcuts.reset(command)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to \(command.defaultBinding.display)")
                    .accessibilityLabel("Reset \(command.title) to its default")
                }

                ShortcutRecorderButton(
                    command: command,
                    binding: services.shortcuts.binding(for: command),
                    isRecording: recordingCommand == command,
                    onBeginRecording: { recordingCommand = command },
                    onCapture: { captured in
                        services.shortcuts.setBinding(captured, for: command)
                        recordingCommand = nil
                    },
                    onCancel: { recordingCommand = nil }
                )
            }
        }
    }

    private func isOverridden(_ command: ShortcutCommand) -> Bool {
        services.shortcuts.overrides[command] != nil
    }

    @ViewBuilder
    private func statusBadge(for command: ShortcutCommand) -> some View {
        switch globalResults[command] {
        case .registered:
            Label("Working everywhere", systemImage: "checkmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Palette.green.color)
                .help("This shortcut works from any application.")
        case .alreadyClaimed, .unsupportedKey:
            Label("Not available", systemImage: "exclamationmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Colors.unresolvedLink)
                .help("Another application claimed these keys first.")
        case .unbound, .none:
            EmptyView()
        }
    }
}

// MARK: - The recorder

/// One shortcut, as a button that records the next keystroke when clicked.
///
/// While recording: any key with ⌘, ⌥ or ⌃ becomes the new binding; ⌫ alone removes the binding;
/// Escape keeps the old one. The event is consumed either way, so a half-typed shortcut cannot
/// also fire whatever it used to mean.
private struct ShortcutRecorderButton: View {
    let command: ShortcutCommand
    let binding: KeyBinding?
    let isRecording: Bool
    let onBeginRecording: () -> Void
    let onCapture: (KeyBinding?) -> Void
    let onCancel: () -> Void

    /// The installed key monitor, held so it can be removed the moment recording ends.
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Group {
                if isRecording {
                    Text("Type shortcut…")
                        .foregroundStyle(Theme.Colors.secondaryText)
                } else if let binding {
                    Text(binding.display)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("None")
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .help(
            isRecording
                ? "Press the new keys. ⌫ removes the shortcut, Escape keeps the old one."
                : "Click, then press the new keys."
        )
        .accessibilityLabel("\(command.title) shortcut")
        .accessibilityValue(binding?.display ?? "none")
        .onChange(of: isRecording) { _, nowRecording in
            nowRecording ? installMonitor() : removeMonitor()
        }
        .onDisappear(perform: removeMonitor)
    }

    private func toggle() {
        isRecording ? onCancel() : onBeginRecording()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // Swallowed: a keystroke being *recorded* must not also be *performed*.
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let modifiers = KeyModifiers(event.modifierFlags)

        // Escape keeps what was there.
        if event.keyCode == 53 {
            onCancel()
            return
        }

        // ⌫ alone unbinds — the registry treats "deliberately none" as distinct from "default".
        if event.keyCode == 51, modifiers.isEmpty {
            onCapture(nil)
            return
        }

        guard let key = Self.normalisedKey(for: event) else { return }

        // A bare letter is typing, not a shortcut. Requiring a real modifier is what stops the
        // recorder eating the first character of somebody's distracted sentence.
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else { return }

        onCapture(KeyBinding(key, modifiers))
    }

    /// The stored form of the pressed key, matching the conventions the defaults already use.
    private static func normalisedKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "\r"       // Return
        case 51: return "\u{8}"    // Delete, stored as backspace like `moveToTrash`'s default
        case 48: return "\t"
        case 49: return " "
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let first = characters.first
            else { return nil }
            return String(first).lowercased()
        }
    }
}

extension KeyModifiers {
    /// The registry's own modifier set, from an AppKit event.
    fileprivate init(_ flags: NSEvent.ModifierFlags) {
        var out: KeyModifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.control) { out.insert(.control) }
        self = out
    }
}
