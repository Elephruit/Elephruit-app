import ElephruitCore
import ElephruitFeaturesCore
import ElephruitModel
import SwiftUI

/// The hardware keyboard's claim on the iPad shell.
///
/// Every binding comes from the `ShortcutRegistry` — the same single source of truth the Mac's
/// menu bar reads, with the same one-owner rule enforced by the same test. Nothing here invents a
/// key. The commands appear in the iPad's ⌘-hold overlay, which is that platform's Help menu, and
/// each one acts on the focused window's own models via focused values, so a shortcut in one
/// window never moves another.
struct ElephruitMobileCommands: Commands {
    @FocusedValue(\.padShell) private var pad
    @FocusedValue(\.mobileShell) private var mobile
    @FocusedValue(\.focusedServices) private var services

    private var shortcuts: ShortcutRegistry { ShortcutRegistry.load(from: .standard) }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            // The same canonical action every swipe and context menu calls, on the record the
            // reading pane is showing — recoverable, so it needs no confirmation; permanent
            // deletion stays where it always was, in the Trash, named as itself.
            Button("Move to Trash") { trashReadingPaneRecord() }
                .shortcut(.moveToTrash, in: shortcuts)
                .disabled(trashableRecordID == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("Quick Capture") {
                if let pad {
                    pad.isCaptureVisible = true
                } else {
                    mobile?.isCaptureVisible = true
                }
            }
            .shortcut(.quickCapture, in: shortcuts)
            .disabled(pad == nil && mobile == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Search Everything") { go(.search) }
                .shortcut(.search, in: shortcuts)
                .disabled(pad == nil && mobile == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            // The Mac's own go-to set, in the Mac's own order and on the Mac's own keys.
            Button("Today") { go(.today) }
                .shortcut(.goToday, in: shortcuts)
            Button("Inbox") { go(.inbox) }
                .shortcut(.goInbox, in: shortcuts)
            Button("Notes") { go(.notes) }
                .shortcut(.goNotes, in: shortcuts)
            Button("Records") { go(.records) }
                .shortcut(.goRecords, in: shortcuts)
            Button("Calendar") { go(.calendar) }
                .shortcut(.goCalendar, in: shortcuts)
            Button("Reminders") { go(.reminders) }
                .shortcut(.goReminders, in: shortcuts)
            Button("Time") { go(.time) }
                .shortcut(.goTime, in: shortcuts)

            Divider()

            // The iPad's sidebar answers to the same key as the Mac's.
            Button("Toggle Sidebar") { pad?.requestSidebarToggle() }
                .shortcut(.toggleSidebar, in: shortcuts)
                .disabled(pad == nil)

            Button("Back") { goBack() }
                .shortcut(.goBack, in: shortcuts)
                .disabled(!canGoBack)
        }
    }

    /// One destination, named for both shells: the iPad selects the sidebar root that holds it,
    /// the phone selects the drawer row. Named in the compact vocabulary because that is the one
    /// the deep-link scheme and the drawer already speak — see `AdaptiveRootView.handleDeepLink`,
    /// which resolves the same way for the same reason.
    private func go(_ destination: MobileDestination) {
        if let pad {
            pad.select(PadShellModel.homeRoot(for: destination))
        } else {
            mobile?.select(destination)
        }
    }

    /// The item the reading pane is showing, when it is a kind Move to Trash recovers.
    private var trashableRecordID: UUID? {
        guard let pad, case .item(let id) = pad.detailPath.last else { return nil }
        return id
    }

    private func trashReadingPaneRecord() {
        guard let pad, let services, let id = trashableRecordID,
            let item = try? services.items.item(id: id)
        else { return }
        services.perform {
            try services.items.moveToTrash(item)
            services.noteRemoval(of: id)
        }
        pad.detailPath.removeLast()
    }

    private var canGoBack: Bool {
        if let pad { return !pad.contentPath.isEmpty || !pad.detailPath.isEmpty }
        if let mobile { return mobile.canPop }
        return false
    }

    private func goBack() {
        if let pad {
            if !pad.contentPath.isEmpty {
                pad.contentPath.removeLast()
            } else if !pad.detailPath.isEmpty {
                pad.detailPath.removeLast()
            }
        } else {
            mobile?.goBack()
        }
    }
}

// MARK: - Focused values

extension FocusedValues {
    @Entry var padShell: PadShellModel?
    @Entry var mobileShell: MobileShellModel?
    @Entry var focusedServices: AppServices?
}

// MARK: - Registry-driven shortcuts

extension View {
    /// Applies a registry binding, exactly as the Mac's `ShortcutBinding` does: read from the one
    /// place that decides, so a collision fails a test rather than silently shadowing another
    /// command.
    @ViewBuilder
    func shortcut(_ command: ShortcutCommand, in registry: ShortcutRegistry) -> some View {
        if let binding = registry.binding(for: command), let character = binding.key.first {
            keyboardShortcut(
                KeyEquivalent(character),
                modifiers: binding.modifiers.eventModifiers
            )
        } else {
            self
        }
    }
}

extension KeyModifiers {
    /// SwiftUI's spelling of the same facts.
    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}
