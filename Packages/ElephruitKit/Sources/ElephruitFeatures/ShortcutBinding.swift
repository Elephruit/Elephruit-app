import ElephruitCore
import SwiftUI

extension KeyModifiers {
    /// The SwiftUI equivalent.
    public var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}

extension View {
    /// Binds a view to whatever the registry says this command's keys are.
    ///
    /// The one way a shortcut reaches the interface. A literal `.keyboardShortcut("n", ...)` beside
    /// a menu item is a second, unenforced copy of a fact the registry already owns, and the two
    /// drift — which is exactly what the command palette's hard-coded glyph arrays used to do.
    ///
    /// A command the user has unbound gets no shortcut, which is the point of unbinding it.
    @ViewBuilder
    public func shortcut(_ command: ShortcutCommand, in registry: ShortcutRegistry) -> some View {
        if let binding = registry.binding(for: command) {
            self.keyboardShortcut(
                KeyEquivalent(Character(binding.key)),
                modifiers: binding.modifiers.eventModifiers
            )
        } else {
            self
        }
    }

    /// The same, for a command that may not exist.
    ///
    /// Only some modules have a binding of their own, and a call site forced to invent one to say
    /// "this one has no shortcut" is a call site that will eventually claim a key somebody was
    /// already using.
    @ViewBuilder
    public func shortcut(_ command: ShortcutCommand?, in registry: ShortcutRegistry) -> some View {
        if let command {
            self.shortcut(command, in: registry)
        } else {
            self
        }
    }
}
