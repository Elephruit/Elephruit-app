import Carbon.HIToolbox
import ElephruitCore
import Foundation

/// What happened when a shortcut was offered to the system.
///
/// A result rather than a thrown error, because a shortcut that could not be registered is not a
/// failure of the app — it is usually another application having claimed the keys first, which is
/// information the user needs and not a problem the app can solve.
public enum HotKeyRegistration: Sendable, Hashable {
    case registered(KeyBinding)

    /// Deliberately unbound by the user.
    case unbound

    /// The keys could not be turned into something the system understands.
    case unsupportedKey(KeyBinding)

    /// Another application already owns these keys.
    case alreadyClaimed(KeyBinding)

    public var isActive: Bool {
        if case .registered = self { return true }
        return false
    }

    /// One sentence for Settings. `nil` when there is nothing worth saying.
    public var explanation: String? {
        switch self {
        case .registered, .unbound:
            nil
        case .unsupportedKey(let binding):
            "\(binding.display) cannot be used as a system-wide shortcut. Try a different key."
        case .alreadyClaimed(let binding):
            "\(binding.display) is already used by another app, so Elephruit did not take it. "
                + "Choose different keys, or quit whatever is holding them."
        }
    }
}

/// Registers a shortcut with the system, so it works while another application is frontmost.
///
/// ### Why Carbon
/// The alternative is a global event monitor, which needs the **Accessibility** permission — a large
/// ask for a note-taking app, and one people are right to be wary of. `RegisterEventHotKey` works
/// inside the sandbox with **no entitlement and no permission prompt at all**, which
/// `docs/10-phase-a-scope.md` established and this finally uses. It is an old API and it is the
/// right one: it asks the window server for a specific combination and is told yes or no.
///
/// ### Why the collision objection no longer stands
/// The recorded reason for not doing this was that Carbon "collides silently". It does not have to:
/// `RegisterEventHotKey` returns an error when the combination is already claimed, so the failure is
/// **detectable**, and a detected failure that is reported in Settings is the opposite of a silent
/// one. That is the whole difference between this and what was declined. See ADR 0008.
@MainActor
public final class GlobalHotKeyCenter {
    /// Handlers by hot-key identifier.
    ///
    /// Static because the C callback the system invokes cannot capture context — it is a bare
    /// function pointer. `@MainActor` isolation is what keeps that safe rather than an
    /// `unchecked` annotation: Carbon delivers these on the main thread, and nothing else touches it.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var registrations: [ShortcutCommand: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private(set) public var results: [ShortcutCommand: HotKeyRegistration] = [:]

    public init() {}

    deinit {
        // `registrations` cannot be read here — deinit is not main-actor isolated — so unregistering
        // is the owner's job via `unregisterAll()`. The owner is the app, which lives as long as the
        // process, so the only path that skips it is termination, where the system reclaims anyway.
    }

    /// Registers one command, replacing any previous registration for it.
    ///
    /// Idempotent: calling it again with the same binding unregisters and re-registers, which is
    /// what a preference change needs and what makes double-firing impossible.
    @discardableResult
    public func register(
        _ command: ShortcutCommand,
        binding: KeyBinding?,
        action: @escaping () -> Void
    ) -> HotKeyRegistration {
        unregister(command)

        guard let binding else {
            results[command] = .unbound
            return .unbound
        }

        guard let keyCode = Self.virtualKeyCode(for: binding.key) else {
            results[command] = .unsupportedKey(binding)
            return .unsupportedKey(binding)
        }

        Self.installEventHandlerIfNeeded()

        let identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            keyCode,
            Self.carbonModifiers(binding.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            results[command] = .alreadyClaimed(binding)
            return .alreadyClaimed(binding)
        }

        Self.handlers[identifier] = action
        registrations[command] = (identifier, reference)
        results[command] = .registered(binding)
        return .registered(binding)
    }

    public func unregister(_ command: ShortcutCommand) {
        guard let existing = registrations.removeValue(forKey: command) else { return }
        UnregisterEventHotKey(existing.ref)
        Self.handlers.removeValue(forKey: existing.id)
        results.removeValue(forKey: command)
    }

    public func unregisterAll() {
        for command in Array(registrations.keys) { unregister(command) }
    }

    // MARK: - Carbon plumbing

    private static let signature: OSType = 0x454C_5048  // 'ELPH'

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }

                // Carbon delivers hot keys on the main thread, which is what makes this sound.
                return MainActor.assumeIsolated {
                    guard let action = GlobalHotKeyCenter.handlers[identifier.id] else {
                        return OSStatus(eventNotHandledErr)
                    }
                    action()
                    return noErr
                }
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    private static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { out |= UInt32(shiftKey) }
        if modifiers.contains(.option) { out |= UInt32(optionKey) }
        if modifiers.contains(.control) { out |= UInt32(controlKey) }
        return out
    }

    /// Maps a character to its virtual key code.
    ///
    /// Only the keys a shortcut can actually use. A layout-independent lookup would need
    /// `TISGetInputSourceProperty`, and for the ASCII letters and digits — which is all the registry
    /// offers — the ANSI codes are the same positions on every Latin layout.
    static func virtualKeyCode(for key: String) -> UInt32? {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            " ": kVK_Space,
        ]
        guard let code = table[key.lowercased()] else { return nil }
        return UInt32(code)
    }
}
